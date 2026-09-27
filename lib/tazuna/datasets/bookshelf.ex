defmodule Tazuna.Datasets.Bookshelf do
  @moduledoc """
  **定番の技術書**。記事の収集（`Tazuna.Datasets.Books`）に付いた
  「本:<書名>」のタグから、**機械で**作ります。

  **数えるのは機械です。** その本のタグが付いている記事の数が、そのまま
  「何本の記事が勧めているか」になります —— AI に数えさせていた頃は、
  **その回の検索運で数が動きました**（同じ本が次の回では見つからない）。

  **AI がやるのは整えるところだけ**です。言い換えを畳む（「リーダブルコード」と
  「Readable Code」）、分野を付ける、技術書でない語を外す、一言で説明する ——
  どれも数では決まりません。**トピックの網とまったく同じ形**です。

  **定番と候補は数で分けます**（#{3} 本以上で定番）。1 人が絶賛した本と、
  何十本の記事が挙げてきた本は別物で、そこが「技術者なら読んでいる」の境目です。
  """

  alias Tazuna.Chiezo
  alias Tazuna.Datasets.Books
  alias Tazuna.SweepNames
  alias Tazuna.Themes
  alias Tazuna.Themes.Search

  @collection "tazuna_books"

  # 1 冊ごとに必ず付く印
  @kind_tag "技術書"

  # 分野のタグの頭
  @field_tag "分野"

  # 本のタグの頭。**その本に付けるべき語を AI が自由に付ける**（数も決めない）。
  # 興味トピックとはこのタグで突き合わせる
  @topic_tag "話題"

  # 話題の語彙を持つ技術ニュースの話題
  @tech_topics "tazuna_tech"

  # 定番と候補の印
  @classic_tag "定番"
  @candidate_tag "候補"

  # ISBN のタグの頭（`ISBN:9784873115658`）。**脇書きと同じ番号をタグにも付ける** ——
  # 整理の回が全冊を見る差し込み口（`{names}`）は見出しとタグしか見せないので、
  # タグに無いと「ISBN がまだ無い本」を選べない
  @isbn_tag "ISBN"
  # 調べて確かめられなかった印。**付いた本は整理のたびには調べ直さない**
  @isbn_unknown "不明"
  # 整理の 1 回で調べ残し（分野・ISBN の無い本）を埋める冊数の上限
  # （web で 1 冊ずつ確かめるので、枠を見て絞る）
  @isbn_per_run 20

  # 定番に上げる下限（勧めている記事の数）。**3 は「たまたま」を外せる数**
  @classic_sources 3

  # 名簿に載せる下限。**1 本の記事にしか出てこない本は、まだ本棚に置かない**
  # （記事が増えれば上がってくる）
  @min_docs 2

  # 直近として数える日数（画面で「いま挙げられている本」を見るため）
  @recent_days 180

  # 一緒に挙げられている本を、1 冊あたり何冊まで持つか
  @link_count 6

  # 名簿の上限。**本を落とすための数ではない** —— 機械収集は足すだけなので、名簿から
  # 外れた本も本棚には残るが、**数が更新されなくなる**（勧める記事が増えても反映されない）。
  # 数えるのは手元の索引だけで軽いので、本棚が育っても外れない高さに置く
  @tag_limit 20_000

  # 画面に並べるときに読む上限（名簿の上限と揃える）
  @list_limit 400

  # 表紙の置き場。**ISBN から URL が決まる**ので、問い合わせずに組み立てられる
  # （無い本は 404 が返るので、画面が隠す）
  @cover_base "https://www.hanmoto.com/bd/img/"
  @book_page_base "https://www.hanmoto.com/bd/isbn/"

  # 機械収集の回と整理の回（AI）の間隔
  @pick_minutes 360
  @tidy_minutes 1440

  @doc "1 冊ごとに必ず付く印。"
  def kind_tag, do: @kind_tag

  @doc "分野のタグの頭。"
  def field_tag, do: @field_tag

  @doc "本のタグの頭。"
  def topic_tag, do: @topic_tag

  @doc "話題の語彙を持つ技術ニュースの収集。"
  def tech_topics, do: @tech_topics

  @doc "定番の印。"
  def classic_tag, do: @classic_tag

  @doc "候補の印。"
  def candidate_tag, do: @candidate_tag

  @doc "ISBN のタグの頭。"
  def isbn_tag, do: @isbn_tag

  @doc "整理の 1 回で調べ残しを埋める冊数の上限。"
  def isbn_per_run, do: @isbn_per_run

  @doc "定番に上げる下限（勧めている記事の数）。"
  def classic_sources, do: @classic_sources

  @doc "分野の語彙。**tazuna が持ちます** —— AI に決めさせると回ごとに表記が割れます。"
  def fields_of_study do
    [
      "プログラミング言語",
      "設計・アーキテクチャ",
      "アルゴリズムとデータ構造",
      "OS・低レイヤ",
      "ネットワーク",
      "データベース",
      "分散システム",
      "セキュリティ",
      "テスト・品質",
      "開発プロセス・チーム",
      "機械学習・AI",
      "インフラ・運用",
      "フロントエンド",
      "数学・理論",
      "キャリア・働き方"
    ]
  end

  @doc "溜め先の収集の名前。**後から変えない**。"
  def collection do
    case System.get_env("TAZUNA_BOOKS_COLLECTION", "") |> String.trim() do
      "" -> @collection
      name -> name
    end
  end

  @doc "画面に出す名前（親の収集の下に並べます）。"
  def name, do: "本棚（定番の技術書）"

  @doc """
  語を拾ってくる指定。**記事のタグのうち「本:」で始まるものだけ**を名簿にします。

  **外す側で書いているのは、いまの Chiezo にそういう口しか無いから**です
  （先頭で選ぶ指定はありません）。`^(?!本:)` は「本: で始まらないものを外す」
  という意味で、記事の種別も配信元の名前もこれで落ちます。
  """
  def extract_spec do
    %{
      source: Books.collection(),
      of: "tags",
      skip: ["^(?!#{Books.book_tag()}:)"],
      min_docs: @min_docs,
      recent_days: @recent_days,
      links: @link_count,
      limit: @tag_limit,
      tags: [%{const: @kind_tag}]
    }
  end

  @doc """
  巡回 2 本。**機械収集の回は AI を呼びません**（機械がタグを数えるだけ）。
  """
  def sweeps do
    [
      %{
        name: SweepNames.machine(),
        interval_minutes: @pick_minutes,
        use_extract: true,
        only_new: true
      },
      %{name: SweepNames.tidy(), interval_minutes: @tidy_minutes, prompt: :tidy}
    ]
  end

  @doc """
  整理の回の依頼文。**数には触らせません**（数えるのは機械の仕事）。
  """
  def tidy_prompt do
    """
    技術書の本棚を整えます。**1 冊 1 文書**で、見出しは「本:<書名>」です。

    **返すときは、いまの見出しを一字も変えずに使ってください**（「本:」も付けたまま）。
    見出しで既にある 1 冊に当てるので、変えると直したつもりの中身が**別の本として
    足され**、元の本は直らないまま残ります。

    **数は機械が数えています**（その本を挙げている記事の本数）。
    **数を書き換えないでください** —— あなたの仕事は、**読めるようにする**ことです。

    ## A. 本棚ぜんたいを見て畳む

    いま並んでいる本の見出しです（本文は出していません）。

    {names}

    **言い換えを 1 つに畳む。** 「リーダブルコード」と「Readable Code」、
    副題の有無、版違いは同じ本です。**残すのは邦題のあるほう**で、
    消すほうには墓標を付けてください（tags に "#{Chiezo.tombstone_tag()}" を入れ、
    body に「◯◯と同じ本」と 1 行）。

    **「本:」で始まらない見出しがあれば、それは間違って足したものです。**
    同じく墓標を付けてください（body に「本:◯◯と同じ本」）。

    **技術書でない語を外す。** 「入門書」「名著」のような**本の名前でないもの**、
    雑誌、資格の問題集は本棚に置きません（同じく墓標で）。

    **調べ残しを埋める。** 上の一覧から、次のどちらかに当たる本を上から
    **#{@isbn_per_run} 冊まで**選んでください。

    - 「#{@field_tag}:」のタグが**まだ無い本** —— 下の B の 1〜4 を**すべて**調べて返す
      （説明の body も書く）
    - 「#{@field_tag}:」はあるが、「#{@isbn_tag}:」で始まるタグが**まだ無い本** ——
      「4. ISBN を調べる」だけでよい（body は返さなくて構いません。今のまま残ります）。
      「#{@isbn_tag}:#{@isbn_unknown}」の付いた本は選ばない

    ## B. 新しく入った本を調べる

    次に並んでいるのは、**まだ誰も調べていない本だけ**です（調べ終えた本は並びません。
    ここに載せたものは、調べがついてもつかなくても次からは並びません）。

    {unreviewed}

    #{book_checks()}

    **印は数で決まります**（あなたは書かなくて構いません）——
    「#{@classic_tag}」は #{@classic_sources} 本以上の記事が挙げている本、
    「#{@candidate_tag}」はそれ未満です。

    **迷ったものは触らないでください。** 間違って畳んだ本は、記事の側から
    もう一度上がってくるまで戻りません。

    **触ったものだけ返してください。** 触れなかったものはそのまま残ります。
    """
  end

  # 1 冊ずつ確かめること（分野・タグ・説明・ISBN）。**整理の回と、1 冊を名指しして
  # 調べ直す回で同じ文を使う** —— 片方だけ直すと、同じ本の調べ方が回によって変わる
  defp book_checks do
    """
    1 冊ずつ、次を書いてください。

    **1. 分野を付ける。** 「#{@field_tag}:<分野>」を、当てはまるものすべて。
    **下の語彙から選んでください**（新しい語は作らない）。
    #{Enum.map_join(fields_of_study(), " / ", & &1)}

    **2. タグを付ける。** 「#{@topic_tag}:<語>」を、**その本に付けるべきだと思う語を
    すべて**付けてください（数は決めません）。扱っている技術や道具の名前、
    考え方や手法、対象の読み手（「新人向け」「リーダー向け」など）、
    **読む人がその本を探すときに引きそうな語**です。読む人が興味で選んだ語と、
    このタグで突き合わせます —— **付いていない語では見つけられません**。
    表記は一般的なものを 1 つ（略称と正式名の両方が通るなら両方）。

    **3. 一言で説明する。** body に 2〜3 行 —— **何の本で、どういう人が読むと効くか**。
    「名著です」ではなく、**読むかどうかを決められること**を書いてください。
    原書名・著者・出た年が分かれば 1 行足してください。

    **4. ISBN を調べる。** **いま手に入る日本語版の ISBN-13**（ハイフンなし）を、
    脇書き（extra）の "isbn" と、タグ「#{@isbn_tag}:<13 桁>」の両方に書いてください。
    邦訳が無い本は原書のもの。**調べて確かめられたときだけ**書いてください ——
    表紙の画像はこの番号から引くので、違う番号だと別の本の表紙が出ます。
    調べても確かめられなかったら、タグ「#{@isbn_tag}:#{@isbn_unknown}」だけを付けてください
    （次からは調べ直しません）。

    **返すときは、いま付いているタグをすべて残したうえで足してください** ——
    返した内容で丸ごと置き換わるので、書かなかったタグ（分野・話題など）は消えます。
    """
    |> String.trim_trailing()
  end

  @doc """
  **1 冊を名指しして調べ直させる**ときの依頼文（本の詳細から頼む割り込み）。

  整理の回の依頼文は**まだ調べていない本**しか並べない（`{unreviewed}`）ので、
  そのまま使うと、調べ終えた本を名指ししても何も並ばない。名指しした 1 冊を
  `{current}` で見せ、書いてあることを確かめ直させる。
  """
  def focus_prompt do
    """
    技術書の本棚の 1 冊を調べ直します。**1 冊 1 文書**で、見出しは「本:<書名>」です。

    **返すときは、いまの見出しを一字も変えずに使ってください**（「本:」も付けたまま）。
    **数は機械が数えています**（その本を挙げている記事の本数）。書き換えないでください。

    {current}

    **いま書いてあることを確かめ、違っていれば直し、無いものは埋めてください。**
    #{book_checks()}

    **確かめられなかったものは触らないでください。** 技術書でないと分かったとき・
    ほかの本と同じ本だと分かったときだけ、墓標を付けてください（tags に
    "#{Chiezo.tombstone_tag()}" を入れ、body に理由を 1 行）。
    """
  end

  @doc """
  **この本を詳しく調べて**、を Chiezo に頼みます（本棚の整理の回として、1 回だけ）。
  `note` は読む人が書き添えた一言（空でもよい）。
  """
  def focus_book(base, title, note) when is_binary(title) do
    name = title |> String.replace_prefix(Books.book_tag() <> ":", "") |> String.trim()

    written =
      case String.trim(note || "") do
        "" -> "#{name}について、分野・タグ・説明・ISBN を確かめ、違っていれば直し、無いものは埋めてください。"
        text -> "#{name}について、分野・タグ・説明・ISBN を確かめてください。補足: #{text}"
      end

    Chiezo.focus(base, collection(), written, [title], SweepNames.tidy(), nil, focus_prompt())
  end

  @doc "巡回ごとの依頼文（画面に出すため。機械収集の回は AI を呼ばないので持たない）。"
  def prompts, do: [{SweepNames.tidy(), tidy_prompt()}]

  @doc """
  いま本棚にある本の、**分野・タグ・説明・ISBN を埋め直す 1 回だけの依頼文**。

  整理の回は**まだ調べていない本だけ**を見るので、仕組みを入れる前に目を通して
  しまった本（ISBN の欄が無かった頃の本）には、もう回ってきません。
  それを埋めるための割り込みです。
  """
  def backfill_prompt do
    tidy_prompt()
    |> String.replace("{unreviewed}", "{current}")
    |> String.replace(
      "次に並んでいるのは、**まだ誰も調べていない本だけ**です（調べ終えた本は並びません。\n" <>
        "ここに載せたものは、調べがついてもつかなくても次からは並びません）。",
      "**今回だけ、本棚の本を全部並べます。** 分野・タグ・説明・ISBN のうち、" <>
        "**まだ無いものだけ**を埋めてください（あるものはそのまま）。"
    )
  end

  @doc """
  いま本棚にある本を、**1 回だけ全部調べ直させます**（割り込み。`backfill_prompt/0`）。
  名指しした本だけが差し込まれるので、並べている本の見出しを全部渡します。
  """
  def backfill(base, titles) when is_list(titles) do
    Chiezo.focus(
      base,
      collection(),
      "本棚の本の分野・タグ・説明・ISBN のうち、まだ無いものを埋めてください",
      titles,
      SweepNames.tidy(),
      nil,
      backfill_prompt()
    )
  end

  @doc "Chiezo へ送る収集の設定ぜんぶ。"
  def attrs(choices \\ %{}) do
    %{
      name: collection(),
      description: "tazuna のデータ収集（定番の技術書。記事のタグから作る本棚）",
      prompt: tidy_prompt(),
      interval_minutes: @tidy_minutes,
      kind: "stock",
      extract: extract_spec(),
      sweeps: with_choices(sweeps(), choices),
      requested_by: "tazuna"
    }
  end

  @doc """
  収集を用意します —— **無ければ作り、あれば設定を送り直します**
  （トピックの網と同じ形）。
  """
  def setup(base, choices \\ %{}) do
    attrs = attrs(choices)

    with :ok <- Chiezo.request(base, attrs) do
      Chiezo.patch(base, attrs.name, attrs)
    end
  end

  # ---- 画面に並べる ----------------------------------------------------------

  @doc """
  本棚に並んでいる本（**おすすめ度の高い順**）。

  おすすめ度は**勧めている記事の本数**（機械が数えたもの）。同じ本数なら、
  直近で挙げられている本・最後に挙げられた日が新しい本を先にします。
  まだ 1 度も焼いていなければ空（失敗ではない）。
  """
  def list(base) do
    query =
      URI.encode_query(%{
        "tag" => @kind_tag,
        "fields" => "title,tags,opening,extra",
        "limit" => @list_limit
      })

    case Chiezo.get(base <> "/v1/" <> collection() <> "/filter?" <> query) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"results" => results}} when is_list(results) ->
            # **勧めている記事が数えられていない本は並べない。** 本棚に入るのは
            # 機械が数えた本だけで、数を持たないのは整理の回が見出しを書き換えて
            # 別の 1 冊として足してしまったもの（次の整理の回に畳ませる）
            {:ok,
             results
             |> Enum.map(&to_book/1)
             |> Enum.filter(&(&1.docs > 0))
             |> with_interests(near_map(base))
             |> ranked()}

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

  @doc """
  技術ニュースで選んだ興味トピックに**近い語**（均した形 → 興味トピック）。
  興味トピックが無ければ空。トピックの網が読めなければ、興味トピックの名前だけで引く
  （言い換えと子が効かなくなるだけで、強調が全部消えるよりよい）。
  """
  def near_map(base) do
    case Tazuna.News.Interests.list(@tech_topics) do
      [] ->
        %{}

      interests ->
        themes =
          case Themes.list(base, @tech_topics) do
            {:ok, themes} -> themes
            _unreadable -> []
          end

        Search.near_map(themes, interests)
    end
  end

  @doc """
  本ごとに、**近い興味トピック**を埋めます。`near_map` は均した語 → 興味トピック
  （`Tazuna.Themes.Search.near_map/2`）。
  """
  def with_interests(books, near_map) when map_size(near_map) == 0, do: books

  def with_interests(books, near_map) do
    for book <- books do
      near =
        book.topics
        |> Enum.flat_map(&List.wrap(Map.get(near_map, Search.normalize(&1))))
        |> Enum.uniq()

      %{book | near: near}
    end
  end

  @doc "おすすめ度の高い順に並べます。"
  def ranked(books) do
    Enum.sort_by(books, &{-&1.docs, -&1.recent, invert(&1.last_seen), &1.name})
  end

  # 日付の新しいほうを先にするための並べ鍵（文字列の降順）
  defp invert(date), do: date |> String.to_charlist() |> Enum.map(&(-&1))

  @doc false
  def to_book(%{"title" => title} = result) do
    tags = for tag <- result["tags"] || [], is_binary(tag), do: tag
    extra = if is_map(result["extra"]), do: result["extra"], else: %{}
    docs = counted(extra["docs"])
    # **脇書きが先、無ければタグ**（どちらも同じ番号を書かせている）
    isbn =
      isbn13(extra["isbn"]) ||
        Enum.find_value(tags, fn tag ->
          case tag do
            "#{@isbn_tag}:" <> number -> isbn13(number)
            _other -> nil
          end
        end)

    %{
      title: title,
      # 見出しは「本:<書名>」（記事のタグと同じ形）。画面には書名だけ出す
      name: title |> String.replace_prefix(Books.book_tag() <> ":", "") |> String.trim(),
      note: result["opening"] || "",
      fields: for("#{@field_tag}:" <> field <- tags, do: field),
      topics: for("#{@topic_tag}:" <> topic <- tags, do: String.trim(topic)),
      # 近い興味トピック（`with_interests/2` が埋める）
      near: [],
      docs: docs,
      recent: counted(extra["docs_recent"]),
      last_seen: to_string(extra["last_seen"] || ""),
      classic: docs >= @classic_sources,
      isbn: isbn,
      cover_url: isbn && @cover_base <> isbn <> ".jpg",
      page_url: isbn && @book_page_base <> isbn
    }
  end

  @doc """
  ISBN を 13 桁に揃えます。**チェックディジットが合わなければ nil** ——
  AI が書いた番号なので、1 桁違いで別の本の表紙が出るのを止めます。
  10 桁のものは 13 桁に直します。
  """
  def isbn13(raw) when is_binary(raw) do
    digits = raw |> String.upcase() |> String.replace(~r/[^0-9X]/, "")

    cond do
      String.length(digits) == 13 and valid13?(digits) -> digits
      String.length(digits) == 10 and valid10?(digits) -> from10(digits)
      true -> nil
    end
  end

  def isbn13(raw) when is_integer(raw), do: isbn13(Integer.to_string(raw))
  def isbn13(_raw), do: nil

  defp valid13?(digits) do
    if digits =~ ~r/^97[89]\d{10}$/ do
      nums = digits |> String.graphemes() |> Enum.map(&String.to_integer/1)

      sum =
        nums
        |> Enum.with_index()
        |> Enum.map(fn {n, i} -> if rem(i, 2) == 0, do: n, else: n * 3 end)
        |> Enum.sum()

      rem(sum, 10) == 0
    else
      false
    end
  end

  defp valid10?(digits) do
    if digits =~ ~r/^\d{9}[\dX]$/ do
      sum =
        digits
        |> String.graphemes()
        |> Enum.with_index()
        |> Enum.map(fn {c, i} -> if(c == "X", do: 10, else: String.to_integer(c)) * (10 - i) end)
        |> Enum.sum()

      rem(sum, 11) == 0
    else
      false
    end
  end

  defp from10(digits) do
    body = "978" <> String.slice(digits, 0, 9)

    sum =
      body
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.map(fn {c, i} -> String.to_integer(c) * if(rem(i, 2) == 0, do: 1, else: 3) end)
      |> Enum.sum()

    body <> Integer.to_string(rem(10 - rem(sum, 10), 10))
  end

  # 機械が入れた数。**読めなければ 0**
  defp counted(value) when is_integer(value), do: value

  defp counted(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> 0
    end
  end

  defp counted(_value), do: 0

  defp with_choices(sweeps, choices) do
    for sweep <- Enum.map(sweeps, &resolve_prompt/1) do
      case Map.get(choices, sweep.name) do
        nil -> sweep
        picked -> Map.merge(sweep, Map.reject(picked, fn {_k, v} -> is_nil(v) end))
      end
    end
  end

  defp resolve_prompt(%{prompt: :tidy} = sweep), do: %{sweep | prompt: tidy_prompt()}
  defp resolve_prompt(sweep), do: sweep
end
