defmodule Chidori.Relations.Films do
  @moduledoc """
  映画の関連図（関連図の画面の「映画のつながり」）。**同じ監督の作品どうしと、
  同じ主演の作品どうしを、色の違う線で結びます**。画家・芸能人の図と同じ仕組みで、
  Chiezo に名簿を持たせて育てます。

  名簿の元は名作（下の「名簿」）ですが、**新しく公開された作品も入ります** ——
  最新情報の映画のうち注目度が高いものと見た記録を付けたもの、それに図の画面から
  見た記録と一緒に足したもの（「引き継ぎ」。`Chidori.Relations.FilmCarry`）。

  ## 名簿 —— ほとんど機械で引ける

  日本語版 Wikipedia の映画の記事には、**「黒澤明の監督映画」のような監督の分類**と、
  **「1954年の映画」のような公開年の分類**が付いています。名簿・監督・公開年・国・ジャンルは
  ここから機械で引き、AI には書かせません（`extract/1`）。

  - **名簿は「〜の監督映画」で終わる分類をまとめて指します**（`tag_suffix`）。監督の名前を
    書き並べると必ず取りこぼすため（画家の「〜の画家」と同じ）
  - **知名度で下を切ります**（Wikipedia の月の閲覧数。既定 3,000。`Chidori.Relations.Settings`）。
    監督の分類の上位 500 人ぶん（8,879 本）で数えると、月 3,000 以上は 950 本・2,000 以上は
    1,371 本・1,000 以上は 2,334 本だった（実測）
  - **主な映画賞の受賞作は知名度に関わらず入れます**（`tag` で名簿の元にし、
    `min_extra_unless_tag` で下限を免除する）。古い名作は今の閲覧数が少なく、受賞作 359 本の
    うち月 3,000 未満が 241 本ある（実測）—— 閲覧数だけで切ると、名作の図から名作が抜ける

  **主演だけは AI に書かせます**（主演の分類は Wikipedia に無い）。名前は日本語版 Wikipedia の
  記事名にそろえさせ、実在する見出しだけを残します（収集の `verify_tags`）。

  ## 札・枠・線

  - 札は**作品**だけ（俳優は札にしない。札が倍以上になって図が読めなくなる）
  - **同じ監督の作品と、同じ主演の作品は、それぞれ線で結ぶ**（`shared` の線。公開年の順に
    隣どうしを結ぶ —— 全部の組を結ぶと、作品の多い監督や俳優で線が網になる）。線の色で
    監督と主演を分ける
  - **監督の枠では囲まない。** 枠は 1 かたまりで 1 つの高さにしか置けず（作品の公開年の
    中ほど）、作品が何十年にも散らばる監督では、新しい作品が古い作品より上に来て縦の
    公開年が読めなくなった
  - 色は国（「日本の…映画」「アメリカ合衆国の…映画」のような分類から機械で付ける）

  ## 並べ方

  縦は公開年、横は国の帯（`@country_bands`。合作は先に挙げた帯に入れる）。
  区画は「国 × 公開年」で切ります。

  ## 見た記録

  **最新情報の映画と同じ置き場を使います**（`mark_view/0` = `Chidori.News.Movies.mark_view/0`）。
  最新情報で付けた記録が、図へ引き継いだ作品にそのまま出るようにするため。鍵は見出しですが、
  図の見出しは日本語版 Wikipedia の記事名にそろうので、最新情報の見出しと違うことがあります
  （「〇〇 (映画)」）。そこで**引き継いだ作品には元の見出しをタグで残させ**（`記録:<見出し>`）、
  図の札の記録はその見出しでも引きます（`marks_by_node/2`）。
  """

  alias Chidori.Chiezo
  alias Chidori.Relations.Graph
  alias Chidori.Relations.Marks

  @kind_tag "映画"
  # 色と区画に使う国
  @country_prefix "国"
  # 線を組む材料（値は監督の日本語版 Wikipedia の記事名。分類から機械で付ける）
  @director_prefix "監督"
  # 線を組む材料（値は主演の日本語版 Wikipedia の記事名。AI が書く）
  @star_prefix "主演"

  # 見た記録の見出し（引き継いだ作品の、最新情報や画面で書いたときの見出し）
  @record_prefix "記録"

  # 監督の分類の末尾（「黒澤明の監督映画」）
  @director_suffix "の監督映画"

  # **知名度に関わらず入れる賞**（受賞作の分類。実在を確かめた名前だけ）
  @award_categories [
    "アカデミー賞作品賞受賞作",
    "アカデミー長編アニメ映画賞受賞作",
    "パルム・ドール受賞作",
    "金獅子賞受賞作",
    "金熊賞受賞作",
    "日本アカデミー賞最優秀作品賞"
  ]

  # 国の分類（「日本の時代劇映画」「アメリカ合衆国のロマンティック・コメディ映画」）。
  # **書いた国だけを拾う** —— 「〜の…映画」をまとめて拾うと「黒澤明の監督映画」も
  # 国に読めてしまう
  @countries ~w(
    日本 アメリカ合衆国 イギリス フランス イタリア ドイツ 西ドイツ スペイン ソビエト連邦
    ロシア 中国 香港 台湾 韓国 インド スウェーデン デンマーク メキシコ カナダ オーストラリア
  )

  # 横の帯（左から）。**合作は先に挙げた帯に入れる**（日本との合作は日本、ハリウッドとの
  # 合作はアメリカ）。名簿は日本とアメリカで 9 割近くを占め、ほかの国は合わせても 70 本ほど
  # （ヨーロッパとアジアに分けると帯が 1 列ずつになり、帯の名前が重なって読めない）。
  # 国の分類を持たない作品（1 割ほど。続編やシリーズ物に多い）は「その他」の帯に入る
  @country_bands [
    {"日本", ~w(日本)},
    {"アメリカ", ~w(アメリカ合衆国 カナダ メキシコ)},
    {"ほかの国", ~w(
      イギリス フランス イタリア ドイツ 西ドイツ スペイン ソビエト連邦 ロシア スウェーデン デンマーク
      中国 香港 台湾 韓国 インド オーストラリア
    )}
  ]

  # ジャンル（「アメリカ合衆国のホラー映画」「日本のSF映画作品」のような分類から機械で付ける）。
  # 分類の中の語 → 札に出す名前。語が 2 つ入った分類（「SFホラー」「ロマンティック・コメディ」）は
  # 前の語と後ろの語の両方を拾う（`genre_rules/0`）。「〜を題材とした」「〜を原作とする」の
  # 分類は拾わない（「テレビドラマを原作とする映画」がドラマに、「人形を題材とした」が人形に読める）
  @genre_prefix "ジャンル"
  @genres %{
    "コメディ" => "コメディ",
    "ホラー" => "ホラー",
    "SF" => "SF",
    "アクション" => "アクション",
    "サスペンス" => "サスペンス",
    "スリラー" => "スリラー",
    "ミステリ" => "ミステリー",
    "ファンタジー" => "ファンタジー",
    "アニメ" => "アニメ",
    "ミュージカル" => "ミュージカル",
    "戦争" => "戦争",
    "西部劇" => "西部劇",
    "時代劇" => "時代劇",
    "恋愛" => "恋愛",
    "ロマンティック" => "恋愛",
    "犯罪" => "犯罪",
    "クライム" => "犯罪",
    "ドキュメンタリー" => "ドキュメンタリー",
    "青春" => "青春",
    "伝記" => "伝記",
    "冒険" => "冒険",
    "アドベンチャー" => "冒険",
    "ドラマ" => "ドラマ",
    "怪獣" => "怪獣",
    "特撮" => "特撮",
    "パニック" => "パニック",
    "スポーツ" => "スポーツ",
    "歴史" => "歴史",
    "ヤクザ" => "ヤクザ",
    "スパイ" => "スパイ",
    "ゾンビ" => "ゾンビ",
    "刑事" => "刑事"
  }

  # 日本の大手の製作の分類（国の分類を持たない古い邦画がある）
  @japanese_studios ~w(東宝 東映 松竹 日活 大映)

  # 区画の割り方。**国 × 公開年で 25 本ずつ**（画家・芸能人と同じ大きさ）
  @partition %{by: "band", prefix: @country_prefix, value: Graph.years_tag(), target: 25}

  # 一周の日数（既定の間隔のとき）。名簿は芸能人の 3 分の 1 ほど
  @rough_days_at_default 2
  @survey_days_at_default 14

  @doc """
  収集の名前。**映画の目録**（最新の映画の `chidori_movies` と頭をそろえる）。いまは映画の
  つながりの図を描くのに読んでいるが、中身は名作と引き継いだ新作の幅広い情報（監督・主演・
  公開年・国・ジャンル）なので、図の名前ではなく目録として名付ける（前は `chidori_films`）。
  """
  def collection, do: "chidori_movie_catalog"

  @doc "図に載せる文書の印。"
  def kind_tag, do: @kind_tag

  @doc "ジャンルのタグの頭（札の国の後ろに添える）。"
  def genre_prefix, do: @genre_prefix

  @doc "国のタグの頭（色と区画）。"
  def category_tag, do: @country_prefix

  @doc "監督のタグの頭（線）。"
  def director_tag, do: @director_prefix

  @doc "主演のタグの頭（線）。"
  def star_tag, do: @star_prefix

  @doc "区画の割り方。"
  def partition, do: @partition

  @doc "見た記録の見出しのタグの頭（引き継いだ作品が持つ）。"
  def record_tag, do: @record_prefix

  @doc "見た記録の置き場の種類。**最新情報の映画と同じ**（記録を引き継ぐため）。"
  def mark_view, do: Chidori.News.Movies.mark_view()

  @doc "札が持つ、見た記録の見出し（`記録:<見出し>`）。無ければ空。"
  def record_titles(%{tags: tags}) when is_list(tags) do
    for tag <- tags,
        String.starts_with?(tag, @record_prefix <> ":"),
        value = tag |> String.replace_prefix(@record_prefix <> ":", "") |> String.trim(),
        value != "",
        do: value
  end

  def record_titles(_node), do: []

  @doc """
  記録の置き場（見出し → 記録）を、**図の札の名前で引ける形**に直します。
  札の名前で書かれた記録が先、無ければ札が持つ `記録:` の見出しで書かれたもの。
  """
  def marks_by_node(marks, nodes) when is_map(marks) and is_list(nodes) do
    for node <- nodes,
        key = mark_key(node, marks),
        mark = Map.get(marks, key),
        into: %{},
        do: {node.name, mark}
  end

  @doc """
  その札の記録をどの見出しで書くか。**既に書いてある見出しがあればそれ**（2 つに割れない）、
  無ければ札の名前。
  """
  def mark_key(%{name: name} = node, marks) when is_map(marks) do
    cond do
      Map.has_key?(marks, name) -> name
      key = Enum.find(record_titles(node), &Map.has_key?(marks, &1)) -> key
      # **引き継いだ作品は、元の見出し（最新情報の見出し）で書く** —— 札の名前で書くと、
      # 最新情報の画面はその見出しでしか引かないので、同じ作品に見た印が付かない
      title = List.first(record_titles(node)) -> title
      true -> name
    end
  end

  @doc """
  **札の名前で書かれてしまった記録を、元の見出しへ移す組**（`[{札の名前, 元の見出し}]`）。
  引き継いだ作品の記録を札の名前で書いていた頃のぶん（最新情報の画面で見た印が付かない）。
  元の見出しに記録が既にあるものは動かさない（2 つに割れたものを勝手に畳まない）。
  """
  def misplaced_marks(marks, nodes) when is_map(marks) and is_list(nodes) do
    for node <- nodes,
        Map.has_key?(marks, node.name),
        title = List.first(record_titles(node)),
        title != nil and title != node.name,
        not Map.has_key?(marks, title),
        do: {node.name, title}
  end

  @doc """
  札の名前で書かれた記録を元の見出しへ移す（`misplaced_marks/2`）。移した組の数を返す。
  書き写してから元を消す（途中で落ちても記録が消えない順）。
  """
  def align_marks(nodes) when is_list(nodes) do
    view = mark_view()
    marks = Marks.for_view(view)

    marks
    |> misplaced_marks(nodes)
    |> Enum.count(fn {from, to} ->
      mark = Map.fetch!(marks, from)
      attrs = %{"seen" => mark.seen, "seen_on" => mark.seen_on, "note" => mark.note}

      with {:ok, _moved} <- Marks.put(view, to, attrs),
           {:ok, nil} <- Marks.put(view, from, %{"seen" => false, "seen_on" => nil, "note" => ""}) do
        true
      else
        _error -> false
      end
    end)
  end

  @doc """
  **図にまだ載っていない記録**（見出し → 記録）。引き継ぎを頼んだばかりの作品と、
  引き継げなかった作品がここに残ります（画面で「まだ図に無い」として出す）。
  """
  def unplaced(marks, nodes) when is_map(marks) and is_list(nodes) do
    placed =
      nodes
      |> Enum.flat_map(&[&1.name | record_titles(&1)])
      |> MapSet.new()

    Map.reject(marks, fn {key, _mark} -> MapSet.member?(placed, key) end)
  end

  @doc """
  引き継ぎの回の依頼文（割り込み 1 回だけの文。定義の文は変わらない）。`items` は
  `%{title, date, summary, url}`（`date`・`summary`・`url` は分からなければ nil）。

  **図に足すかは AI に選ばせません**（並んでいるものは全部足す）。名作かどうかではなく、
  見た・話題になった、という事情で入れるものなので。**元の見出しを `記録:` で残させます**
  —— 見出しを記事名にそろえると、見た記録の見出しと違ってくるため。
  """
  def carry_prompt(items) when is_list(items) do
    lines =
      Enum.map_join(items, "\n", fn item ->
        facts =
          [
            item[:date] && "公開日 #{Date.to_iso8601(item.date)}",
            present(item[:summary]),
            present(item[:url])
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" / ")

        if facts == "", do: "- #{item.title}", else: "- #{item.title}（#{facts}）"
      end)

    """
    映画の関連図に、**下に並べた作品を足してください**。最近公開された映画で、見た記録が
    付いたか、話題になったものです。**名作かどうかは問いません。全部足してください。**

    #{lines}

    図に既にある作品で、上と同じものかもしれないものは次のとおりです（無ければ空）。
    {current}

    - **既にある作品と同じなら、新しく足さずに、その作品を返して** "#{@record_prefix}:<上の見出し>" のタグを
      足してください（いま付いているタグはすべて残す）
    - 新しく足すとき、title は**日本語版 Wikipedia の記事名**にしてください（記事が無ければ上の見出しのまま）。
      **"#{@record_prefix}:<上の見出し>" のタグを必ず付けてください**（上に書いた見出しをそのまま。
      見た記録と結び付ける印です）
    - tags には "#{@kind_tag}"・"#{Graph.years_tag()}:<公開年>"・"#{@country_prefix}:<製作国>"・"#{@director_prefix}:<監督>"
      （監督の日本語版 Wikipedia の記事名。記事の無い監督は書かない）を付けてください

    #{stars_rule()}
    返す形は次のとおりです。
    - title: 作品名
    - body: どんな作品か（1〜2 文。**結末や仕掛けは書かない**）
    - url: 日本語版 Wikipedia の記事の URL（無ければ公式サイト）
    - tags: 上のとおり
    """
  end

  defp present(value) when is_binary(value) do
    case value |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.find(&(&1 != "")) do
      nil -> nil
      line -> String.slice(line, 0, 160)
    end
  end

  defp present(_value), do: nil

  @doc "知名度に関わらず入れる賞の分類。"
  def award_categories, do: @award_categories

  @doc """
  図の読み方（`Chidori.Relations.Graph.from_docs/2`）。**横は国の帯**、**同じ監督の作品と
  同じ主演の作品を、それぞれ線で結ぶ**（`shared`。線の種類 `:director` と `:costar`）。
  """
  def graph_spec,
    do: %{
      kind_tag: @kind_tag,
      kinds: [],
      default_kind: :film,
      style_prefix: @country_prefix,
      # 札の国の後ろに添えるもの（「アメリカ合衆国・ホラー・サスペンス」）。凡例と色は国だけ
      note_prefix: @genre_prefix,
      band_prefix: @country_prefix,
      bands: @country_bands,
      works?: false,
      # **上を新しい年に**（見に来るのは最近の作品のほう。古い順だと、新しい作品が図の下の端に溜まる）
      newest_first: true,
      edge_rules: [
        %{prefix: @director_prefix, kind: :director, shared: true, undirected: true},
        %{prefix: @star_prefix, kind: :costar, shared: true, undirected: true}
      ]
    }

  @doc "収集の巡回（画家・芸能人と同じ 3 本。名簿 → 主演を埋める → 区画ごとに仕上げる）。"
  def sweeps do
    [
      %{
        name: Chidori.SweepNames.machine(),
        interval_minutes: 10_080,
        use_extract: true,
        only_new: true,
        once: true
      },
      %{
        name: Chidori.SweepNames.scan(),
        interval_minutes: Chidori.SweepNames.scan_minutes(),
        cover_days: Chidori.CollectPace.days(:scan, @rough_days_at_default),
        after: Chidori.SweepNames.machine(),
        one_lap: true
      },
      %{
        name: Chidori.SweepNames.tidy(),
        interval_minutes: Chidori.SweepNames.tidy_minutes(),
        cover_days: Chidori.CollectPace.days(:tidy, @survey_days_at_default),
        prompt: survey_prompt(),
        after: Chidori.SweepNames.scan()
      }
    ]
  end

  @doc "Chiezo に送る設定（関連図の画面の「収集の設定を更新」と同じもの）。"
  def attrs(choices \\ %{}) do
    %{
      name: collection(),
      description: "Chidori の映画の目録（映画のつながりの図などで読む）",
      prompt: prompt(),
      interval_minutes: Chidori.SweepNames.scan_minutes(),
      partition: @partition,
      sweeps: with_choices(sweeps(), choices),
      extract: extract(),
      kind: "stock",
      # 名簿にいない作品を指す関連と、記事の無い主演は、Chiezo が焼く前に落とす
      verify_tags: [
        %{prefix: Graph.related_tag(), source: "jawiki"},
        %{prefix: @star_prefix, source: "jawiki"}
      ],
      requested_by: "chidori"
    }
  end

  defp with_choices(sweeps, choices) do
    for sweep <- sweeps do
      case Map.get(choices, sweep.name) do
        nil -> sweep
        picked -> Map.merge(sweep, Map.reject(picked, fn {_k, v} -> is_nil(v) end))
      end
    end
  end

  @doc """
  名簿の引き方（Chiezo の「抽出の指定」）。「〜の監督映画」の作品と主な賞の受賞作の和を
  知名度で切る（**受賞作は下限を免除**）。監督・公開年・国・ジャンルを機械で付けます。
  """
  def extract(min_pageviews \\ Chidori.Relations.Settings.min_pageviews("films")) do
    %{
      source: "jawiki",
      tag_suffix: @director_suffix,
      tag: Enum.join(@award_categories, ","),
      min_extra: %{pageviews_month: min_pageviews},
      min_extra_unless_tag: Enum.join(@award_categories, ","),
      body: "opening",
      url: "https://ja.wikipedia.org/wiki/{title}",
      tags:
        [
          %{const: @kind_tag},
          # 監督は分類の名前から（「黒澤明の監督映画」→「監督:黒澤明」）
          %{pattern: "^(.+)#{@director_suffix}$", format: "#{@director_prefix}:{1}"},
          # 公開年（「1954年の映画」「2001年のアニメ映画」）。区画はこの数で決まる
          %{pattern: "^(\\d{4})年の.*映画$", format: "#{Graph.years_tag()}:{1}"}
        ] ++
          country_rules() ++
          genre_rules() ++
          [
            # 続編・同じ題材のように記事どうしが互いにリンクしている組は、薄い線で引く
            %{linked: "mutual", format: "#{Graph.related_tag()}:{1}"}
          ],
      extra: ["pageviews_month", "image"]
    }
  end

  # ジャンル。分類の中の最初の語と最後の語を 1 本ずつ（語が 1 つなら同じタグになり 1 本に畳まれる）。
  # **`fill` を付ける** —— 名簿を引き直す回は既にいる作品のタグに触らないので、付けないと
  # この読み替えを足す前に入った作品にジャンルが付かない（Chiezo の `fill`。ジャンルのタグを
  # 1 つも持たない作品にだけ渡す）
  defp genre_rules do
    words = @genres |> Map.keys() |> Enum.sort_by(&(-String.length(&1))) |> Enum.join("|")
    head = "^(?:[^のを]+の)?[^のを]*"
    tail = "[^のを]*映画(?:作品)?$"

    for lazy <- ["?", ""] do
      %{
        pattern: head <> lazy <> "(" <> words <> ")" <> tail,
        format: "#{@genre_prefix}:{1}",
        map: @genres,
        fill: true
      }
    end
  end

  defp country_rules do
    [
      %{
        pattern: "^(" <> Enum.map_join(@countries, "|", &Regex.escape/1) <> ")の.*映画",
        format: "#{@country_prefix}:{1}"
      },
      %{
        pattern: "^(?:" <> Enum.join(@japanese_studios, "|") <> ")製作の",
        format: "#{@country_prefix}:日本"
      }
    ]
  end

  # 依頼文に共通の、主演の書き方
  defp stars_rule do
    """
    - **主演は "#{@star_prefix}:<俳優の名前>"** で付けてください（主演が 2〜3 人いれば全員。
      アニメは主人公の声の主演）。**名前は日本語版 Wikipedia の記事名そのまま**
      （「松田優作」「トム・ハンクス」。括弧書きが付く記事名は括弧ごと）—— 作品どうしで書き方が
      揃わないと、同じ俳優だと分かりません。記事の無い人は書かないでください
    - 助演・脇役・カメオ出演は書かないでください（線が増えすぎて図が読めなくなります）
    """
  end

  # 機械で付けたタグ（触らせない）
  defp machine_rule do
    """
    **"#{@director_prefix}:"・"#{Graph.years_tag()}:"・"#{@country_prefix}:"・"#{@genre_prefix}:" のタグは Wikipedia の分類から
    機械で付けたものです。そのまま残してください**（足りないときだけ足してください）。
    **"#{@record_prefix}:" のタグも、そのまま残してください**（見た記録と結び付ける印です）。
    """
  end

  @doc """
  ざっと見る回の依頼文（収集の既定の文）。**主演を埋める**のがいちばんの仕事
  （監督・公開年・国・ジャンルは名簿の時点で機械で付いている）。
  """
  def prompt do
    """
    映画の関連図を育ててください。**同じ監督の作品と、同じ主演の作品をつなぐ図**です。

    **今回見る範囲**
    {partition}

    **この範囲の作品が、下にすべて並んでいます。** どれを見るか選ぶ必要は
    ありません —— 並んでいるものを順に詳しくしてください。**範囲の外のものは
    返さないでください**（別の回に回ってきます）。

    {current}

    #{machine_rule()}
    いちばん大事なのは**主演**です。一本ずつ確かめて付けてください。

    #{stars_rule()}
    **映画ではないもの**（テレビドラマ・小説・人物の記事など）が混ざっていたら、墓標で消してください
    （tags に "#{Chiezo.tombstone_tag()}" を入れ、body に消す理由を 1 行）。

    **変えないものを返す必要はありません。** 返すものは次の形にしてください。
    - title: 作品名（**上に並んでいる表記をそのまま使う**）
    - body: どんな作品か（1〜2 文。あらすじの核と、なぜ知られているか）
    - url: 日本語版 Wikipedia の記事の URL
    - tags: **いま付いているタグをすべて残したうえで**、上のタグを足す
    """
  end

  @doc "区画ごとに仕上げる回の依頼文。**主演の漏れと誤りを直し、要らないものを消す**。"
  def survey_prompt do
    """
    映画の関連図を、**この区画ぶんだけ仕上げてください**。

    **今回見る範囲**
    {partition}

    {current}

    **上に並んでいるのが、この範囲の全部です。** 範囲は「国」と「公開年」で区切ってあります。

    やってほしいことは 2 つです。

    **1. 主演を確かめる。** 主演のタグが空のものを埋め、明らかに違うもの（助演を主演にしている・
    名前の書き方が記事名と違う）だけ直してください。**確かめられなかったものは触らないでください。**

    #{stars_rule()}
    **2. 要らないものを消す。** 映画ではないもの（テレビドラマ・小説・人物の記事など）と、
    表記の揺れで 2 つに分かれた同じ作品（残すほうに中身をまとめる）だけを墓標で消してください
    （tags に "#{Chiezo.tombstone_tag()}"、body に理由を 1 行）。

    #{machine_rule()}
    **触ったものだけ返してください。** いま付いているタグは、直すもの以外そのまま残してください
    （返した内容で丸ごと置き換わるので、書かなかったタグは消えます）。

    直すものの形は次のとおりです。
    - title: 作品名（**日本語版 Wikipedia の記事名にそろえる**）
    - body: どんな作品か（1〜2 文）
    - url: 日本語版 Wikipedia の記事の URL
    - tags: "#{@kind_tag}"・"#{@director_prefix}:<監督>"・"#{Graph.years_tag()}:<公開年>"・"#{@country_prefix}:<国>"・
      "#{@star_prefix}:<主演>"。"#{Graph.related_tag()}" と "#{@record_prefix}:" のタグは**そのまま残してください**
    """
  end
end
