defmodule Chidori.Relations.Films do
  @moduledoc """
  名作映画の関連図（関連図の画面の「名作映画のつながり」）。**同じ監督の作品を枠で囲んで
  近くに置き、同じ主演の作品どうしを線で結びます**。画家・芸能人の図と同じ仕組みで、
  Chiezo に名簿を持たせて育てます。

  ## 名簿 —— ほとんど機械で引ける

  日本語版 Wikipedia の映画の記事には、**「黒澤明の監督映画」のような監督の分類**と、
  **「1954年の映画」のような公開年の分類**が付いています。名簿・監督・公開年・国は
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
  - **同じ監督の作品は枠で囲み、ひとかたまりに置く**（`clusters`。芸能人の図のグループと
    同じ組み方で、作品の「監督:<名前>」から組む）。共同監督の作品は、名簿に作品の多いほうの
    監督の枠に入る
  - **同じ主演の作品は線で結ぶ**（`shared` の線。公開年の順に隣どうしを結ぶ ——
    全部の組を結ぶと、作品の多い俳優で線が網になる）
  - 色は国（「日本の…映画」「アメリカ合衆国の…映画」のような分類から機械で付ける）

  ## 並べ方

  縦は公開年（枠は作品の公開年の中ほど）。区画は「国 × 公開年」で切ります。
  """

  alias Chidori.Chiezo
  alias Chidori.Relations.Graph

  @kind_tag "映画"
  # 色と区画に使う国
  @country_prefix "国"
  # 枠を組む材料（値は監督の日本語版 Wikipedia の記事名。分類から機械で付ける）
  @director_prefix "監督"
  # 線を組む材料（値は主演の日本語版 Wikipedia の記事名。AI が書く）
  @star_prefix "主演"

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

  # 日本の大手の製作の分類（国の分類を持たない古い邦画がある）
  @japanese_studios ~w(東宝 東映 松竹 日活 大映)

  # 区画の割り方。**国 × 公開年で 25 本ずつ**（画家・芸能人と同じ大きさ）
  @partition %{by: "band", prefix: @country_prefix, value: Graph.years_tag(), target: 25}

  # 一周の日数（既定の間隔のとき）。名簿は芸能人の 3 分の 1 ほど
  @rough_days_at_default 2
  @survey_days_at_default 14

  @doc "収集の名前。"
  def collection, do: "chidori_films"

  @doc "図に載せる文書の印。"
  def kind_tag, do: @kind_tag

  @doc "国のタグの頭（色と区画）。"
  def category_tag, do: @country_prefix

  @doc "監督のタグの頭（枠）。"
  def director_tag, do: @director_prefix

  @doc "主演のタグの頭（線）。"
  def star_tag, do: @star_prefix

  @doc "区画の割り方。"
  def partition, do: @partition

  @doc "知名度に関わらず入れる賞の分類。"
  def award_categories, do: @award_categories

  @doc """
  図の読み方（`Chidori.Relations.Graph.from_docs/2`）。**横の帯は持たず、同じ監督の
  作品を枠で囲み**（`clusters`）、**同じ主演の作品を線で結ぶ**（`shared`）。
  """
  def graph_spec,
    do: %{
      kind_tag: @kind_tag,
      kinds: [],
      default_kind: :film,
      style_prefix: @country_prefix,
      band_prefix: @country_prefix,
      bands: [],
      works?: false,
      clusters: %{tag_prefix: @director_prefix},
      edge_rules: [
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
      description: "Chidori の関連図（名作映画のつながり）",
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
  知名度で切る（**受賞作は下限を免除**）。監督・公開年・国を機械で付けます。
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
          [
            # 続編・同じ題材のように記事どうしが互いにリンクしている組は、薄い線で引く
            %{linked: "mutual", format: "#{Graph.related_tag()}:{1}"}
          ],
      extra: ["pageviews_month", "image"]
    }
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
    **"#{@director_prefix}:"・"#{Graph.years_tag()}:"・"#{@country_prefix}:" のタグは Wikipedia の分類から
    機械で付けたものです。そのまま残してください**（足りないときだけ足してください）。
    """
  end

  @doc """
  ざっと見る回の依頼文（収集の既定の文）。**主演を埋める**のがいちばんの仕事
  （監督・公開年・国は名簿の時点で機械で付いている）。
  """
  def prompt do
    """
    名作映画の関連図を育ててください。**同じ監督の作品と、同じ主演の作品をつなぐ図**です。

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
    - body: どんな作品か（1〜2 文。あらすじの核と、なぜ名作とされるか）
    - url: 日本語版 Wikipedia の記事の URL
    - tags: **いま付いているタグをすべて残したうえで**、上のタグを足す
    """
  end

  @doc "区画ごとに仕上げる回の依頼文。**主演の漏れと誤りを直し、要らないものを消す**。"
  def survey_prompt do
    """
    名作映画の関連図を、**この区画ぶんだけ仕上げてください**。

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
      "#{@star_prefix}:<主演>"。"#{Graph.related_tag()}" のタグは**そのまま残してください**
    """
  end
end
