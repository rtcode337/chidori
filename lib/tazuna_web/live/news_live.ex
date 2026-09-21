defmodule TazunaWeb.NewsLive do
  @moduledoc """
  最新情報の一覧。集めるのは Chiezo の「集める」層で、この画面は依頼と閲覧だけを持ちます。

  収集は数十秒から数分かかることがあるので、押した人に再読み込みをさせません。
  結果は `Tazuna.News` からの通知で届きます。

  **話題ごとにタブで分けます。** 集めるものも溜まるものも話題ごとに別なので、
  1 つに混ぜると、どちらの状態を見ているのか読めなくなります。タブに並ぶのは
  `Tazuna.Topics` の話題そのもので、並びも定義のとおりです。

  **一覧の並びは重要度です。** 先頭に出すのは要約の巡回が書いたまとめで、その下に
  1 件ずつを重要度の高い順に並べます —— どちらも収集の側が付けたもので、
  この画面では何も判断しません。
  """

  use TazunaWeb, :live_view

  import TazunaWeb.Collect
  import TazunaWeb.CollectPanel
  import TazunaWeb.Report

  alias Tazuna.Digest
  alias Tazuna.Digest.Scheduler
  alias Tazuna.Jst
  alias Tazuna.News
  alias Tazuna.Notify
  alias Tazuna.Notify.Setting
  alias Tazuna.Notify.Settings
  alias Tazuna.Ntfy
  alias Tazuna.Topics

  @impl true
  def mount(_params, _session, socket) do
    # 相手の一覧は**繋がってから、待たずに**引く。画面の中で同期に引くと、Chiezo が
    # 遅いあいだページが固まる（選択肢が無くても記事は読めるので、待つ価値が無い）
    socket =
      assign(socket,
        topics: Topics.list(),
        backends: [],
        picks: %{},
        asking: false,
        digest_message: nil,
        notify_form: nil
      )

    socket =
      if connected?(socket) do
        start_async(socket, :backends, fn -> Tazuna.Relations.ai_backends() end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    topic = pick_topic(socket.assigns.topics, params["view"])

    # 話題を切り替えたら購読も付け替える。付け替えないと、見ていない話題の
    # 収集結果でこの画面が書き換わる
    if connected?(socket) do
      if previous = socket.assigns[:topic] do
        News.unsubscribe(previous.collection)
      end

      if topic do
        News.subscribe(topic.collection)
        # Chiezo の側は勝手に進むので、開くたびにいまの状態を取り直す
        News.refresh(News.server(topic.collection))
      end
    end

    {:noreply,
     assign(socket,
       topic: topic,
       page_title: if(topic, do: "最新情報 — #{topic.name}", else: "最新情報"),
       news: if(topic, do: News.current(News.server(topic.collection)), else: News.empty()),
       notify_form: notify_form(topic)
     )}
  end

  @impl true

  # **選んだところはサーバーが覚える。** 覚えないと、収集の状態が届いた拍子に
  # フォームが描き直され、選んだ相手が元の値へ戻る（選んだつもりで押すと、
  # いま入っている値がそのまま送り返される）
  def handle_event("pick_sweep", params, socket) do
    {:noreply, assign(socket, picks: sweep_choices(params))}
  end

  # **押す口はここだけ。** 収集がまだ無ければ作り、あれば設定を送り直して読み直す ——
  # 関連図と同じ形にしてある。ボタンを役割ごとに並べていた頃は、どれを押せば
  # 何が起きるのかが押す前に読めなかった（しかも走らせる口が混ざっていた）
  def handle_event("collect", params, socket) do
    topic = socket.assigns.topic
    picks = merged_picks(socket.assigns.picks, params)
    with_server(socket, &News.setup(&1, topic, picks))
  end

  # 通知先を書き換える。**押したときだけ送る**ので、ここでは保存だけ
  # **書いたそばから覚える。** 覚えないと、収集の状態が届いた拍子にフォームが
  # 描き直され、**書きかけの通知先が消えます**（保存したつもりで消えたように見える）
  def handle_event("edit_notify", %{"setting" => attrs}, socket) do
    topic = socket.assigns.topic

    {:noreply, assign(socket, notify_form: notify_form(topic, attrs))}
  end

  def handle_event("save_notify", %{"setting" => attrs}, socket) do
    topic = socket.assigns.topic

    case Settings.put(topic.collection, attrs) do
      {:ok, _setting} ->
        {:noreply,
         socket |> assign(notify_form: notify_form(topic)) |> put_flash(:info, "通知先を保存しました。")}

      {:error, changeset} ->
        # **書いたものは消さない。** 時刻の書き方を間違えただけで通知先まで
        # 書き直させられると、直すたびに全部を入れ直すことになる
        {:noreply,
         socket
         |> assign(notify_form: to_form(changeset, as: :setting))
         |> put_flash(:error, first_error(changeset))}
    end
  end

  # **まとめを作らせて知らせる。** 整理を 1 回起こしてから要約を起こす ——
  # 整理されていないものでまとめさせると、宣伝も重複も読み物に入る。
  # **数分かかる**ので、待つのは押した人ではなく Task の側
  def handle_event("digest_now", _params, socket) do
    topic = socket.assigns.topic
    Digest.start(topic)

    {:noreply, assign(socket, digest_message: "整理から始めています…（数分かかります）")}
  end

  # **いまあるまとめをもう一度知らせる。** 作り直さずに送るだけ
  def handle_event("notify", _params, socket) do
    topic = socket.assigns.topic
    news = socket.assigns.news

    {:noreply,
     case Notify.deliver_latest(topic.collection, news, force: true) do
       {:ok, :sent} -> put_flash(socket, :info, "まとめを知らせました。")
       {:ok, :nothing_to_send} -> put_flash(socket, :error, "知らせるまとめがまだありません。")
       {:error, reason} -> put_flash(socket, :error, notify_error(reason))
     end}
  end

  # **この場で 1 回だけ頼む。** 定時の巡回は決まった仕事しかしないので、
  # 「この話の続きを追って」のような頼みごとの行き先がここしかない
  def handle_event("ask", %{"note" => note}, socket) do
    topic = socket.assigns.topic

    case String.trim(note) do
      "" ->
        {:noreply, put_flash(socket, :error, "頼みたいことを書いてください。")}

      written ->
        {:noreply,
         socket
         |> assign(asking: true)
         |> start_async(:ask, fn -> News.ask_focus(topic.collection, written) end)}
    end
  end

  defp with_server(socket, fun) do
    if topic = socket.assigns.topic, do: fun.(News.server(topic.collection))
    {:noreply, socket}
  end

  @impl true
  def handle_async(:ask, {:ok, :ok}, socket) do
    {:noreply,
     socket
     |> assign(asking: false)
     |> put_flash(:info, "Chiezo へ頼みました。次の巡回とは別に走ります。")}
  end

  def handle_async(:ask, {:ok, {:error, reason}}, socket),
    do: {:noreply, socket |> assign(asking: false) |> put_flash(:error, ask_error(reason))}

  # 起きなかったことは黙って捨てない。押した人には確かめようがない
  def handle_async(:ask, _result, socket),
    do: {:noreply, socket |> assign(asking: false) |> put_flash(:error, ask_error(:unknown))}

  def handle_async(:backends, {:ok, list}, socket) when is_list(list),
    do: {:noreply, assign(socket, backends: list)}

  # 引けなくても記事は読める。**選べないだけ**
  def handle_async(:backends, _result, socket), do: {:noreply, socket}

  @impl true
  # まとめを作らせている最中の一言。**収集の状態とは別に受ける** ——
  # 状態に混ぜると、届くたびに画面ぜんたいが書き換わる
  def handle_info({:digest_progress, collection, message}, socket) do
    topic = socket.assigns.topic

    if topic && collection == topic.collection do
      {:noreply, assign(socket, digest_message: message)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:news_updated, news}, socket) do
    topic = socket.assigns.topic

    # 話題を切り替えた直後は、前の話題の結果が遅れて届くことがある
    if topic && news.name == topic.collection do
      {:noreply, assign(socket, news: news)}
    else
      {:noreply, socket}
    end
  end

  @doc """
  どの話題を見るか。**知らない名前が来たら先頭に落とします** ——
  消した話題のリンクを踏んだだけで空白の画面を出す理由が無い。
  """
  def pick_topic(topics, view) do
    Enum.find(topics, &(&1.collection == view)) || List.first(topics)
  end

  @doc """
  重要度の高い順に並べる。**同じ重さのものは新しい順のまま**（並べ替えは安定なので、
  Chiezo が返した並びがそのまま残る）。

  重要度を付けるのは整理の巡回で、読んだうえでの判断です。ここで並べ替えずに
  出すと、その判断が画面に現れません —— 新しい順に並ぶだけなら、印を付けた意味が
  一覧から消えます。

  **低いものも消しません** —— 重要度は並びであって、ふるい分けではない。
  """
  def sorted_articles(%{articles: articles}), do: Enum.sort_by(articles, &(-&1.importance))

  def sorted_articles(_news), do: []

  @doc "重要度の見え方。0〜2 の 3 段で、高いものだけ色を変える。"
  def importance_class(2), do: "priority"
  def importance_class(0), do: "later"
  def importance_class(_importance), do: "standard"

  def importance_label(2), do: "優先"
  def importance_label(0), do: "急がない"
  def importance_label(_importance), do: "注目"

  @doc """
  いまの状態を1文で言う。押した人が次に何をすればよいか分かる言い方にする。
  """
  def status_message(%{configured: false}),
    do: "Chiezo の場所が設定されていません。`CHIEZO_BASE_URL` を渡すと使えるようになります。"

  def status_message(%{status: :loading}), do: "Chiezo に問い合わせています。"

  def status_message(%{reason: reason}) when not is_nil(reason), do: reason_text(reason)

  def status_message(%{collection: nil}),
    do:
      "まだ Chiezo に収集を依頼していません。「収集を依頼する」を押すと、" <>
        "止めた状態の収集が Chiezo に作られます。"

  def status_message(%{collection: %{enabled: false}}),
    do:
      "収集は Chiezo にありますが、まだ止まっています。" <>
        "動かすかどうかは Chiezo 側で決めるので、Chiezo の管理画面の「集める」で有効にしてください。"

  def status_message(%{collection: %{docs: 0}}),
    do: "収集は動いていますが、まだ1件も溜まっていません。"

  def status_message(_news), do: nil

  @doc """
  AI に頼んでいる本文。

  **依頼した後は Chiezo が持っているものを出す** —— 向こうの画面から直せるので、
  tazuna の雛形を出し続けると、実際に投げている文と画面が食い違う。
  まだ依頼していないときは、これから送る雛形を出す。
  """
  def prompt_text(%{collection: %{prompt: prompt}}, _topic)
      when is_binary(prompt) and prompt != "",
      do: prompt

  def prompt_text(_news, topic), do: News.prompt(topic)

  def prompt_note(%{collection: nil}), do: "「収集を依頼する」を押すと、この内容で Chiezo に頼みます。"

  def prompt_note(_news),
    do: "いま Chiezo が持っている内容です。直すのは Chiezo の管理画面の「集める」から。"

  @doc "いまの通知先。フォームに載せます。"
  def notify_setting(nil), do: Settings.changeset("")
  def notify_setting(%{collection: collection}), do: Settings.changeset(collection)

  @doc "知らせられる状態か。**押せない口は出さない**。"
  def can_notify?(nil), do: false
  def can_notify?(%{collection: collection}), do: match?({:ok, _ready}, Ntfy.ready(collection))

  @doc "最後に知らせた時刻。押した結果がここに出ます。"
  def last_sent_text(nil), do: nil

  def last_sent_text(%{collection: collection}) do
    case Notify.last_sent_at(collection) do
      nil -> "まだ知らせていません。"
      at -> "最後に知らせたのは #{Jst.format(at)}。"
    end
  end

  @doc false
  def notify_error(:ntfy_topic_missing), do: "この話題の通知先が決まっていません。"
  def notify_error(:ntfy_unavailable), do: "ntfy に接続できませんでした。"
  def notify_error({:ntfy_status, status}), do: "ntfy が #{status} を返しました。"
  def notify_error(reason), do: "知らせられませんでした（#{inspect(reason)}）。"

  defp first_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {_field, messages} -> messages end)
    |> List.first() || "書いた内容を保存できませんでした。"
  end

  @doc """
  通知の設定の一言。**押す前に、届くのかどうかが読めるように**。

  黙って何もしないと、設定を間違えているのか、まだまとめが無いだけなのかを
  区別できません。**書き先まで出します** —— どこへ書けばよいか分からないと、
  設定しようがありません。
  """
  def notify_note(nil), do: nil

  def notify_note(%{collection: collection}) do
    case Ntfy.ready(collection) do
      {:ok, {base, ntfy_topic}} ->
        "「知らせる」を押すと、#{base} の「#{ntfy_topic}」へまとめを送ります。"

      {:error, :ntfy_topic_missing} ->
        "この話題の通知先が決まっていません（下の欄にトピック名を書くと送れます）。"
    end
  end

  # 通知の設定のフォーム。**組むのはここだけ** —— 描くたびに DB から組み直すと、
  # 書きかけが消える
  defp notify_form(nil), do: nil

  defp notify_form(%{collection: collection}, attrs \\ %{}) do
    to_form(Settings.changeset(collection, attrs), as: :setting)
  end

  @doc """
  設定の枠の見出し。**画面の名前に合わせます** —— 「設定」とだけ書くと、
  何の設定なのかがタブを切り替えた後に読めません。
  """
  def settings_title(%{name: name}), do: "#{name}の設定"
  def settings_title(_topic), do: "設定"

  @doc """
  知らせる時刻の一言。**次にいつ知らせるのかまで出します** ——
  時刻だけ書かれていても、それが今日のぶんとして残っているのかは読めません。
  """
  def digest_note(nil), do: nil

  def digest_note(%{collection: collection}) do
    setting = Settings.get(collection)

    case Setting.digest_times(setting) do
      [] ->
        "時刻を書くと、その時刻に整理→要約を起こして知らせます" <>
          "（空なら自分からは回りません。08:00 でも 0800 でも 8 でも読めます）。"

      times ->
        "この時刻に、整理を 1 回起こしてからまとめを作らせて知らせます（JST）: " <>
          Enum.map_join(times, "、", fn {hour, minute} ->
            String.pad_leading("#{hour}", 2, "0") <>
              ":" <> String.pad_leading("#{minute}", 2, "0")
          end)
    end
  end

  @doc """
  定時の回がどうなったか。**結果まで出します** —— 誰も見ていない時刻に走る回なので、
  「作らせた時刻」だけだと、知らせが来なかったのか、そもそも走っていないのかが
  読めません（実際、ntfy の場所が空のまま走って、静かに送れずにいました）。

  **「前回の」と断ります。** これは記録で、いまの状態ではありません ——
  理由の文は現在形なので（「Chiezo 側で止まっています」）、断らないと、
  ずっと前に止まった回の理由が**いまの状態として読まれます**（実際に読まれました。
  そのときは収集も要約も動いていました）。いまの状態は `digest_state_text/2`。
  """
  def last_digest_text(nil), do: nil

  def last_digest_text(%{collection: collection}) do
    setting = Settings.get(collection)

    case {setting.last_digest_at, setting.last_digest_result} do
      {nil, _result} -> "まだ作らせていません。"
      {_at, result} when is_binary(result) and result != "" -> "前回の定時の回: " <> result
      {at, _result} -> "前回の定時の回: #{Jst.format(at)}。"
    end
  end

  @doc """
  定時の回の、いまの見通し。**記録とは別に出します**。

  下に並ぶのは前に走った回の記録なので、それだけだと「いま動いているのか、
  止まったままなのか」が読めません —— 止まった回の理由が現在形で残るぶん、
  なおさら取り違えます。

  **止まっているときは、次の回も止まると言い切ります**（動かせるのは Chiezo 側
  だけなので、待っていても直りません）。
  """
  def digest_state_text(news, topic)

  def digest_state_text(_news, nil), do: nil

  def digest_state_text(%{collection: %{enabled: false}}, _topic),
    do: "いまは Chiezo 側で止まっています。戻すまでは、次の定時の回もここで止まります。"

  def digest_state_text(%{collection: %{}}, topic) do
    case Scheduler.next(topic) do
      nil -> nil
      at -> "いまは動いています（次の定時の回は #{Jst.format(at)}）。"
    end
  end

  def digest_state_text(_news, _topic), do: nil

  @doc """
  押す口の文字。**何を待っているのかまで出します** ——
  「送っています…」だけだと、押せていないのと区別が付きません。
  """
  def collect_label(%{status: :loading}), do: "送っています…"
  def collect_label(%{collection: nil}), do: "収集を依頼する"
  def collect_label(_news), do: "収集の設定を更新"

  @doc """
  収集がどうなっているかの一言。**押す前に、何が起きるのかが読めるように**。
  """
  def collection_note(%{collection: nil, configured: false}),
    do: "Chiezo の場所（CHIEZO_BASE_URL）が設定されていないので、まだ依頼できません。"

  def collection_note(%{collection: nil}),
    do: "まだ Chiezo に収集がありません。押すと、止まった状態の収集が作られます。"

  def collection_note(%{collection: %{enabled: false}}),
    do: "Chiezo 側で止まっています。動かすのは Chiezo の画面からです。"

  def collection_note(_news), do: "押すと、いまの設定を Chiezo へ送り直します（走らせはしません）。"

  @doc false
  # 断られた理由。**数字だけ出しても、押した人には次に何をすればよいか分からない**
  def ask_error(:collection_disabled), do: "この収集は Chiezo 側で止まっています。"
  def ask_error(:not_requested), do: "まだ収集を依頼していません。"
  def ask_error(:chiezo_busy), do: "Chiezo がいま別の依頼を抱えています。少し待ってください。"
  def ask_error(:chiezo_not_configured), do: "Chiezo の場所が設定されていません。"
  def ask_error({:chiezo_refused, _status, reason}) when is_binary(reason), do: reason
  def ask_error(_reason), do: "Chiezo へ頼めませんでした。"

  @doc """
  その話題を何で集めているかの一言。**機械で引いているかどうかが読めないと、
  抜けを AI のせいにしてしまいます**。
  """
  def sweep_note(%{feeds: [_ | _] = feeds}) do
    "見出しは #{length(feeds)} 本の配信元から機械的に取り込みます（AI は呼びません）。" <>
      "整理と要約だけが AI の仕事です。"
  end

  def sweep_note(_topic),
    do: "この話題には配信元を付けていないので、集めるところから AI に頼みます。"

  @doc """
  巡回ごとの依頼文。**回ごとに頼むことが違う**ので、1 つの文だけを出すと、
  実際に走っている内容と画面が食い違います。
  """
  def sweep_prompts(%{} = topic) do
    for sweep <- News.sweeps(topic),
        text = Map.get(sweep, :prompt),
        is_binary(text) and text != "",
        do: {sweep.name, text}
  end

  def sweep_prompts(_topic), do: []
end
