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

  # 原作の記事を指す作品の閲覧数の割引（`with_new_film_views/3`）。記事の閲覧数は原作・アニメ・映画の合計で、
  # 映画の分は原作の種類で違う。**小説は映画で知られることが多く**（映画化で読まれる）、**漫画・ライトノベル・
  # アニメ・ドラマは原作やテレビの人気で読まれ、映画はその後に作られることが多い**。率は目安で、AI の話題度が
  # 入れば使わない
  @source_work_shares %{"小説" => 0.5}
  # 公開から間もない作品の閲覧数の割引（公開からの年数 → 率。載っていない年数はそのまま）。月の閲覧数は公開直後の
  # 話題で膨らみ、最近の作品が過去の大作と並んでいた。公開年ごとの上位 1 割の閲覧数は、2005〜2020 年の作品が
  # 月 1.4 万前後で揃うのに対し、今年の作品は約 4 倍・1〜2 年前は約 1.7 倍・3 年前は約 1.4 倍あった（その逆数ほど）。
  # 未来の公開年（負の年数）は今年と同じ
  @recency_shares %{-1 => 0.3, 0 => 0.3, 1 => 0.6, 2 => 0.7, 3 => 0.8}
  @source_work_share 0.2
  # 映画としての話題度（1〜10）を AI が書く脇書きの鍵（`fame_rule/0`・`with_new_film_views/3`）
  @fame_level_key "fame_level"
  # 名簿が原作の記事を指している作品の印（`記事:<原作の種類>`。機械が記事の 1 文目から付ける `source_work_rule/0`）
  @source_work_prefix "記事"

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
    "日本アカデミー賞最優秀作品賞",
    # 日本で広く見られた洋画の目印（49 本。監督の分類が無い記事もある）
    "日本アカデミー賞最優秀外国作品賞"
  ]

  # **公開年の分類からも入れる**（「1985年の映画」「2001年のアニメ映画」。知名度の下限はかかる）。
  # 監督の分類（「〜の監督映画」）だけでは、記事にその分類が付いていない作品が漏れた ——
  # 月 2 万の閲覧がある有名作が、監督の分類が無く主な賞も取っていないために名簿に居なかった
  # （月 3,000 以上で漏れていたのは 904 本）
  @year_suffixes ["年の映画", "年のアニメ映画"]

  # 国の分類（「日本の時代劇映画」「アメリカ合衆国のロマンティック・コメディ映画」）。
  # **書いた国だけを拾う** —— 「〜の…映画」をまとめて拾うと「黒澤明の監督映画」も
  # 国に読めてしまう。**主な 20 か国だけにしていた頃は、それ以外の国の作品に国が付かなかった**
  # （「ルーマニアのドラマ映画」のパルム・ドール受賞作など）。正規表現に並べると Chiezo の
  # 長さの上限（200 字）を超えるので、捕まえた名前を表（`map`）で引く（`country_rules/0`）
  @major_countries ~w(
    日本 アメリカ合衆国 イギリス フランス イタリア ドイツ 西ドイツ スペイン ソビエト連邦
    ロシア 中国 香港 台湾 韓国 インド スウェーデン デンマーク メキシコ カナダ オーストラリア
  )
  @countries @major_countries ++
               ~w(
                 東ドイツ アイルランド ベルギー オランダ ルクセンブルク スイス オーストリア ポルトガル
                 ギリシャ ノルウェー フィンランド アイスランド エストニア ラトビア リトアニア ポーランド
                 チェコ チェコスロバキア スロバキア ハンガリー ルーマニア ブルガリア ユーゴスラビア
                 セルビア クロアチア スロベニア ボスニア・ヘルツェゴビナ 北マケドニア アルバニア
                 ウクライナ ベラルーシ ジョージア アルメニア アゼルバイジャン カザフスタン トルコ
                 イラン イラク イスラエル パレスチナ レバノン ヨルダン シリア サウジアラビア
                 アラブ首長国連邦 エジプト モロッコ アルジェリア チュニジア 南アフリカ共和国
                 ナイジェリア セネガル ケニア エチオピア ブラジル アルゼンチン チリ ペルー コロンビア
                 ウルグアイ ベネズエラ ボリビア キューバ プエルトリコ ニュージーランド タイ ベトナム
                 フィリピン インドネシア マレーシア シンガポール カンボジア ミャンマー モンゴル
                 北朝鮮 パキスタン バングラデシュ スリランカ ネパール ブータン マカオ
               )

  # 横の帯（左から）。**合作は先に挙げた帯に入れる**（日本との合作は日本、ハリウッドとの
  # 合作はアメリカ）。名簿は日本とアメリカで 9 割近くを占め、ほかの国は合わせても 70 本ほど
  # （ヨーロッパとアジアに分けると帯が 1 列ずつになり、帯の名前が重なって読めない）。
  # 国の分類を持たない作品（1 割ほど。続編やシリーズ物に多い）は「その他」の帯に入る
  @country_bands [
    {"日本", ~w(日本)},
    {"アメリカ", ~w(アメリカ合衆国 カナダ メキシコ)},
    {"ほかの国", @countries -- ~w(日本 アメリカ合衆国 カナダ メキシコ)}
  ]

  # ジャンル（「アメリカ合衆国のホラー映画」「日本のSF映画作品」のような分類から機械で付ける）。
  # 分類の中の語 → 札に出す名前。語が 2 つ入った分類（「SFホラー」「ロマンティック・コメディ」）は
  # 前の語と後ろの語の両方を拾う（`genre_rules/0`）。「〜を題材とした」「〜を原作とする」の
  # 分類は拾わない（「テレビドラマを原作とする映画」がドラマに、「人形を題材とした」が人形に読める）
  @genre_prefix "ジャンル"
  # 注目度（最新の映画の印。引き継いだ作品の大きさに使う `with_attention_views/2`）
  @attention_prefix "注目度"
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

  @doc """
  配信（サブスク）を探す Google 検索の URL（「<題名> サブスク」）。題名の括弧書き
  （「(映画)」「(2011年の映画)」）は外す —— 記事名の見分けの札で、検索の邪魔になる。
  開くのは見る人のブラウザ（サーバーからは引かない）。
  """
  def subscription_search_url(title) when is_binary(title) do
    "https://www.google.com/search?" <> URI.encode_query(%{"q" => plain_title(title) <> " サブスク"})
  end

  @doc """
  題名から記事名の見分けの札（末尾の「(映画)」「(2011年の映画)」）を外したもの。配信サービスなどで
  探すときに使う（札が付いたままだと当たらない）。
  """
  def plain_title(title) when is_binary(title),
    do: title |> String.replace(~r/\s*\([^)]*\)$/u, "") |> String.trim()

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
            attention_word(item[:attention]) && "注目度 #{attention_word(item[:attention])}",
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
    - 上で「注目度」が書いてある作品には、"#{@attention_prefix}:<高・中・低>" のタグも付けてください（書いてあるとおりに写す。
      図の札の大きさに使います —— 新しい作品は Wikipedia の閲覧数がまだ無いため）
    - 足す作品にも、既にある作品として返す作品にも、#{fame_rule()}

    #{stars_rule()}
    返す形は次のとおりです。
    - title: 作品名
    - body: どんな作品か（1〜2 文。**結末や仕掛けは書かない**）
    - url: 日本語版 Wikipedia の記事の URL（無ければ公式サイト）
    - tags: 上のとおり
    """
  end

  defp attention_word(:high), do: "高"
  defp attention_word(:mid), do: "中"
  defp attention_word(:low), do: "低"
  defp attention_word(_level), do: nil

  @doc """
  **札の大きさに使う閲覧数を、日本語版 Wikipedia の記事に合わせて直します**（`Chidori.Relations` が図を読むときに、
  大きさを付ける前に呼ぶ）。`wiki_views` は閲覧数の無い作品の作品名 → `%{views: 記事の月の閲覧数, kind: 原作の種類か nil}`
  （Chiezo の jawiki から引いたもの。`kind` は記事の 1 文目から `source_kind_of/1`）。

  0. **公開から間もない作品は閲覧数を割り引く**（今年 3 割・1 年前 6 割・2 年前 7 割・3 年前 8 割。`settled/2`）。
     月の閲覧数は公開直後の話題で膨らむ
  1. **原作の記事（`#{@source_work_prefix}:<原作の種類>` のタグ。名簿を引くときに機械が記事の 1 文目から付ける
     `source_work_pattern/0`）の閲覧数は、小説なら #{round(@source_work_shares["小説"] * 100)}%、漫画・ライトノベル・アニメ・ドラマ・
     ゲームなら #{round(@source_work_share * 100)}% に割り引く。** 映画だけの記事が無い作品は、
     名簿が原作（小説・漫画）の記事を指していて、閲覧数は原作・アニメ・映画をまとめたものになる
     （漫画の記事の作品が、映画として月 5 万の閲覧がある扱いになっていた。目録の 2 割近くがこれ）。
     原作の記事のうち映画の占める割合は作品で違うので、割合は目安
  2. **閲覧数の無い作品**（最新の映画から引き継いだ作品・手で足した作品。名簿を引く回で閲覧数が運ばれず、
     月 40 万の閲覧がある作品までいちばん小さい札になっていた）は、記事の閲覧数を使う（名簿の作品と同じ物差し）
  3. 記事も無ければ、**最新の映画の注目度で控えめに**決める。注目度は作品の `注目度:` のタグか、
     最新の映画の収集の注目度（`attention`。見出し → `:high` / `:mid`。札の名前か `記録:` の見出しで引く）。
     大きさは閲覧数の基準（多い順で 5 番目）に対して、高 4 割・中 3 割・低や印なし（引き継いだ・足した作品）2 割。
     **最大にはしない** —— 引き継ぐのは注目度が高い作品ばかりなので、高を最大にすると、新作が軒並み
     いちばん流行った作品と肩を並べた

  **AI が書いた話題度（`extra.fame_level`。1〜10）があれば、1〜3 より先にそれを使う**（閲覧数相当は基準から話題度が
  4 下がるごとに 10 分の 1。`fame_views/2`）。
  使うのは閲覧数の当てにならない作品 —— 原作の記事の作品と、引き継いだ・足した作品 —— だけで、映画だけの記事を持つ作品は
  機械の閲覧数のほうを信じる。原作の記事のうち映画の分は作品でまったく違い（アニメ映画の閲覧が大半の記事も、
  漫画とアニメの閲覧が大半の記事もある）、閲覧数からは見分けられないので、興行や受賞を知っている AI に決めさせる。
  基準（多い順で 5 番目）は話題度で決める作品を除いて数える。

  引き継いでも足してもいない作品（`記録:` の無い名簿の作品）で記事も注目度も無いものは、いちばん小さいまま。
  """
  def with_new_film_views(nodes, attention, wiki_views, this_year \\ Chidori.Jst.today().year)
      when is_list(nodes) and is_map(attention) and is_map(wiki_views) do
    nodes = Enum.map(nodes, &(&1 |> with_wiki(wiki_views[&1.name]) |> settled(this_year)))

    top =
      nodes
      |> Enum.reject(&judged?/1)
      |> Enum.map(&(&1[:views] || 0))
      |> Enum.sort(:desc)
      |> Enum.at(4, 0)

    Enum.map(nodes, fn node ->
      cond do
        top > 0 and judged?(node) ->
          Map.put(node, :views, fame_views(top, node.fame_level))

        (node[:views] || 0) > 0 ->
          node

        top > 0 ->
          case size_ratio(attention_of(node, attention), record_titles(node) != []) do
            nil -> node
            ratio -> Map.put(node, :views, views_for(top, ratio))
          end

        true ->
          node
      end
    end)
  end

  @doc """
  札の大きさがどう決まったかの言葉（詳細の「知名度」に添える）。AI の話題度で決めた作品はそれだけ、
  そうでなければ閲覧数にかけた割引（原作の記事・公開から間もない）。何もかけていなければ空。
  """
  def size_basis(node, this_year \\ Chidori.Jst.today().year) do
    if judged?(node) do
      ["AI の話題度 #{node.fame_level}"]
    else
      kind = source_kind(node)

      recent =
        with {year, _rest} <- Integer.parse(to_string(node[:years] || "")),
             share when is_number(share) <- Map.get(@recency_shares, this_year - year),
             do: share,
             else: (_none -> nil)

      [
        kind && "原作（#{kind}）の記事の閲覧数を #{tenths(share_of(kind))} 割に",
        recent && "公開から間もないので #{tenths(recent)} 割に"
      ]
      |> Enum.reject(&is_nil/1)
    end
  end

  defp tenths(share), do: round(share * 10)

  # 公開から間もない作品の閲覧数を割り引く（`@recency_shares`）。公開年は札の年代（`年代:` のタグ）
  defp settled(node, this_year) do
    with views when is_integer(views) and views > 0 <- node[:views],
         {year, _rest} <- Integer.parse(to_string(node[:years] || "")),
         share when is_number(share) <- Map.get(@recency_shares, this_year - year) do
      Map.put(node, :views, max(round(views * share), 1))
    else
      _not_recent -> node
    end
  end

  # 話題度から閲覧数相当を決める。**話題度が 4 上がるごとに 10 倍**（10 = 基準、8 = 約 3 割、6 = 約 1 割、
  # 4 = 約 3%）—— 実際の映画の記事の閲覧数は桁で開くので、目盛りも桁で刻む。基準に対して 10 分の話題度の
  # 大きさにしていた頃は、話題度 5（ヒット作）が月 3.6 万相当になり、実写化された漫画の作品が君の名は。
  # （月 3.9 万）と並ぶ大きさになって、図の知名度の下限（1 万）も通っていた
  defp fame_views(top, level), do: max(round(top * :math.pow(10, (level - 10) / 4)), 1)

  # 大きさは閲覧数の比の 0.65 乗（`Graph`）なので、基準に対して ratio の大きさになる閲覧数は基準の ratio^(1/0.65)
  defp views_for(top, ratio), do: max(round(top * :math.pow(ratio, 1 / 0.65)), 1)

  # AI の話題度で大きさを決める作品か。**閲覧数の当てにならない作品だけ**（原作の記事・引き継いだ・足した作品）。
  # 映画だけの記事を持つ作品は、機械の閲覧数のほうを信じる
  defp judged?(node),
    do: is_integer(node[:fame_level]) and (source_work?(node) or record_titles(node) != [])

  defp source_work?(node), do: source_kind(node) != nil

  @doc """
  閲覧数では映画の知名度が測れず、AI の話題度もまだ無い作品か。**原作が小説以外**（漫画・ライトノベル・アニメ・
  ドラマ・ゲーム）の記事を指す作品で、話題度（`fame_level`）が無いもの。漫画などの記事の閲覧数は原作とアニメの
  人気でいくらでも大きくなり（月 10 万を超える作品もある）、どんな率で割り引いても図の知名度の下限を通った。
  小説の記事は映画で知られることが多いので、割り引いた閲覧数で比べる。
  """
  def unrated_source_work?(node) do
    source_kind(node) not in [nil, "小説"] and not is_integer(node[:fame_level])
  end

  @doc "原作の記事の種類（`記事:<種類>` のタグの値）。原作の記事でなければ nil。"
  def source_kind(node) do
    Enum.find_value(node[:tags] || [], fn
      @source_work_prefix <> ":" <> kind -> kind
      _tag -> nil
    end)
  end

  # 原作の記事の閲覧数を割り引き、閲覧数の無い作品には記事の閲覧数を入れる。引いた記事が原作の記事なら
  # （引き継いだ作品の記事名が原作の記事へ転送されている）、そちらの種類でも割り引く
  defp with_wiki(node, article) do
    {views, article_kind} =
      cond do
        (node[:views] || 0) > 0 ->
          {node.views, nil}

        match?(%{views: v} when is_integer(v) and v > 0, article) ->
          {article.views, article[:kind]}

        true ->
          {0, nil}
      end

    cond do
      views == 0 ->
        node

      kind = source_kind(node) || article_kind ->
        Map.put(node, :views, max(round(views * share_of(kind)), 1))

      true ->
        Map.put(node, :views, views)
    end
  end

  defp share_of(kind), do: Map.get(@source_work_shares, kind, @source_work_share)

  # 原作の記事を見分ける読み替え（Chiezo の `on: "lead"` = 記事の 1 文目に当てる）。**主語は 1 文目の最後に
  # 出てくる作品の種類で読む**（「〜を原作とした日本映画」は映画、「〜による日本の漫画」は漫画）。「、また」
  # 「および」の後ろ（「小説、またそれを原作とした映画」）は読まない。**分類では見分けない** —— 映画の記事にも
  # 小説版・漫画版の分類が付く（ヒットしたアニメ映画ほど付いている）。目録 1598 本のうち 287 本が当たる
  # （小説 166・漫画 109・ドラマ 6・ほか 6）。捕まえた種類はタグの名前に読み替える（ライト文芸はライトノベルに）
  @source_kinds %{
    "小説" => "小説",
    "漫画" => "漫画",
    "ライト文芸" => "ライトノベル",
    "ライトノベル" => "ライトノベル",
    "テレビアニメ" => "アニメ",
    "ドラマ" => "ドラマ",
    "ゲーム" => "ゲーム"
  }
  @film_kinds ~w(映画 劇場用?アニメ)
  @lead_cut ~w(、また および 及び ならびに 並びに)

  @doc "原作の記事を見分ける正規表現（Chiezo の読み替えに渡す。Python の正規表現。200 字まで）。"
  def source_work_pattern do
    source = @source_kinds |> Map.keys() |> Enum.sort_by(&(-String.length(&1))) |> Enum.join("|")
    film = Enum.join(@film_kinds, "|")
    cut = Enum.join(@lead_cut, "|")

    # 頭を欲張りにして、1 文目の最後に出てくる種類を捕まえる（「小説を原作とした漫画」は漫画）
    "(?s)^(?:(?!#{cut}).)*(#{source})(?:(?!#{film}|#{cut}).)*(?:(?:#{cut}).*)?$"
  end

  @doc """
  記事の冒頭から、原作の記事ならその種類（`"小説"`・`"漫画"` など。名簿の `記事:` のタグと同じ名前）を、
  映画の記事なら nil を返します。名簿の回に Chiezo が付けるタグと同じ規則（`source_work_pattern/0` を
  `lead_sentence/1` の 1 文目に当てる）で、名簿を通らない引き継いだ作品に使う。

      iex> Chidori.Relations.Films.source_kind_of("『ちいかわ』（ちいかわ）は、ナガノによる日本の漫画。2026年に映画化。")
      "漫画"
      iex> Chidori.Relations.Films.source_kind_of("『君の名は。』は、2016年公開の日本のアニメーション映画。")
      nil
  """
  def source_kind_of(opening) when is_binary(opening) do
    case Regex.run(Regex.compile!(source_work_pattern(), "u"), lead_sentence(opening)) do
      [_ | [kind | _]] -> @source_kinds[kind]
      _none -> nil
    end
  end

  def source_kind_of(_opening), do: nil

  # 1 文目の取り出し方は Chiezo の抽出（`extract.lead_sentence`）と同じにする —— 名簿の作品と引き継いだ作品で
  # 見分け方がずれないように。括弧の中の句点で切らず（『君の名は。』）、丸括弧の中身と、冒頭に残った
  # 情報欄の表の行（`|` で始まる行と、そのすぐ後ろの短い見出しの行）は除く
  @lead_chars 400
  @lead_pairs %{"『" => "』", "「" => "」", "【" => "】", "(" => ")", "（" => "）"}
  @lead_dropped ["(", "（"]

  @doc false
  def lead_sentence(text) when is_binary(text) do
    text
    |> String.slice(0, @lead_chars * 8)
    |> String.split("\n")
    |> without_table_rows()
    |> Enum.join("\n")
    |> String.slice(0, @lead_chars * 4)
    |> String.graphemes()
    |> Enum.reduce_while({[], []}, &lead_char/2)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
    |> String.trim()
    |> String.slice(0, @lead_chars)
  end

  defp lead_char(ch, {out, stack}) do
    hidden? = Enum.any?(stack, &(&1 in @lead_dropped))

    cond do
      stack != [] and ch == @lead_pairs[hd(stack)] ->
        [opener | rest] = stack
        shown? = opener not in @lead_dropped and not Enum.any?(rest, &(&1 in @lead_dropped))
        {:cont, {if(shown?, do: [ch | out], else: out), rest}}

      Map.has_key?(@lead_pairs, ch) ->
        {:cont, {if(hidden? or ch in @lead_dropped, do: out, else: [ch | out]), [ch | stack]}}

      stack == [] and ch == "。" ->
        {:halt, {out, stack}}

      hidden? ->
        {:cont, {out, stack}}

      true ->
        {:cont, {[ch | out], stack}}
    end
  end

  defp without_table_rows(lines) do
    lines
    |> Enum.reduce({[], false}, fn line, {kept, after_row?} ->
      bare = String.trim(line)

      cond do
        String.starts_with?(bare, ["|", "!", "{|"]) ->
          {kept, true}

        after_row? and bare != "" and String.length(bare) <= 20 and
            not String.contains?(bare, ["。", "、"]) ->
          {kept, true}

        true ->
          {[line | kept], after_row? and bare == ""}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp source_work_rule,
    do: %{
      pattern: source_work_pattern(),
      format: "#{@source_work_prefix}:{1}",
      map: @source_kinds,
      on: "lead",
      fill: true
    }

  defp size_ratio(:high, _carried?), do: 0.4
  defp size_ratio(:mid, _carried?), do: 0.3
  defp size_ratio(_level, true), do: 0.2
  defp size_ratio(_level, false), do: nil

  defp attention_of(node, attention) do
    by_tag =
      Enum.find_value(node[:tags] || [], fn
        @attention_prefix <> ":高" -> :high
        @attention_prefix <> ":中" -> :mid
        @attention_prefix <> ":低" -> :low
        _other -> nil
      end)

    by_tag || Enum.find_value([node.name | record_titles(node)], &Map.get(attention, &1))
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
      # Wikipedia の相互リンク（続編・シリーズ）の薄い線は引かない。同じ監督・同じ主演の線で
      # 読む図なので、リンクの線が混ざると、どの線が何のつながりか読みにくい
      related: false,
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

  # 絵を探させる 1 回に名指しする上限（Chiezo の割り込みの名指しの上限）
  @image_titles 50

  @doc """
  **名指しした作品に絵を探させます**（見た映画のページの「絵を探してもらう」。割り込み 1 回で、
  押した人の 1 回なので止めている収集でも走る）。Wikipedia にはポスターがほとんど無いので、
  AI に公式サイトや映画の情報サイトのポスターの URL を探させ、Chiezo が縮めて持つ（`thumbs`）。
  `{:ok, 名指しした数}` / `{:error, 理由}`。
  """
  def fill_images(_base, []), do: {:ok, 0}

  def fill_images(base, titles) when is_list(titles) do
    titles = Enum.take(titles, @image_titles)

    result =
      Chidori.Chiezo.by_hand(fn ->
        Chidori.Chiezo.focus(
          base,
          collection(),
          "名指しした作品に、絵（image）を付けてください。",
          titles,
          Chidori.SweepNames.tidy(),
          nil,
          image_prompt()
        )
      end)

    case result do
      :ok -> {:ok, length(titles)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "絵を探させる回の依頼文（その回だけの依頼文。定義の文は変わらない）。"
  def image_prompt do
    """
    下に並んでいる映画それぞれについて、**ポスターかキービジュアルの画像の URL** を探して
    image に入れて返してください。

    {current}

    - image は**画像そのものの URL**（ページの URL ではなく）。公式サイトのページの og:image、
      無ければ配給会社や映画の情報サイトの作品ページのもの。Wikipedia の記事に絵があればそれでも構いません。
      **確かめられなければ入れないでください**（その作品は返さなくて構いません）
    - **title と tags は上のまま、tags は全部返してください** —— 返した tags がそのまま
      付け替わります（1 つでも落とすと、監督・主演・公開年・国・ジャンルが消えます）
    - **body は返さないでください**（本文は今のまま残ります）
    - **next_cursor は返さないでください**
    """
  end

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
      # 一覧の 1 行に、縮めた絵（ポスター）が無いことを添えてもらう（Chiezo の `show_blanks`。
      # 一覧は見出し・タグ・本文だけで、AI にはどれに絵が無いか見えない）。整理の回がポスターを探す
      show_blanks: ["thumb", "runtime_minutes", @fame_level_key],
      # 作品の絵（ポスター）は AI が返した URL から Chiezo が縮めて持つ（`fill_images/2`。
      # ページの og:image は拾わない —— 作品の URL は Wikipedia の記事なので、拾うと千数百本の
      # 記事を読みに行く）
      thumbs: true,
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
  名簿の引き方（Chiezo の「抽出の指定」）。「〜の監督映画」と公開年の分類（「〇〇年の映画」）の作品と主な賞の受賞作の和を
  知名度で切る（**受賞作は下限を免除**）。監督・公開年・国・ジャンルを機械で付けます。
  """
  def extract(min_pageviews \\ Chidori.Relations.Settings.min_pageviews("films")) do
    %{
      source: "jawiki",
      tag_suffix: Enum.join([@director_suffix | @year_suffixes], ","),
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
            source_work_rule(),
            # 続編・同じ題材のように記事どうしが互いにリンクしている組は、薄い線で引く
            %{linked: "mutual", format: "#{Graph.related_tag()}:{1}"}
          ],
      extra: ["pageviews_month", "pageviews_avg", "image"]
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

  # 国。「<国>の…映画」の頭を捕まえ、国の表（`@countries`）にあるものだけ作る（表に無い
  # 「黒澤明の監督映画」は作らない）。**`fill` を付ける** —— 名簿を引き直す回は既にいる作品の
  # タグに触らないので、付けないと国の表を広げる前に入った作品に国が付かない
  defp country_rules do
    [
      %{
        pattern: "^(.+?)の.*映画",
        format: "#{@country_prefix}:{1}",
        map: Map.new(@countries, &{&1, &1}),
        fill: true
      },
      %{
        pattern: "^(?:" <> Enum.join(@japanese_studios, "|") <> ")製作の",
        format: "#{@country_prefix}:日本",
        fill: true
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

  # 話題度の書き方（整理の回と引き継ぎの回で共有）。**物差しは例で決める** —— 数だけ渡すと相手ごとに
  # 付け方が揃わない。10 段にするのは、3 段の注目度では新作の差が付かなかったため
  defp fame_rule do
    """
    **映画としての話題度**を extra に `"#{@fame_level_key}": 1〜10 の整数` で入れてください
    （例: `"extra": {"#{@fame_level_key}": 6}`）。日本でどれくらい知られ、見られた映画かで、原作や
    シリーズ全体の人気ではなく**その映画 1 本**の話題度です。興行収入・観客動員・受賞・社会的な話題で決めてください。
      - 10: 誰もが知る作品（歴代の興行記録に並ぶ大ヒット・国民的な作品）
      - 8: その年を代表する大ヒット（日本の興行収入がおよそ 50 億円以上、社会現象になった）
      - 6: ヒット作（興行収入がおよそ 10〜50 億円、広く話題になった）
      - 4: 映画好きには知られている（興行収入が数億円、公開は限られても評判になった）
      - 2: あまり知られていない
    古い作品は公開当時の話題と今の知られ方の両方で決めてください。確かめられなければ入れないでください。
    """
  end

  # 原作の記事の作品を消さない決まり（ざっと見る回と整理の回で共有）。**映画化された作品の映画の記事が無いとき、
  # 原作（小説・漫画）やテレビ番組の記事がその映画の札**になっている（名簿は記事の分類から引くので、映画の分類が
  # 付いた原作の記事も入る）。「映画ではないもの」を消す決まりだけを渡していた頃は、AI が「小説の記事なので
  # 映画ではない」と原作の記事を 61 本消した（映画の記事が別にあったのは 4 本だけ）
  def source_work_keep_rule do
    """
    **"#{@source_work_prefix}:" のタグが付いた作品は、記事が原作（小説・漫画）やテレビ番組の記事でも、劇場公開された
    映画があれば消さないでください。** 映画の記事が別に無いので、その記事が映画の札の代わりになっています
    （「小説の記事だから映画ではない」は消す理由になりません）。消すのは次のときだけです:
      - 同じ作品の映画の記事が目録に別にある（同じ映画が 2 枚になる）
      - 劇場公開の映画がそもそも 1 本も無い（テレビ放送・配信・ビデオだけ）
    """
  end

  # 機械で付けたタグ（触らせない）
  defp machine_rule do
    """
    **"#{@director_prefix}:"・"#{Graph.years_tag()}:"・"#{@country_prefix}:"・"#{@genre_prefix}:" のタグは Wikipedia の分類から
    機械で付けたものです。そのまま残してください**（足りないときだけ足してください）。
    **"#{@country_prefix}:" のタグが 1 つも無い作品には、製作国を足してください**（分類に国が無く、
    機械では付けられなかった作品です）。"#{@country_prefix}:<国名>" で、国名は日本語版 Wikipedia の表記
    （アメリカ合衆国・イギリス・フランス・日本など）。合作は主な製作国から順に、確かめられた国だけ。
    **"#{@record_prefix}:" のタグも、そのまま残してください**（見た記録と結び付ける印です）。
    **"#{@source_work_prefix}:" のタグも機械が記事から付けたものです。そのまま残してください**。
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
    **映画ではないもの**（人物の記事・劇場公開の映画が 1 本も無いテレビドラマや小説の記事など）が混ざっていたら、
    墓標で消してください（tags に "#{Chiezo.tombstone_tag()}" を入れ、body に消す理由を 1 行）。

    #{source_work_keep_rule()}

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

    やってほしいことは 5 つです。

    **1. 主演を確かめる。** 主演のタグが空のものを埋め、明らかに違うもの（助演を主演にしている・
    名前の書き方が記事名と違う）だけ直してください。**確かめられなかったものは触らないでください。**

    #{stars_rule()}
    **2. 要らないものを消す。** 映画ではないもの（人物の記事・劇場公開の映画が 1 本も無いテレビドラマや小説の
    記事など）と、表記の揺れで 2 つに分かれた同じ作品（残すほうに中身をまとめる）だけを墓標で消してください
    （tags に "#{Chiezo.tombstone_tag()}"、body に理由を 1 行）。

    #{source_work_keep_rule()}

    **3. ポスターを探す。** 行の後ろに「〔空: thumb〕」と付いている作品は、まだ絵がありません。
    **ポスターかキービジュアルの画像の URL** を探して image に入れて返してください。
    - image は**画像そのものの URL**（ページの URL ではなく）。公式サイトのページの og:image、
      無ければ配給会社や映画の情報サイトの作品ページのもの
    - **作品のロゴや出演者の写真は入れないでください**（ポスターかキービジュアルだけ）
    - **確かめられなければ入れないでください**（主演も国も直すものが無ければ、その作品は返さなくて構いません）
    - ポスターだけを足すときは、title と tags（**いま付いているものを全部**）と image だけ返してください
      （body を返さなければ、本文は今のまま残ります）

    **4. 上映時間を確かめる。** 行の後ろに「〔空: runtime_minutes〕」と付いている作品は、上映時間（分）を
    extra に `"runtime_minutes": 分の整数` で入れて返してください（例: `"extra": {"runtime_minutes": 125}`）。
    公式サイトや映画の情報サイト・Wikipedia の記事で確かめた数だけ（版によって違うときは劇場公開版）。
    確かめられなければ入れないでください。3 と同じく、title と tags（全部）と extra だけで構いません。

    **5. 話題度を書く。** 行の後ろに「〔空: #{@fame_level_key}〕」と付いていて、**"#{@source_work_prefix}:" か
    "#{@record_prefix}:" のタグがある作品だけ**（Wikipedia の閲覧数では映画の知名度が測れない作品です。
    "#{@source_work_prefix}:" は記事が原作（小説・漫画など）の記事、"#{@record_prefix}:" は最近足した作品）、#{fame_rule()}
    3 と同じく、title と tags（全部）と extra だけで構いません。ほかの作品には書かなくて構いません。

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
