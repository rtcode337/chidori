defmodule AntennaWeb.NewsLive do
  @moduledoc """
  最新情報の一覧。集めるのは Chiezo の「集める」層で、この画面は依頼と閲覧だけを持ちます。

  収集は数十秒から数分かかることがあるので、押した人に再読み込みをさせません。
  結果は `Antenna.News` からの通知で届きます。

  **話題ごとにタブで分けます。** 集める相手も溜まるものも話題ごとに別なので、
  1 つに混ぜると、どちらの状態を見ているのか読めなくなります。タブに並ぶのは
  `Antenna.Topics` の話題そのもので、並びも定義のとおりです。
  """

  use AntennaWeb, :live_view

  alias Antenna.Jst
  alias Antenna.News
  alias Antenna.Topics

  @impl true
  def mount(_params, _session, socket) do
    # 話題が 1 つも無いと、タブも収集も出せない
    {:ok, assign(socket, topics: Topics.list())}
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
       news: if(topic, do: News.current(News.server(topic.collection)), else: News.empty())
     )}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    with_server(socket, &News.refresh/1)
  end

  def handle_event("request", _params, socket) do
    # 依頼の本文も相手も話題の設定から作る。DB を読むのは画面のあるこちら側
    topic = socket.assigns.topic
    with_server(socket, &News.request_collection(&1, topic))
  end

  def handle_event("run", _params, socket) do
    with_server(socket, &News.run_now/1)
  end

  def handle_event("select", _params, socket) do
    # 押したときは、溜まったものが変わっていなくても選び直す
    topic = socket.assigns.topic
    with_server(socket, &News.select(&1, topic, true))
  end

  defp with_server(socket, fun) do
    if topic = socket.assigns.topic, do: fun.(News.server(topic.collection))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:news_updated, news}, socket) do
    topic = socket.assigns.topic

    # 話題を切り替えた直後は、前の話題の結果が遅れて届くことがある
    if topic && news.name == topic.collection do
      # 溜まったものが変わっていれば選び直す（変わっていなければ何も起きない）
      if news.status == :ready, do: News.select(News.server(topic.collection), topic)
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
  選ばれたものを先に、それ以外を後に並べる。

  **選ばれなかったものも消さない** —— 選別は絞り込みであって検閲ではないので、
  選から漏れたものも読めるようにしておく。
  """
  def sorted_articles(%{articles: articles, picked_titles: picked}) when picked != [] do
    order = picked |> Enum.with_index() |> Map.new()
    {chosen, rest} = Enum.split_with(articles, &Map.has_key?(order, &1.title))
    Enum.sort_by(chosen, &order[&1.title]) ++ rest
  end

  def sorted_articles(%{articles: articles}), do: articles

  @doc "AI がこれを選んだ理由（選ばれていなければ nil）。"
  def pick_reason(news, article), do: Map.get(news.picks || %{}, article.title)

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
  antenna の雛形を出し続けると、実際に投げている文と画面が食い違う。
  まだ依頼していないときは、これから送る雛形を出す。
  """
  def prompt_text(%{collection: %{prompt: prompt}}, _topic)
      when is_binary(prompt) and prompt != "",
      do: prompt

  def prompt_text(_news, topic), do: News.prompt(topic)

  def prompt_note(%{collection: nil}), do: "「収集を依頼する」を押すと、この内容で Chiezo に頼みます。"

  def prompt_note(_news),
    do: "いま Chiezo が持っている内容です。直すのは Chiezo の管理画面の「集める」から。"

  @doc """
  Chiezo の収集の状態を短く並べたもの。動いているかの判断に要る3つを出す。
  """
  def collection_facts(%{collection: nil}), do: []

  def collection_facts(%{collection: c}) do
    [
      {"状態", if(c.enabled, do: "有効", else: "止まっている")},
      {"頼む相手", backend_text(c)},
      {"集め方", if(c.mode == "refine", do: "整理する（磨いていく）", else: "集める（足していく）")},
      {"間隔", if(c.interval_minutes, do: "#{c.interval_minutes} 分ごと", else: "—")},
      {"次に集める", at_text(c.next_run_at, c.enabled)},
      {"溜まった数", "#{c.docs} 件"},
      {"前回", last_text(c)}
    ]
  end

  # 相手は Chiezo が持っているものを出す。未指定なら誰に行くかは Chiezo が決める
  defp backend_text(%{backend: nil}), do: "Chiezo の既定にまかせる"

  defp backend_text(%{backend: backend} = c) do
    detail = Enum.reject([c.model, c.effort], &(&1 in [nil, ""]))
    if detail == [], do: backend, else: "#{backend}（#{Enum.join(detail, " / ")}）"
  end

  defp at_text(_at, false), do: "—（止まっています）"
  defp at_text(nil, _enabled), do: "—"
  defp at_text(at, _enabled), do: Jst.format(at)

  defp last_text(%{last_run_at: nil}), do: "まだ集めていません"

  defp last_text(%{last_status: "error", last_error: error}) when is_binary(error),
    do: "失敗: #{error}"

  defp last_text(%{last_run_at: at}), do: Jst.format(at)

  defp reason_text(:chiezo_not_configured),
    do: "Chiezo の場所が設定されていないため、収集を頼めません。"

  defp reason_text(:collect_unsupported),
    do: "この Chiezo には「集める」層がまだありません。Chiezo を新しくすると使えるようになります。"

  defp reason_text(:collect_disabled),
    do: "Chiezo 側で「集める」層が無効です。CHIEZO_NOTES_DIR と CHIEZO_TRIGGER_URL を設定すると有効になります。"

  defp reason_text(:collection_disabled),
    do: "収集はまだ止まっています。Chiezo の管理画面の「集める」で有効にしてください。"

  defp reason_text(:not_requested), do: "Chiezo にこの収集がありません。先に依頼してください。"
  defp reason_text(:too_soon), do: "続けて集めさせようとしています。少し時間を置いてから押してください。"
  defp reason_text({:chiezo_refused, status, nil}), do: "Chiezo が依頼を断りました（#{status}）。"

  defp reason_text({:chiezo_refused, _status, message}), do: "Chiezo が依頼を断りました: #{message}"

  defp reason_text(:chiezo_unavailable), do: "Chiezo に接続できませんでした。"
  defp reason_text({:chiezo_status, status}), do: "Chiezo が #{status} を返しました。"
  defp reason_text(:chiezo_unexpected_body), do: "Chiezo の応答を解釈できませんでした。"
  defp reason_text(:collection_crashed), do: "問い合わせの途中で問題が起きました。もう一度押してください。"
  defp reason_text(_reason), do: "Chiezo とのやり取りに失敗しました。"
end
