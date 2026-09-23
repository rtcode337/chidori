defmodule TazunaWeb.DatasetsLive do
  @moduledoc """
  データ収集 —— 他のアプリで使うデータを、Chiezo に集めさせる依頼を出す画面です。

  **この画面は溜まったものを見せません。** 読むのは使う側のアプリ（食事処なら
  travel-log の地図）で、こちらが持つのは**依頼と進み具合**だけです ——
  同じものを 2 つの画面で見せると、どちらが本当の状態なのか読めなくなります。

  **押しても走りません。** 作られる収集は止まった状態で、動き出すのは Chiezo の
  管理画面で有効にしたときだけです（この画面から AI が勝手に動くことはありません）。

  **収集の状態は覚えません。** 開いたときに Chiezo から読み、押したら送り直して
  読み直します —— 正は向こうが持っているものなので、写しを置くと食い違います。
  """

  use TazunaWeb, :live_view

  import TazunaWeb.Collect
  import TazunaWeb.CollectPanel
  import TazunaWeb.PartitionMap

  alias Tazuna.Datasets
  alias Tazuna.Jst

  # 区画の一覧に出す数。**数百あるので全部は並べない**（並びは次に回ってくる順なので、
  # 先頭だけ見えれば足りる）
  @shown_partitions 60

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "データ収集",
       datasets: Datasets.list(),
       backends: [],
       # 巡回ごとに選んだ相手。**サーバー側で覚える** —— 覚えないと、状態が届いた
       # 拍子にフォームが描き直されて、選んだところが元の値に戻る
       picks: %{},
       asking: false,
       asked: nil,
       # 地図で選んでいる区画。**選ぶのと頼むのを分ける** —— 押した瞬間に走ると、
       # どこを押したのか確かめる前に AI が動く
       picked: nil
     )
     |> assign(state: empty_state())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    key = Datasets.valid_key(params["view"])
    dataset = Datasets.get(key)

    socket =
      socket
      |> assign(view: key, dataset: dataset, picks: %{}, asked: nil, picked: nil)
      |> assign(state: empty_state())

    # **開いたら読みに行く。** 読むのは Chiezo に置いた収集の状態だけで、
    # 何も作りません —— 開いただけで向こうに収集ができるのは驚きが大きい
    {:noreply,
     if connected?(socket) do
       socket
       |> assign(state: %{empty_state() | status: :loading})
       |> start_async(:read, fn -> Datasets.read(dataset) end)
       |> start_async(:backends, &Datasets.backends/0)
     else
       socket
     end}
  end

  @impl true
  # **依頼を送って、そのまま読み直す。** 送っただけでは画面が変わらないので、
  # 効いたのかどうかが分かりません
  def handle_event("collect", params, socket) do
    dataset = socket.assigns.dataset
    choices = merged_picks(socket.assigns.picks, params)

    {:noreply,
     socket
     |> assign(state: %{socket.assigns.state | pushing: true, reason: nil})
     |> start_async(:push, fn -> {Datasets.push(dataset, choices), Datasets.read(dataset)} end)}
  end

  # 選び直したら、その場で覚える。**送るのは押したときだけ**。
  #
  # **ここでは覚えているほうを勝たせません。** この事象そのものが選び直しなので、
  # 前に覚えた値を優先すると、一度覚えた欄を二度と変えられなくなります。
  def handle_event("pick_sweep", params, socket),
    do: {:noreply, assign(socket, picks: sweep_choices(params))}

  def handle_event("reload", _params, socket) do
    dataset = socket.assigns.dataset

    {:noreply,
     socket
     |> assign(state: %{socket.assigns.state | status: :loading})
     |> start_async(:read, fn -> Datasets.read(dataset) end)}
  end

  # **地図で区画を選ぶ。** ここでは頼みません —— 押した先に何があるのか
  # （件数・見終わったか）を読んでから頼めるように、選ぶのと頼むのを分けてあります
  def handle_event("pick_partition", %{"key" => key}, socket) do
    picked = if socket.assigns.picked == key, do: nil, else: key

    {:noreply, assign(socket, picked: picked, asked: nil)}
  end

  def handle_event("unpick_partition", _params, socket),
    do: {:noreply, assign(socket, picked: nil)}

  # **この区画を先に調べて、を頼む。** 定時の巡回の進み具合にも次の予定にも触りません
  def handle_event("focus_partition", %{"key" => key} = params, socket) do
    dataset = socket.assigns.dataset
    note = partition_note(key, params["note"])

    {:noreply,
     socket
     |> assign(asking: true, asked: nil)
     |> start_async(:ask, fn -> Datasets.focus_partition(dataset, key, note) end)}
  end

  # 定時の巡回とは別に、1 回だけ頼む
  def handle_event("ask", %{"note" => note}, socket) do
    dataset = socket.assigns.dataset

    case String.trim(note || "") do
      "" ->
        {:noreply, socket}

      written ->
        {:noreply,
         socket
         |> assign(asking: true, asked: nil)
         |> start_async(:ask, fn -> Datasets.focus(dataset, written) end)}
    end
  end

  @impl true
  def handle_async(:read, {:ok, result}, socket),
    do: {:noreply, assign(socket, state: applied(socket.assigns.state, result))}

  def handle_async(:read, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, state: crashed(socket.assigns.state))}

  # 送った結果と読み直した結果の両方を見る。**断られたら黙って済ませない** ——
  # 読み直しは成功するので、結果だけ見ていると「押したのに何も変わらない」としか映らず、
  # 送れていないことに気づけません
  def handle_async(:push, {:ok, {pushed, read}}, socket) do
    state = %{applied(socket.assigns.state, read) | pushing: false}

    {:noreply,
     assign(socket,
       state:
         case pushed do
           :ok -> state
           {:error, reason} -> %{state | reason: reason}
         end
     )}
  end

  def handle_async(:push, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, state: %{crashed(socket.assigns.state) | pushing: false})}

  def handle_async(:ask, {:ok, result}, socket),
    do: {:noreply, assign(socket, asking: false, asked: result)}

  def handle_async(:ask, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, asking: false, asked: {:error, :collection_crashed})}

  def handle_async(:backends, {:ok, backends}, socket),
    do: {:noreply, assign(socket, backends: backends)}

  def handle_async(:backends, {:exit, _reason}, socket), do: {:noreply, socket}

  # **まだ何も読んでいない状態。** 「収集が無い」と区別する —— 読めていないのに
  # 「まだ作られていません」と出すと、押した人は作り直そうとする
  defp empty_state,
    do: %{collection: nil, status: :idle, reason: nil, checked_at: nil, pushing: false}

  defp applied(state, {:ok, collection}),
    do: %{
      state
      | collection: collection,
        status: :ready,
        reason: nil,
        checked_at: DateTime.utc_now()
    }

  defp applied(state, {:error, reason}),
    do: %{state | status: :ready, reason: reason}

  defp crashed(state), do: %{state | status: :ready, reason: :collection_crashed}

  @doc """
  いつ読んだか。**開くたびに取り直さない**ので、いま見ているものの古さが読めないと困ります。
  """
  def checked_text(%{checked_at: at}) when at != nil, do: "最後に取得: #{Jst.format(at)}"
  def checked_text(_state), do: "まだ取得していません"

  @doc """
  いまの状態を1文で言う。**断られた理由はそのまま出します**。
  """
  def status_message(%{reason: reason}) when not is_nil(reason), do: reason_text(reason)
  def status_message(%{pushing: true}), do: "Chiezo に依頼を送っています…"
  def status_message(%{status: :loading}), do: "Chiezo に問い合わせています…"

  def status_message(%{collection: nil, status: :idle}), do: "Chiezo の状態を読んでいません。"

  def status_message(%{collection: nil}),
    do: "この収集は、まだ Chiezo にありません。押すと、この内容で依頼します（止まった状態で作られます）。"

  def status_message(%{collection: %{enabled: false}}),
    do:
      "収集はありますが、Chiezo 側で止まっています。" <>
        "Chiezo の管理画面の「集める」で有効にすると、決まった間隔で集め始めます。"

  def status_message(%{collection: %{docs: 0}}),
    do: "有効になっています。まだ 1 件も溜まっていないので、最初の取り込みを待っています。"

  def status_message(_state), do: "有効になっています。溜まったものは Chiezo のソースとして引けます。"

  @doc "ボタンの文字。**まだ無いときと、あるときで頼むことが違います**。"
  def collect_label(%{pushing: true}), do: "送っています…"
  def collect_label(%{collection: nil}), do: "収集を依頼する"
  def collect_label(_state), do: "収集の設定を更新"

  @doc """
  押すと何が起きるかの一言。**走らせはしない**ことを、押す前に読めるようにします。
  """
  def push_note(%{collection: nil}),
    do:
      "押すと、この内容で Chiezo に収集を作ります。**作られるのは止まった状態**なので、" <>
        "押しただけで AI が動くことはありません。"

  def push_note(_state),
    do:
      "押すと、tazuna が持っている抽出の指定・依頼文・区画の割り方・巡回を Chiezo へ" <>
        "送り直します（**走らせはしません**。Chiezo の画面で手で直したものは上書きされます）。"

  @doc "割り込みの届き具合。**断られたことも出します**。"
  def ask_message(:ok), do: "Chiezo に頼みました。定時の巡回とは別に 1 回だけ走ります。"
  def ask_message({:error, reason}), do: reason_text(reason)
  def ask_message(_asked), do: nil

  @doc """
  区画への割り込みの指示文。**必ず区画の名前で始めます**。

  区画は別に渡していて Chiezo がそちらを見て範囲を差し込みますが、
  **指示文だけを読んだ人には、どこ宛てか分かりません**。
  """
  def partition_note(key, note) do
    case String.trim(note || "") do
      "" -> "#{key} の区画を先に調べてください。"
      written -> "#{key} の区画について。#{written}"
    end
  end

  @doc """
  travel-log がスポットにするときに読む項目（集めるものごとに違う）。
  """
  def field_rows(%{module: module}), do: module.fields()

  @doc "区画の一覧に出す数。"
  def shown_partitions, do: @shown_partitions

  @doc """
  選んでいる区画の 1 行ぶん。**選ばれていなければ nil**。

  一覧から探し直さずに済むように、鍵で引いてそのまま返します ——
  地図で押した区画の件数も「見終わったか」も、台帳にしかありません。
  """
  def picked_row(rows, key) when is_binary(key), do: Enum.find(rows, &(&1.key == key))
  def picked_row(_rows, _key), do: nil

  @doc """
  抽出の指定（機械で引く条件）。**何で埋まったのかが読めないと、間違いを
  AI のせいにしてしまいます** —— 名前と座標は辞典から引いたものです。

  **Chiezo が持っているものを出します**（依頼した後は向こうの画面から直せるので、
  tazuna の雛形を出し続けると食い違う）。
  """
  def extract_text(%{collection: %{extract: spec}}) when is_map(spec),
    do: Jason.encode!(spec, pretty: true)

  def extract_text(%{dataset: dataset}), do: Jason.encode!(dataset.module.extract(), pretty: true)

  @doc "区画の割り方。**座標で割るので、鍵は矩形になります**。"
  def partition_text(%{collection: %{partition: spec}}) when is_map(spec),
    do: Jason.encode!(spec, pretty: true)

  def partition_text(%{dataset: dataset}),
    do: Jason.encode!(dataset.module.partition(), pretty: true)

  @doc """
  巡回ごとの依頼文。**回ごとに頼むことが違う**ので、1 つの文だけを出すと、
  実際に走っている内容と画面が食い違います。

  **Chiezo が持っているものを先に出します**（送った後は向こうが正）。
  """
  def sweep_prompts(%{collection: %{sweeps: sweeps}} = assigns) when is_list(sweeps) do
    written =
      for sweep <- sweeps,
          text = sweep_prompt_of(sweep, assigns),
          text != "",
          do: {sweep.name, text}

    if written == [], do: default_prompts(assigns), else: written
  end

  def sweep_prompts(assigns), do: default_prompts(assigns)

  # 巡回に書かれていなければ、収集ぜんたいの依頼文がその回の文になる（Chiezo の決まり）
  defp sweep_prompt_of(sweep, assigns) do
    case Map.get(sweep, :prompt) do
      text when is_binary(text) and text != "" -> text
      _ -> if sweep[:use_extract], do: "", else: collection_prompt(assigns)
    end
  end

  defp collection_prompt(%{state: %{collection: %{prompt: prompt}}}) when is_binary(prompt),
    do: prompt

  defp collection_prompt(_assigns), do: ""

  defp default_prompts(%{dataset: dataset}) do
    [{"ざっと見る", dataset.module.scan_prompt()}, {"整理", dataset.module.survey_prompt()}]
  end
end
