defmodule Chidori.Datasets.Dining do
  @moduledoc """
  食事処 —— travel-log の地図に並べる「食べに行く先」を Chiezo に集めさせる依頼です。

  **網羅の収集**です。ある括りの全部が対象で、増減はしても古いものが要らなくなる
  ことはない —— ニュースのように期限で落とすと、地図に穴が開きます。

  ## 名簿は 3 つの辞典から機械で引きます

  名前・座標・住所・電話・サイト・紹介文は、Chiezo の百科事典（`jawiki`）・
  地図辞典（`osm_japan`）・店舗辞典（`overture_japan`）に入っています。
  **AI に書かせません** —— 座標を書かせると当てにならない値が混ざり、しかも実行の
  たびに違う値になります。AI に頼むのは、そこに書いていないこと（これは食べに行く
  先か・まだ開いているか・どう紹介するか）だけです。

  **どの項目をどこから採るかは決めてあります**（`extract/1`）。座標は地図辞典、
  説明は百科事典、店舗辞典はいちばん低く —— 同じ店が複数の辞典に居たときに、
  そのつど違う値が入らないようにするためです。

  **どの辞典も絞りません**（範囲の四角で切るだけ）。網羅の収集なので、機械で
  引けるものを取りこぼすと、そのぶんを巡回が区画ごとに探し直すことになります ——
  **機械で済む仕事を AI に払わせる**形です。店舗辞典を上位 2 万件で切っていた頃は
  41 万件の 5% しか採れておらず、触れ込みと中身が食い違っていました。

  ## 収集は範囲ごとに 1 つ

  **見たい範囲だけを、細かい区画で回します**（`Chidori.Datasets.DiningAreas`。
  収集の名前は `chidori_dining_<範囲の番号>`）。日本全体を 1 つで回していた頃は、
  59.7 万件・4,105 区画で一周のめどが立たず、AI の費用もかさみ、抜け漏れと間違いが
  多すぎて地図として使えませんでした。

  ## 区画は座標で割ります

  **母集団は自分自身**（集めたものの座標）で、bbox に範囲の四角を書いてあります。
  外のソースを母集団にすると区画は動かないので楽ですが、**割り直しが効かなくなります**
  —— Chiezo が区画を割り直すのは、自分自身を割っているときだけです
  （育って `target` を超えた区画と、空になった区画が引き金）。座標が直れば区画も
  それに追随してほしいので、こちらを採ります。

  **bbox を書くのは、まだ 1 軒も入っていないところを対象から落とさないため**です。
  点から矩形を作ると、点の無いところは矩形の外になり、「ここに足りない店はないか」を
  永遠に問えません。

  ## 巡回は 2 本

  **機械収集と情報収集の 2 本です**（`sweeps/1`）。食事処は 1 件ずつ web で営業を
  確かめ、足りない店を外から探す仕事なので、**外部の検索が得意な相手に考える量を多く**
  頼まないと進みません —— 低コストの相手で回したざっと見る・中コストの相手で回した
  整理はどちらもうまくいかず、結局どちらも同じ重い相手（情報収集の相手）に回していた。
  重い相手で回す巡回は情報収集に揃え、1 本で、まだ目を通していない店を確かめる・
  足りない店を足す・空欄を埋める・見直す、までを頼みます（`survey_prompt/0`）。
  **費用が重いので、Chiezo の時計では回さず Chidori が時刻を決めて起こします**
  （`Chidori.Datasets.SurveyClock`。時刻は設定ページで決める）。

  **情報収集は名簿ができてから走ります**（`after`）—— 名簿が無ければ区画に
  何も並ばず、空の一覧に向かって「この範囲の全部です」と言うことになります。

  **何日で一周するかは、ここでは決め打ちしません。** 巡回に書く日数は希望で、
  実際の速さは**区画の数**と**Chiezo が 1 回に見る区画の上限**で決まります ——
  区画が増えれば伸び、上限に当たれば書いた日数には届きません。
  **いま何日かかるかは Chiezo の画面**（収集の面の巡回の表）が出します。
  """

  alias Chidori.Chiezo

  # **範囲ごとの収集**（`definition/1`）。収集の名前はこの頭に範囲の番号を付けたもの
  @area_collection_prefix "chidori_dining_"
  # 区画の大きさ。**AI が 1 回で 1 件ずつ確かめられる数にする**。
  # 1 区画 150 件で回していた頃は、AI は 1 区画を 90〜135 秒で見ていた（実測の中央値。
  # 1 件 1 秒に満たない）—— 閉店や実在を web で確かめる見方にはなっておらず、
  # 「見切れた」と出ても名前と座標を眺めただけの回だった。確かめるには 1 件に
  # 10〜30 秒かかるので、1 回の持ち時間（十数分）に収まる 20 件にする
  @area_partition_target 20
  # 情報収集の間隔（分）。**起こすのは Chidori の時計**（`Chidori.Datasets.SurveyClock`。
  # 時刻は設定ページで決める）。Chiezo には巡回の間隔として書くだけで、時計では回らない
  @survey_minutes 720

  # 空いていたら埋めてもらう欄（`blanks/1`・`fill_request/3`）。情報収集の依頼文の 4 で
  # 「空いていたら埋める」と頼んでいるもの。並びが画面の並びで、営業時間を先頭に置く
  # （travel-log の絞り込みの朝食営業・ランチ営業・深夜営業は営業時間から付く）
  @blank_fields [
    opening_hours: "営業時間",
    feature: "特徴",
    genre: "ジャンル",
    rank: "ランク",
    area: "地域",
    description: "説明",
    url: "出典の URL"
  ]
  # 空欄を埋める 1 回に名指しする店の数。既定は区画の目安と同じ —— 1 件ずつ web で
  # 確かめるので、情報収集の 1 回（1 区画）と同じ量なら持ち時間に収まる。
  # 上限は Chiezo の割り込みが名指しを受け取る数（`MAX_FOCUS_TITLES`）
  @fill_default @area_partition_target
  @fill_max 50
  # 一覧の 1 行に「空いている」と添えてもらう脇書きの鍵（`attrs/2` の `show_blanks`）
  @blank_keys ["opening_hours", "url"]
  # travel-log の種別。**範囲が違っても同じ種別に入る**（書き出しは範囲ごと、
  # 読み込み先は 1 つ）
  @area_export_key "dining"

  # 名簿を引き直す間隔。**週 1 で足りる** —— 地図辞典が焼き直されるのはその程度で、
  # AI を呼ばないぶん頻度を上げても得るものが無い
  @roster_minutes 10_080

  # 名簿の回。**どちらの AI の回もこれを待ちます** —— 名簿が無ければ区画に
  # 何も並ばず、差し込みが空のまま「この範囲の全部です」と言うことになる
  @roster_sweep Chidori.SweepNames.machine()

  # 区画を回り続ける回（`sweeps/1`）。**Chidori が時刻を決めて起こす**（Chiezo の時計は外す）。
  # 割り込み（「この区画を先に調べて」「この店が違う」）と travel-log からの依頼も
  # この回が引き受ける
  @survey_sweep Chidori.SweepNames.survey()

  # 出典の目印。**travel-log と AI の両方が読む** —— 同じ店が 2 つに分かれているとき、
  # どちらの座標を残すかはここで決まる（1 軒に複数付くこともある）
  @source_tags [wikipedia: "出典:Wikipedia", osm: "出典:OSM", overture: "出典:Overture"]

  # 百科事典の飲食店カテゴリ。**都道府県ごとに分かれている**ので末尾で指す
  # （書き並べると、あとから県が増えたときに黙って落ちる）
  @wiki_suffix "の飲食店"
  @wiki_tags "日本のレストラン,ラーメン店"

  # 百科事典から外すカテゴリ。**チェーンは地図の邪魔になる**（どこにでもある）
  @wiki_excluded "レストランチェーン"

  # 地図辞典（OSM）で食事処に当たる地物。**喫茶店やファストフードは採らない**
  @osm_feature "amenity=restaurant"

  # 名簿に引く地図辞典のカテゴリ。**食べに行く先だけ**を採る。
  # カテゴリ名は Overture のもので、推測で書くと**エラーにならず 0 件**になる
  # （`/v1/overture_japan/tags?contains=` で実在を確かめてある）
  #
  # ラーメン屋は `noodles_restaurant` に入る（`ramen_restaurant` は今の取り込みに無い）。
  # Overture は版で語彙が動くので、取り込み直したら実在を確かめ直す
  @categories ~w(
    restaurant japanese_restaurant sushi_restaurant noodles_restaurant
    barbecue_restaurant seafood_restaurant chinese_restaurant korean_restaurant
    italian_restaurant french_restaurant
  )

  # 名簿から外すカテゴリ。**チェーンのファストフードは地図の邪魔になる**ので、
  # 同じ地物に付いていたら名簿ごと落とす（残すかは AI ではなくここで決める）
  @excluded ~w(fast_food_restaurant burger_restaurant pizza_restaurant)

  # 地図辞典のカテゴリ → 日本語のジャンル。**travel-log のシリーズになる**ので、
  # AI ではなく機械で付ける（実行のたびに揺れない）。
  #
  # **細かいものを先に並べる。** 読み替えは書いた順にタグを作り、travel-log は
  # 先頭のものをシリーズに使う —— 1 軒には何段階かのカテゴリが同時に付いている
  # （寿司屋には「寿司」と「和食」の両方）ので、粗いほうが先にあると、
  # 地図はどの店も同じ一語で埋まる。
  #
  # **カテゴリ名は実在を確かめてから足す。** 推測で書いてもエラーにならず、
  # その読み替えが一度も当たらないまま静かに残る
  # （`/v1/overture_japan/tags?contains=` で引ける）
  @genres [
    {"sushi_restaurant", "寿司"},
    {"noodles_restaurant", "麺類"},
    {"barbecue_restaurant", "焼肉"},
    {"seafood_restaurant", "海鮮"},
    {"chicken_restaurant", "鶏料理"},
    {"steakhouse", "ステーキ"},
    {"korean_restaurant", "韓国料理"},
    {"chinese_restaurant", "中華"},
    {"italian_restaurant", "イタリアン"},
    {"french_restaurant", "フレンチ"},
    {"indian_restaurant", "インド料理"},
    {"thai_restaurant", "タイ料理"},
    # **いちばん粗いものを最後に。** 上のどれにも当たらなかった和の店がここに落ちる
    {"japanese_restaurant", "和食"}
  ]

  # 店の特徴（「特徴:ランチ営業」）。**travel-log のカテゴリになる**ので、
  # 語彙は Chidori が持つ —— AI に決めさせると表記が割れて、絞り込みが効かなくなる。
  # 並びがそのまま travel-log の絞り込みの並びになる
  @features ~w(朝食営業 ランチ営業 深夜営業 ゆっくりできる 1人で入りやすい 個室あり 子連れ歓迎 予約がおすすめ)

  # 人が現地で位置を確かめた店のカテゴリ。**Chiezo の固定（`Chiezo.locked_tag/0`）から
  # 機械で付ける**ので、AI に頼む語彙（`@features`）には入れない —— 入れると AI が
  # 確かめていない店にも付けてしまう。travel-log から位置確認を渡したあと、取り込み直して
  # この印が付いていれば、Chiezo まで届いたと分かる
  @checked_category "位置確認済み"
  # その逆。**まだ確かめていない店を現地で見て回るため**に絞り込めるようにする
  # （確かめ済みだけでは、残りを探すのに全部の店を開くことになる）
  @unchecked_category "位置未確認"
  # 位置を確かめた店を、AI が閉店と読んだときの印。**消さずにこれを付けて残す**のは
  # Chiezo（`locked_doubt_tag`）。印のタグがそのまま travel-log のカテゴリになる
  @doubt_category "閉店の可能性あり"

  # 営業時間から機械で読み取れる特徴（`Chidori.Datasets.OpeningHours`）
  @hours_features [breakfast: "朝食営業", lunch: "ランチ営業", late: "深夜営業"]

  @doc "この収集の目印のタグ。**travel-log はこれで 1 件を拾います**。"
  def kind_tag, do: "食事処"

  @doc "ジャンル。**先頭が travel-log のシリーズ**で、残りはカテゴリに回せます。"
  def genre_tag, do: "ジャンル"

  @doc "特徴のタグの頭。**travel-log のカテゴリ**になります。"
  def feature_tag, do: "特徴"

  @doc "特徴の語彙（AI に付けさせるもの）。"
  def features, do: @features

  @doc "travel-log のカテゴリの並び（特徴の語彙と、位置確認済み・位置未確認）。絞り込みの並びになります。"
  def category_order,
    do: @features ++ [@doubt_category, @checked_category, @unchecked_category]

  @doc "位置を確かめた店を AI が閉店と読んだときの印（タグとカテゴリ）。"
  def doubt_category, do: @doubt_category

  @doc """
  1 軒の特徴（travel-log のカテゴリ）。**AI が付けたタグと、営業時間から機械で
  読み取れるもの**を合わせ、語彙の並びで返します。語彙に無い語は落とします。
  座標が固定された店（`Chiezo.locked_tag/0`）には「位置確認済み」を、それ以外には
  「位置未確認」を足します。

  営業時間を持っているのは地図辞典（OSM）の店の一部だけなので、機械で付くのは
  そこまでです。残りは AI が調べて付けます。
  """
  def categories(tags, extra) do
    from_tags =
      for tag <- tags,
          is_binary(tag),
          String.starts_with?(tag, feature_tag() <> ":"),
          do: String.replace_prefix(tag, feature_tag() <> ":", "")

    from_hours =
      extra
      |> Map.get("opening_hours")
      |> Chidori.Datasets.OpeningHours.features()
      |> Enum.map(&@hours_features[&1])

    checked =
      if Chiezo.locked_tag() in tags, do: [@checked_category], else: [@unchecked_category]

    doubted = if @doubt_category in tags, do: [@doubt_category], else: []

    have = MapSet.new(from_tags ++ from_hours ++ doubted ++ checked)
    Enum.filter(category_order(), &MapSet.member?(have, &1))
  end

  @doc "都道府県。travel-log の `region` に当たります。"
  def area_tag, do: "地域"

  @doc "知名度の段階（A〜E）。travel-log の `rank` に当たります。"
  def rank_tag, do: "ランク"

  @doc "範囲ごとの収集の名前の頭（後ろに範囲の番号が付く）。"
  def area_collection_prefix, do: @area_collection_prefix

  @doc """
  範囲ごとの収集の名前（`chidori_dining_<範囲の番号>` = Chiezo のソース名）。

  **後から変えない** —— 変えると、それまで溜めた先を見失います。
  """
  def collection(%{id: id}), do: @area_collection_prefix <> to_string(id)

  @doc "範囲ごとの収集の区画の大きさ（1 区画あたりの件数の目安）。"
  def area_partition_target, do: @area_partition_target

  @doc "ジャンルの並び（travel-log のシリーズの並び。範囲が違っても同じ並び・同じ色にする）。"
  def genre_order, do: @genres |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

  @doc """
  範囲 1 つぶんのタブ（データ収集の画面に出す 1 タブぶん）。**収集も溜まる先も
  範囲ごと**です。

  **巡回は機械収集と情報収集の 2 本**（`sweeps/1`）。情報収集が区画を回り、
  travel-log からの報告・まだ目を通していない店・足りない店を先にし、見直しは
  残りの時間で行います（`survey_prompt/0`）。割り込みも travel-log からの依頼も
  情報収集が引き受けます。

  travel-log へは同じ種別（`dining`）に書き出し、スポットの key に
  範囲の番号を付けます（収集ごとに `doc_id` が 1 から振られるので、付けないと
  範囲どうしで key がぶつかり、あとから読み込んだ範囲が前の範囲を上書きする）。
  """
  def definition(%{id: id, name: name} = area) do
    %{
      key: "dining-#{id}",
      name: name,
      module: __MODULE__,
      eyebrow: "EATERIES IN AN AREA",
      title: "#{name}の食事処",
      description:
        "travel-log の地図に並べる「食べに行く先」を、この範囲の中だけで集めます。" <>
          "名前と座標は辞典から機械で引き、食べに行く価値があるかどうかを AI が見ます。",
      collection: collection(area),
      area: area,
      # **溜まったものを誰がどう読むか**は対象ごとに違う（画面の文面になる）
      reader: "travel-log",
      unit: "1 店 1 文書",
      note: note(),
      # **割り込みの行き先は情報収集**（「この区画を先に調べて」「この店が違う」）
      survey_sweep: @survey_sweep,
      # **travel-log からの依頼を走らせる巡回**（`Chidori.Datasets.Requests`）
      request_sweep: @survey_sweep,
      # **区画を回る巡回**（1 本）
      partition_sweeps: [@survey_sweep],
      # **情報収集は Chidori が時刻を決めて起こす**（`Chidori.Datasets.SurveyClock`）
      survey_clock: true,
      export_key: @area_export_key,
      export_name: "食事処",
      key_prefix: "#{id}-",
      series_order: genre_order()
    }
  end

  @doc "巡回ごとの依頼文（画面に出すため）。"
  def prompts(_area), do: [{@survey_sweep, survey_prompt()}]

  @doc "情報収集の巡回の名前（時刻で起こすときに名指しする）。"
  def survey_sweep, do: @survey_sweep

  @doc """
  渡す中身の補足（食事処の「全体」のタブに出す）。**記号で強調しない** —— ここは
  Markdown として描かれないので、`**` を書くとそのまま画面に出る（規約）。
  """
  def note do
    "座標は AI に書かせません（当てにならないうえ、実行のたびに変わります）。" <>
      "辞典から運んだ値を下地にして、食い違っているものだけを AI の回に" <>
      "直させます。座標を持たない 1 件はどの区画にも入らないので、足すときは" <>
      "必ず座標を入れるよう頼んであります。"
  end

  @doc """
  travel-log がスポットにするときに読む項目。

  **画面に出すのは、足りない項目に気づけるようにするため**です —— 集めたものを
  読むのは向こうなので、ここに書いていない項目は、向こうで空欄になります。
  """
  def fields do
    [
      %{field: "名前（name）", stored: "title", who: "辞典（同じ見出しは 1 件に畳まれます）"},
      %{
        field: "座標（lat / lng）",
        stored: "extra.lat / extra.lon",
        who: "地図辞典が優先（食い違うものだけ AI が直す）"
      },
      %{
        field: "地域（region）",
        stored: "タグ「#{area_tag()}:<都道府県>」 / extra.area",
        who: "百科事典のカテゴリと地図辞典（無いものを AI が足す）"
      },
      %{
        field: "シリーズ（series）",
        stored: "タグ「#{genre_tag()}:…」の先頭",
        who: "辞典のカテゴリ（抜けているものを AI が足す）"
      },
      %{
        field: "カテゴリ（categories）",
        stored: "タグ「#{feature_tag()}:…」と extra.opening_hours",
        who: "営業時間から機械で（朝食営業・ランチ営業・深夜営業）、残りは AI"
      },
      %{
        field: "ランク（rank）",
        stored: "タグ「#{rank_tag()}:A〜E」",
        who: "AI（百科事典にある店は extra.pageviews_month が目安になります）"
      },
      %{field: "説明（description）", stored: "body の 2 行目以降", who: "百科事典が優先、無ければ AI"},
      %{
        field: "所在地の手がかり",
        stored: "body の 1 行目 / extra.address",
        who: "辞典と AI"
      },
      %{field: "連絡先・公式サイト", stored: "extra.phone / extra.website", who: "地図辞典が優先"},
      %{
        field: "営業日・営業時間（説明に添える）",
        stored: "extra.opening_hours",
        who: "地図辞典（一部の店だけ）と、情報収集の回の AI（確かめられた店だけ）"
      },
      %{field: "出典", stored: "extra.url", who: "百科事典の記事、無ければ AI"},
      %{
        field: "（どの辞典から来たか）",
        stored: "タグ「#{Enum.join(source_tags(), "」「")}」",
        who: "機械（複数の辞典に居た店には複数付きます）"
      }
    ]
  end

  @doc """
  名簿の引き方（Chiezo の「抽出の指定」）。**Chidori が持ちます**。

  中身が travel-log に渡す項目そのもの（座標・住所・サイト・ジャンル）なので、
  向こうに預けると、読む側と引く側が別々に動いて静かにズレます。

  ## 3 つのソースから引きます

  ひとつの辞典だけでは、要る項目が揃いません。**それぞれ得意なところが違う**ので、
  同じ見出しが複数に居たときに**どの項目をどこから採るか**まで書いてあります
  （Chiezo の `provides`）。

  | ソース | 勝つ項目 | なぜ |
  |---|---|---|
  | 百科事典（`jawiki`） | 説明・出典 | **読み物になる紹介文があるのはここだけ** |
  | 地図辞典（`osm_japan`） | 座標・住所・サイト | 現地を歩いた人が置いた点で、いちばん確か |
  | 店舗辞典（`overture_japan`） | （何も勝たない） | 件数はいちばん多いが、値の確かさは上の 2 つに劣る |

  **順位を譲ることと、その値を捨てることは別です。** 百科事典は座標で勝ちませんが、
  地図に載っていない 1 軒の座標はそこにしか無い —— 捨てると、**その 1 軒はどの区画にも
  入らず、AI から永遠に見えなくなります**（区画は座標で決まります）。Chiezo は
  勝った本で埋めたあと、空いたところを残りの本で埋めます。

  **見出しが違えば畳めません。** 実測では、同じ範囲の地図辞典と店舗辞典で名前が
  一致するのは 3%（60m 以内という条件を足しても 2〜9%）。**畳めなかったぶんは
  別の 1 件として並びます** —— 同じ店が 2 つあることに気づけるのは、区画をまとめて
  見る AI の回のほうなので、そちらに頼んであります。
  一方、**百科事典の見出しは地図辞典とよく一致します**（東京都の飲食店 128 件のうち
  地図辞典に 47 件・店舗辞典に 72 件）。紹介文が要るのはまさにそこなので、
  この形がいちばん効きます。

  **範囲の四角で絞ります**（Chiezo の抽出の `bbox`）。座標を持たない 1 件は
  範囲に入りません。**ほかの収集からは引きません**（範囲の収集は 1 つの独立した
  収集にする）。別の収集を名簿の辞典に加えると、Chiezo はその収集から作られた
  ものとして扱い、親の下に並べる。
  """
  def extract(area) do
    box = Chidori.Datasets.DiningAreas.bbox(area)
    Enum.map([wikipedia_extract(), osm_extract(), overture_extract()], &Map.put(&1, :bbox, box))
  end

  # 百科事典。**説明で勝つ**（読み物になる紹介文があるのはここだけ）。
  # 座標も持っているが譲る —— 地図辞典のほうが確かなため
  defp wikipedia_extract do
    %{
      source: "jawiki",
      tag: @wiki_tags,
      tag_suffix: @wiki_suffix,
      not_tag: @wiki_excluded,
      provides: ~w(body url),
      # 記事の冒頭。**何の店で何が名物か**が 1〜2 文で書いてある
      body: "opening",
      url: "https://ja.wikipedia.org/wiki/{title}",
      tags: [
        %{const: kind_tag()},
        %{const: @source_tags[:wikipedia]},
        # **都道府県で終わるものだけを地域にする。** 「の飲食店」で終わる
        # カテゴリには「2021年開業の飲食店」のような年のものが混ざっていて、
        # そのまま採ると「地域:2021年開業」ができる
        %{pattern: "^(.+[都道府県])#{@wiki_suffix}$", format: "#{area_tag()}:{1}"},
        %{pattern: "^寿司屋$", format: "#{genre_tag()}:寿司"},
        %{pattern: "^ラーメン店$", format: "#{genre_tag()}:麺類"}
      ],
      # **知名度はここにしか無い。** ランクを AI に決めさせる材料になる
      extra: ~w(lat lon pageviews_month image)
    }
  end

  # 地図辞典。**座標で勝つ**（現地を歩いた人が置いた点）。
  # **件数を書かない** —— 書くと見出し順で切られる。OSM は飲食店にどれも同じ点しか
  # 付けないので、`rank_score` が並びを決めず、名前が先に来るものだけが残る
  defp osm_extract do
    %{
      source: "osm_japan",
      tag: @osm_feature,
      provides: ~w(extra),
      body: "opening",
      # `area` は都道府県。**travel-log の地域が機械で決まる**
      # `opening_hours` は**朝食営業・ランチ営業・深夜営業を機械で読み取る**ため（`categories/2`）。
      # 持っているのは地図辞典の飲食店の 1 割ほど
      # `wikidata` は使っていません（上と同じ理由で運びません）
      extra: ~w(lat lon area address website phone opening_hours),
      # **元の地物を名指す鍵。** 見出しは同じ名前の地物に「先に来たほうが素の名前、
      # あとは (node:番号)」と付けるので、取り込み直すと入れ替わりうる ——
      # 見出しだけで突き合わせていると、閉店で消した店が別の見出しで戻ってくる
      identity: ~w(osm_type osm_id),
      tags: [%{const: kind_tag()}, %{const: @source_tags[:osm]}]
    }
  end

  # 店舗辞典。**何も勝ちにいかない**（件数はいちばん多いが、値の確かさは劣る）。
  # 上の 2 つが埋めなかったところだけを埋める
  defp overture_extract do
    %{
      source: "overture_japan",
      tag: Enum.join(@categories, ","),
      not_tag: Enum.join(@excluded, ","),
      provides: [],
      # **件数は書かない（全部採る）。** 飲食店のカテゴリは 41 万件あるが、
      # ここで切ると網羅にならない —— 2 万件で切っていた頃は 5% しか採れておらず、
      # 「食事処を全部集める」という収集の触れ込みと食い違っていた。
      # 切り口に意味がある（`confidence` の順）としても、**採らなかった 95% は
      # 巡回が区画ごとに探し直すことになり、機械で引けるものを AI に払わせる**
      # 名前・種別・所在・住所・座標が 1 段落に入っている。
      # **AI に見せるのはこの本文**なので、座標の食い違いはここから読み取れる
      body: "opening",
      tags:
        [%{const: kind_tag()}, %{const: @source_tags[:overture]}] ++
          for {category, genre} <- @genres do
            %{pattern: "^#{category}$", format: "#{genre_tag()}:#{genre}"}
          end,
      # **元の地物に書いてある事実は、そのまま運ぶ。** travel-log が要るのはここ ——
      # 読む側が 1 件ずつ地図辞典を引き直さずに済む
      # **運ぶのは、後から読むものだけ。** `confidence` は名簿を作るときの並びに
      # 使うだけで、溜めたあとは誰も読みません（`locality` は本文の「所在:」と同じ）——
      # 脇書きは**毎回の素材に丸ごと乗る**ので、読まないものを運ぶと焼きが遅くなります
      # （実測で、この 2 つだけで 9.8 MB）
      extra: ~w(lat lon address website phone),
      # **元の地物を名指す鍵。** 同じ名前の店の見出しの札は取り込みの版で変わる
      # （通し番号 → 町の名前）ので、見出しだけで突き合わせていると、変わった日に
      # 消した店が丸ごと戻り、生きている店は 2 件に増える。Overture の id は
      # 版をまたいで変わらない
      identity: ~w(overture_id)
    }
  end

  @doc "出典の目印。**1 軒に複数付くことがあります**（複数のソースに居た店）。"
  def source_tags, do: Keyword.values(@source_tags)

  @doc """
  出典タグの前置き。書き出し（`Chidori.Datasets.TravelLog`）が、どの辞典から来たかを
  説明文に写すのに使います。**辞典ごとにライセンスが違う**ので、渡した先で
  切り分けられるようにしておく必要があります。
  """
  def source_tag_prefix, do: "出典"

  @doc """
  区画の割り方。**範囲の四角を、座標で、密なところは細かく、疎なところは粗く**
  割ります（k-d 木と同じ割り方。1 区画 20 件）。

  母集団を書かないのは、**自分自身を割っているときだけ Chiezo が割り直す**ためです。

  **どこから広げるかも渡します**（`origin`）。書かないと鍵の文字列順、つまり
  南西の隅からになります。
  """
  def partition(origin, area) do
    %{
      by: "geo",
      target: @area_partition_target,
      bbox: Chidori.Datasets.DiningAreas.bbox(area),
      origin: origin
    }
  end

  @doc "起点の既定は、範囲の真ん中（区画はここから近い順に広げる）。"
  def default_origin(area) do
    {lat, lon} = Chidori.Datasets.DiningAreas.center(area)
    %{name: "#{area.name}の真ん中", lat: Float.round(lat, 6), lon: Float.round(lon, 6)}
  end

  @doc """
  巡回 2 本（機械収集 → 情報収集）。

  **情報収集は一周しても止めない** —— 閉店も開店も続くので、回り続けて追いかける。
  **Chiezo の時計は外し（`by_caller`）、Chidori が決めた時刻に起こします**
  （`Chidori.Datasets.SurveyClock`）。重い相手で回すので、何時に何回起こすかを
  Chidori の側で決めて費用を抑えるため。

  **1 回に回る区画の数も範囲ごとに決めます**（`partitions_per_run`。範囲の
  `survey_per_run`、既定 1）。一周の日数から Chiezo に計算させると、区画の多い範囲ほど
  1 回が重くなる —— 重い相手で回すので、1 回の重さは人が決める。
  """
  def sweeps(area) do
    [
      roster_sweep(),
      %{
        name: @survey_sweep,
        prompt: :survey,
        interval_minutes: @survey_minutes,
        partitions_per_run: Map.get(area, :survey_per_run) || 1,
        after: @roster_sweep,
        by_caller: true
      }
    ]
  end

  # **機械で引く回。** AI を呼ばず、抽出の指定を走らせるだけ。
  # **一度きり** —— 地図辞典が焼き直されない限り何度やっても同じで、
  # その 1 回ぶんの取り込みが無駄になる（焼き直したら押して走らせる。範囲を
  # 変えたときは Chidori が名指しで走らせ直す: `Chidori.Datasets.reshape/1`）。
  # **足すだけ**（`only_new`）にしないと、AI が肉付けしたぶんを
  # 名前と住所しか持たない名簿で上書きする
  defp roster_sweep do
    %{
      name: @roster_sweep,
      interval_minutes: @roster_minutes,
      use_extract: true,
      only_new: true,
      once: true
    }
  end

  @doc "名簿の回の名前（範囲を変えたときに走らせ直す）。"
  def roster_sweep_name, do: @roster_sweep

  @doc "空いていたら埋めてもらう欄（鍵 → 画面の名前。並びが画面の並び）。"
  def blank_fields, do: @blank_fields

  @doc "空欄を埋める 1 回に名指しする店の数の既定と上限（`{既定, 上限}`）。"
  def fill_counts, do: {@fill_default, @fill_max}

  @doc """
  1 件の空いている欄（`blank_fields/0` の鍵の並び）。

  特徴は「付いていない = 分からない」の意味（`item_format/0`）なので、1 つも付いて
  いなければ空とみなします。説明は本文の「所在地: …」の行のほかに何も無ければ空です。
  """
  def blanks(doc) do
    tags = Enum.filter(doc["tags"] || [], &is_binary/1)
    extra = doc["extra"] || %{}
    text = doc["body"] || doc["opening"] || ""

    for {field, _label} <- @blank_fields, blank?(field, tags, extra, text), do: field
  end

  defp blank?(:opening_hours, _tags, extra, _text), do: empty?(extra["opening_hours"])
  defp blank?(:url, _tags, extra, _text), do: empty?(extra["url"])
  defp blank?(:feature, tags, _extra, _text), do: not tagged?(tags, feature_tag())
  defp blank?(:genre, tags, _extra, _text), do: not tagged?(tags, genre_tag())
  defp blank?(:rank, tags, _extra, _text), do: not tagged?(tags, rank_tag())
  defp blank?(:area, tags, _extra, _text), do: not tagged?(tags, area_tag())
  defp blank?(:description, _tags, _extra, text), do: not described?(text)

  defp empty?(value), do: not is_binary(value) or String.trim(value) == ""

  defp tagged?(tags, prefix) do
    Enum.any?(tags, fn tag ->
      String.starts_with?(tag, prefix <> ":") and String.trim(tag) != prefix <> ":"
    end)
  end

  # 1 行目は「所在地: …」（`item_format/0`）。それ以外の行が 1 つでもあれば紹介がある
  defp described?(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 != "" and not String.starts_with?(&1, ["所在地", "住所"])))
  end

  @doc """
  範囲の店のうち、空いている欄のある店。`{:ok, %{total: 店の数, shops: [...]}}`。

  **読むのは AI が目を通した店だけ**（Chiezo の読み口は、まだ目を通していない店と
  消えた店を既定で外す）。目を通していない店は情報収集の 2 で 1 件ずつ確かめるので、
  ここで頼む相手ではありません。
  """
  def blank_report(area) do
    with {:ok, base} <- Chidori.Datasets.base_url(),
         {:ok, docs} <- shop_docs(base, collection(area)) do
      listed = Enum.filter(docs, &(kind_tag() in (&1["tags"] || [])))

      shops =
        for doc <- listed,
            (missing = blanks(doc)) != [],
            do: %{
              title: doc["title"],
              missing: missing,
              lat: coord(doc, "lat"),
              lon: coord(doc, "lon")
            }

      {:ok, %{total: length(listed), shops: shops}}
    end
  end

  defp coord(doc, key) do
    case get_in(doc, ["extra", key]) do
      value when is_number(value) -> value
      _other -> nil
    end
  end

  @doc """
  区画ごとの、空いている欄のある店の数（`%{区画の鍵 => 店の数}`）。区画の一覧と選んだ区画に出す。

  区画は座標で切ってあるので、店の座標が入る区画で数えます（鍵の四角の西・南の辺は含み、
  東・北の辺は含まない。境目の上の店を 2 つの区画で数えないため）。座標の無い店は数えません。
  """
  def blank_by_partition(%{shops: shops}, keys) do
    boxes = for key <- keys, box = Chidori.Datasets.Map.box_of(key), do: {key, box}

    shops
    |> Enum.flat_map(fn
      %{lat: lat, lon: lon} when is_number(lat) and is_number(lon) ->
        case Enum.find(boxes, fn {_key, {s, w, n, e}} ->
               s <= lat and lat < n and w <= lon and lon < e
             end) do
          {key, _box} -> [key]
          nil -> []
        end

      _shop ->
        []
    end)
    |> Enum.frequencies()
  end

  def blank_by_partition(_report, _keys), do: %{}

  # 全ページ。**件数は 1 ページ目が教えてくれる**ので、何周するかはそこで決まる
  defp shop_docs(base, name, offset \\ 0, acc \\ []) do
    case Chiezo.spot_docs(base, name, kind_tag(), offset, 500) do
      {:ok, %{docs: []}} ->
        {:ok, acc}

      {:ok, %{total: total, docs: docs}} ->
        got = acc ++ docs
        if length(got) >= total, do: {:ok, got}, else: shop_docs(base, name, length(got), got)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  欄ごとの空いている店の数（`blank_fields/0` の並び。`[{鍵, 名前, 数}]`）。
  **空いている店の無い欄は出しません**（0 店の欄を選べても頼むものが無い）。
  """
  def blank_counts(shops) do
    for {field, label} <- @blank_fields,
        (count = Enum.count(shops, &(field in &1.missing))) > 0,
        do: {field, label, count}
  end

  @doc """
  空欄を埋める 1 回の頼みごと（`Chidori.Datasets.fill_blanks/3` に渡すもの）。
  `fields` は埋めてほしい欄の鍵、`count` は名指しする店の数（1〜`fill_counts/0` の上限に
  丸める）。当てはまる店が無ければ `:nothing`。

  **区画に縛らず、範囲の全部から店を名指しします**（Chiezo の割り込みの `titles`）——
  名指しした店だけが `{current}` に並ぶので、区画で切らなくても AI はほかの店に触れず、
  1 回の量は数で決まります。区画を渡さないので、情報収集の印も付きません（付くと閉店の
  見直しや足りない店探しが一周先へ回る）。どの店のどの欄が空かは依頼文に書きます
  （一覧には脇書きが出ない）。

  **営業時間の無い店を先に**、そのあと空いている欄の多い店から。**同じ並びの中は
  毎回混ぜます** —— 確かめられなかった欄は空いたまま残るので、決まった順だと
  続けて押したときに同じ店ばかり頼むことになる。
  """
  def fill_request(shops, fields, count) do
    wanted = for {field, _label} <- @blank_fields, field in fields, do: field
    count = count |> max(1) |> min(@fill_max)

    picked =
      shops
      |> Enum.map(&%{&1 | missing: Enum.filter(&1.missing, fn field -> field in wanted end)})
      |> Enum.reject(&(&1.missing == []))
      |> Enum.shuffle()
      |> Enum.sort_by(&{if(:opening_hours in &1.missing, do: 0, else: 1), -length(&1.missing)})
      |> Enum.take(count)

    case picked do
      [] ->
        :nothing

      _some ->
        {:ok,
         %{
           titles: Enum.map(picked, & &1.title),
           note: "挙げた #{length(picked)} 店の空いている欄（#{labels(wanted)}）だけを調べて埋めてください。",
           prompt: fill_prompt(picked)
         }}
    end
  end

  defp labels(fields), do: Enum.map_join(fields, "・", &@blank_fields[&1])

  @doc """
  空欄を埋める 1 回の依頼文（`fill_request/3`）。**保存しない**（その回だけ Chiezo に渡す）。
  情報収集の 4 だけを切り出した形で、1 件の形（`item_format/0`）は同じものを使います。
  """
  def fill_prompt(shops) do
    list =
      Enum.map_join(shops, "\n", fn shop -> "- #{shop.title}: #{labels(shop.missing)}" end)

    """
    「食事処」の一覧のうち、**下に挙げた店の空いている欄だけ**を埋めてください。
    travel-log という地図アプリのスポットとして使います。

    **埋めてほしい店と、空いている欄**
    #{list}

    {current}

    **1 件ずつ調べてください。** 公式サイト・口コミサイト（食べログ・ホットペッパーグルメ・
    Retty など）の店の頁・地図サービスの店の情報を開き、**確かめられたものだけ**書いて
    ください。**分からない欄は空けたままにしてください** —— 当てずっぽうで埋めると、
    正しい情報に見えてしまいます。この回に時間の制限はありません。

    - 営業時間 …… 営業日と営業時間（`extra.opening_hours`）。**地図の絞り込み（朝食営業・
      ランチ営業・深夜営業）はここから機械で付く**ので、いちばん大事です
    - 特徴 …… 下の語から、確かめられたものだけ
    - ジャンル・ランク・地域 …… 下の 1 件の形のとおり。地域は本文の「所在地:」から分かります
    - 説明 …… body の 2 行目以降に 2〜3 文の紹介。**1 行目の「所在地: …」は残してください**
    - 出典の URL …… 実際に開いて、その店の頁だと確かめたものだけ

    **挙げた欄のほかは書き換えないでください。** 座標も触らないでください。
    **返すときは、いま付いているタグと本文を残してください**（返した内容で置き換わります）。
    調べている途中で閉店が分かった店は、墓標で消して構いません（理由を body に 1 行）。
    #{eat_in_rule()}
    #{item_format()}

    **埋めた店・消す店だけを返してください。** 1 つも埋まらなかった店は返さなくて構いません。

    **何を調べたかを、答えの `checked` に 1 行ずつ書いてください**（items と並べて
    `"checked": ["…", "…"]`）。埋まらなかった欄も、どこを見て見つからなかったかを
    残してください。例: "◯◯亭: 公式サイトに営業時間あり、特徴は確かめられず"。
    """
  end

  @doc """
  Chiezo へ送る依頼の中身（作るときも、送り直すときも同じもの）。
  """
  def attrs(choices, area) do
    %{
      name: collection(area),
      # 収集の依頼文も情報収集のもの（割り込みはこの文で走る）
      prompt: survey_prompt(),
      interval_minutes: @survey_minutes,
      sweeps: with_choices(sweeps(area), choices),
      # **網羅。** ある括りの全部が対象で、古いものが要らなくなることはない
      kind: "stock",
      # **現地で位置を確かめた店は、AI が閉店と読んでも消さない**（Chiezo が墓標を
      # このタグに置き換えて残す）。確かめた人が現地でもう一度見られるように
      locked_doubt_tag: @doubt_category,
      # **店の URL を Chiezo に確かめさせる**（開けるか・転送先・頁の題名）。AI が推し量った
      # 口コミサイトの番号や、地図辞典に残った古い URL を、書き出すときに落とすため
      # （`Chidori.Datasets.ShopLinks`）
      links: true,
      # **一覧の 1 行に、空いている脇書きを添えてもらう**（Chiezo の `show_blanks`）。一覧は
      # 見出し・タグ・本文だけなので、依頼文の 4 で「営業時間が無い店を先に」と頼んでも、
      # AI にはどの店が空なのか見えない
      show_blanks: @blank_keys,
      requested_by: "chidori"
    }
    |> Map.merge(shape(area))
  end

  @doc """
  範囲で決まるところ（説明・名簿の指定・区画）。**範囲を変えたときはこれだけを
  送ります** —— 巡回まで送り直すと、画面で選んだ相手が既定に戻る。
  """
  def shape(area) do
    %{lat: lat, lon: lon} = default_origin(area)

    %{
      description: "Chidori のデータ収集（#{area.name}の食事処 / travel-log 向け）",
      extract: extract(area),
      partition: partition([lat, lon], area)
    }
  end

  # 画面で選んだ相手を巡回に載せる。**Chidori は覚えない** —— 正は Chiezo が
  # 持っているもので、画面はそれを読んで見せているだけ
  defp with_choices(sweeps, choices) do
    for sweep <- Enum.map(sweeps, &resolve_prompt/1) do
      case Map.get(choices, sweep.name) do
        # **空文字は落とさない。** あれは「Chiezo の既定にまかせる」を選んだという
        # 意思表示で、落とすと一度決めた相手を外せなくなる
        nil -> sweep
        picked -> Map.merge(sweep, Map.reject(picked, fn {_k, v} -> is_nil(v) end))
      end
    end
  end

  # 巡回ごとの依頼文。**定義の中では名前で置いてある** —— 依頼文は数十行あるので、
  # 巡回の一覧に直に書くと、どの巡回がどんな設定かが読めなくなる
  defp resolve_prompt(%{prompt: :survey} = sweep), do: %{sweep | prompt: survey_prompt()}
  defp resolve_prompt(sweep), do: sweep

  @doc """
  範囲の収集の情報収集の依頼文（巡回は 1 本なので、収集の依頼文もこれ）。
  まだ目を通していない店（名簿から入ったばかりの店を含む）を先に確かめ、そのあとの
  仕事を次の順に頼みます。かつてはざっと見る（`check_prompt`）で一度ずつ確かめた
  あとの整理の文だったので、**ざっと見るにしか書いていなかった決まり**（1 件に混ざった
  別々の店を分ける・地域は必ず埋める）を 2 の段へ移してある。

  1. travel-log からの報告（付いているときだけ。`Chidori.Datasets.Requests`）
  2. まだ目を通していない店（あとから入った店・前の回で見られなかった店）
  3. 足りない店を足す
  4. 埋まっていない情報（営業日と営業時間など）がある店を詳しく調べる
  5. 残りの時間で、並んでいる店を見直す（とくに閉店）

  4 を見直しより先に置くのは、**営業時間の無い店は travel-log で「朝食営業」
  「ランチ営業」の絞り込みにかからない**から。一度確かめた店でも、空いている欄は
  探せば埋まることが多い。

  全件を毎回確かめ直すと、一度見た店に AI の枠を使い続けることになる。ただ、
  閉店の取りこぼしは多いので、見直しもやめはしない。**見直せなかった店は申告させない**
  —— 一度確かめてある店なので、申告すると区画が毎回先頭に戻ってくる。
  """
  def survey_prompt do
    """
    「食事処」の一覧を、**この区画ぶんだけ手入れしてください**。
    travel-log という地図アプリのスポットとして使います。

    **今回見る範囲**
    {partition}

    {current}

    #{nearby_block()}

    **上に並んでいるのが、この範囲の全部です。** 名簿は 3 つの辞典
    （Wikipedia・OpenStreetMap・Overture Maps）から機械的に作ってあり、
    1 件ごとに**どこから来たかのタグ**が付いています。
    **今回は次の順に進めてください**（上のものほど大事です）。

    **1. 地図を使っている人からの報告に答える。** この依頼文の後ろに、現地で見た人の
    報告が付いていることがあります。**付いていたら、何より先にそれに答えてください。**

    **2. まだ目を通していない店を、1 件ずつ確かめる。** tags に
    "#{Chiezo.unreviewed_tag()}" が付いている店です（あとから名簿に入った店や、前の回で
    見られなかった店）。いまも営業しているか（web で確かめる）・食べに行く先か・
    座標が所在地と合っているか・同じ店が 2 つに分かれていないかを見て、下の形で
    中身を埋めてください。**営業を確かめた頁に営業日と営業時間が載っていれば、
    それも書いてください**（`extra.opening_hours`。同じ頁で済むので、手間は増えません）。
    **地域（都道府県）は必ず埋めてください** —— 空のままだと travel-log はその
    スポットを地図に置けません（本文の「住所:」と座標から分かります）。
    **座標は、確かめられなかったら触らないでください** —— 書き換えると、正しかった座標が
    当てずっぽうの値に置き換わります。
    **1 件に別々の店が混ざっていたら分けてください**（同じ名前の別の店が 1 件に
    潰れていることがあります。片方を新しい見出しで足し、店名のうしろに市区町村を添える）。
    **消すのは閉店の証拠が見つかったときだけです**
    （見つからないだけでは消さない）。

    **3. 足りない店を足す。** この範囲にあって、上に並んでいない店を探してください。
    **新しい店・小さい店・地図に載っていない店**が抜けていることがあります。
    **探し方:** 上に並んでいる店の住所から、この範囲の町名・丁目を拾い、
    口コミサイト（食べログ・ホットペッパーグルメ・Retty など）や地図サービスで
    **その町名・丁目の飲食店の一覧**を引いてください。一覧の店と上の店を突き合わせ、
    上に無い店が候補です。手元の知識サーバー（chiezo の MCP）も引けます。
    **足す前に、いまも営業しているかを確かめてください**（直近 1 年ほどの口コミ・公式の
    告知・営業時間の更新のどれかで確かめられた店だけ）。**足すものには必ず座標を
    入れてください**（`lat` と `lon` に数で）。**足すのは範囲の中の店だけです** ——
    座標が上の範囲の外になる店は、隣の区画に並んでいるので挙げないでください。
    確信が持てるものだけで構いません。

    **4. 埋まっていない情報がある店を、詳しく調べる。** 上に並んでいる店のうち、
    **営業日と営業時間（`extra.opening_hours`）が無い店**を先に、そのあと説明・ジャンル・
    地域・ランク・特徴・公式サイト（`url`）のどれかが空いている店を、1 件ずつ調べて
    埋めてください。**営業時間は地図の絞り込み（朝食営業・ランチ営業・深夜営業）に
    使うので、いちばん大事です。** 公式サイト・口コミサイトの店の頁・地図サービスの
    店の情報で**確かめられたものだけ**書き、分からない欄は空けたままにしてください
    （当てずっぽうで埋めると、正しい情報に見えてしまいます）。
    **返すときは、いま付いているタグと脇書きを残してください**（返した内容で
    置き換わります）。

    **5. 時間が残っていたら、並んでいる店を見直す。** **とくに閉店です** ——
    前に確かめたあとで閉めた店が、地図に残っていることがよくあります。
    **見直し方:** 店ごとに、口コミサイトの店の頁と地図サービスの店の情報を開き、
    「閉店」「閉業」「移転」の表示が無いか、最後の口コミがいつかを見てください。
    3 で引いた町名の一覧に出てこない店も、閉店を疑う手がかりになります。
    閉店・閉業の告知、口コミサイトの「閉店」の表示、跡地に別の店が入っている、の
    どれかが見つかった店は墓標で消してください（tags に "#{Chiezo.tombstone_tag()}" を
    入れ、body に「◯年に閉店」のように理由を 1 行）。
    **4 と 5 は全部でなくて構いません。** 見直せなかった店は申告しないでください
    （`not_reviewed` に入れない）—— 一度確かめてある店です。

    **`not_reviewed` に入れるのは、2 で時間切れのため手を付けられなかった店だけです。**
    調べたが営業の情報も閉店の情報も見つからなかった店は、見たうえで残す店なので
    申告しないでください。
    #{closed_twin_rule()}
    #{move_by_fixing()}
    #{eat_in_rule()}
    #{merge_rule()}

    **消す理由は必ず body に書いてください。** 消したものは名前が並ぶだけなので、
    理由が無いと消し間違いに気づけません。

    #{item_format()}

    **直した店・消す店・足す店だけを返してください。** 直すところが無かった店は
    返さなくて構いません（そのまま残ります）。

    **何を調べたかを、答えの `checked` に 1 行ずつ書いてください**（items と並べて
    `"checked": ["…", "…"]`）。直すところが無かった店も、見つからなかったことも、
    ここに残します。例:
    "◯◯亭: 食べログに 2026年9月の口コミあり、営業中"、
    "足りない店: 食べログ・ホットペッパーで丸の内1丁目の一覧を確認、上に無い店 1 件"、
    "見直し: 12 件の店の頁を確認、閉店の表示は無し"。
    **ここは地図には載りません** —— あとで、この回に何を確かめたのかを読むためのものです。
    """
  end

  # 閉店した店の片割れ。
  # 同じ店が辞典に 2 件入っていることがあり、片方だけ消すともう片方が地図に残る
  # （実測: 閉店で消した店と同じ名前の店が、同じ住所で生きたまま残っていた）
  defp closed_twin_rule do
    """
    **閉店で消すときは、同じ店の片割れも消してください。** 同じ店が辞典に 2 件以上
    入っていることがあります（辞典違い・表記違い・見出しの後ろの「(番号)」「(町名)」だけが
    違うもの）。**上に同じ住所・同じ名前の 1 件があれば、それも同じ理由で墓標を付けて**
    ください —— 片方だけ消すと、もう片方が開いている店として地図に残ります。
    同じチェーンの別の店舗（住所が違う）は別の店なので残してください。
    """
  end

  # 座標のずれた 1 件をどう扱うか。実際に「本来の区画へ移動」と書いて
  # 消された店が出た（移った先の回はその店を知らないので、移動にはならない）
  defp move_by_fixing do
    """
    **座標が違うことは、消す理由ではありません。** 住所がこの範囲の外を指していても、
    **消さずに正しい緯度・経度へ直してください** —— 直せば次の回から本来の区画に並びます。
    **「本来の区画へ移す」ために消すのも同じです。** 移す手立ては座標を直すことだけで、
    消してから移すことはできません —— 移った先の回はその店を知りませんし、
    消したものには墓標が立つので、機械で作る名簿からも戻ってきません。
    **あなたが消せば、その店はそこで終わりです。**
    **tags に "#{Chiezo.locked_tag()}" が付いた店は、人が現地で確かめた位置です。
    座標を直さないでください**（直しても元の座標に戻ります）。
    この店を閉店と判断して墓標にすると、消えずに「#{@doubt_category}」のタグが付いて
    残ります（現地で確かめ直すため）。**「#{@doubt_category}」のタグは消さないでください。**
    """
  end

  # 食事処の線引き。**travel-log は「食べに行く先」の地図**なので、その場で
  # 食べられない店は並べない
  defp eat_in_rule do
    """
    **その場で食べられるかで分けてください。**

    - **消す** …… 持ち帰り専門の弁当・惣菜・パン・菓子の店、百貨店の地下や駅ナカの
      物販売場、仕出し・ケータリング、入れない社員食堂。
      買って帰るだけの店は、地図に並べても行き先になりません
    - **残す** …… 席があって、その場で食べられる店。
      **持ち帰りもやっている店は残してください**（寿司屋や麺類の店の持ち帰りは、
      その店の一部です）
    - **迷ったら残す** …… 消せば名簿から消えたまま戻りません。判断の付かないものは
      触らずに置いてください
    """
  end

  # 同じ店が 2 つに分かれていたときの、どちらを採るかの決まり。
  #
  # **機械で決められるところは機械で決めてある**（`extract/1` の `provides`）ので、
  # ここで言うのは**機械が畳めなかったぶん**の話。畳めていれば AI は 1 件しか見ない
  defp merge_rule do
    """
    **まとめるときは、出典のタグを見て決めてください。**

    - **座標は "#{@source_tags[:osm]}" の付いた側**を残す（現地を歩いた人が置いた点です）。
      無ければ "#{@source_tags[:wikipedia]}"、それも無ければ残ったほうで構いません
    - **説明は "#{@source_tags[:wikipedia]}" の付いた側**を残す（読み物になっているのはこちらです）
    - **電話・公式サイトは埋まっているほう**を残す
    - **出典のタグは、まとめた側にすべて残してください**（どの辞典に載っていた店かは、
      次に見るときの手がかりになります）
    """
  end

  # 1 件の形（travel-log が読むのはこの形）
  # 隣の区画にある店（Chiezo の `{nearby}`）。**`{current}` は区画の中しか見せない**ので、
  # 密集した地区では境目の向こうに既にある店を「足りない」と読んで足し直していた。
  # **どの依頼文にも同じ文を置く**（足す回が 1 つでも見ていなければ、そこで被る）
  defp nearby_block do
    """
    **隣の区画にある店**（この範囲のすぐ外。見出しと座標だけ）。**ここに並んでいる店は
    足さないでください** —— 隣の区画で扱っています。辞典ごとに座標が少しずれるので、
    この範囲の中にあるように見えても、同じ名前・同じ場所なら同じ店です。

    {nearby}
    """
  end

  defp item_format do
    """
    1 件の形は次のとおりです。

    - title: **店の名前だけ**（地名や説明を混ぜない）。
      **同じ店は同じ表記で返してください** —— ここが同一の鍵で、変えると別の店として
      増えます。上に並んでいるものを直すときは、その表記のまま返してください
    - body: 1 行目に「所在地: 都道府県 市区町村 まで」、2 行目以降に
      **2〜3 文の紹介**（何が名物で、どういうときに寄る店か）。
      味の評価ではなく、**行くかどうかを決められること**を書いてください
    - url: 出典（店の公式サイトか、口コミサイトのその店の頁）。**実際に開いて、その店の頁だと
      確かめたものだけ**書いてください。**口コミサイト（食べログ・ホットペッパー・Retty・
      じゃらんなど）の店の番号を推し量って書かないでください** —— 番号が 1 つ違うと
      別の店の頁になります。確かめられなければ書かない（null も書かない）。
      **https で**書いてください（http しか無いときだけ http）。
      いま付いている url が別の店の頁・開けない頁だと分かったら、確かめた正しい URL に
      直すか、**`extra.url` に `null` を書いて**消してください（url を書かないだけでは
      前の値が残ります）
    - lat / lon: 緯度・経度を数で。**直すときと足すときだけ**書きます
    - extra.opening_hours: **営業日と営業時間**。公式サイト・口コミサイトの店の頁などで
      **確かめられたときだけ**書きます（分からなければ書かない。null も書かない ——
      書くと、地図辞典から入っていた値まで消えます）。
      **OpenStreetMap の `opening_hours` の書き方**で、曜日（Mo Tu We Th Fr Sa Su、祝日は PH）と
      24 時間制の時刻で書いてください。定休日は `off`、昼と夜で分かれていれば `,` で並べ、
      日付をまたぐ閉店は `18:00-02:00` のように書きます。
      例: `Mo-Fr 11:00-14:30,17:30-22:00; Sa,Su,PH 11:00-21:00; We off`。
      **ここから朝食営業・ランチ営業・深夜営業の印が機械で付く**ので、書式を崩さないでください
    - tags: **いま付いているタグは、直すもの以外そのまま残してください**
      （返した内容で丸ごと置き換わるので、書かなかったタグは消えます）
      - "#{kind_tag()}" —— この一覧の目印。**必ず残してください**
      - "#{genre_tag()}:<ラーメン / 寿司 / 和食 のような料理の種類>"。
        **先頭のものが地図の見た目になる**ので、その店を一言で言うものを先に。
        当てはまるものが複数あれば並べて構いません
      - "#{area_tag()}:<東京都 / 京都府 のような都道府県>"。
        **空いているものは必ず埋めてください** —— travel-log の `region` に当たり、
        ここが無いスポットは地図に置けません。名簿の元の店舗辞典は、日本では
        この欄がほとんど空のまま入ってきます
      - "#{feature_tag()}:<特徴>" —— **その店の特徴**。travel-log の絞り込みになります。
        **次の語から選んでください**（新しい語は作らない）:
        #{Enum.join(@features, " / ")}。
        **調べて確かめられたものだけ**付けてください —— 付いていないことは
        「分からない」の意味で、付けた印は「そうだ」と読まれます
      - "#{rank_tag()}:<A〜E>" —— **どれくらい知られているか**。
        A=全国から人が来る、B=その県を代表する、C=その市区町村で知られる、
        D=地元で親しまれている、E=それ以外。**地図の丸の大きさになります**ので、
        迷ったら下の段にしてください（全部が A だと、大きさが何も表さなくなります）
      - "#{Enum.join(source_tags(), ~s(" / "))}" —— **どの辞典から来たか**。
        機械が付けたものなので、**足したり消したりしないでください**
        （自分で見つけて足した 1 件には、どれも付けません）

    **消す 1 件は、形が 1 つ違います。**

    - tags に "#{Chiezo.tombstone_tag()}" を入れる
    - **body に消す理由を 1 行**書く（「◯年に閉店」「◯◯と同じ店なのでまとめた」
      「弁当屋で食べに行く先ではない」のように、**何をどう判断したか**）

    **理由の無い墓標は、あとから誰にも直せません。** 消したものは名前が並ぶだけで、
    本文は機械が入れた元のまま残ります —— **消し間違いに気づけず、戻す判断もできません**
    （実際に、座標が違うだけの店がまとめて消え、理由が無いために戻せませんでした）。
    **1 行で構いません。**
    """
  end
end
