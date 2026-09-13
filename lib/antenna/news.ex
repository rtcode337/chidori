defmodule Antenna.News do
  @moduledoc """
  ニュースの収集状態を持つ入れ物です。

  集めるのは antenna ではなく Chiezo の「集める」層です。antenna は収集を
  依頼して、溜まったものを読むだけにしてあります —— 定期実行の時計も、AI の
  呼び出しも、集めたものの置き場も、すでに Chiezo が持っているためです。

  依頼して作られる収集は必ず止まった状態で、動き出すのは Chiezo の管理画面で
  有効にしたときだけです。だからこの画面から AI が勝手に動くことはありません。

  Chiezo への問い合わせは `Task.Supervisor` の下で動かし、この GenServer では
  待ちません。結果は `subscribe/1` した先へ届きます。

  **話題ごとに 1 つ立ちます。** 「ニュース」と「技術」では集める相手も溜まるものも
  別なので、1 つの入れ物に混ぜると、片方を読み直したときにもう片方の状態まで
  入れ替わります。立てるのは開かれたときで、話題（`Antenna.Topics`）が増えても
  誰も開いていないものまで常駐しないようにしてあります。
  """

  use GenServer

  require Logger

  alias Antenna.Http

  @user_agent "antenna/0.1 (+https://github.com/rtcode337/antenna)"

  # Chiezo は LAN 内なので短くてよい。ただし「いま集めさせる」は AI が動くので長い
  @request_timeout 15_000
  @run_timeout 600_000
  @connect_timeout 5_000

  # AI を動かす操作だけ間隔を空ける。読み直しは相手が手元にいるので絞らない
  @min_run_interval_ms 30_000

  # 画面に出す件数。Chiezo 側の上限は 50
  @samples 20

  # 収集の既定。名前は Chiezo のソース名になるので英小文字・数字・_ だけ
  @default_collection "antenna_news"
  @interval_minutes 360

  # 話題に関心が書かれていないときの言い方
  @default_interest "暮らし・社会・経済への影響が大きいこと"

  defstruct collection_name: nil,
            status: :idle,
            collection: nil,
            articles: [],
            # 選ばれたもの（見出し → なぜ）。**選ぶたびに AI を呼ばない**ので、
            # 溜まったものが変わっていなければ前の結果をそのまま出す
            picks: %{},
            picked_titles: [],
            picked_from: nil,
            selecting: false,
            checked_at: nil,
            reason: nil,
            task: nil,
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
           Antenna.News.Supervisor,
           {__MODULE__, collection: collection}
         ) do
      {:ok, _pid} -> via(collection)
      {:error, {:already_started, _pid}} -> via(collection)
      # 立てられなくても画面は出す（状態が読めないだけ）
      {:error, _reason} -> via(collection)
    end
  end

  defp via(collection), do: {:via, Registry, {Antenna.News.Registry, collection}}

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
  予定を待たずに1回集めさせます。止まっている収集は Chiezo が断ります。
  """
  def run_now(server) do
    GenServer.cast(server, {:command, :run})
  end

  @doc """
  溜まったものから重要なものを選ばせます。

  **溜まったものが変わっていなければ呼び直しません** —— 画面を開くたびに AI を
  呼ぶと枠を食い切ります。`force` を立てると、変わっていなくても選び直します。
  """
  def select(server, topic, force \\ false) do
    GenServer.cast(server, {:select, topic, force})
  end

  @doc """
  収集状態の変化を受け取ります。LiveView が接続時に呼びます。

  **話題ごとに分けて配ります** —— 1 本にまとめると、見ていない話題が集め終わった
  拍子に、いま開いている画面まで書き換わります。
  """
  def subscribe(collection \\ nil) do
    Phoenix.PubSub.subscribe(Antenna.PubSub, topic(collection || collection_name()))
  end

  @doc "受け取るのをやめます。話題を切り替えたときに呼びます。"
  def unsubscribe(collection) when is_binary(collection) do
    Phoenix.PubSub.unsubscribe(Antenna.PubSub, topic(collection))
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
      picks: %{},
      picked_titles: [],
      selecting: false,
      checked_at: nil,
      reason: nil,
      configured: chiezo_base_url() != nil
    }
  end

  defp topic(collection), do: "news:" <> collection

  @doc """
  Chiezo に置く収集の名前。`ANTENNA_NEWS_COLLECTION` で変えられます。
  """
  def collection_name do
    case System.get_env("ANTENNA_NEWS_COLLECTION", "") |> String.trim() do
      "" -> @default_collection
      name -> name
    end
  end

  @doc """
  誰に頼むか。`ANTENNA_NEWS_BACKEND` / `_MODEL` / `_EFFORT` で指定します。

  **未指定なら Chiezo の既定にまかせます**（有効にしてある相手の先頭）。
  どの相手に頼むかは本来 Chiezo 側の判断なので、antenna から名指しするのは
  「この収集だけは別の相手に」と決めたときだけです。依頼した後は Chiezo の
  管理画面からも変えられます。
  """
  def backend_settings do
    %{
      backend: env("ANTENNA_NEWS_BACKEND"),
      model: env("ANTENNA_NEWS_MODEL"),
      effort: env("ANTENNA_NEWS_EFFORT")
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
          Task.Supervisor.async_nolink(Antenna.TaskSupervisor, fn ->
            perform(command, base, name)
          end)

        state = %{state | status: :loading, reason: nil, task: task}
        state = if command == :run, do: %{state | last_run_at: now_ms()}, else: state

        {:noreply, broadcast(state)}
    end
  end

  @impl true
  def handle_cast({:select, topic, force}, state) do
    signature = signature(state.articles)

    cond do
      state.selecting or state.articles == [] ->
        {:noreply, state}

      not force and state.picked_from == signature ->
        # 溜まったものが変わっていない。前の結果をそのまま使う
        {:noreply, state}

      true ->
        base = chiezo_base_url()

        if base && topic do
          articles = state.articles

          Task.Supervisor.async_nolink(Antenna.TaskSupervisor, fn ->
            {:selected, signature, Antenna.Selection.pick(base, topic, articles)}
          end)

          {:noreply, broadcast(%{state | selecting: true})}
        else
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({_ref, {:selected, signature, result}}, state) do
    state =
      case result do
        {:ok, picks} ->
          %{
            state
            | selecting: false,
              picked_from: signature,
              picks: Map.new(picks, &{&1.title, &1.why}),
              picked_titles: Enum.map(picks, & &1.title)
          }

        {:error, reason} ->
          Logger.warning("選別に失敗した: #{inspect(reason)}")
          %{state | selecting: false}
      end

    {:noreply, broadcast(state)}
  end

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

  defp apply_result(state, {:ok, %{collection: collection, articles: articles}}) do
    # 溜まったものが入れ替わったら、前の選別はもう当てにならない
    %{
      state
      | status: :ready,
        collection: collection,
        articles: articles,
        checked_at: DateTime.utc_now(),
        reason: nil,
        task: nil
    }
  end

  defp apply_result(state, {:error, reason}) do
    # 一度でも読めていれば、前に読めたものを消さずに残す
    status = if state.checked_at, do: :stale, else: :unavailable
    %{state | status: status, reason: reason, task: nil}
  end

  defp throttled?(%__MODULE__{last_run_at: nil}), do: false
  defp throttled?(%__MODULE__{last_run_at: at}), do: now_ms() - at < @min_run_interval_ms

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(
      Antenna.PubSub,
      topic(state.collection_name),
      {:news_updated, public(state)}
    )

    state
  end

  # 溜まったものが変わったかの目印。見出しの並びが同じなら選び直さない
  defp signature(articles), do: articles |> Enum.map(& &1.title) |> :erlang.phash2()

  # 画面へ渡す形。内部で持っているタスクや計測用の時刻は出さない
  defp public(state) do
    %{
      # どの話題のものか。**画面が取り違えないための印** —— 話題を切り替えた直後に
      # 前の話題の結果が届くことがある
      name: state.collection_name,
      status: state.status,
      collection: state.collection,
      articles: state.articles,
      picks: state.picks,
      picked_titles: state.picked_titles,
      selecting: state.selecting,
      checked_at: state.checked_at,
      reason: state.reason,
      configured: chiezo_base_url() != nil
    }
  end

  # ---- Chiezo とのやり取り ------------------------------------------------

  defp perform(:refresh, base, name), do: read(base, name)

  defp perform({:request, topic}, base, name) do
    with :ok <- create_collection(base, name, topic) do
      read(base, name)
    end
  end

  defp perform(:run, base, name) do
    with :ok <- run_collection(base, name) do
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

            {:ok, %{collection: collection, articles: to_articles(detail["recent"])}}

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
    payload =
      Jason.encode!(
        Map.merge(
          %{
            name: name,
            description: description(topic),
            prompt: prompt(topic),
            interval_minutes: @interval_minutes,
            # ニュースは足していくもの。Chiezo の既定と同じだが、
            # 集め方が 2 つある層なので、どちらのつもりかは明示して置く
            mode: "append",
            requested_by: "antenna"
          },
          # 名指ししないものは送らない —— null を送ると「指定しない」と同じだが、
          # 依頼の本文に空の項目が並ぶと、何を決めて何を任せたのかが読めない
          collect_settings(topic) |> Enum.reject(&(elem(&1, 1) == nil)) |> Map.new()
        )
      )

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

  defp run_collection(base, name) do
    case post(base <> "/v1/collect/" <> name <> "/run", "", @run_timeout) do
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
      mode: item["mode"] || "append",
      # 誰に頼んでいるか。**Chiezo が持っているものが正** —— 依頼した後は
      # 向こうの画面から変えられるので、antenna の設定を映しても嘘になりうる
      backend: item["backend"],
      model: item["model"],
      effort: item["effort"],
      # Chiezo が実際に持っている本文。**antenna の雛形とは限らない** ——
      # 依頼した後は Chiezo の画面から直せるので、いま何を頼んでいるかは向こうが正
      prompt: item["prompt"] || "",
      # 件数は定義には入っていない。読めたときに detail が上書きする
      docs: 0,
      requested_by: item["requested_by"] || "",
      url: chiezo_url(item["url"])
    }
  end

  def to_collection(_item), do: nil

  @doc false
  # 溜まっているものを画面の並びにする。新しい順は Chiezo が付けたまま保つ。
  #
  # **原文の URL は `extra` の中**（Chiezo が集めた1件の出典）。本文の要約は
  # `opening`。どちらも無いことがあるので、無ければその欄を出さない
  def to_articles(recent) when is_list(recent) do
    Enum.flat_map(recent, fn
      %{"title" => title} = item when is_binary(title) ->
        title = String.trim(title)

        if title == "" do
          []
        else
          {importance, reason} = importance(title)
          extra = if is_map(item["extra"]), do: item["extra"], else: %{}

          [
            %{
              title: title,
              url: source_url(extra["url"]),
              summary: trimmed(item["opening"]),
              collected_at: item["updated_at"] || extra["collected_at"],
              importance: importance,
              reason: reason
            }
          ]
        end

      _item ->
        []
    end)
  end

  def to_articles(_recent), do: []

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
  （`Antenna.Topics.defined/0`）にあります。

  `{cursor}` は実行のたびに進む印で、AI が `next_cursor` で次を返します
  （前回以降を集めるのに使う）。
  """
  def prompt(topic \\ nil) do
    """
    {cursor} 以降に日本語で報じられたもののうち、次に当てはまるものを10件集めてください。

    #{interest_of(topic)}

    title はそれを一意に指す短い見出しにします（同じ出来事には同じ見出しを使ってください）。
    body には3行程度の要約を書き、記事本文はそのまま写さないでください。
    url には出典の記事のURLを必ず入れます。
    tags には分野を1〜3個入れます。
    next_cursor には、今回集めた中でいちばん新しい記事の日時をISO8601で入れてください。
    """
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
    do: "antenna の「#{name}」。#{interest_of(topic)}"

  defp description(_topic), do: "antenna のニュース。#{@default_interest}"

  # 誰に集めさせるか。**話題の設定が先で、環境変数は後** —— 画面（`/settings`）で
  # 決めた相手が無視されると、設定した側からは何も起きていないように見える。
  # どちらも空なら Chiezo の既定にまかせる
  defp collect_settings(%{collect_backend: backend} = topic) when is_binary(backend) do
    %{backend: backend, model: topic.collect_model, effort: topic.collect_effort}
  end

  defp collect_settings(_topic), do: backend_settings()

  @critical_keywords ~w(
    地震 津波 避難 警報 台風 大雨 災害 感染症 選挙 首相 日銀 金利 戦争
  )

  @doc false
  # 重要度の判定。語の並びだけで決まるのでここだけでテストできる
  def importance(title) do
    if Enum.any?(@critical_keywords, &String.contains?(title, &1)) do
      {2, "暮らしや社会への影響が大きい可能性があります"}
    else
      {1, "今日の主要な報道として集めました"}
    end
  end
end
