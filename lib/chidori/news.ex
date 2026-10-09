defmodule Chidori.News do
  @moduledoc """
  ニュースの収集状態を持つ入れ物です。

  集めるのは Chidori ではなく Chiezo の「集める」層です。Chidori は収集を
  依頼して、溜まったものを読むだけにしてあります —— 定期実行の時計も、AI の
  呼び出しも、集めたものの置き場も、すでに Chiezo が持っているためです。

  依頼して作られる収集は必ず止まった状態で、動き出すのは Chiezo の管理画面で
  有効にしたときだけです。だからこの画面から AI が勝手に動くことはありません。

  Chiezo への問い合わせは `Task.Supervisor` の下で動かし、この GenServer では
  待ちません。結果は `subscribe/1` した先へ届きます。

  **話題ごとに 1 つ立ちます。** 「ニュース」と「技術」では集める相手も溜まるものも
  別なので、1 つの入れ物に混ぜると、片方を読み直したときにもう片方の状態まで
  入れ替わります。立てるのは開かれたときで、話題（`Chidori.Topics`）が増えても
  誰も開いていないものまで常駐しないようにしてあります。
  """

  use GenServer

  require Logger

  alias Chidori.Topics
  alias Chidori.Chiezo
  alias Chidori.Http
  alias Chidori.Jst
  alias Chidori.News.Events
  alias Chidori.News.Interests
  alias Chidori.News.Report

  @user_agent "chidori"

  # Chiezo は LAN 内なので短くてよい。ただし「いま集めさせる」は AI が動くので長い
  @request_timeout 15_000
  @run_timeout 600_000
  @connect_timeout 5_000

  # AI を動かす操作だけ間隔を空ける。読み直しは相手が手元にいるので絞らない
  @min_run_interval_ms 30_000

  # 画面に出す件数。Chiezo 側の上限は 50（超えて頼むと 0 件で返る）
  @samples 20

  # まとめが引いた記事を引き直すときの同時本数と待ち時間。
  # 相手は LAN の中なので短くてよく、遅れた 1 本で画面を止めない
  @cited_concurrency 5
  @cited_timeout 5_000

  # 通知に添える出典の本数。全部は添えない —— 通知は畳まれて先頭しか
  # 見えないことがあるので、URL が並ぶと要旨が押し出される
  @notice_sources 3

  # 収集の既定。名前は Chiezo のソース名になるので英小文字・数字・_ だけ
  @default_collection "tazuna_news"

  # 巡回の時計。**引き方で変える** —— 機械で引く回は AI の枠を使わないので短くてよく、
  # 判断の要る回は長い（頻繁に読み直しても、中身はそれほど変わらない）
  # 巡回の間隔の既定（分）。**話題ごとに上書きできます**（`Chidori.Topics` の `every`）
  @feed_minutes 60
  @collect_minutes 360
  # **整理は定時でも回す。** まとめの直前にもう 1 回起こすが、それだけにすると
  # 落とす仕事も外を当たる仕事もまとめの回数ぶんしか走らない。
  # **間隔はどの収集も同じ**（`Chidori.SweepNames.tidy_minutes/0`。話題ごとに変えない。
  # 設定ページから変えられるので、実行時に読む）

  # 割り込みを頼む先。**専用の 1 本は置かない** —— 頼みごとは「落として」
  # 「印を直して」がほとんどで、その力を持つのは整理の回だけ
  @focus_sweep Chidori.SweepNames.tidy()

  # まとめに付ける印。**同じ収集の中に、記事とまとめが混ざる**ので、
  # これが無いと画面でも通知でも見分けられない
  @digest_tag "まとめ"
  # 重要度の印。AI が付け直す（Chidori 側の語の一致より、読んだうえでの判断が先）
  @importance_tag "重要度"

  # **どれだけ反応されているか**の印。重要度とは別の軸です —— あちらは
  # 「いま読む価値があるか」で、こちらは「界隈がその話をしているか」。
  # 混ぜると、**話題になっていないが効く 1 件**と**効かないが沸いている 1 件**が
  # 同じ印になり、どちらの読み方もできなくなります。
  #
  # **数は持ちません。** 配信元は反応の数を配らないので、付けるのは読んだ AI の
  # 判断です（同じ出来事が何本の媒体で報じられているか、人気枠から入っているか）。
  @buzz_tag "話題度"

  # **興味トピックとの近さ**の印（0〜100。整理の回が付ける）。重要度とも話題度とも
  # 別の軸 —— あちらは「誰にとっても読む価値があるか」「界隈が話しているか」で、
  # こちらは「この読者が選んだ語にどれだけ近いか」。興味トピックを選んでいなければ付けない
  @interest_tag "興味度"

  # 興味トピックの要約に付ける印と、それを書く巡回。**ふつうのまとめと印を分ける** ——
  # 同じ「まとめ」の印にすると、画面でも通知でも 2 本が 1 つの並びに混ざる
  @interest_digest_tag "興味のまとめ"
  @interest_digest_sweep Chidori.SweepNames.interest_digest()

  # 記事一覧の窓。**公開の新しい順**に、直近 `@window_hours` 時間に出たものを並べる。
  # 収集の見本（`?samples=`）は `updated_at` の新しい順で、整理が触るたびに進む ——
  # そのまま並べると一覧は「直近の整理で AI が触った順」になり、いつ出た記事かと
  # 関係が無くなっていた。候補は新着の口から多めに取り（`@window_candidates`）、
  # 窓が薄いときは新しい順に `@window_min` 件までは埋める
  @window_hours 72
  @window_min 20
  @window_max 80
  @window_candidates 200

  # トピックから引く記事の上限（語 1 つあたり）。**見に行く画面なので、全部は要らない**
  @tagged_limit 60

  # 話題に関心が書かれていないときの言い方
  @default_interest "暮らし・社会・経済への影響が大きいこと"

  defstruct collection_name: nil,
            status: :idle,
            collection: nil,
            articles: [],
            # まとめ（`@digest_tag` の付いた1件）。**記事と別に持つ** ——
            # 一覧に混ぜると、まとめが記事のふりをして並ぶ
            digests: [],
            # 興味トピックの要約（`@interest_digest_tag`）。ふつうのまとめとは別の並び
            interest_digests: [],
            checked_at: nil,
            reason: nil,
            task: nil,
            # 押して送っている最中か。**開いたときの読み直しと区別する** ——
            # どちらも読み込み中（`:loading`）なので、一緒にすると読むだけのときに
            # 「送っています」と出る
            pushing: false,
            last_run_at: nil

  @doc """
  話題 1 つぶんの入れ物を立てます。

  名前を渡せるようにしてあるのは、テストが本番と同じ入れ物を共有すると、
  片方のテストの収集状態がもう片方へ漏れるためです。
  """
  def start_link(options) do
    collection = Keyword.get(options, :collection) || collection_name()
    name = Keyword.get(options, :name, via(collection))
    GenServer.start_link(__MODULE__, collection, name: name)
  end

  @doc """
  その話題の入れ物。**まだ無ければ立てます** ——
  開かれた話題のぶんだけ立てるので、起動時にはまだ無い。
  """
  def server(collection) when is_binary(collection) do
    case DynamicSupervisor.start_child(
           Chidori.News.Supervisor,
           {__MODULE__, collection: collection}
         ) do
      {:ok, _pid} -> via(collection)
      {:error, {:already_started, _pid}} -> via(collection)
      # 立てられなくても画面は出す（状態が読めないだけ）
      {:error, _reason} -> via(collection)
    end
  end

  defp via(collection), do: {:via, Registry, {Chidori.News.Registry, collection}}

  @doc """
  いまの収集状態。画面はこれだけを見ます。

  **話題が読めないときも形の揃った空を返します** —— 画面はこれだけを見るので、
  落ちると開けなくなる。
  """
  def current(server) do
    GenServer.call(server, :current)
  catch
    :exit, _reason -> empty()
  end

  @doc """
  Chiezo に溜まっているものを読み直します。AI は動きません。
  """
  def refresh(server) do
    GenServer.cast(server, {:command, :refresh})
  end

  @doc """
  収集そのものを Chiezo へ依頼します。作られるのは止まった状態です。

  **話題は呼ぶ側が渡します。** 依頼の本文も相手も話題の設定から作りますが、
  それを取りに行くのはここではありません —— DB を読むのは画面のある側の仕事で、
  ここから読むと、問い合わせを動かしている Task から読むことになります
  （テストの sandbox では持ち主のいないプロセスになり、読めません）。
  """
  def request_collection(server, topic \\ nil) do
    GenServer.cast(server, {:command, {:request, topic}})
  end

  @doc """
  画面で選んだ設定（巡回ごとの相手）を送り直します。**走らせはしません** ——
  走らせると、定時の巡回がその回ぶん先送りになります。

  **依頼のときと同じものを送ります。** 作るときの `POST` は「もうある」で断られるので、
  これが無いと、Chidori 側で依頼文や巡回を直しても永遠に届きません。
  """
  def push_settings(server, topic, choices \\ %{}) do
    GenServer.cast(server, {:command, {:push, topic, choices}})
  end

  @doc """
  収集を用意します —— **無ければ作り、あれば設定を送り直します**。

  画面の押す口が 1 つなので、こちらで場合分けします。作るときの `POST` は
  「もうある」で断られるだけなので、続けて送り直せば、どちらの状態から押しても同じ
  ところへ着きます。**走らせはしません**（走らせると、定時の巡回がその回ぶん先送りになる）。
  """
  def setup(server, topic, choices \\ %{}) do
    GenServer.cast(server, {:command, {:setup, topic, choices}})
  end

  @doc """
  その場で 1 回だけ、頼みたいことを Chiezo へ割り込ませます。

  **定時の巡回とは別の道**で、進み具合にも次の予定にも触りません。
  巡回の依頼文は書き換わりません（この回だけの文として渡ります）。

  **走らせるのは整理の回です**（`focus_sweep/0`）。頼まれるのはたいてい
  「これは宣伝だから落として」「この印が違う」で、**落とす力と印を付け直す力を
  持つのはこの回だけ**だからです。
  """
  def ask_focus(collection, note, titles \\ []) do
    case chiezo_base_url() do
      nil ->
        {:error, :chiezo_not_configured}

      # 画面から頼んだ 1 回（止めている収集でも走らせる。`Chiezo.by_hand/1`）
      base ->
        Chidori.Chiezo.by_hand(fn ->
          Chidori.Chiezo.focus(base, collection, note, titles, focus_sweep_of(collection))
        end)
    end
  end

  @doc """
  割り込みを走らせる巡回。

  **専用の 1 本は置きません。** 置いていた頃は時計を持たないだけの空の巡回で、
  依頼文を持たないので収集ぜんたいの文（集める回の文）で走っていました ——
  頼みごとは「落として」「印を直して」がほとんどなのに、**その力を持つのは
  整理の回だけ**なので、頼んだとおりには動きません。
  """
  def focus_sweep, do: @focus_sweep

  @doc """
  その話題で割り込みを走らせる巡回。**整理を置かない話題**（配信元を持たず、先を探す回
  だけで集めるお笑いイベント）は先を探す回で走らせる —— 無い巡回を名指しすると Chiezo が断る。
  """
  def focus_sweep_of(collection) do
    if only_look_ahead?(Chidori.Topics.get(collection)),
      do: Chidori.SweepNames.survey(),
      else: @focus_sweep
  end

  @doc """
  予定を待たずに1回集めさせます。止まっている収集は Chiezo が断ります。
  """
  def run_now(server) do
    GenServer.cast(server, {:command, :run})
  end

  @doc """
  収集状態の変化を受け取ります。LiveView が接続時に呼びます。

  **話題ごとに分けて配ります** —— 1 本にまとめると、見ていない話題が集め終わった
  拍子に、いま開いている画面まで書き換わります。
  """
  def subscribe(collection \\ nil) do
    Phoenix.PubSub.subscribe(Chidori.PubSub, topic(collection || collection_name()))
  end

  @doc "受け取るのをやめます。話題を切り替えたときに呼びます。"
  def unsubscribe(collection) when is_binary(collection) do
    Phoenix.PubSub.unsubscribe(Chidori.PubSub, topic(collection))
  end

  @doc """
  話題を開いていないときに画面へ渡す空の状態。
  """
  def empty do
    %{
      name: nil,
      status: :idle,
      collection: nil,
      articles: [],
      digests: [],
      interest_digests: [],
      checked_at: nil,
      reason: nil,
      configured: chiezo_base_url() != nil
    }
  end

  defp topic(collection), do: "news:" <> collection

  @doc """
  Chiezo に置く収集の名前。`CHIDORI_NEWS_COLLECTION` で変えられます。
  """
  def collection_name do
    case System.get_env("CHIDORI_NEWS_COLLECTION", "") |> String.trim() do
      "" -> @default_collection
      name -> name
    end
  end

  @doc """
  誰に頼むか。`CHIDORI_NEWS_BACKEND` / `_MODEL` / `_EFFORT` で指定します。

  **これは収集ぜんたいの下敷き**で、巡回ごとの相手は画面の表から選びます
  （巡回に書いてあればそちらが勝ちます）。

  **未指定なら Chiezo の既定にまかせます**（有効にしてある相手の先頭）。
  どの相手に頼むかは本来 Chiezo 側の判断なので、Chidori から名指しするのは
  「この収集だけは別の相手に」と決めたときだけです。依頼した後は Chiezo の
  管理画面からも変えられます。
  """
  def backend_settings do
    %{
      backend: env("CHIDORI_NEWS_BACKEND"),
      model: env("CHIDORI_NEWS_MODEL"),
      effort: env("CHIDORI_NEWS_EFFORT")
    }
  end

  defp env(name) do
    case System.get_env(name, "") |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  @doc """
  Chiezo のルートURL。未設定ならこの機能は使えません。
  """
  def chiezo_base_url do
    case System.get_env("CHIEZO_BASE_URL") do
      nil -> nil
      "" -> nil
      value -> value |> String.trim() |> String.trim_trailing("/")
    end
  end

  @doc """
  Chiezo の画面へ渡すリンク。相対パスをルートURLに繋ぐだけです。
  """
  def chiezo_url(path) when is_binary(path) do
    case chiezo_base_url() do
      nil -> nil
      base -> base <> path
    end
  end

  def chiezo_url(_path), do: nil

  @impl true
  def init(collection) do
    {:ok, %__MODULE__{collection_name: collection}}
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, public(state), state}
  end

  @impl true
  def handle_cast({:command, _command}, %__MODULE__{status: :loading} = state) do
    {:noreply, state}
  end

  def handle_cast({:command, command}, state) do
    cond do
      chiezo_base_url() == nil ->
        {:noreply, broadcast(%{state | status: :unavailable, reason: :chiezo_not_configured})}

      command == :run and throttled?(state) ->
        {:noreply, broadcast(%{state | reason: :too_soon})}

      true ->
        name = state.collection_name
        base = chiezo_base_url()

        task =
          Task.Supervisor.async_nolink(Chidori.TaskSupervisor, fn ->
            perform(command, base, name)
          end)

        state = %{
          state
          | status: :loading,
            reason: nil,
            task: task,
            pushing: command != :refresh
        }

        state = if command == :run, do: %{state | last_run_at: now_ms()}, else: state

        {:noreply, broadcast(state)}
    end
  end

  @impl true
  def handle_info({ref, result}, %__MODULE__{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, broadcast(apply_result(state, result))}
  end

  # タスクが落ちたときも必ず状態を戻す。戻さないと :loading のまま固まり、
  # 二度と押せなくなる
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %__MODULE__{task: %Task{ref: ref}} = state
      ) do
    Logger.error("ニュースの収集タスクが落ちた: #{inspect(reason)}")
    {:noreply, broadcast(apply_result(state, {:error, :collection_crashed}))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp apply_result(state, {:ok, %{collection: collection, articles: articles} = read}) do
    %{
      state
      | status: :ready,
        collection: collection,
        articles: articles,
        digests: Map.get(read, :digests, []),
        interest_digests: Map.get(read, :interest_digests, []),
        checked_at: DateTime.utc_now(),
        reason: nil,
        task: nil,
        pushing: false
    }
  end

  defp apply_result(state, {:error, reason}) do
    # 一度でも読めていれば、前に読めたものを消さずに残す
    status = if state.checked_at, do: :stale, else: :unavailable
    %{state | status: status, reason: reason, task: nil, pushing: false}
  end

  defp throttled?(%__MODULE__{last_run_at: nil}), do: false
  defp throttled?(%__MODULE__{last_run_at: at}), do: now_ms() - at < @min_run_interval_ms

  defp now_ms, do: System.monotonic_time(:millisecond)

  @doc false
  # まとめを作らせている最中の一言。**収集の状態とは別の知らせ**にする ——
  # 状態に混ぜると、届くたびに画面ぜんたいが書き換わる
  def broadcast_digest(collection, message) when is_binary(collection) do
    Phoenix.PubSub.broadcast(
      Chidori.PubSub,
      topic(collection),
      {:digest_progress, collection, message}
    )
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(
      Chidori.PubSub,
      topic(state.collection_name),
      {:news_updated, public(state)}
    )

    state
  end

  # 画面へ渡す形。内部で持っているタスクや計測用の時刻は出さない
  defp public(state) do
    %{
      # どの話題のものか。**画面が取り違えないための印** —— 話題を切り替えた直後に
      # 前の話題の結果が届くことがある
      name: state.collection_name,
      status: state.status,
      collection: state.collection,
      articles: state.articles,
      digests: state.digests,
      interest_digests: state.interest_digests,
      checked_at: state.checked_at,
      reason: state.reason,
      pushing: state.pushing,
      configured: chiezo_base_url() != nil
    }
  end

  # ---- Chiezo とのやり取り ------------------------------------------------

  defp perform(:refresh, base, name), do: read(base, name)

  defp perform({:request, topic}, base, name) do
    with :ok <- create_collection(base, name, Interests.attach(topic)) do
      read(base, name)
    end
  end

  defp perform({:setup, topic, choices}, base, name) do
    case create_collection(base, name, Interests.attach(topic)) do
      :ok -> perform({:push, topic, choices}, base, name)
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform({:push, topic, choices}, base, name) do
    # **断られても読み直す。** 読み直しは成功するので、結果だけ見ていると
    # 「押したのに何も変わらない」としか映らない（送れていないことに気づけない）
    # **興味トピックを載せてから組む**（整理と興味の要約の依頼文に書き込むため）
    attrs = attrs(name, Interests.attach(topic), choices)

    case {Chidori.Chiezo.patch(base, name, attrs), read(base, name)} do
      {:ok, read} -> read
      {{:error, reason}, _read} -> {:error, reason}
    end
  end

  # 「いま集める」は画面から押したときだけ来る（止めている収集でも走らせる）
  defp perform(:run, base, name) do
    with :ok <- Chidori.Chiezo.by_hand(fn -> run_collection(base, name) end) do
      read(base, name)
    end
  end

  # 一覧を先に見るのは、404 の意味を切り分けるため —— 収集そのものが無い Chiezo と、
  # まだ依頼していないだけの状態は、1件の口だけでは同じ 404 に見える
  defp read(base, name) do
    with {:ok, collections} <- list_collections(base) do
      case Enum.find(collections, &(&1["name"] == name)) do
        nil -> {:ok, %{collection: nil, articles: []}}
        found -> detail(base, name, found)
      end
    end
  end

  # 溜まった件数は収集の定義には入っていない。集めたものは長期記憶へ焼かれるので、
  # 数はソース表の側にある（まだ 1 度も焼いていなければソースごと無い）
  defp docs_count(base, name) do
    with {:ok, %{status: 200, body: body}} <- get(base <> "/v1/sources"),
         {:ok, %{"sources" => sources}} <- Jason.decode(body),
         %{"docs" => docs} <- Enum.find(sources, &(&1["name"] == name)) do
      docs
    else
      _ -> 0
    end
  end

  defp list_collections(base) do
    case get(base <> "/v1/collect") do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"collections" => collections}} when is_list(collections) -> {:ok, collections}
          _ -> {:error, :chiezo_unexpected_body}
        end

      # 収集の口そのものが無い Chiezo（層を足す前の版）
      {:ok, %{status: 404}} ->
        {:error, :collect_unsupported}

      # 溜め先が設定されていない Chiezo
      {:ok, %{status: 503}} ->
        {:error, :collect_disabled}

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  defp detail(base, name, fallback) do
    case get(base <> "/v1/collect/" <> name <> "?samples=#{@samples}") do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{} = detail} ->
            collection =
              detail
              |> to_collection()
              |> Map.put(:docs, docs_count(base, name))

            {:ok,
             %{
               collection: collection,
               articles: window(base, name, detail["recent"]),
               digests: digests(base, name, detail["recent"]),
               interest_digests: interest_digests(base, name)
             }}

          _ ->
            {:error, :chiezo_unexpected_body}
        end

      # 一覧には出ていたのに引けないときは、一覧のぶんだけで出す
      {:ok, %{status: _status}} ->
        {:ok, %{collection: to_collection(fallback), articles: []}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  defp create_collection(base, name, topic) do
    payload = Jason.encode!(attrs(name, topic, %{}))

    case post(base <> "/v1/collect", payload, @request_timeout) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      # 既にあるなら依頼は済んでいる。読み直せば状態が出る
      {:ok, %{status: 409}} -> :ok
      {:ok, %{status: 404}} -> {:error, :collect_unsupported}
      {:ok, %{status: 503}} -> {:error, :collect_disabled}
      {:ok, %{status: status}} -> {:error, {:chiezo_status, status}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
    end
  end

  @doc """
  Chiezo へ送る収集の設定ひとそろい。**依頼のときも、送り直すときも同じもの**を送ります
  —— 別々に組み立てると、片方だけ直る。

  `choices` は画面で選んだ巡回ごとの相手。
  """
  def attrs(name, topic, choices \\ %{}) do
    Map.merge(
      %{
        name: name,
        description: description(topic),
        prompt: collection_prompt(topic),
        interval_minutes: @collect_minutes,
        # **育てる側で置く。** 溜めるだけなら足すほうでよいが、この収集は
        # 重要度やタグを後から付け直す（それができるのは育てる側だけ）
        # **流れ。** 時とともに増えるものを追っていて、直近だけが対象 ——
        # 古いものは順に要らなくなるので、Chiezo に期限で落としてもらう
        # （落とさないと、この収集は永久に増え続ける）。
        # **終わったら要らなくなる話題も流れ**（技術イベントは、これから開かれるものを
        # 次々と集めていく）。ただし**期限は外す**（`keep_days: 0`）—— Chiezo の期限は
        # 配信日で数えるので、半年先のイベントを募集が出た日から 30 日で落とすことになる。
        # 終わったものは整理の回に落とさせる（`ages_out?`）
        kind: "flow",
        feed: feed_spec(topic),
        sweeps: with_choices(sweeps(topic), choices),
        requested_by: "chidori"
      }
      |> Map.merge(if(Topics.ages_out?(topic), do: %{}, else: %{keep_days: 0}))
      # **絵は Chiezo に縮めて持たせる**（書いた話題だけ。`Chidori.Topics` の `thumbs`）
      |> Map.merge(if(thumbs = Map.get(topic || %{}, :thumbs), do: %{thumbs: thumbs}, else: %{})),
      # 収集ぜんたいの相手。**巡回に書いてなければここへ落ちる**（Chiezo 側の決まり）。
      # 名指ししないものは送らない —— null を送ると「指定しない」と同じだが、
      # 依頼の本文に空の項目が並ぶと、何を決めて何を任せたのかが読めない
      backend_settings() |> Enum.reject(&(elem(&1, 1) == nil)) |> Map.new()
    )
  end

  # 収集ぜんたいの依頼文（巡回に書いていなければここへ落ちる）。作品を育てる話題では
  # 先を探す回の文 —— 記事を集める文を置くと、名指ししない回が記事を溜め始める
  defp collection_prompt(topic) do
    cond do
      works = Topics.works(topic) -> works.survey_prompt(interest_of(topic))
      only_look_ahead?(topic) -> hd(look_ahead_sweeps(topic, true)).prompt
      true -> prompt(topic)
    end
  end

  @doc """
  その話題の巡回。**引き方の違う仕事を、別の時計で回します**。

  1 つの文で全部を頼むと、どの回も同じ薄さの仕事になります —— 集めるのと、
  漏れを探すのと、読んで重要度を付けるのと、まとめるのは別の仕事です。

  - 見出し / 集める —— 溜める回。配信元があれば機械で引き、無ければ AI に集めさせる
  - 整理 —— 前回から入ったものを読んで印を付け直し、要らないものを落とし、
    **そのうえで**配信元が拾わなかったものを外から探して足す
  - 要約 —— 前回から入ったものを 1 件にまとめて残す（通知と画面で読むもの）。
    **時計を持ちません** —— 起こすのは Chidori で、その直前に整理をもう 1 回回します
    （整理されていないものでまとめさせない）

  **漏れを探す回と分けていません。** 分けていた頃は、重なった時間ぶんを 2 度読ませて
  いました（外を当たる回は直近 4 時間、印を付け直す回は直近 6 時間）—— 画家の収集が
  同じ理由で 1 本にまとめてあります（あちらは同じ区画を 3 回渡していた）。

  **割り込みの専用の 1 本は置きません。** 頼みごとは整理の回で走ります
  （`focus_sweep/0`）—— 落とす力と印を付け直す力を持つのはその回だけだからです。
  """
  def sweeps(topic) do
    cond do
      works = Topics.works(topic) -> work_sweeps(topic, works)
      true -> article_sweeps(topic)
    end
  end

  # 1 件 = 1 作品の話題（映画。`Chidori.Topics` の `works`）。**配信元も集める回も
  # 持たない** —— 記事を溜めると単位が記事に戻る。先を探して足す回と、今あるものを
  # 育てる回だけで回す。整理は**先を探す回が 1 回走るまで待つ**（空の収集を相手に走らない）
  defp work_sweeps(topic, works) do
    survey = %{
      name: Chidori.SweepNames.survey(),
      interval_minutes: works.survey_minutes(),
      only_new: true,
      prompt: works.survey_prompt(interest_of(topic))
    }

    [
      survey,
      %{
        name: @focus_sweep,
        after: survey.name,
        interval_minutes: Chidori.SweepNames.tidy_minutes(),
        prompt: refine_prompt(topic)
      }
    ] ++ digest_sweeps(topic)
  end

  # **配信元を持たず、先を探す回で集める話題**（お笑いイベント）は、**先を探す回だけ**
  # にする。溜める回を置くとニュースを集める文で記事を溜め始め、整理を置くと「上に無い
  # ものを探して足す」が先を探す回と重なって AI の回が倍になる。終わったものを消す・
  # タグを揃えるのは先を探す回が引き受ける（`standalone`）
  defp article_sweeps(topic) do
    if only_look_ahead?(topic),
      do: look_ahead_sweeps(topic, true) ++ digest_sweeps(topic),
      else: fed_sweeps(topic)
  end

  defp fed_sweeps(topic) do
    first = intake(topic)

    [first] ++
      [
        %{
          name: @focus_sweep,
          # **溜める回が 1 回走るまで待つ**（`after`）。巡回はそれぞれ別の時計で動くので、
          # 有効にした直後は両方が「いますぐ」になり、整理が空の収集を相手に走ることがある
          # （ワーカーを経由する整理が、機械収集より先に取り込みへ届く）
          after: first.name,
          interval_minutes: Chidori.SweepNames.tidy_minutes(),
          prompt: refine_prompt(topic)
        }
      ] ++ digest_sweeps(topic) ++ look_ahead_sweeps(topic)
  end

  # 配信元を持たず、先を探す回だけで集める話題か
  defp only_look_ahead?(topic) when is_map(topic),
    do: Map.get(topic, :feeds) in [nil, []] and look_ahead_of(topic) != nil

  defp only_look_ahead?(_topic), do: false

  # 先を探す回の作り方。`look_ahead: true` は技術イベントのもの（`Chidori.News.Events`）、
  # モジュールを書けばそのモジュールのもの（お笑いイベント）
  defp look_ahead_of(%{look_ahead: true}), do: Events
  defp look_ahead_of(%{look_ahead: module}) when is_atom(module) and module != nil, do: module
  defp look_ahead_of(_topic), do: nil

  # 先の月を探す回（技術イベント。`Chidori.Topics` の `look_ahead`）。巡回の名前は
  # 「情報収集」—— 足りないものを外から探して足す仕事。
  # **足すだけ**（今あるものは整理が見る）。**整理を置かない話題**（`standalone`）では、
  # 終わったものを消してタグを揃えるのもこの回なので、足すだけにしない
  defp look_ahead_sweeps(topic, standalone \\ false) do
    case look_ahead_of(topic) do
      nil ->
        []

      module ->
        prompt = module.look_ahead_prompt(interest_of(topic), interests_of(topic))

        [
          %{
            name: Chidori.SweepNames.survey(),
            interval_minutes: module.look_ahead_minutes(),
            only_new: !standalone,
            prompt:
              if(standalone and function_exported?(module, :housekeeping, 0),
                do: prompt <> "\n" <> module.housekeeping(),
                else: prompt
              )
          }
        ]
    end
  end

  # 要約の回。**要約を作らない話題には置かない**（`Chidori.Topics.digest?/1`）——
  # 置いたままだと、時刻を決めた拍子に読まれない要約を作らせて枠を食う
  defp digest_sweeps(topic) do
    if Chidori.Topics.digest?(topic), do: main_digest_sweeps(topic), else: []
  end

  defp main_digest_sweeps(topic) do
    [
      %{
        name: Chidori.SweepNames.digest(),
        # **時計を持たせない**（`on_demand`）。起こすのは Chidori の側で、
        # 何時に読みたいかは利用者の都合 —— Chiezo に持たせると、あちらが
        # 都合を知る場所になる。頼まれたときだけ動くので、**いつ回ったかが分かる**
        on_demand: true,
        # **まとめる回に消す力を持たせない。** 読んで書くだけの回なので、
        # 触れるのは自分が足す 1 件だけでよい
        only_new: true,
        prompt: digest_prompt(topic)
      }
    ] ++ interest_sweeps(topic)
  end

  # 興味トピックの要約を書く回。**選んでいなければ置かない**（書く材料が無い）。
  # 時計を持たないのは要約と同じ（起こすのは Chidori で、ふつうの要約のすぐ後）
  defp interest_sweeps(topic) do
    case interests_of(topic) do
      [] ->
        []

      _interests ->
        [
          %{
            name: @interest_digest_sweep,
            on_demand: true,
            only_new: true,
            prompt: interest_digest_prompt(topic)
          }
        ]
    end
  end

  @doc "話題に載っている興味トピック（`Chidori.News.Interests.attach/1` が載せる）。"
  def interests_of(%{interests: interests}) when is_list(interests), do: interests
  def interests_of(_topic), do: []

  # 溜める回。**配信元があれば機械で引く** —— 見出し・要約・URL・配信日は機械が
  # 正確に取れるので、AI の枠は「何が重要か」「どうまとめるか」へ回す。
  # **足すだけと組にする** —— 組にしないと、整理が付けたタグを配信の薄い内容で上書きする
  defp intake(%{feeds: [_ | _]} = topic),
    do: %{
      name: Chidori.SweepNames.machine(),
      interval_minutes: every(topic, :feed, @feed_minutes),
      use_feed: true,
      only_new: true
    }

  defp intake(topic),
    do: %{
      name: Chidori.SweepNames.collect(),
      interval_minutes: every(topic, :collect, @collect_minutes),
      only_new: true,
      prompt: prompt(topic)
    }

  # 巡回の間隔。**話題が書いていればそちら** —— 世の中の動く速さは話題ごとに違い、
  # 動きの遅い話題を短い間隔で回しても、同じものを読み直すだけで枠を食う
  defp every(topic, which, fallback) when is_map(topic) do
    case topic |> Map.get(:every, %{}) |> Map.get(which) do
      minutes when is_integer(minutes) and minutes > 0 -> minutes
      _other -> fallback
    end
  end

  # 話題が分からないまま依頼されることがある（画面を通さない頼み方）
  defp every(_topic, _which, fallback), do: fallback

  # 画面で選んだ相手を巡回に載せる。**Chidori は覚えない** —— 正は Chiezo が持っている
  defp with_choices(sweeps, choices) do
    for sweep <- sweeps do
      case Map.get(choices, sweep.name) do
        nil -> sweep
        # 空文字は落とさない（「Chiezo の既定にまかせる」という意思表示）
        picked -> Map.merge(sweep, Map.reject(picked, fn {_k, v} -> is_nil(v) end))
      end
    end
  end

  @doc """
  機械で引く配信元の指定（無ければ nil）。

  **前回より後、で絞りません。** 絞る基準は収集ぜんたいの前回の実行なので、
  巡回を分けていると、別の巡回が走った拍子に見出しの回が取りこぼします
  （重複は Chiezo が見出しで弾くので、毎回まるごと引いてよい）。
  """
  def feed_spec(%{feeds: [_ | _] = feeds}), do: %{urls: feeds}
  def feed_spec(_topic), do: nil

  defp run_collection(base, name) do
    manual = if Chidori.Chiezo.by_hand?(), do: "?manual=true", else: ""

    case post(base <> "/v1/collect/" <> name <> "/run" <> manual, "", @run_timeout) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      # 止まっている収集は Chiezo が断る。有効にできるのは Chiezo の画面だけ
      {:ok, %{status: 403}} -> {:error, :collection_disabled}
      {:ok, %{status: 404}} -> {:error, :not_requested}
      {:ok, %{status: 503}} -> {:error, :collect_disabled}
      {:ok, %{status: status}} -> {:error, {:chiezo_status, status}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
    end
  end

  defp get(url) do
    Http.get(url,
      headers: [{"user-agent", @user_agent}],
      timeout: @request_timeout,
      connect_timeout: @connect_timeout
    )
  end

  defp post(url, body, timeout) do
    Http.post(url, body,
      headers: [{"user-agent", @user_agent}],
      content_type: "application/json",
      timeout: timeout,
      connect_timeout: @connect_timeout
    )
  end

  @doc false
  # Chiezo の応答から画面に要るものだけ取り出す。
  # ここだけを取り出してテストできるようにしてある
  def to_collection(%{} = item) do
    %{
      name: item["name"],
      description: item["description"] || "",
      enabled: item["enabled"] == true,
      interval_minutes: item["interval_minutes"],
      next_run_at: item["next_run_at"],
      last_run_at: item["last_run_at"],
      last_status: item["last_status"],
      last_error: item["last_error"],
      last_added: item["last_added"] || 0,
      kind: item["kind"] || "stock",
      keep_days: item["keep_days"] || 0,
      # 誰に頼んでいるか。**Chiezo が持っているものが正** —— 依頼した後は
      # 向こうの画面から変えられるので、Chidori の設定を映しても嘘になりうる
      backend: item["backend"],
      model: item["model"],
      effort: item["effort"],
      # 巡回。**相手も進み具合も巡回ごとに違う**ので、収集に 1 つだけ持たせると、
      # そこに出る値はどれか 1 本のものにしかならない
      sweeps: Chidori.Chiezo.sweeps_of(item),
      partitions_total: item["partitions_total"] || 0,
      # 進み具合（次の実行で {cursor} に入る値）。**画面の状態と並べて出す**
      cursor: item["cursor"] || "",
      # Chiezo が実際に持っている本文。**Chidori の雛形とは限らない** ——
      # 依頼した後は Chiezo の画面から直せるので、いま何を頼んでいるかは向こうが正
      prompt: item["prompt"] || "",
      # 件数は定義には入っていない。読めたときに detail が上書きする
      docs: 0,
      requested_by: item["requested_by"] || "",
      url: chiezo_url(item["url"])
    }
  end

  def to_collection(_item), do: nil

  # まとめは通しで読ませるもの。一覧に付いてくる要約は冒頭だけなので、
  # 画面に出す 1 件だけ本文を取り直す。取れなければ冒頭のまま出す ——
  # 切れた文が出るほうが、まとめの枠ごと消えるよりましなので
  @doc false
  def with_body([digest | rest], base, name) do
    case Chiezo.doc(base, name, digest.title, "title,body") do
      {:ok, %{"body" => body}} when is_binary(body) and body != "" ->
        [%{digest | summary: body, cited: cited(body, base, name)} | rest]

      _other ->
        [digest | rest]
    end
  end

  def with_body(digests, _base, _name), do: digests

  @doc """
  まとめ 1 件の本文を取り直します（`with_body/3` を 1 件ぶん）。**画面に最初から出す
  1 件だけ**が本文を持っているので、前後のまとめを開いたときに引きます。
  取れなければ冒頭のまま返します（開けないより、切れた文でも読めるほうがよい）。
  """
  def full_digest(collection, digest) when is_binary(collection) do
    case chiezo_base_url() do
      nil -> digest
      base -> [digest] |> with_body(base, collection) |> List.first()
    end
  end

  # 画面に出すまとめ。**直近の窓から拾わない** —— 一覧に付いてくるのは新しい順の
  # 数十件で、見出しの回が 60 件足した後にはまとめがそこから押し出される
  # （実際、まとめが出ない時間帯ができた）。タグで引けば、窓の大きさに関係なく出る。
  #
  # **引けなければ窓のぶんで出す**（Chiezo が古くて filter を持たない面でも、
  # まとめが丸ごと消えるよりはまし）
  defp digests(base, name, recent) do
    case tagged_digests(base, name) do
      [] -> recent |> to_digests() |> with_body(base, name)
      found -> with_body(found, base, name)
    end
  end

  # 興味トピックの要約。**窓からは拾わない**（ふつうのまとめと同じ理由）。
  # 無ければ空 —— 興味トピックを選んでいなければ書かれない
  defp interest_digests(base, name),
    do: base |> tagged_digests(name, @interest_digest_tag) |> with_body(base, name)

  defp tagged_digests(base, name, tag \\ @digest_tag) do
    query =
      URI.encode_query(%{
        "tag" => tag,
        "fields" => "title,tags,opening,updated_at,extra",
        "limit" => 20
      })

    case get(base <> "/v1/" <> name <> "/filter?" <> query) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"results" => results}} when is_list(results) ->
            # **並びは新しい順に直す。** filter が返すのは点数の順で、
            # そのまま先頭を取ると古いまとめが画面に出る
            results
            |> to_entries()
            |> Enum.filter(&(tag in &1.tags))
            |> Enum.sort_by(& &1.collected_at, :desc)

          _other ->
            []
        end

      _other ->
        []
    end
  end

  @doc false
  # まとめが引いた記事を、見出しで 1 件ずつ引き直します（絵と配信元を添えるため）。
  #
  # 画面に出している直近のぶんと突き合わせる形にはしません —— まとめは前回から
  # 今回までに入った全部から引くので、そこに収まる保証がありません（実測では、
  # 直近 20 件との一致は 13 本中 0 本。50 件でも 7 本）。**見出しは Chiezo の中で
  # 1 件を指す鍵**なので、引き直せば窓の大きさに関係なく当たります。
  #
  # 見出しの無い出典（見出しを書かせる前に溜まったまとめ）は引きません。
  def cited(body, base, name) do
    body
    |> Report.document()
    |> Report.sources()
    |> Enum.filter(&(is_binary(&1.label) and &1.label != ""))
    |> Task.async_stream(&article_of(&1, base, name),
      max_concurrency: @cited_concurrency,
      timeout: @cited_timeout,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {url, article}} -> [{url, article}]
      _other -> []
    end)
    |> Map.new()
  end

  # 引けた 1 件。**鍵は引用された URL のまま**にします —— 画面は出典の URL で
  # 突き合わせるので、Chiezo が持っている URL に付け替えると当たらなくなる
  defp article_of(%{url: url, label: label}, base, name) do
    with {:ok, doc} <- Chiezo.doc(base, name, label, "title,extra"),
         %{} = extra <- doc["extra"] do
      # **Chiezo が縮めて持っている絵を先に使う**（`extra.thumb`。見る人のブラウザが
      # 外のサイトへつながないため）。無ければ配信元が配っている絵
      image = chiezo_thumb(extra["thumb"]) || source_url(extra["image"])
      {url, %{title: doc["title"], image: image, url: url}}
    else
      _other -> nil
    end
  end

  # Chiezo が配るサムネイルの場所（相対パス → Chiezo の URL）。その形のものだけ通す
  defp chiezo_thumb("/v1/thumbs/" <> name = path) do
    if name =~ ~r/\A[0-9a-f]{40}\.webp\z/, do: chiezo_url(path), else: nil
  end

  defp chiezo_thumb(_path), do: nil

  # 記事一覧の窓（`@window_hours`）。**新着の口が読めなければ、収集の見本で代える**
  # （古い並びでも、何も出ないよりよい）。はてブ数はここで載せる（`Chidori.News.Hatena`）。
  # **記事一覧を出さない話題では引かない**（映画は 1 件が作品で、並べるのは別の口。
  # 公式サイトの URL のはてブ数を外へ聞きに行っても使い道が無い）
  defp window(base, name, fallback) do
    if Topics.articles?(Topics.get(name)), do: article_window(base, name, fallback), else: []
  end

  defp article_window(base, name, fallback) do
    candidates =
      case get(
             base <>
               "/v1/" <>
               name <>
               "/recent?limit=#{@window_candidates}&fields=title,tags,extra,opening,updated_at"
           ) do
        {:ok, %{status: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"docs" => docs}} when is_list(docs) -> docs
            _ -> fallback
          end

        _ ->
          fallback
      end

    candidates |> to_articles() |> in_window() |> Chidori.News.Hatena.with_counts()
  end

  @doc false
  # 公開の新しい順に並べ、直近 `@window_hours` 時間のものを残す（薄ければ新しい順に
  # `@window_min` 件までは埋め、`@window_max` 件で切る）
  def in_window(articles, now \\ DateTime.utc_now()) do
    sorted = Enum.sort_by(articles, &published_at/1, {:desc, DateTime})
    cutoff = DateTime.add(now, -@window_hours * 3600, :second)
    recent = Enum.take_while(sorted, &(DateTime.compare(published_at(&1), cutoff) != :lt))

    if length(recent) >= @window_min,
      do: Enum.take(recent, @window_max),
      else: Enum.take(sorted, @window_min)
  end

  # 公開日時。**日付だけのもの**（`2026-09-25`）はその日の 0 時（UTC）として読む。
  # 読めなければいちばん古い扱い（窓の外へ）
  defp published_at(%{at: at}) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _offset} ->
        dt

      _ ->
        case Date.from_iso8601(String.slice(at, 0, 10)) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          _ -> ~U[1970-01-01 00:00:00Z]
        end
    end
  end

  defp published_at(_article), do: ~U[1970-01-01 00:00:00Z]

  @doc false
  # 溜まっているものを画面の並びにする。新しい順は Chiezo が付けたまま保つ。
  #
  # **原文の URL は `extra` の中**（Chiezo が集めた1件の出典）。本文の要約は
  # `opening`。どちらも無いことがあるので、無ければその欄を出さない
  def to_articles(recent) when is_list(recent) do
    recent |> to_entries() |> Enum.reject(&digest?/1)
  end

  def to_articles(_recent), do: []

  @doc false
  # まとめ（`@digest_tag` の付いたもの）。**記事と別に返す** ——
  # 一覧に混ぜると、まとめが記事のふりをして並ぶ
  def to_digests(recent) when is_list(recent) do
    recent |> to_entries() |> Enum.filter(&(@digest_tag in &1.tags))
  end

  def to_digests(_recent), do: []

  # **興味トピックの要約も記事ではない**（一覧に混ぜると、要約が記事のふりをして並ぶ）。
  # ふつうのまとめの並び（`to_digests/1`）にも入れない —— あちらは印で分ける
  defp digest?(%{tags: tags}), do: @digest_tag in tags or @interest_digest_tag in tags

  @doc false
  # 興味トピックの要約（`@interest_digest_tag`）。直近の窓から拾う形（まとめを待つ側が使う）
  def to_interest_digests(recent) when is_list(recent) do
    recent |> to_entries() |> Enum.filter(&(@interest_digest_tag in &1.tags))
  end

  def to_interest_digests(_recent), do: []

  defp to_entries(recent) do
    Enum.flat_map(recent, fn
      %{"title" => title} = item when is_binary(title) ->
        title = String.trim(title)

        tags = tags_of(item)

        # **読者に出さないものを、こちらで選り分けない。** 消えたものも、まだ整理が
        # 読んでいないものも、Chiezo が既定で落として返す（どの読み口でも同じ）——
        # こちらが落とす形にすると、**あちらの印が増えるたびに、ここも直して回る**
        # ことになる。しかも漏れるのは読者の画面だけなので、気づくのが遅い
        if title == "" do
          []
        else
          {importance, reason} = importance(title, tags)
          extra = if is_map(item["extra"]), do: item["extra"], else: %{}

          [
            %{
              title: title,
              tags: tags,
              url: source_url(extra["url"]),
              # **絵は Chiezo が持っている URL を指すだけ**（Chidori は画像を持たない）。
              # 配信元が配っているものだけなので、無いことのほうが多い
              image: source_url(extra["image"]),
              summary: trimmed(item["opening"]),
              # **配信日があればそちら** —— 集めた日だけだと、半年前の記事を
              # 今日拾ったのか、今日出たものなのかが読めない
              # 人に見せる日時なので JST に直す（届くのは UTC の文字列）
              collected_at:
                Jst.format(extra["published_at"] || item["updated_at"] || extra["collected_at"]),
              # 並べるための生の日時（**公開が先**。無ければ取り込んだ日時）
              at: extra["published_at"] || extra["collected_at"] || item["updated_at"],
              # はてブ数（`Chidori.News.Hatena`。記事一覧の窓で載せる）
              bookmarks: nil,
              importance: importance,
              reason: reason,
              # **どれだけ反応されているか**（整理の回が付ける。無いこともある）
              buzz: buzz(tags),
              # **興味トピックにどれだけ近いか**（0〜100。整理の回が付ける。無いこともある）
              interest: interest_score(tags),
              # まとめが引いた記事（出典の URL → 見出しと絵）。記事の側では空のまま
              cited: %{}
            }
          ]
        end

      _item ->
        []
    end)
  end

  defp tags_of(%{"tags" => tags}) when is_list(tags), do: Enum.map(tags, &to_string/1)
  defp tags_of(_item), do: []

  # 出典は AI が入れたものなので、そのまま信じてリンクにしない
  defp source_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when is_binary(host) and host != "" ->
        if scheme in ["http", "https"], do: url, else: nil

      _ ->
        nil
    end
  end

  defp source_url(_url), do: nil

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_value), do: nil

  @doc """
  Chiezo へ渡す収集の本文。

  **何を集めるかは話題の「関心」から作ります** —— 話題ごとに本文を丸ごと持たせると、
  話題を足すたびに同じ形の文をもう一度書くことになります。関心は話題の定義
  （`Chidori.Topics.defined/0`）にあります。

  `{cursor}` は実行のたびに進む印で、AI が `next_cursor` で次を返します
  （前回以降を集めるのに使う）。
  """
  def prompt(topic \\ nil) do
    """
    {cursor} 以降に日本語で報じられたもののうち、次に当てはまるものを10件集めてください。

    #{interest_of(topic)}

    {feed}

    前回から新しく入ったものは次のとおりです。**同じ出来事には同じ title を使ってください**
    （見出しが重複の鍵なので、言い回しを変えると同じ話が二重に溜まります）。
    {recent}

    title はそれを一意に指す短い見出しにします。
    body には3行程度の要約を書き、記事本文はそのまま写さないでください。
    url には出典の記事のURLを必ず入れます。
    tags には次を入れてください。
    - 種別（#{kinds()} のどれか 1 つ）
    - 分野（当てはまるものをすべて）
    - **その記事に出てくる固有名を、付けるべきものはすべて**（人・組織・製品・サービス・技術・地名などの名前。
      会社と製品がどちらも出てくるなら両方。数は決めません。
      見出しや本文に出てくる綴りのまま。配信元が語を付けていればそれを使ってください）
    next_cursor には、今回集めた中でいちばん新しい記事の日時をISO8601で入れてください。
    """
  end

  @doc """
  整理の回の依頼文。**読んで印を付け直し、要らないものを落とし、足りないものを足します**。

  **3 つを 1 本で頼みます。** 分けていた頃は、重なった時間ぶんを 2 度読ませて
  いました —— 画家の収集が同じ理由で 1 本にまとめてあります。

  **落とす力と印を付け直す力を持つのはこの回だけ**なので、割り込みもここへ来ます。

  **論文だけ名指しで念を押しています。** 外を当たる先の 1 つとして箇条書きに
  並べていただけの頃は、実測で 269 件のうち論文が 2 件しか入りませんでした ——
  4 つ並んだうちの最後の 1 行では埋もれます。配信元は論文を配らないので、
  この回が見に行かなければ**その話題には論文が永遠に入りません**。

  **件数は求めません。** 「必ず N 件」と書くと数合わせで薄いものが入り、
  重要度の印が意味を失います（読む人は印で絞って読むので、そこに当たりが
  混ざるほうが害が大きい）。
  """
  def refine_prompt(topic) do
    cond do
      works = Topics.works(topic) -> works.refine_prompt(interest_of(topic))
      true -> article_refine_prompt(topic)
    end
  end

  defp article_refine_prompt(topic) do
    """
    前回から新しく入ったものを読んで、**印を付け直し、要らないものを落とし、
    そのうえで足りないものを足してください**。

    何を大事とみなすかは次のとおりです。
    #{interest_of(topic)}

    {feed}

    {recent}

    **1. 読んで、印を付け直す。**
    見出しは配信元から機械的に取り込んでいるので、**関係のないものも混ざります**。
    次のものは **tags に "#{Chiezo.tombstone_tag()}" だけを入れて返してください**（墓標。
    その1件は消えた扱いになり、以後どの画面にも出ません）。
    **そのとき body に、なぜ消すのかを1行で書いてください** —— 消したものは
    Chiezo の一覧に見出しと理由が並ぶだけなので、理由が無いと消し間違いに気づけません。
    - 上の関心とまったく関係のないもの
    - 中身が宣伝・求人・販促だけのもの
    - 同じ出来事を指す1件が既にあるもの（**残すほうは1つだけ**。先に入っているほうを残す）

    **迷ったら落とさないでください。** 消したものは Chiezo が覚えていて、
    次に同じ見出しが流れてきても戻りません。

    **「#{@digest_tag}」「#{@interest_digest_tag}」のタグが付いたものには触らないでください**（消すのも書き換えるのも）。
    あれは要約の回が書いた読み物で、記事ではありません —— 同じ出来事に触れているので
    重複に見えますが、落とすと**画面と通知からまとめが消えます**（実際に消えました）。

    #{outside_of(topic)}

    **足す前に、その記事が既に入っていないか URL で確かめてください。**
    見出しでは確かめられません —— 同じ記事が配信元ごとに違う見出しで流れてきますし
    （「記事名 - サイト名」と「記事名」）、上に差し込んであるのは前回から後に入った
    ぶんだけです。道具が使えるなら、次のように引けます（読むだけの SQL）。

        query(source: "#{collection_of(topic)}",
              sql: "SELECT title FROM docs
                    WHERE json_extract(extra, '$.url') LIKE '%記事のURLの一部%'")

    **上に並んでいるものを、探したついでに書き換えないでください。**
    見出しが同じものを薄い要約で返すと、付いている印ごと置き換わります ——
    直すのは印と要約を良くするときだけで、**外から見つけたものは新しい見出しで**足してください。

    残すものも足すものも、1 件ごとに次の形で返してください。
    - title: 既にあるものは**そのままにしてください**（見出しが重複の鍵です）。
      **見出しの付け替えはできません** —— 別の見出しで返しても、同じ URL の 1 件と
      して弾かれ、元の見出しのまま残ります。足すものは、それを一意に指す短い見出し
    - body: 要約。読みにくければ書き直してよい（記事本文はそのまま写さない）
    - url: 既にあるものはそのまま。足すものは出典の記事の URL（**必ず入れる**。
      一覧ページではなく、**その記事そのもののページ**を指す URL）
    - tags:
      - "#{@importance_tag}:高" / "#{@importance_tag}:中" / "#{@importance_tag}:低" を
        **必ず 1 つ**（上の関心に照らして、いま読む価値があるかで決める）
      - "#{@buzz_tag}:高" / "#{@buzz_tag}:中" / "#{@buzz_tag}:低" を**必ず 1 つ**。
        **#{@importance_tag} とは別の軸です** —— あちらは「いま読む価値があるか」、
        こちらは「界隈がその話をしているか」。**話題になっていないが効くもの**も、
        **効かないが沸いているもの**もあるので、同じ印にしないでください。
        目安は次のとおりです。
        #{buzz_rubric(topic)}
      - 種別（#{kinds()} のどれか 1 つ。いま付いているものが正しければそのまま）
      - 分野（当てはまるものをすべて。配信元の名前はそのまま残してください）
      - **その記事に出てくる固有名を、付けるべきものはすべて**（人・組織・製品・サービス・技術・地名などの名前。
        会社と製品がどちらも出てくるなら両方 ——「OpenAI」だけで「ChatGPT」を落とすと、
        製品の名前で探したときに見つかりません。数は決めません。
        見出しや本文に出てくる綴りのまま。**分野だけでは図になりません** ——
        話題のつながりはこのタグから作るので、「AI」「セキュリティ」のような広い語しか
        無いと、どの記事も同じ場所に集まってしまいます）
    #{interest_rubric(topic)}
    **触ったものと足すものだけ返してください。** 触れなかったものはそのまま残ります。
    #{note_of(topic)}
    """
  end

  # 要約の書き出し・材料・調子。**話題が書いていればそちら**（`Chidori.Topics` の
  # `digest_intro` / `digest_material` / `digest_tone`）—— 映画は「前回から入ったもの」
  # ではなく「いま入っている作品」から、ニュースの固さではなく映画館の販促記事の調子で書く
  defp digest_intro(topic),
    do:
      Map.get(topic || %{}, :digest_intro) ||
        "前回のまとめから今回までに入ったものを、**1 件のレポート**にしてください。"

  defp digest_material(topic), do: Map.get(topic || %{}, :digest_material) || "{recent}"

  defp digest_tone(topic) do
    case Map.get(topic || %{}, :digest_tone) do
      tone when is_binary(tone) and tone != "" -> "\n" <> String.trim_trailing(tone) <> "\n"
      _ -> ""
    end
  end

  # 整理の回に付けさせる興味度の目安。**興味トピックを選んでいなければ何も足さない**
  # （付ける基準が無いのに数を書かせると、どの記事にも同じような点が並ぶだけになる）
  defp interest_rubric(topic) do
    case interests_of(topic) do
      [] ->
        ""

      interests ->
        """
          - "#{@interest_tag}:<0〜100 の整数>" を**必ず 1 つ**。読む人が選んだ興味トピック
            （#{Enum.map_join(interests, "、", &"「#{&1}」")}）に、その 1 件が**どれだけ近いか**です。
            **#{@importance_tag}・#{@buzz_tag}とは別の軸です** —— 誰にとっても大事か、界隈が
            話しているかではなく、**この読者の興味に当たっているか**で決めてください。
            目安は次のとおりです。
            - 90〜100: 興味トピックそのものが主役（名指しで取り上げている）
            - 60〜89: 興味トピックに直接効く（それを動かす出来事・周辺の製品や組織・競合）
            - 30〜59: 同じ分野だが、興味トピックとのつながりは間接的
            - 0〜29: 興味トピックとはほぼ関係がない
            **既に「#{@interest_tag}:」が付いているものは付け直さないでください** ——
            興味トピックは選び直されることがありますが、付けた点はその時点の興味での
            判断として残します（選び直すたびに過去の点が動くと、並びが読めなくなります）。
            **印がまだ無いものにだけ**付けてください。
        """
    end
  end

  # Chiezo での収集の名前（道具で引くときの相手）。**画面を通さない頼み方では
  # 話題が分からないことがある** —— そのときは名前を書かずに、読む人（AI）に
  # 手元の名前を使わせる
  defp collection_of(%{collection: name}) when is_binary(name) and name != "", do: name
  defp collection_of(_topic), do: "この収集の名前"

  # 整理の回の「上に無いものを探して足す」。**話題が書いていればそちら**
  # （`Chidori.Topics` の `outside`）—— 探す先は話題で違う（技術イベントに
  # 論文を探させても何も入らない）
  defp outside_of(%{outside: text}) when is_binary(text) and text != "",
    do: String.trim_trailing(text)

  defp outside_of(_topic) do
    """
    **2. 上に無いものを探して足す。**
    決まった配信元だけを見ていると、そこに載らないものは永遠に入りません。
    **上に並んでいない出どころ**を当たってください。たとえば次のようなところです。

    - 公式の発表・一次情報（リリースノート、公式ブログ、脆弱性の告知）
    - **企業のテックブログや個人のブログで、いま話題になっているもの**
    - 海外で話題になっていて、日本語ではまだ広まっていないもの
    - **話題になっている論文**（機械学習や分散システムなど、作る人の判断が変わるもの）

    **論文は、この回が見に行かなければ 1 件も入りません。** 配信元は論文を配らないので、
    毎回かならず当たってください。話題になっているものが無ければ 0 件で構いませんが、
    **探さずに 0 件にしないでください**。

    **ニュースだけではありません。** 種別（#{kinds()}）のどれでも構いません ——
    配信元から機械的に入るのは決まった媒体のぶんだけなので、
    記事も論文もここでしか入りません。
    **確信が持てるものだけ**を挙げてください。
    """
    |> String.trim_trailing()
  end

  # 話題度の目安。**話題が書いていればそちら**（`Chidori.Topics` の `buzz`）——
  # どこが「人気枠」かは話題で違う（技術ならはてなブックマークの IT や Qiita、
  # 一般ニュースなら各社のトップや総合の人気エントリー）
  defp buzz_rubric(%{buzz: text}) when is_binary(text) and text != "",
    do: indent(String.trim_trailing(text), 4)

  defp buzz_rubric(_topic) do
    """
    - 高: 同じ出来事を複数の媒体が報じている、人気枠（はてなブックマークの
      人気エントリー、Qiita の人気、Zenn のトレンド）から入っていて
      さらに他でも取り上げられている、反応が大きい
    - 中: 人気枠には入っているが、広がりはその媒体の中まで
    - 低: 公式の発表や論文など、まだ広がっていないもの
      （**広がっていないことは悪いことではありません**。早いだけです）
    """
    |> String.trim_trailing()
    |> indent(4)
  end

  # 2 行目から先の行頭を揃える（1 行目の深さは、差し込む側の行が持っている）
  defp indent(text, n) do
    pad = String.duplicate(" ", n)
    [first | rest] = String.split(text, "\n")
    Enum.join([first | Enum.map(rest, &if(&1 == "", do: "", else: pad <> &1))], "\n")
  end

  # その話題ならではの頼みごと（`Chidori.Topics` の `note`）。
  # **関心とは別物** —— あちらは「何が読む価値があるか」、こちらは
  # 「1 件ごとに何を書き足すか」。持たない話題では何も足さない
  defp note_of(topic) when is_map(topic) do
    case topic |> Map.get(:note) |> to_string() |> String.trim() do
      "" -> ""
      note -> "\n" <> note
    end
  end

  defp note_of(_topic), do: ""

  @doc """
  まとめを、通知に流すプレーンテキストにします。**流すのは要旨だけです。**

  レポート本文をそのまま送りません —— 通知は Markdown として描かれないので、
  見出しも表も箇条書きも記号のまま並び、読みたい文字の間に `*` や `|` が挟まります。
  要旨は依頼文で**通知に流す前提の 2〜3 文**として別に書かせてあるので、
  ここではそれをそのまま使います（画面では、同じ文がレポートの導入として出ます）。

  **出典の URL は添えます。** 画面のほうは記事の見出しでリンクにしますが、
  通知では逆です —— ntfy が URL を見つけて自分でリンクにするので、見出しに
  差し替えると**行き先が読めないただの文字**になります。

  **要点ごとの出典は、その要点のすぐ下に並べます**（`Report.to_notice/1`）。
  レポート全体の出典を最後にまとめて並べていた頃は、どの URL がどの要点の
  根拠なのかが通知から読めなかった。要点に出典の無い古いまとめは、今までどおり
  最後にまとめて並べます。

  **見出しは写しません。** ntfy はタイトルを別に持つので、本文にも入れると
  同じ文字が 2 度並びます。
  """
  def digest_text(%{summary: summary}) when is_binary(summary) do
    document = Report.document(summary)

    if Enum.any?(document.summary, &match?({:source, _url, _label}, &1)) do
      Report.to_notice(document.summary)
    else
      urls = document |> Report.sources() |> Enum.take(@notice_sources)

      [summary_text(document), Enum.map_join(urls, "\n", & &1.url)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
    end
  end

  def digest_text(_digest), do: ""

  # 要旨が読めない本文（要旨を書かせる前に溜まったまとめ）は、章の本文で代える ——
  # 通知が空で飛ぶより、飾りを落とした本文が流れるほうがまだ読める
  defp summary_text(document) do
    case Report.to_text(document.summary) do
      "" -> document.sections |> Enum.flat_map(& &1.blocks) |> Report.to_text()
      text -> text
    end
  end

  @default_digest_format """
  - body: 下の書き方で、**読み物のレポート**として書いてください

  body の形です。**使ってよい記法はここにあるものだけ**で、HTML と画像は書かないでください。

  ```
  ## 要旨
  <2〜3 文>

  ## 要点
  - <1 行>

  ## <章の見出し>
  <段落>
  - <箇条書き>
  | 比較軸 | A | B |
  | --- | --- | --- |
  | <値> | <値> | <値> |
  > <注記>
  出典: [記事の見出し](URL)
  ```

  **「## 要旨」は通知にそのまま流れます。** 次の形で書いてください。

  ```
  <その期間を一言で。1 文>

  ・<要点を 1 行で>
  出典: [記事の見出し](URL)
  ・<要点を 1 行で>
  出典: [記事の見出し](URL)
  ・<要点を 1 行で>
  出典: [記事の見出し](URL)
  ```

  - **1 行目だけで意味が通るように**書いてください（通知は畳まれて先頭しか
    見えないことがあります）
  - 続けて**空行を 1 つ**置き、要点を「・」で **3〜4 行**。**1 行に 1 つのこと**だけ
    書いてください —— 全部を 1 つの段落に詰めると、通知でも画面でも読めません
  - **要点ごとに、すぐ下の行へ根拠にした記事を `出典: [記事の見出し](URL)` で
    1〜2 行**書いてください。通知では要点の下にその URL が並ぶので、どの URL が
    どの要点の根拠なのかが読めます。**見出しも URL も、上に並んでいるものを
    そのまま写してください**（上に無い URL を作らない）
  - 飾りの記号（`**` や行頭の `-`）は入れないでください
    —— 通知は Markdown として描かれないので、記号がそのまま出ます
  - レポート本文の言い直しで構いません（画面では導入として出ます）

  章の書き方です。
  - 「## 要点」は 3〜5 行。その期間に何が動いたのかを 1 行ずつ
  - 章（「## <見出し>」）は 3〜6 個。**似た話はひとつにまとめて構いません**
    （同じ出来事の別の記事は 1 つに）
  - 1 つの章は 3〜6 文。**何が起きたのか**と、**なぜ押さえるべきか**
    （読む人の判断がどう変わるか）まで書いてください
  - 比べるもの（版・道具・手法・料金）が並ぶときは表にしてください
    —— 並べて初めて分かることは、文章にすると読み返さないと分かりません
  - 身構える点（未確定・注意・期限）があれば `> ` の行で章に 1 つだけ添えられます
  - 章の終わりに `出典: [記事の見出し](URL)` を 1〜3 行。**見出しも URL も、上に
    並んでいるものをそのまま写してください** —— **上に無い URL を作らないでください**。
    見出しを書くのは、裸の URL では押す前にどこへ行くのか読めないからです
  - 強調（`**…**`）は 1 つの段落に 1 か所までにしてください。
    全部が強調だと、どれが強調なのか読み取れません
  - 上に書かれていないことを補わないでください
  - 最後に「## 次に見るもの」を置いても構いません（続報を待つもの、確かめるもの）
  """

  @doc """
  まとめる回の依頼文。**画面で読むレポート**を1件作ります。

  溜まったものをそのまま並べても読めません —— 何が起きたかを先に言うのが、
  画面の先頭と通知に要るものです。

  **要旨は本文と別に書かせます。** 通知へ流すのは要旨だけで（`digest_text/1`）、
  レポートを潰して流すと記号の混じった塊になります。画面では、その要旨を
  レポートの導入として出します —— **1 件のまとめを、出す場所に合わせて使い分けます**。
  """
  def digest_prompt(topic) do
    """
    #{digest_intro(topic)}

    読む人が知りたいのは次のようなことです。
    #{interest_of(topic)}
    #{digest_tone(topic)}
    #{digest_material(topic)}

    返すのは **items に 1 件だけ**です。

    - title: "#{@digest_tag}: <その期間を一言で>（{now}）"
      **{now} はそのまま写してください**（いまの日時に置き換わります）。
      見出しは重複の鍵なので、**同じ見出しを返すとこの回のまとめが丸ごと捨てられます**
      —— 日付だけだと、1 日に 2 回まとめたときの 2 回目が入りません
    - url: **空のままにしてください。** まとめは 1 本の記事を指すものではありません ——
      記事の URL を名乗ると、**その記事が既に入っているぶんと同じ 1 件とみなされて
      落ちます**（同じ URL は Chiezo が弾きます）。出典は本文の「出典:」行に書きます
    - tags: "#{@digest_tag}" を**必ず**付けてください（画面と通知はこれで見分けます）

    #{digest_format(topic)}
    まとめるものが無ければ、**1 件も返さないでください**（空のまとめは要りません）。
    """
  end

  # まとめの書き方（body の形と章の決まり）。**話題が書き方ごと持てる**（`digest_format`）——
  # 既定は人が読むレポートで、市況ニュースは売買提案の AI が読む決まった形にする。
  # 既定に戻せるよう、既定の文はここに 1 つだけ置く
  defp digest_format(topic) do
    case Map.get(topic || %{}, :digest_format) do
      format when is_binary(format) and format != "" -> String.trim_trailing(format) <> "\n"
      _ -> @default_digest_format
    end
  end

  @doc """
  興味トピックの要約の依頼文。**ふつうの要約とは別の 1 本**を作ります。

  同じ依頼文で材料だけ絞ると、どちらも「その期間の総ざらい」になって読み分けられません
  （別の収集アプリ で同じことを確かめた判断）。こちらは**読む人が選んだ語に絞って**、
  どの興味トピックの話か・何をすればよいかが分かるように書かせます。
  形（要旨・要点・章・出典）はふつうの要約と同じにしてあります —— 画面と通知が
  同じ読み方で扱えるように。
  """
  def interest_digest_prompt(topic) do
    interests = Enum.map_join(interests_of(topic), "、", &"「#{&1}」")

    digest_prompt(topic)
    |> String.replace(
      "前回のまとめから今回までに入ったものを、**1 件のレポート**にしてください。",
      """
      前回から今回までに入ったもののうち、**読む人が選んだ興味トピック（#{interests}）に
      関わるものだけ**を、**1 件のレポート**にしてください。

      **その期間の総ざらいにしないでください**（それは別の回が書いています）。
      「#{@interest_tag}」の印が高いものを中心に、**どの興味トピックの話か**と、
      **読む人が何をすればよいか**（試す・備える・追いかける）が分かるように書いてください。
      興味トピックに関わるものが無ければ、**1 件も返さないでください**。
      """
    )
    |> String.replace(
      ~s("#{@digest_tag}: <その期間を一言で>（{now}）"),
      ~s("#{@interest_digest_tag}: <その期間を一言で>（{now}）")
    )
    |> String.replace(
      ~s(tags: "#{@digest_tag}" を**必ず**付けてください),
      ~s(tags: "#{@interest_digest_tag}" を**必ず**付けてください。"#{@digest_tag}" は**付けないでください**)
    )
  end

  # 種別の言い方。**配信元の指定と揃える** —— 別々に書くと、機械が付ける種別と
  # AI が付ける種別が食い違う
  defp kinds, do: Enum.join(kind_tags(), " / ")

  @doc """
  種別のタグ。**1 件がどんなものかを表す語**で、話題の語ではありません。

  トピックを拾う側が「これは話題ではない」と落とすのに要ります
  （`Chidori.Themes`）—— 語彙を 2 か所に書くと、片方だけ足したときに
  種別がトピックとして図に並びます。
  """
  def kind_tags, do: ["ニュース", "記事", "論文"]

  @doc "重要度のタグの頭。"
  def importance_tag, do: @importance_tag

  @doc "話題度のタグの頭。"
  def buzz_tag, do: @buzz_tag

  @doc "まとめに付くタグ。"
  def digest_tag, do: @digest_tag

  @doc "興味度のタグの頭。"
  def interest_tag, do: @interest_tag

  @doc "興味トピックの要約に付くタグ。"
  def interest_digest_tag, do: @interest_digest_tag

  @doc "興味トピックの要約を書く巡回の名前。"
  def interest_digest_sweep, do: @interest_digest_sweep

  @doc """
  そのトピックの記事（新しい順）。**トピックの語と、畳んだ言い換えのタグで引きます**
  （記事の側は畳む前の表記のまま残っているので、言い換えで引かないと取りこぼす）。

  トピックは記事のタグの値そのもの（`Chidori.Themes`）なので、Chiezo のタグの口で
  引けます。同じ記事が 2 つの語で当たることがあるので、見出しで 1 つにまとめます。
  """
  def articles_tagged(collection, names) when is_binary(collection) and is_list(names) do
    case chiezo_base_url() do
      nil ->
        {:error, :chiezo_not_configured}

      base ->
        names
        |> Enum.uniq()
        |> Enum.reduce_while({:ok, []}, fn name, {:ok, found} ->
          case Chiezo.spot_docs(base, collection, name, 0, @tagged_limit) do
            {:ok, %{docs: docs}} -> {:cont, {:ok, found ++ docs}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, docs} ->
            {:ok,
             docs
             |> to_articles()
             |> Enum.uniq_by(& &1.title)
             |> Enum.sort_by(& &1.collected_at, :desc)}

          error ->
            error
        end
    end
  end

  # 関心が空のままでも集めさせない文にはしない —— 指定なしで頼むと、
  # 何を集めればよいか決まらないまま AI が埋めることになる
  defp interest_of(%{interest: interest}) when is_binary(interest) do
    case String.trim(interest) do
      "" -> @default_interest
      text -> text
    end
  end

  defp interest_of(_topic), do: @default_interest

  defp description(%{name: name} = topic) when is_binary(name),
    do: "Chidori の「#{name}」。#{interest_of(topic)}"

  defp description(_topic), do: "Chidori のニュース。#{@default_interest}"

  @critical_keywords ~w(
    地震 津波 避難 警報 台風 大雨 災害 感染症 選挙 首相 日銀 金利 戦争
  )

  @doc false
  # 重要度の判定。**AI が付けた印が先** —— 語の一致で決めると、同じ語を含むだけの
  # 1 件が上に出る（読んだうえでの判断には勝てない）。印が無いときだけ語で見る
  def importance(title, tags \\ []) do
    case marked_importance(tags) do
      nil -> from_words(title)
      marked -> marked
    end
  end

  @doc false
  # 話題度。**付いていなければ nil**（印の無いものに「低」を当てない —— 整理が
  # まだ読んでいないだけのものが、「話題になっていない」として並ぶ）
  def buzz(tags) when is_list(tags) do
    Enum.find_value(tags, fn tag ->
      case String.split(tag, ":", parts: 2) do
        [@buzz_tag, level] when level in ["高", "中", "低"] -> level
        _ -> nil
      end
    end)
  end

  def buzz(_tags), do: nil

  @doc """
  興味度（0〜100）。**無ければ nil** —— 興味トピックを選ぶ前に入ったものや、
  まだ整理が読んでいないものを「0 点」扱いすると、近いものまで下に沈む。
  範囲の外の値は端へ寄せる（AI が 120 と書くことはある）。
  """
  def interest_score(tags) when is_list(tags) do
    Enum.find_value(tags, fn tag ->
      with [@interest_tag, value] <- String.split(tag, ":", parts: 2),
           {n, _rest} <- Integer.parse(String.trim(value)) do
        n |> max(0) |> min(100)
      else
        _ -> nil
      end
    end)
  end

  def interest_score(_tags), do: nil

  defp marked_importance(tags) do
    Enum.find_value(tags, fn tag ->
      case String.split(tag, ":", parts: 2) do
        [@importance_tag, "高"] -> {2, "AI が、いま読む価値が高いと判断しました"}
        [@importance_tag, "中"] -> {1, "AI が読んで、ふつうの重さと判断しました"}
        [@importance_tag, "低"] -> {0, "AI が読んで、急がないと判断しました"}
        _ -> nil
      end
    end)
  end

  defp from_words(title) do
    if Enum.any?(@critical_keywords, &String.contains?(title, &1)) do
      {2, "暮らしや社会への影響が大きい可能性があります"}
    else
      {1, "今日の主要な報道として集めました"}
    end
  end
end
