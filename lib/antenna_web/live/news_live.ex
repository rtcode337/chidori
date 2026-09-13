defmodule AntennaWeb.NewsLive do
  @moduledoc """
  最新情報の一覧。集めるのは Chiezo の「集める」層で、この画面は依頼と閲覧だけを持ちます。

  収集は数十秒から数分かかることがあるので、押した人に再読み込みをさせません。
  結果は `Antenna.News` からの通知で届きます。

  **話題ごとにタブで分けます。** 集めるものも溜まるものも話題ごとに別なので、
  1 つに混ぜると、どちらの状態を見ているのか読めなくなります。タブに並ぶのは
  `Antenna.Topics` の話題そのもので、並びも定義のとおりです。

  **一覧の並びは重要度です。** 先頭に出すのは要約の巡回が書いたまとめで、その下に
  1 件ずつを重要度の高い順に並べます —— どちらも収集の側が付けたもので、
  この画面では何も判断しません。
  """

  use AntennaWeb, :live_view

  import AntennaWeb.Collect
  import AntennaWeb.CollectPanel

  alias Antenna.News
  alias Antenna.Topics

  @impl true
  def mount(_params, _session, socket) do
    # 相手の一覧は**繋がってから、待たずに**引く。画面の中で同期に引くと、Chiezo が
    # 遅いあいだページが固まる（選択肢が無くても記事は読めるので、待つ価値が無い）
    socket = assign(socket, topics: Topics.list(), backends: [], picks: %{}, asking: false)

    socket =
      if connected?(socket) do
        start_async(socket, :backends, fn -> Antenna.Relations.ai_backends() end)
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
       news: if(topic, do: News.current(News.server(topic.collection)), else: News.empty())
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

  重要度を付けるのは情報更新の巡回で、読んだうえでの判断です。ここで並べ替えずに
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
  まとめの本文を、段落と出典に読み分けます。

  **出典の URL は、溜まっている記事に突き合わせて見出しでリンクにします** ——
  裸の URL のままだと、押す前にどこへ行くのか読めません。突き合わない URL は
  そのまま出します（AI が上に無いものを書いたときに、黙って消さないため）。
  """
  def digest_blocks(body, articles) when is_binary(body) do
    known = Map.new(articles, &{&1.url, &1.title})

    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      case source_url_in(line) do
        nil -> {:text, line}
        url -> {:link, url, known[url] || url}
      end
    end)
  end

  def digest_blocks(_body, _articles), do: []

  # 「出典: <URL>」の行と、URL だけの行を拾う
  defp source_url_in(line) do
    case Regex.run(~r{https?://\S+}, line) do
      [url] -> if String.replace(line, url, "") |> String.trim() |> short?(), do: url, else: nil
      _ -> nil
    end
  end

  # URL の前に付くのは「出典:」程度の短い言葉だけ。本文の途中の URL はリンクにしない
  defp short?(rest), do: String.length(rest) <= 6

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
      "漏れ探し・情報更新・要約だけが AI の仕事です。"
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

  # 相手は Chiezo が持っているものを出す。未指定なら誰に行くかは Chiezo が決める
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
