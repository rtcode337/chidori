defmodule Tazuna.Datasets.Books do
  @moduledoc """
  **技術書を勧めている記事**を集めるところ。本そのものは別の収集で数えます
  （`Tazuna.Datasets.Bookshelf`）。

  **なぜ記事を溜めるのか。** 「定番かどうか」を決めるのは**何本の記事が挙げているか**で、
  その数は**母数が動くと意味を失います** —— AI にその場で探させて数えさせると、
  同じ本が次の回では見つからず、数が増えたり戻ったりします。
  記事のほうを溜めておけば、**同じ材料からは同じ数**が出ます。

  **立ち上げは人気順、定常は新着順。** 定番の根拠は何年も前の記事にあるので、
  新着だけを追っても永遠に届きません（実測で、人気順なら 2022〜2024 年の記事が
  ブックマーク 1,000 超えの順に出てきます）。人気順はページを繰れるので、
  **1 周目で過去を拾い、2 周目からは新着だけが足されます**（同じ記事は
  見出しと URL で弾かれます）。

  **本の名前を書くのは AI です。** 配信元が配るのは見出しと要約だけなので、
  どの本を勧めているかは記事を開かないと分かりません —— そこは機械では無理です。
  付けるのは `#{"本"}:<書名>` のタグで、**数えるのはそのタグ**になります。
  """

  alias Tazuna.Chiezo
  alias Tazuna.Datasets.BookQueries
  alias Tazuna.SweepNames

  @collection "tazuna_book_posts"

  # 記事 1 本ごとに付く印
  @kind_tag "記事"

  # 勧めている本のタグの頭。**数える側（本棚）はこの頭だけを拾います**
  @book_tag "本"

  # 最初の回の検索文。**2 回目からは AI が考えます**（`Tazuna.Datasets.BookQueries`）——
  # 同じ検索文で引き直しても同じ記事が返るだけなので、回ごとに差し替える
  @queries ["技術書", "エンジニア 本 おすすめ", "プログラマ 読むべき 本", "読んでよかった 技術書"]

  # 機械収集の回の間隔。**Chiezo の時計では回さない**（tazuna が決めた時刻に、
  # 検索文を差し替えてから起こす）ので、使われない。Chiezo が値を要るので置く
  @pick_minutes 1440

  # 整理の回の間隔。**記事を開くので web を開ける**（配信元は要約しか配らない）
  @read_minutes 720

  @doc "記事 1 本ごとに付く印。"
  def kind_tag, do: @kind_tag

  @doc "勧めている本のタグの頭（`本:リーダブルコード` の形）。"
  def book_tag, do: @book_tag

  @doc "探す語。"
  def queries, do: @queries

  @doc """
  溜め先の収集の名前（= Chiezo のソース名）。**後から変えない**。
  """
  def collection do
    case System.get_env("TAZUNA_BOOK_POSTS_COLLECTION", "") |> String.trim() do
      "" -> @collection
      name -> name
    end
  end

  @doc """
  その本を勧めている記事（**新しい順**）。本の見出し（「本:<書名>」）が、
  そのまま記事に付いているタグなので、タグで引けます。
  """
  def recommending(base, book_title) when is_binary(book_title) do
    query =
      URI.encode_query(%{"tag" => book_title, "fields" => "title,extra", "limit" => 100})

    case Chiezo.get(base <> "/v1/" <> collection() <> "/filter?" <> query) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"results" => results}} when is_list(results) ->
            {:ok, results |> Enum.map(&to_post/1) |> Enum.sort_by(& &1.published_at, :desc)}

          _other ->
            {:error, :chiezo_unexpected_body}
        end

      {:ok, %{status: 404}} ->
        {:ok, []}

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  defp to_post(result) do
    extra = if is_map(result["extra"]), do: result["extra"], else: %{}

    %{
      title: to_string(result["title"] || ""),
      url: if(is_binary(extra["url"]), do: extra["url"]),
      # 日付の無い記事は後ろへ（空文字は降順で最後に来る）
      published_at: to_string(extra["published_at"] || "")
    }
  end

  @doc "データ収集の画面に出す 1 タブぶん。"
  def definition do
    %{
      key: "books",
      name: "技術書",
      module: __MODULE__,
      eyebrow: "BOOKS ENGINEERS KEEP RECOMMENDING",
      title: "定番の技術書",
      description:
        "技術者が繰り返し勧めている本を集めます。良し悪しは AI に決めさせず、" <>
          "勧めている記事を溜めて、その数で定番かどうかを分けます。",
      collection: collection(),
      reader: "読む人",
      unit: "記事 1 本 1 文書",
      note:
        "本そのものは別の収集で数えます（下の「本棚」）。" <>
          "数える材料がこの記事なので、ここが溜まるほど数は確かになります。",
      # **この収集から作る収集**（画面に別の口として出します）
      derived: Tazuna.Datasets.Bookshelf,
      survey_sweep: SweepNames.tidy(),
      # **tazuna が決めた時刻に起こす巡回**（`Tazuna.Datasets.SurveyScheduler`）。
      # 起こす前に検索文を AI に考えさせて差し替える（`before_survey/1`）
      survey_plan_sweep: SweepNames.machine(),
      partition_sweeps: []
    }
  end

  @doc "1 本ぶんに入る項目。"
  def fields do
    [
      %{field: "記事の見出し", stored: "title", who: "配信元（機械）"},
      %{field: "URL", stored: "extra.url", who: "配信元（機械）"},
      %{field: "配信日", stored: "extra.published_at", who: "配信元（機械）"},
      %{
        field: "勧めている本",
        stored: "タグ「#{@book_tag}:<書名>」",
        who: "AI（記事を開いて読む。**ここが数の元**）"
      },
      %{field: "何の記事か", stored: "body", who: "AI（1〜2 行）"}
    ]
  end

  @doc """
  配信元。**はてなブックマークの検索**を RSS で引きます（検索文 1 つにつき、
  人気順と新着順の 1 ページずつ）。**どの検索文で入ったかを印にします**
  （「#{BookQueries.query_tag()}:<検索文>」）—— 次の回に、検索文ごとに何件入ったかを
  数えて AI に見せるため。

  検索文は、いま配信元に載っている組（AI が考えたもの）。まだ無ければ最初の組。
  """
  def feed_spec(queries \\ nil) do
    queries = queries || current_queries()

    urls =
      for q <- queries, sort <- ["popular", "recent"] do
        %{url: search_url(q, sort, 1), tags: ["はてな", BookQueries.query_tag() <> ":" <> q]}
      end

    %{urls: urls, since: "always", limit: 200}
  end

  @doc "いま配信元に載っている検索文。まだ無ければ最初の組。"
  def current_queries do
    case BookQueries.current(collection()) do
      [] -> @queries
      queries -> queries
    end
  end

  @doc """
  決めた時刻の回の頭にすること（`Tazuna.Datasets.Survey.run/3` が呼ぶ）。
  **検索文を AI に考えさせ、配信元を書き換えてから**機械収集を起こす ——
  同じ検索文のまま起こしても、同じ記事が返るだけです。
  """
  def before_survey(base) do
    with {:ok, queries} <- BookQueries.refresh(base, collection(), @queries) do
      Chiezo.patch(base, collection(), %{feed: feed_spec(queries)})
    end
  end

  defp search_url(query, sort, page) do
    "https://b.hatena.ne.jp/q/" <>
      URI.encode(query, &URI.char_unreserved?/1) <>
      "?" <>
      URI.encode_query(%{"mode" => "rss", "target" => "text", "sort" => sort, "page" => page})
  end

  @doc """
  巡回 2 本。**拾うのは機械、読むのは AI**（配信元は要約しか配らないので、
  どの本を勧めているかは記事を開かないと分かりません）。
  """
  def sweeps do
    [
      # **Chiezo の時計では回さない**（止めておき、tazuna が決めた時刻に起こす）
      %{
        name: SweepNames.machine(),
        interval_minutes: @pick_minutes,
        use_feed: true,
        only_new: true,
        enabled: false
      },
      %{name: SweepNames.tidy(), interval_minutes: @read_minutes, web: true, prompt: :read}
    ]
  end

  @doc """
  整理の回の依頼文。**手元の記事を開いて、挙げている本をタグにします。**

  **読ませるのは、まだ目を通していない記事だけ**（`{unreviewed}`）。全部を渡して
  いた頃は、読み終えた記事も開けなかった記事も毎回開き直していました ——
  溜まるほど 1 回が重くなります。

  **自分で探しに行く仕事は頼みません。** 頼んでいた頃は、同じ有名な記事を毎回
  見つけ直しては URL で弾かれることがあり、枠を食うだけでした。記事を広げるのは
  回ごとに AI が考える検索文のほう（`Tazuna.Datasets.BookQueries`）。
  """
  def read_prompt do
    """
    技術書を勧めている記事・技術書を参考文献として挙げている記事を溜めています。
    **新しく入った記事を読んで、挙げている本をタグにしてください。**

    次に並んでいるのは、**まだ誰も読んでいない記事だけ**です（読み終えた記事は
    並びません。ここに載せたものは、読めても読めなくても次からは並びません）。

    {unreviewed}

    記事を開いて、**その記事が勧めている本・参考文献として挙げている本**を
    「#{@book_tag}:<書名>」のタグで並べてください（1 本の記事に何冊でも）。

    - **書名は邦題があれば邦題**で、**版や巻の数字は入れない**でください
      （「リーダブルコード」であって「リーダブルコード 第 2 版」ではない）。
      **ここが数える鍵**なので、表記が割れると同じ本が別々に数えられます
    - **勧めている本・参考にした本だけ**です。「読んでいない」「合わなかった」と
      書かれている本は入れないでください
    - body には**何の記事か**を 1〜2 行（「新人向けの推薦リスト」「設計の本を 5 冊」）
    - **開けなかった記事は触らないでください**（当て推量で本を並べると、
      根拠の無い数になります）
    - **本を 1 冊も挙げていない記事・宣伝と本の紹介ページ**（出版社の告知や書店の
      ページ）は、tags に "#{Chiezo.tombstone_tag()}" だけを入れて返してください
      （墓標。body になぜ外すかを 1 行）

    **「#{BookQueries.query_tag()}:」で始まるタグは消さずに残してください**（どの検索で
    入った記事かの印で、次の検索文を考えるのに使います）。

    **触ったものだけ返してください。** 触れなかったものはそのまま残ります。
    """
  end

  @doc "巡回ごとの依頼文（画面に出すため）。"
  def prompts, do: [{SweepNames.tidy(), read_prompt()}]

  @doc "Chiezo へ送る収集の設定ぜんぶ。"
  def attrs(choices \\ %{}) do
    %{
      name: collection(),
      description: "tazuna のデータ収集（技術書を勧めている記事）",
      prompt: read_prompt(),
      interval_minutes: @read_minutes,
      feed: feed_spec(),
      sweeps: with_choices(sweeps(), choices),
      # **網羅。** 2022 年の記事も根拠として生きている（期限で落とすと数が減る）
      kind: "stock",
      requested_by: "tazuna"
    }
  end

  defp with_choices(sweeps, choices) do
    for sweep <- Enum.map(sweeps, &resolve_prompt/1) do
      case Map.get(choices, sweep.name) do
        nil -> sweep
        picked -> Map.merge(sweep, Map.reject(picked, fn {_k, v} -> is_nil(v) end))
      end
    end
  end

  defp resolve_prompt(%{prompt: :read} = sweep), do: %{sweep | prompt: read_prompt()}
  defp resolve_prompt(sweep), do: sweep

  @doc "墓標のタグ（依頼文から参照するため）。"
  def tombstone_tag, do: Chiezo.tombstone_tag()
end
