defmodule Chidori.Datasets.Books do
  @moduledoc """
  **技術書を勧めている記事**を集めるところ。本そのものは別の収集で数えます
  （`Chidori.Datasets.Bookshelf`）。

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

  alias Chidori.Chiezo
  alias Chidori.SweepNames

  @collection "chidori_book_posts"

  # 記事 1 本ごとに付く印
  @kind_tag "記事"

  # 勧めている本のタグの頭。**数える側（本棚）はこの頭だけを拾います**
  @book_tag "本"

  # 最初の回の検索文。**2 回目からは AI が考えます** —— 同じ検索文で引き直しても
  # 同じ記事が返るだけなので、回ごとに差し替える。考えるのも控えるのも Chiezo
  # （機械収集の巡回の依頼文に `{queries}` を書くと、その巡回の相手が考える）
  @queries ["技術書", "エンジニア 本 おすすめ", "プログラマ 読むべき 本", "読んでよかった 技術書"]

  # 1 回に使う検索文の数。**1 つにつき配信元を 4 本使う**（人気順 3 ページと新着順）ので、
  # Chiezo の上限（40 本）に収まる数
  @per_run 8

  # 人気順を何ページまで引くか。**定番の推薦記事は 2〜3 ページ目に集まっている** ——
  # 1 ページ目だけでは 98 件入っても、2 本以上の記事に出てくる本が 2 冊しか無かった
  @popular_pages 3

  # 記事に付く、どの検索文で入ったかの印の頭（Chiezo が付けて、数える）
  @query_tag "検索"

  # 使った検索文を、また使えるようになるまでの日数。**二度と使えない形にはしない** ——
  # 本を勧める記事は少しずつ増えるので、しばらく経てば同じ検索文でも新しい記事が当たる
  @reuse_days 60

  # 機械収集の回の間隔。**回るたびに AI が検索文を考える**ので、枠を見て空ける
  @pick_minutes 1440

  # 整理の回の間隔（どの収集も同じ。`Chidori.SweepNames.tidy_minutes/0`）。
  # **記事を開くので web 検索が要る**（配信元は要約しか配らない）。開け閉めは Chiezo の
  # 収集ぜんたいの設定（`web`。既定で開いている）で、巡回ごとには決められないので送らない

  @doc "記事 1 本ごとに付く印。"
  def kind_tag, do: @kind_tag

  @doc "勧めている本のタグの頭（`本:リーダブルコード` の形）。"
  def book_tag, do: @book_tag

  @doc "最初の回の検索文。"
  def queries, do: @queries

  @doc "記事に付く、どの検索文で入ったかの印の頭（`検索:<検索文>` の形）。"
  def query_tag, do: @query_tag

  @doc """
  溜め先の収集の名前（= Chiezo のソース名）。**後から変えない**。
  """
  def collection, do: @collection

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
      # 配信元が入れた URL。http・https 以外はリンクにしない
      url: Chidori.SafeUrl.href(extra["url"]),
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
      # 検索文を AI に考えさせて引く収集（収集の画面に、これまで使った検索文の一覧を出す）
      queries: true,
      # 収集の画面の節の見出し（本棚の節と同じ高さに並べる）
      collection_name: "技術書を勧めている記事",
      reader: "読む人",
      unit: "記事 1 本 1 文書",
      note:
        "本そのものは別の収集で数えます（下の「本棚」）。" <>
          "数える材料がこの記事なので、ここが溜まるほど数は確かになります。",
      # **この収集から作る収集**（画面に別の口として出します）
      derived: Chidori.Datasets.Bookshelf,
      survey_sweep: SweepNames.tidy(),
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
        who: "AI（記事を開いて読む。ここが数の元）"
      },
      %{field: "何の記事か", stored: "body", who: "AI（1〜2 行）"}
    ]
  end

  @doc """
  配信元。**はてなブックマークの見出し検索**を RSS で引きます（検索文 1 つにつき、
  人気順 3 ページと新着順 1 ページ）。URL の `{query}` に、回ごとの検索文が入ります
  （展開するのは Chiezo）。入った記事には「#{@query_tag}:<検索文>」の印が付き、
  次の回に検索文ごとの件数を数えて AI に見せます。

  **本文ではなく見出しを探す**（`target=title`）。本文検索は語をどこかに含む記事を
  ゆるく拾うので、「エンジニア 本 おすすめ」で転職の報告や SEO の記事が並び、
  入った 163 件のうち本を勧めていたのは 5 件だった。見出しに語がある記事なら、
  少なくとも本の話をしている。
  """
  def feed_spec do
    %{
      urls:
        for(page <- 1..@popular_pages, do: %{url: search_url("popular", page), tags: ["はてな"]}) ++
          [%{url: search_url("recent", 1), tags: ["はてな"]}],
      queries: @queries,
      query_tag: @query_tag,
      per_run: @per_run,
      reuse_days: @reuse_days,
      since: "always",
      # 32 本 × 1 本 40 件まで。**Chiezo の天井（1,600）の手前で切らない** ——
      # 切ると 1 本あたり数件しか残らず、ページを深く引いた意味が消える
      limit: 1600
    }
  end

  # `{query}` は Chiezo が符号化して入れるので、ここでは差し込み口のまま置く
  defp search_url(sort, page) do
    "https://b.hatena.ne.jp/q/{query}?" <>
      URI.encode_query(%{"mode" => "rss", "target" => "title", "sort" => sort, "page" => page})
  end

  @doc """
  巡回 2 本。**拾うのは機械、読むのは AI**（配信元は要約しか配らないので、
  どの本を勧めているかは記事を開かないと分かりません）。
  """
  def sweeps do
    [
      # **AI が検索文を考えてから引く回。** 依頼文に `{queries}` があるので、Chiezo が
      # その巡回の相手に考えさせる（相手は画面の巡回の表で選ぶ）
      %{
        name: SweepNames.machine(),
        interval_minutes: @pick_minutes,
        use_feed: true,
        only_new: true,
        prompt: :queries
      },
      # **機械収集が 1 回走るまで待つ**（`after`。有効にした直後に、空の収集を読ませない）
      %{
        name: SweepNames.tidy(),
        after: SweepNames.machine(),
        interval_minutes: Chidori.SweepNames.tidy_minutes(),
        prompt: :read
      }
    ]
  end

  @doc """
  整理の回の依頼文。**手元の記事を開いて、挙げている本をタグにします。**

  **読ませるのは、まだ目を通していない記事だけ**（`{unreviewed}`）。全部を渡して
  いた頃は、読み終えた記事も開けなかった記事も毎回開き直していました ——
  溜まるほど 1 回が重くなります。

  **自分で探しに行く仕事は頼みません。** 頼んでいた頃は、同じ有名な記事を毎回
  見つけ直しては URL で弾かれることがあり、枠を食うだけでした。記事を広げるのは
  回ごとに AI が考える検索文のほう（機械収集の回の `queries_prompt/0`）。
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
    - **技術書だけ**です。読書記録の記事には小説や漫画も並びますが、それは入れないで
      ください（技術書の範囲は下に）
    - body には**何の記事か**を 1〜2 行（「新人向けの推薦リスト」「設計の本を 5 冊」）
    - **開けなかった記事は触らないでください**（当て推量で本を並べると、
      根拠の無い数になります）
    - **技術書を 1 冊も挙げていない記事・宣伝と本の紹介ページ**（出版社の告知や書店の
      ページ）は、tags に "#{Chiezo.tombstone_tag()}" だけを入れて返してください
      （墓標。body になぜ外すかを 1 行）

    #{Chidori.Datasets.Bookshelf.scope_text()}

    **「#{@query_tag}:」で始まるタグは消さずに残してください**（どの検索で
    入った記事かの印で、次の検索文を考えるのに使います）。

    **触ったものだけ返してください。** 触れなかったものはそのまま残ります。
    """
  end

  @doc """
  機械収集の回の依頼文。**検索文を考えさせるだけ**です（記事を探すのは機械）。

  `{queries}` には、Chiezo がこれまでの検索文と、それぞれで入った記事の数・
  消されずに残った数を差し込みます。**残った数を見させる** —— 全文検索は語を
  含む記事をゆるく拾いがちで、入った数が多くても大半が本と関係ない検索文がある。
  """
  def queries_prompt do
    """
    はてなブックマークの**見出し検索**（記事の題名だけを探します）で、**技術書を勧めている
    記事・技術書を参考文献として挙げている記事**を見つけるための検索文を #{@per_run} 個
    考えてください。

    これまでに使った検索文と、それぞれで入った記事の数です（新しい順）。
    「消されずに残った」は、整理の回が本の推薦ではないとして外さなかった数です。

    {queries}

    - **まだ試していない切り口**にしてください（同じ検索文・言い換えただけのものは、
      同じ記事が返るだけです）。**残った数が多い検索文の近くを掘ってください** ——
      入った数が多くても、残った数が少ない検索文は本と関係ない記事ばかり拾っています
    - 切り口の例: 分野（設計・DB・ネットワーク・セキュリティ・機械学習…）、
      読み手（新人・リーダー・SRE…）、記事の形（読書記録・書評・輪読会・
      参考文献・年間ベスト…）、言語（英語の記事）
    - 1 つの検索文は 1〜3 語。**記事の題名に出てくる言い方**にしてください
      （「おすすめ 技術書」「読んだ本 2025」「本棚 エンジニア」のように。
      題名だけを探すので、長すぎると 1 件も当たりません）
    - #{@reuse_days} 日より前に使った検索文は、また使えます（記事は増えていくので、
      当たった検索文を時間をおいて使い直すのも有効です）
    """
  end

  @doc "巡回ごとの依頼文（画面に出すため）。"
  def prompts, do: [{SweepNames.machine(), queries_prompt()}, {SweepNames.tidy(), read_prompt()}]

  @doc "Chiezo へ送る収集の設定ぜんぶ。"
  def attrs(choices \\ %{}) do
    %{
      name: collection(),
      description: "Chidori のデータ収集（技術書を勧めている記事）",
      prompt: read_prompt(),
      interval_minutes: Chidori.SweepNames.tidy_minutes(),
      feed: feed_spec(),
      sweeps: with_choices(sweeps(), choices),
      # **網羅。** 2022 年の記事も根拠として生きている（期限で落とすと数が減る）
      kind: "stock",
      requested_by: "chidori"
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
  defp resolve_prompt(%{prompt: :queries} = sweep), do: %{sweep | prompt: queries_prompt()}
  defp resolve_prompt(sweep), do: sweep

  @doc "墓標のタグ（依頼文から参照するため）。"
  def tombstone_tag, do: Chiezo.tombstone_tag()
end
