defmodule Chidori.Datasets.AnimeSeichi do
  @moduledoc """
  アニメ聖地 —— travel-log の地図に「その作品の舞台になった土地」を並べる依頼です。

  **1 件は 1 作品 × 舞台の土地 1 つ**です。1 作品の聖地を何十か所も並べず、舞台の土地に
  ピンを 1 本だけ立て、**その土地で作中にどんな場所が出てくるかは説明に書きます**。
  劇場版で舞台が別の土地なら、劇場版を別の 1 件にします（見出しは劇場版の作品名）。
  対象は **TV アニメと劇場アニメ**だけです（OVA・配信だけの作品・漫画やゲームだけの舞台は入れない）。

  ## 名簿は百科事典のカテゴリから機械で引きます

  **入口は年のカテゴリ**（「2018年のテレビアニメ」「2019年のアニメ映画」）で、TV アニメと劇場
  アニメだけが入る。そのうち**日本の土地の付いた舞台のカテゴリ**（「埼玉県を舞台としたアニメ作品」
  「鎌倉市を舞台としたアニメ作品」）にも入っている作品だけを採ります（Chiezo の抽出の
  `tag_pairs` の `with_pattern`）。県はカテゴリの名前から読み、市区町村は地図辞典で県へ読み替え
  （`area_of`）、2 つの県に入る作品は県ごとの 1 件に分けます（`split`）。

  **百科事典だけでは足りません。** 舞台のカテゴリが付いていない作品は多く、昔の作品は舞台を
  公表していないことも多い（ファンの考察で特定されている）。そこで情報収集の回が、自治体・
  観光協会・公式の紹介と、聖地巡礼の考察まで当たって、足りない作品と舞台の場所を埋めます。

  ## ピンは象徴的な場所に立てます

  **作品の顔になっている実在の場所**（駅・神社・橋・学校のモデル・商店街など）に立てます。
  決めきれなければ、舞台の最寄駅にします。座標は Chiezo が地図辞典（OSM）に引き当て、
  当たらなければ住所の街区、それでも決まらなければ AI が地図サービスで確かめた座標で置きます
  （`resolve/0`。店舗辞典は使わない —— 公共の場所は地図辞典のほうが確か）。

  ## 巡回は 2 本

  **機械収集 → 情報収集**です（`sweeps/0`）。舞台を確かめるには外の頁を何枚も当たる必要が
  あるので、外部の検索が得意な相手に考える量を多く頼む重い回 1 本にまとめます
  （食事処と同じ考え方。`Chidori.Datasets.Dining`）。区画は県（ご当地グルメと同じ並び）。
  """

  alias Chidori.Chiezo
  alias Chidori.Datasets.Gourmet
  alias Chidori.SweepNames

  @collection "chidori_anime_seichi"
  # travel-log の種別。**前からある種別（百科事典から作った聖地）とは別の種別にする** ——
  # 同じ種別へ読み込むと、作り方の違う 2 つの並びが混ざる。中身を確かめてから入れ替える
  @export_key "anime"
  @export_name "アニメ聖地"

  @roster_sweep SweepNames.machine()
  @survey_sweep SweepNames.survey()
  # 名簿の回は一度きり（百科事典を焼き直したら押して走らせる）。間隔は書くだけ
  @roster_minutes 10_080
  # 情報収集の間隔（分）。重い回なので 1 回 1 県
  @survey_minutes 720

  @unknown_region "不明"
  @unplaced_tag "状態:場所未定"
  @ai_source_label "AI"
  @address_source_label "位置参照情報"

  # 形式（travel-log のシリーズ）。TV アニメと劇場アニメだけ
  @tv "TVアニメ"
  @film "劇場アニメ"
  @kinds [@tv, @film]

  # 裏付け（travel-log のカテゴリ）。**公表されたものか、考察で特定されたものかを分ける** ——
  # 昔の作品は舞台を公表していないことが多く、考察で特定された場所は外れていることもある
  @backings [
    {"公式", "公式が公表"},
    {"自治体", "自治体が紹介"},
    {"観光協会", "観光協会が紹介"},
    {"考察", "ファンの考察で特定"}
  ]

  # 舞台のカテゴリの土地のうち、県の名前ではないもの → 県（地名の書き方が県と違うもの）。
  # 市区町村は地図辞典で読む（`area_of`）ので、ここには書かない
  @places %{
    "東京" => "東京都",
    "京都" => "京都府",
    "大阪" => "大阪府",
    "多摩地域" => "東京都",
    "新宿" => "東京都",
    "渋谷" => "東京都",
    "池袋" => "東京都",
    "秋葉原" => "東京都",
    "吉祥寺" => "東京都",
    "東京臨海副都心" => "東京都",
    "東京副都心" => "東京都",
    "伊豆諸島" => "東京都",
    "湘南" => "神奈川県",
    "甲子園球場" => "兵庫県"
  }

  @setting_suffix "を舞台としたアニメ(?:作品|映画)"

  @doc "この一覧の目印のタグ。"
  def kind_tag, do: "アニメ聖地"

  @doc "県のタグの頭（区画の鍵）。"
  def area_tag, do: Gourmet.area_tag()

  @doc "形式のタグの頭。"
  def genre_tag, do: "形式"

  @doc "場所がまだ決まっていない 1 件の印（手がかりがまだ無いものと、引き当てられなかったもの）。"
  def unplaced_tag, do: @unplaced_tag

  @doc "収集の名前。"
  def collection, do: @collection

  @doc "名簿の回の名前。"
  def roster_sweep_name, do: @roster_sweep

  @doc "形式の語彙（travel-log のシリーズの並び）。"
  def kinds, do: @kinds

  @doc "県の区画の鍵から県（`地域:東京都` → 東京都。県の分からない区画は nil）。"
  def prefecture_of_key(key), do: Gourmet.prefecture_of_key(key)

  @doc "データ収集のタブ 1 つぶん。"
  def definition do
    %{
      key: "anime",
      name: "アニメ聖地",
      module: __MODULE__,
      eyebrow: "ANIME SETTINGS, ONE PREFECTURE AT A TIME",
      title: "アニメ聖地",
      description:
        "travel-log の地図に、TV アニメと劇場アニメの舞台になった土地を並べます。" <>
          "1 件は 1 作品の舞台の土地 1 つで、ピンはその土地の象徴的な場所（決めきれなければ" <>
          "最寄駅）に 1 本だけ立て、作中にどんな場所が出てくるかは説明に書きます。県ごとに回ります。",
      collection: @collection,
      reader: "travel-log",
      unit: "1 作品の舞台の土地 1 つで 1 文書",
      note:
        "座標は Chiezo が地図辞典に引き当てます。当たらなければ住所の街区、それでも決まらなければ" <>
          "AI が地図サービスで確かめた座標で置きます。場所が決まっていない作品は座標を持たないので、" <>
          "travel-log へは書き出しません。",
      extract_note:
        "名簿は百科事典の年のカテゴリ（2018年のテレビアニメ・2019年のアニメ映画など）に入る作品のうち、" <>
          "日本の土地の付いた舞台のカテゴリ（埼玉県を舞台としたアニメ作品・鎌倉市を舞台としたアニメ作品など）" <>
          "にも入っている作品から引きます。県はカテゴリの名前から読み、2 つの県に入っている作品は" <>
          "県ごとの 1 件に分けます。AI は関わりません。",
      partition_note: "区画は県です（47 県と、県の分からない作品の「不明」）。1 周目は東京都から JIS の番号順に回ります。",
      prompt_note:
        "AI が書くのは百科事典に書いていないことだけです —— 舞台の土地と象徴的な場所、作中に出てくる" <>
          "場所、公表されたものか考察で特定されたものか、足りない作品。",
      survey_sweep: @survey_sweep,
      request_sweep: @survey_sweep,
      partition_sweeps: [@survey_sweep],
      export_key: @export_key,
      export_name: @export_name,
      series_order: @kinds
    }
  end

  @doc "巡回ごとの依頼文（画面に出すため）。"
  def prompts, do: [{@survey_sweep, survey_prompt()}]

  @doc "travel-log がスポットにするときに読む項目（画面の「travel-log に渡す中身」）。"
  def fields do
    [
      %{
        field: "名前（name）",
        stored: "title（作品名。県ごとに分けた 1 件の「（県名）」は落とす）",
        who: "百科事典の記事名か、AI（足した作品）"
      },
      %{
        field: "座標（lat / lng）",
        stored: "extra.lat / extra.lon（象徴的な場所。決めきれなければ舞台の最寄駅）",
        who: "Chiezo（AI が書いた場所の手がかりを地図辞典に引き当てる。当たらなければ住所の街区、AI の座標の順）"
      },
      %{field: "地域（region）", stored: "タグ「地域:<県>」", who: "百科事典のカテゴリから機械で（足した作品は AI）"},
      %{field: "ランク（rank）", stored: "extra.pageviews_month（百科事典の月の閲覧数）", who: "名簿が運ぶ値から機械で"},
      %{field: "シリーズ（series）", stored: "タグ「形式:TVアニメ」「形式:劇場アニメ」", who: "年のカテゴリから機械で（足した作品は AI）"},
      %{field: "カテゴリ（categories）", stored: "タグ「裏付け:<誰が舞台を挙げているか>」", who: "AI（確かめた頁があるものだけ）"},
      %{
        field: "説明（description）",
        stored: "body（作中に出てくる場所）・extra.spot（ピンの場所）・extra.spot_reason・出典",
        who: "AI（自分の言葉で。百科事典の文は写さない）と、機械が組み立てる出典と座標の出どころ"
      }
    ]
  end

  @doc "名簿の引き方（Chiezo の抽出の指定）。"
  def extract do
    prefectures = Gourmet.prefectures()
    places = Map.merge(Map.new(prefectures, &{&1, &1}), @places)

    %{
      source: "jawiki",
      # **入口は年のカテゴリ**（TV アニメと劇場アニメだけが入る）
      tag_suffix: "年のテレビアニメ,年のアニメ映画",
      body: "opening",
      url: "https://ja.wikipedia.org/wiki/{title}",
      # **日本の土地の付いた舞台のカテゴリにも入っている作品だけ**（学校・宇宙・時代・外国の舞台だけの作品は入れない）
      tag_pairs: [
        %{pattern: "^\\d{4}年の(?:テレビアニメ|アニメ映画)$", with_pattern: japan_setting_pattern()}
      ],
      tags: [
        %{const: kind_tag()},
        # 県の名前・県と書き方の違う地名（東京・多摩地域・湘南…）から県を読む。当たった県ごとに作る
        %{
          pattern: "^(.+?)#{@setting_suffix}$",
          format: "#{area_tag()}:{1}",
          map: places
        },
        # **県の名前が付いていなければ、市区町村から県を読む**（地図辞典で引く `area_of`）
        %{
          pattern: "^(.+?[市区町村])#{@setting_suffix}$",
          format: "#{area_tag()}:{1}",
          fallback: true,
          area_of: %{
            source: "osm_japan",
            feature: ["place=city", "place=town", "place=village"]
          }
        },
        # **それでも県が決まらなければ「不明」の区画へ**（手入れの回が県へ付け替える）
        %{
          pattern: "^\\d{4}年の(?:テレビアニメ|アニメ映画)$",
          format: "#{area_tag()}:#{@unknown_region}",
          fallback: true
        },
        %{pattern: "^\\d{4}年のテレビアニメ$", format: "#{genre_tag()}:#{@tv}"},
        %{pattern: "^\\d{4}年のアニメ映画$", format: "#{genre_tag()}:#{@film}"}
      ],
      extra: ["pageviews_month"],
      split: %{prefix: "#{area_tag()}:", title: "{title}（{value}）"}
    }
  end

  # 日本の土地の付いた舞台のカテゴリ。県（「〜都道府県」）・県と書き方の違う地名・市区町村で、
  # **カタカナだけの市（ニューヨーク市）は外す**。Chiezo の正規表現は 200 字までなので、
  # 県は 47 を並べずに形で書く（読み替えの表 `map` が県の名前そのものかを確かめる）
  defp japan_setting_pattern do
    places = @places |> Map.keys() |> Enum.map_join("|", &Regex.escape/1)
    "^(?:.{1,3}[都道府県]|#{places}|(?![ァ-ヴー・]+[市区]を).+?[市区町村])#{@setting_suffix}$"
  end

  @doc "区画の割り方（県 47 と「不明」。並べた順が 1 周目の順）。"
  def partition do
    %{
      by: "tag",
      prefix: "#{area_tag()}:",
      target: 500,
      values: Gourmet.prefecture_order() ++ [@unknown_region]
    }
  end

  @doc """
  場所の引き当て（Chiezo の `resolve`）。**店舗辞典は使わない** —— 象徴的な場所は駅・神社・
  橋・学校・商店街のような公共の場所が多く、人が現地で置いた地図辞典の点のほうが確か。
  当たらなければ住所の街区、それでも決まらなければ AI が地図サービスで確かめた座標で置く。
  """
  def resolve do
    %{
      clue: "spot",
      sources: [%{source: "osm_japan", identity: ["osm_type", "osm_id"], tag: "出典:OSM"}],
      address: %{source: "address_jp", tag: "出典:#{@address_source_label}"},
      ai_fallback: %{tag: "出典:#{@ai_source_label}"},
      area_tag: "#{area_tag()}:",
      agree_meters: 100,
      carry: ["address", "website"],
      failed_tag: @unplaced_tag,
      failed_when_missing: true
    }
  end

  @doc """
  巡回 2 本（機械収集 → 情報収集）。**情報収集は 1 回 1 県**で、場所の決まっていない作品が
  残る県には次の回も戻る（`hold_tag`。Chiezo の歯止めは続けて 3 回まで）。
  """
  def sweeps do
    [
      %{
        name: @roster_sweep,
        interval_minutes: @roster_minutes,
        use_extract: true,
        # **足すだけ**（AI が書いた説明と場所を、記事の冒頭しか持たない名簿で上書きしない）
        only_new: true,
        once: true
      },
      %{
        name: @survey_sweep,
        prompt: :survey,
        interval_minutes: @survey_minutes,
        partitions_per_run: 1,
        after: @roster_sweep,
        hold_tag: @unplaced_tag
      }
    ]
  end

  @doc "Chiezo へ送る依頼の中身（作るときも、送り直すときも同じもの）。"
  def attrs(choices \\ %{}) do
    %{
      name: @collection,
      prompt: survey_prompt(),
      interval_minutes: @survey_minutes,
      sweeps: with_choices(sweeps(), choices),
      kind: "stock",
      resolve: resolve(),
      links: true,
      requested_by: "chidori"
    }
    |> Map.merge(shape())
  end

  @doc "説明・名簿の指定・区画。"
  def shape do
    %{
      description: "Chidori のデータ収集（アニメ聖地 / travel-log 向け）",
      extract: extract(),
      partition: partition()
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

  defp resolve_prompt(%{prompt: :survey} = sweep), do: %{sweep | prompt: survey_prompt()}
  defp resolve_prompt(sweep), do: sweep

  @doc """
  情報収集の依頼文。**名簿の確かめ → 場所 → 説明 → 足りない作品**の順に頼みます。
  舞台を公表していない作品は考察まで当たる必要があるので、確かめる手順と、公表と考察の
  書き分けを具体的に書く。
  """
  def survey_prompt do
    backings = Enum.map_join(@backings, " / ", fn {tag, means} -> "\"裏付け:#{tag}\"（#{means}）" end)

    """
    「アニメ聖地」の一覧を、**この県のぶんだけ手入れしてください**。
    travel-log という地図アプリのスポットとして使います。**1 件は 1 つのアニメ作品
    （TV アニメか劇場アニメ）の、舞台になった 1 つの土地**です。ピンはその土地の
    象徴的な場所に 1 本だけ立て、作中にどんな場所が出てくるかは説明に書きます。

    **今回受け持つ県**
    {partition}

    {current}

    **上に並んでいるのが、この県のいまの全部です。** 今日は {now} です。
    **受け持つ県が「#{@unknown_region}」の回は**、下の段ではなく次のことだけをしてください:
    並んでいるのは、カテゴリから県が読めなかった作品です。1 件ずつ舞台の土地のある県を調べ、
    タグ "#{area_tag()}:#{@unknown_region}" を "#{area_tag()}:<その県>" に付け替えて返してください
    （場所と説明は、その県の回が書くので書かなくて構いません）。舞台が日本の実在の土地でない
    作品は、理由を書いて墓標にしてください。県が分からないものは返さずに残してください。
    **次の順に進めてください**（上のものほど大事です）。**この回に時間の制限はありません。**

    **1. 名簿から機械で入った作品を確かめる。** tags に "#{Chiezo.unreviewed_tag()}" が付いている
    作品は、百科事典のカテゴリから機械で入れたもので、まだ誰も見ていません。次のものは墓標で
    消してください（body に理由を 1 行）: TV アニメでも劇場アニメでもないもの（実写・漫画や
    ゲームだけ・OVA や配信だけ）、舞台が架空の土地で実在のモデルも無いもの、**この県に舞台と
    言える場所が無いもの**（カテゴリに県の名前が付いているだけで、作中に出てこない）。
    2 つ以上の県に分けて入った作品（見出しの後ろに「（県名）」が付いたもの）は、それぞれの県に
    舞台の土地があれば県ごとに残します。

    **2. 舞台の土地と、ピンを立てる場所を決める。** tags に "#{@unplaced_tag}" が付いた作品です
    （1 回に 10 作品まで。残りは次の回にこの県のまま続きから頼みます）。
    - **舞台の土地**は、作品の舞台になった市区町村です。`extra.municipality` に書いてください。
      同じ県の中に別々の土地が 2 つ以上あれば、2 つ目からは「作品名（市区町村）」の見出しで
      別の 1 件として足してください。**劇場版で舞台が別の土地なら、劇場版を別の 1 件**にします
      （見出しは劇場版の作品名）
    - **ピンを立てる場所**は、作中に何度も出てくる**作品の顔になっている実在の場所**（駅・神社・
      橋・学校のモデル・商店街・海岸など）です。公式・自治体・観光協会が挙げている場所を先にします。
      **決めきれなければ、舞台の最寄駅**にしてください
    - 書くのは `extra.spot` の `name`（地図や看板どおりの名前）・`address`（都道府県から番地まで）・
      `url`（その場所を紹介している頁）と `ref`。**`ref` は書く前に引いてください**: chiezo の MCP で
      地図辞典 osm_japan をその名前で引き（search か titles）、場所の合う見出しを `osm_japan:見出し` の
      形で書きます。無ければ `ref` は書かず、住所を番地まで書いてください
    - その場所を選んだ理由を `extra.spot_reason` に 1 行で（例「オープニングに毎回出てくる駅で、
      市の観光協会が聖地として紹介している」「舞台は駅の周りで、象徴的な場所が決めきれないので最寄駅」）。
      **確かめた頁に書いてある事実だけ**
    - **調べても舞台の土地が分からない作品**は、返さずにこのまま残してください（次の回が続きを調べます）

    **3. 説明を書く。** 場所を決めた作品の body を、**自分の言葉で**書いてください（百科事典や
    考察サイトの文を写さない）。1 文目にその土地と作品の関わり、続けて
    「作中に出てくる場所: ○○駅（主人公が通学に使う駅）、△△神社（夏祭りの回）、□□商店街…」の
    ように、**その土地で作中に出てくる場所を 3〜8 か所**挙げます。**公式が公表した場所か、ファンの
    考察で特定された場所かを書き分けてください**（「考察で特定」と添える）。あらすじは書きません。
    tags に、確かめた頁があるものを全部: #{backings}

    **4. 足りない作品を足す。** この県を舞台にした TV アニメ・劇場アニメで、上に並んでいない作品を
    **1 回に 5 作品まで**探して足してください（確信の持てるものだけ）。自治体や観光協会の聖地の
    紹介・アニメツーリズムの選定・聖地巡礼のまとめを当たってください。**昔の作品は舞台を公表して
    いないことが多い**ので、考察の頁まで辿って確かめます。足すものにも 2 と 3 を同じように書きます。
    **上に並んでいる作品の見出しでは返さないでください**（直すとき以外）。

    **終わった場所**（取り壊し・閉店・立ち入りできなくなった）がピンの場所なら、作品は消さずに
    ピンの場所を選び直してください。

    #{item_format()}

    **直した作品・消す作品・足す作品だけを返してください。** 直すところが無かった作品は
    返さなくて構いません（そのまま残ります）。**一覧の全部を `not_reviewed` に入れて返さないで
    ください。** 見られなかった作品は申告しないでください（`not_reviewed` に入れない）。

    **何を調べたかを、答えの `checked` に 1 行ずつ書いてください**（items と並べて
    `"checked": ["…", "…"]`）。例: "○○: 市の観光協会の聖地マップで舞台を確認、ピンは△△駅"。
    地図には載りません。
    """
  end

  defp item_format do
    """
    1 件の形は次のとおりです。
    - title: **作品名**（百科事典の記事名どおり。足すときも正式な作品名）。同じ作品の 2 つ目の土地は
      「作品名（市区町村）」。上に並んでいるものはその表記のまま返します
    - body: 上の 3 の説明
    - url: いちばん確かな出典 1 つ（作品の公式サイト、自治体・観光協会の聖地の紹介、百科事典の記事）。
      **実際に開いて確かめたものだけ**
    - tags: **いま付いているタグは、直すもの以外そのまま残してください**（返した内容で丸ごと
      置き換わるので、書かなかったタグは消えます）
      - "#{kind_tag()}" —— この一覧の目印。**必ず付けてください**
      - "#{area_tag()}:<県>" —— 受け持ちの県。**変えないでください**（「#{@unknown_region}」の回だけ付け替えます）
      - "#{genre_tag()}:#{@tv}" か "#{genre_tag()}:#{@film}" —— 1 つだけ
      - "裏付け:<…>" —— 上の 3 の語から
      - "出典:OSM" / "出典:#{@address_source_label}" / "出典:#{@ai_source_label}" / "#{@unplaced_tag}" は機械が付けます
    - extra: `spot`・`spot_reason`・`municipality`（上の 2）
    """
  end

  @doc """
  travel-log からの依頼の前置き。**現地で見た人の報告**なので、ほかの仕事より先に答えさせる。
  """
  def request_preface do
    """
    この補足は、**地図を使っている人が現地で見て書いた報告**です。
    **この県では、ほかの仕事より先に、この報告に答えてください。**
    答えたら、そのあと上の依頼文のいつもの仕事も続けてください。

    - 名前は地図に出している作品名です。見出しの後ろの「（県名）」が落ちていることがあります
    - 「場所が違う」「もう無い」と書かれたものは、作品は消さずにピンの場所を選び直してください
    - 「ある」「追加」と書かれた作品は、上に無ければ足してください（報告の座標の近くを舞台の場所の
      手がかりにする）
    """
    |> String.trim_trailing()
  end

  @doc """
  travel-log からの依頼 1 件を、**どの県の区画で頼むか**（座標のある県。決まらなければ nil）。
  """
  def request_partition(%{lat: lat, lon: lon}) do
    with {:ok, base} <- Chidori.Datasets.base_url(),
         {:ok, prefecture} <- Chiezo.area_at(base, lat, lon),
         true <- prefecture in Gourmet.prefectures() do
      Gourmet.partition_key(prefecture)
    else
      _unknown -> nil
    end
  end

  # ---- travel-log への書き出し -------------------------------------------------------

  @doc "travel-log のカテゴリの並び（絞り込みの並び）。"
  def category_order, do: Enum.map(@backings, &elem(&1, 1))

  @doc """
  1 件をスポットの行にします。**地図に置けないものは作りません**（nil）—— 場所が引き当たって
  いない（座標が無い）・県が語彙に無いもの。
  """
  def spot(doc, dataset) do
    tags = Map.get(doc, "tags") || []
    extra = Map.get(doc, "extra") || %{}
    region = region_of(tags)
    lat = number(extra["lat"])
    lon = number(extra["lon"])
    name = Gourmet.dish_name(doc["title"], region)

    if name == "" or is_nil(lat) or is_nil(lon) or is_nil(region) do
      nil
    else
      %{
        "name" => name,
        "lat" => lat,
        "lng" => lon,
        "region" => region,
        "rank" => rank(extra),
        "series" => series_of(tags),
        "categories" => tags |> categories() |> Enum.join("|"),
        "description" => description(doc, tags, extra),
        "opening_hours" => "",
        "key" => Chidori.Datasets.TravelLog.spot_key(doc["doc_id"], dataset)
      }
    end
  end

  defp region_of(tags) do
    Enum.find_value(tags, fn tag ->
      prefecture = prefecture_of_key(tag)
      if prefecture in Gourmet.prefectures(), do: prefecture
    end)
  end

  # 知名度（百科事典の月の閲覧数）の段。記事の無い作品（AI が足したもの）はランクなし
  @rank_steps [{30_000, "A"}, {10_000, "B"}, {3_000, "C"}, {1_000, "D"}]

  @doc "ランク（百科事典の月の閲覧数から機械で。閲覧数が無ければ空）。"
  def rank(extra) do
    case number(extra["pageviews_month"]) do
      nil -> ""
      views -> Enum.find_value(@rank_steps, "E", fn {at, rank} -> if views >= at, do: rank end)
    end
  end

  @doc "シリーズ（TV アニメか劇場アニメ。両方付いていれば TV アニメ）。"
  def series_of(tags) do
    found = tagged(tags, genre_tag())

    cond do
      @tv in found -> @tv
      @film in found -> @film
      true -> ""
    end
  end

  @doc "カテゴリ（裏付けの語を travel-log の言い方で）。"
  def categories(tags) do
    found = tagged(tags, "裏付け")
    for {tag, label} <- @backings, tag in found, do: label
  end

  @doc "説明文（作中に出てくる場所 → ピンの場所 → 出典 → 座標の出どころ）。"
  def description(doc, tags, extra) do
    spot = if is_map(extra["spot"]), do: extra["spot"], else: %{}

    [
      text(doc["body"]),
      spot_line(spot, extra),
      sources_line(extra),
      coords_line(tags, extra)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp spot_line(spot, extra) do
    case text(spot["name"]) do
      "" ->
        ""

      name ->
        reason = text(extra["spot_reason"])
        "ピン: " <> name <> if(reason == "", do: "", else: "（#{reason}）")
    end
  end

  defp sources_line(extra) do
    case text(extra["url"]) do
      "" -> ""
      url -> "出典: " <> source_ref(url)
    end
  end

  defp source_ref(url) do
    case URI.parse(url) do
      %URI{host: "ja.wikipedia.org", path: "/wiki/" <> article} ->
        "[ja.wikipedia:#{URI.decode(article)}]"

      _other ->
        url
    end
  end

  defp coords_line(tags, extra) do
    from = tagged(tags, "出典")

    cond do
      # 位置参照情報は加工して使うとき出典と整備年を書く約束（利用約款 第 2 条 3）
      @address_source_label in from ->
        "座標: ピンの場所の住所の街区（街区レベル位置参照情報 国土交通省#{Gourmet.isj_year(extra, "spot")}を加工）"

      @ai_source_label in from ->
        "座標: ピンの場所（地図サービスで確かめた位置）"

      "OSM" in from ->
        "座標: ピンの場所（OpenStreetMap）"

      true ->
        ""
    end
  end

  defp tagged(tags, prefix) do
    head = prefix <> ":"

    for tag <- tags,
        is_binary(tag),
        String.starts_with?(tag, head),
        do: String.replace_prefix(tag, head, "")
  end

  defp number(value) when is_number(value), do: value
  defp number(_value), do: nil

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""
end
