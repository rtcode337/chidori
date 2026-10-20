defmodule Chidori.Datasets.Recipes do
  @moduledoc """
  レシピ集 —— 世界と日本の各地の料理の**正統とされる作り方**を、1 品ずつ集めて読む
  収集です。世の中のレシピはアレンジしたものが多く、元の形が分からないので、
  **何がその料理を決めているか**（カルボナーラなら卵黄・グアンチャーレ・ペコリーノ・
  黒胡椒で、生クリームは使わない）と、よくあるアレンジとの違いを書かせます。
  詳しい説明は `docs/datasets.md「レシピ集」`。

  ## 名簿は百科事典の分類から機械で

  **料理名は AI に考えさせません**（存在しない料理が混ざり、回ごとに別の名前で
  同じ料理が増える）。百科事典（`jawiki`）の「〜料理」で終わる分類（パスタ料理・
  卵料理・日本の郷土料理など）に入っている記事を、**月の閲覧数で絞って**名簿にします
  （`extract/1`。下限は画面で変えられる。`min_pageviews/0`）。本番の Chiezo で数えると、
  分類は 268・記事は 3,284 で、月 1,000 以上が 661 品（うち写真のあるもの 608）、
  2,000 以上が 321 品、500 以上が 1,040 品だった（2026-10）。

  分類には料理でない記事も入っている —— 店（ラーメン店）・商品（氷菓の商品名）・
  食材（畜産物・食用キノコ・食品添加物）・行事（年中行事）。**分かるものは分類で外し**
  （`@excluded_categories`）、残りは AI が墓標で消します。

  ## AI が書くこと

  **辞典に書いていないことだけ**です —— 正統とされる形、材料と手順、アレンジとの違い、
  その根拠。web で当たらせ、**発祥地の団体・料理学校・公的機関・定評のある文献**を
  根拠にさせます（個人のレシピブログは根拠にしない）。**定説の無い料理はそう書かせます**
  （作り話の「正統」を書かせない）。**文章は出典の写しではなく AI 自身の言葉**で書かせます。
  本文の形は `body_sections/1` が読むので、見出しの書き方を決めて渡します。

  ## 写真は百科事典の記事の写真

  名簿を引くときに記事の写真（Commons）の URL を運び（`extra.image`）、**Chiezo に
  1 回だけ取って縮めて持たせます**（収集の `thumbs`）。画面から外のサイトの絵を直に
  指さない（見る人のブラウザが開くたびに外へつなぐ）。写真を押すと Commons のファイルの
  頁（撮影者とライセンス）へ行けるようにします。**レシピサイトの写真は使いません**（著作物）。

  ## 区画は料理名の順

  国や地域で割らないのは、名簿の時点では国が分からない料理が多いため（「ローマの食文化」
  のような地域の分類しか無い）。料理名の順に約 20 品ずつ切ります（Chiezo の `by: "title"`）。
  """

  alias Chidori.Chiezo
  alias Chidori.SweepNames

  @collection "chidori_recipes"

  # 図に載せる文書の印（名簿の全件に機械で付ける）
  @kind_tag "レシピ"
  # 地域（百科事典の「<地域>の食文化」から機械で。「ローマ」「北海道」「イタリア」が混ざる）
  @region_tag "地域"
  # 国（AI が書く。地域の分類は都市や州のことがあるので、絞り込みには国を使う）
  @country_tag "国"
  # 料理の種類（AI が書く。語彙は `@kinds`）
  @dish_tag "種類"
  # 主な食材（AI が書く。3 つまで）
  @ingredient_tag "食材"
  # 正統とされる形に定説があるか（AI が書く。「あり」「なし」）
  @canon_tag "定説"

  # 料理の種類の語彙。**この中から選ばせる** —— 自由に書かせると、同じ種類が回ごとに
  # 違う言葉で増え、絞り込みが割れる
  @kinds ~w(主菜 副菜 麺・パスタ ご飯もの 汁物・スープ 鍋 パン・粉もの 菓子・デザート ソース・調味料 漬物・保存食 飲み物 その他)

  # 名簿から外す分類（どれか 1 つでも付いている記事は入れない）。**料理でないもの**を落とす。
  # 本番の名簿の候補で、混ざっていた記事の分類から選んだ（2026-10）:
  # 店（ラーメン店・外食産業・ファストフード店）、商品（氷菓の商品名・インスタントラーメン）、
  # 食材（畜産物・食用キノコ・食品添加物）、行事（年中行事）、国の料理の総論（地域別の料理）
  @excluded_categories ~w(
    地域別の料理 ラーメン店 外食産業 日本の外食事業者
    日本のファストフード店 アメリカ合衆国のファストフード店
    氷菓の商品名 インスタントラーメン インスタントラーメンの商品名
    畜産物 食用キノコ 食品添加物 年中行事 日本の年中行事
  )

  # 区画の割り方。**料理名の順に約 20 品ずつ**（1 回の依頼で 1 品ずつ確かめて書き切れる量）
  @partition %{by: "title", target: 20}

  # 名簿の知名度の下限の選べる値と既定（月の閲覧数）
  # （既定の月 1,000 は `Chidori.Relations.Settings` の図ごとの既定に置く）
  @pageview_choices [3_000, 2_000, 1_000, 500, 300]

  # 一周の日数（既定の間隔のとき）。661 品・区画 33 個を、書く回は 2 週間、
  # 見直す回は 2 か月で一周する
  @write_days_at_default 14
  @review_days_at_default 60

  @doc "収集の名前。"
  def collection, do: @collection

  @doc "図に載せる文書の印。"
  def kind_tag, do: @kind_tag

  @doc "国のタグの頭。"
  def country_tag, do: @country_tag

  @doc "地域のタグの頭。"
  def region_tag, do: @region_tag

  @doc """
  種類のタグの値を語彙に寄せます。**語彙の「・」で区切った片方だけを書いたもの**（「パン」「菓子」）は
  その語彙へ —— 依頼文で語彙を「・」でつないで並べていた頃、AI は「麺・パスタ」を「麺」と「パスタ」の
  2 つと読み、片方だけを書いていた（本番で 18 品中 7 品）。語彙に寄らないものはそのまま、無ければ nil。
  """
  def to_kind(nil), do: nil

  def to_kind(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value in @kinds -> value
      kind = Enum.find(@kinds, &(value in String.split(&1, "・"))) -> kind
      true -> value
    end
  end

  @doc "種類のタグの頭。"
  def dish_tag, do: @dish_tag

  @doc "種類の語彙（並べる順）。"
  def kinds, do: @kinds

  @doc "名簿の知名度の下限で選べる値。"
  def pageview_choices, do: @pageview_choices

  @doc "名簿の知名度の下限（月の閲覧数。画面で変えたものがあればそれ）。"
  def min_pageviews, do: Chidori.Relations.Settings.min_pageviews("recipes")

  @doc "データ収集の画面に出す定義。"
  def definition do
    %{
      key: "recipes",
      name: "レシピ",
      module: __MODULE__,
      eyebrow: "THE DISH AS IT IS MADE WHERE IT CAME FROM",
      title: "レシピ集",
      description:
        "世界と日本の各地の料理を、正統とされる作り方で 1 品ずつ集めます。" <>
          "何がその料理を決めているか、材料と手順、よくあるアレンジとの違いを、根拠と一緒に読めます。",
      collection: @collection,
      reader: "読む人",
      unit: "1 料理 1 文書",
      note:
        "料理名は AI に考えさせず、百科事典の「〜料理」の分類から知名度で絞って引きます。" <>
          "写真は百科事典の記事の写真（Commons）を Chiezo が縮めて持ちます。レシピサイトの写真は使いません。",
      extract_note:
        "名簿は百科事典の「〜料理」で終わる分類（パスタ料理・卵料理・日本の郷土料理など）に入っている記事を、" <>
          "月の閲覧数の下限で絞ったものです。店・商品・食材・行事の分類に入っている記事は外し、" <>
          "地域は「<地域>の食文化」の分類から付けます。AI は関わりません。",
      partition_note: "区画は料理名の順に約 20 品ずつです（名簿の時点では国が分からない料理が多いため）。",
      prompt_note:
        "AI が書くのは辞典に書いていないことだけです —— 正統とされる形、材料と手順、" <>
          "よくあるアレンジとの違い、その根拠（発祥地の団体・料理学校・公的機関・定評のある文献）。",
      # **溜まったレシピを読む**（設定より先に出す）
      reading: __MODULE__,
      survey_sweep: SweepNames.tidy(),
      partition_sweeps: [SweepNames.scan(), SweepNames.tidy()]
    }
  end

  @doc "1 品ぶんに入る項目。"
  def fields do
    [
      %{field: "料理名", stored: "title", who: "百科事典（機械）"},
      %{field: "写真", stored: "extra.image → extra.thumb", who: "百科事典の写真を Chiezo が縮める"},
      %{field: "地域", stored: "タグ「#{@region_tag}:<地域>」", who: "百科事典の「<地域>の食文化」（機械）"},
      %{field: "国", stored: "タグ「#{@country_tag}:<国>」", who: "AI"},
      %{field: "種類", stored: "タグ「#{@dish_tag}:<種類>」", who: "AI（決めた語彙から選ぶ）"},
      %{field: "主な食材", stored: "タグ「#{@ingredient_tag}:<食材>」", who: "AI（3 つまで）"},
      %{field: "定説があるか", stored: "タグ「#{@canon_tag}:あり/なし」", who: "AI"},
      %{
        field: "正統とされる形・材料・作り方・アレンジとの違い・出典",
        stored: "body（見出しで区切る）",
        who: "AI（web で当たり、自分の言葉で書く）"
      }
    ]
  end

  @doc "巡回（名簿 → 書く → 見直す）。"
  def sweeps do
    [
      %{
        name: SweepNames.machine(),
        interval_minutes: 10_080,
        use_extract: true,
        # **足すだけ**。AI が書いたレシピを、記事の冒頭しか持たない名簿で上書きしない
        only_new: true,
        once: true
      },
      %{
        name: SweepNames.scan(),
        prompt: :write,
        interval_minutes: SweepNames.scan_minutes(),
        cover_days: Chidori.CollectPace.days(:scan, @write_days_at_default),
        after: SweepNames.machine(),
        one_lap: true
      },
      %{
        name: SweepNames.tidy(),
        prompt: :review,
        interval_minutes: SweepNames.tidy_minutes(),
        cover_days: Chidori.CollectPace.days(:tidy, @review_days_at_default),
        after: SweepNames.scan()
      }
    ]
  end

  @doc "巡回ごとの依頼文（まだ Chiezo に無いときの雛形の表示）。"
  def prompts, do: [{SweepNames.scan(), write_prompt()}, {SweepNames.tidy(), review_prompt()}]

  @doc "Chiezo へ送る依頼の中身（作るときも、送り直すときも同じもの）。"
  def attrs(choices \\ %{}) do
    %{
      name: @collection,
      # 収集の依頼文は見直すほう（割り込みはこの文で走る）
      prompt: review_prompt(),
      interval_minutes: SweepNames.scan_minutes(),
      sweeps: with_choices(sweeps(), choices),
      # **網羅**。古くなって要らなくなるものではない
      kind: "stock",
      # 百科事典の写真を 1 回だけ取って縮めて持つ（画面から外の絵を直に指さない）
      thumbs: true,
      requested_by: "chidori"
    }
    |> Map.merge(shape())
  end

  @doc "説明・名簿の指定・区画。"
  def shape do
    %{
      description: "Chidori のデータ収集（レシピ集）",
      extract: extract(),
      partition: @partition
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

  defp resolve_prompt(%{prompt: :write} = sweep), do: %{sweep | prompt: write_prompt()}
  defp resolve_prompt(%{prompt: :review} = sweep), do: %{sweep | prompt: review_prompt()}
  defp resolve_prompt(sweep), do: sweep

  @doc """
  名簿の引き方（Chiezo の「抽出の指定」）。「〜料理」で終わる分類の記事を知名度で切り、
  料理でない記事の分類を外し、地域を食文化の分類から付ける。
  """
  def extract(min_pageviews \\ min_pageviews()) do
    %{
      source: "jawiki",
      tag_suffix: "料理",
      not_tag: Enum.join(@excluded_categories, ","),
      min_extra: %{pageviews_month: min_pageviews},
      # 記事の冒頭は AI が料理を確かめる材料（画面には出さない）
      body: "opening",
      url: "https://ja.wikipedia.org/wiki/{title}",
      tags: [
        %{const: @kind_tag},
        %{pattern: "^(.+?)の食文化$", format: "#{@region_tag}:{1}"}
      ],
      extra: ["pageviews_month", "image"]
    }
  end

  # 本文の見出し（`body_sections/1` が読む。依頼文もここから組む）
  @sections [
    {:about, "どんな料理か"},
    {:canon, "正統とされる形"},
    {:ingredients, "材料"},
    {:steps, "作り方"},
    {:variants, "よくあるアレンジとの違い"},
    {:sources, "出典"}
  ]

  defp body_rule do
    """
    body は次の見出しで区切って書いてください（見出しはこの通りに。行頭に置き、後ろに「:」）。
    - どんな料理か: 1〜2 文（発祥の国・地域と、どんな場面で食べるか）
    - 正統とされる形: **何がその料理を決めているか**を 2〜4 文（欠かせない材料・欠かせない手順・
      使わないもの。例: カルボナーラなら卵黄・グアンチャーレ・ペコリーノ・ロマーノ・黒胡椒で、
      生クリームは使わない）。定説が無い料理は「定説はない」と書き、広く伝統的とされる形を書く
    - 材料（N人分）: 1 行に 1 つ、「- 名前 分量」で（分量は g・ml・大さじ・個など。
      手に入りにくい材料は代わりになるものを括弧で添える）
    - 作り方: 1 行に 1 手順、「1. 」「2. 」の番号で（火加減・時間・見極めどころを書く）
    - よくあるアレンジとの違い: 2〜4 文（日本や家庭で広まった形と、どこが違うか）
    - 出典: 1 行に 1 つ、「- URL（何のページか）」で 1〜3 本
    """
  end

  defp source_rule do
    """
    **根拠にするのは、発祥地の団体・料理学校・公的機関（農林水産省「うちの郷土料理」など）・
    定評のある料理書や百科事典**です。個人のレシピブログや動画は根拠にしないでください
    （アレンジが多く、正統な形が分からないから集めています）。**確かめられないことは書かないでください**。
    **文章は出典の写しではなく、あなたの言葉で**書いてください（材料と手順は事実として書き直す）。
    """
  end

  defp tag_rule do
    """
    tags は**いま付いているタグをすべて残したうえで**、次を足してください。
    - "#{@country_tag}:<国>" —— 発祥の国（「イタリア」「日本」「中国」。日本の郷土料理も「日本」）
    - "#{@dish_tag}:<種類>" —— 次のどれか 1 つを、そのままの字で: #{Enum.map_join(@kinds, "、", &"「#{&1}」")}
    - "#{@ingredient_tag}:<食材>" —— 主な食材を 3 つまで（「卵」「豚肉」「米」）
    - "#{@canon_tag}:あり" か "#{@canon_tag}:なし" —— 正統とされる形に定説（団体の定義・
      広く認められた古典的な作り方）があるか
    "#{@region_tag}:" のタグは百科事典の分類から機械で付けたものです。そのまま残してください。
    """
  end

  defp tombstone_rule do
    """
    **料理でないもの**（食材そのもの・店・商品・行事・料理の総称や国の料理の総論）が
    混ざっていたら、墓標で消してください（tags に "#{Chiezo.tombstone_tag()}"、body に理由を 1 行）。
    同じ料理が表記違いで 2 つあるときは、残すほうに中身をまとめ、もう片方を墓標にしてください。
    """
  end

  @doc """
  書く回の依頼文（ざっと見る。一周して止まる）。**区画の料理を 1 品ずつ、正統とされる
  作り方で書かせます**。
  """
  def write_prompt do
    """
    レシピ集を作っています。世の中のレシピはアレンジしたものが多く、元の形が分からないので、
    **各地の料理の、正統とされる作り方**を 1 品ずつ書いてください。

    **今回見る範囲**
    {partition}

    **この範囲の料理が、下にすべて並んでいます。** 並んでいるものを順に書いてください
    （範囲の外のものは返さない。料理を新しく足さない）。

    {current}

    #{body_rule()}
    #{source_rule()}
    #{tag_rule()}
    #{tombstone_rule()}
    返す形は次のとおりです。
    - title: 料理名（**上に並んでいる表記をそのまま**）
    - body: 上の見出しで
    - url: 日本語版 Wikipedia の記事の URL（上に並んでいるもの）
    - tags: 上のとおり
    """
  end

  @doc """
  見直す回の依頼文（整理。ゆっくり回り続ける）。**書いたレシピを確かめ直し、
  まだ書いていない料理を書きます**。
  """
  def review_prompt do
    """
    レシピ集の、この範囲の料理を見直してください。

    **今回見る範囲**
    {partition}

    {current}

    やってほしいことは 3 つです。

    **1. まだ書いていない料理を書く。** 本文が百科事典の冒頭のままのもの（見出しの区切りが無いもの）は、
    下の形で書いてください。

    **2. 書いたものを確かめる。** 正統とされる形・材料・手順に誤りやアレンジが混ざっていないか、
    出典が根拠になっているか（個人のレシピブログになっていないか）を確かめ、直すものだけ直してください。
    **確かめられなかったものは触らないでください。**

    **3. 要らないものを消す。**
    #{tombstone_rule()}
    #{body_rule()}
    #{source_rule()}
    #{tag_rule()}
    **触ったものだけ返してください。** 返すときは title は今のまま、tags は全部（変えないものも）返してください
    （返した tags がそのまま付け替わります）。
    """
  end

  # 1 回に読む件数（Chiezo の filter の上限）
  @page 500

  @doc """
  溜まったレシピ（書いたものだけ。名簿に入っただけで AI がまだ目を通していないものは
  Chiezo の読み口が外す）。`{:ok, [recipe]}` か `{:error, 理由}`。
  """
  def list(base), do: list(base, 0, [])

  defp list(base, offset, acc) do
    case Chiezo.spot_docs(base, @collection, @kind_tag, offset, @page, body: true) do
      {:ok, %{docs: docs, total: total}} ->
        got = acc ++ Enum.map(docs, &to_recipe/1)

        if docs == [] or length(got) >= total,
          do:
            {:ok, got |> Enum.filter(& &1.written?) |> Enum.sort_by(& &1.title) |> with_photos()},
          else: list(base, length(got), got)

      # **まだ依頼していない**（Chiezo に収集が無い）なら、空として出す（読めなかったのではない）
      {:error, {:chiezo_status, 404}} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 写真の縮小版の横幅。**作り置きのありそうな幅を選ぶ** —— Wikimedia は作り置きの無い
  # 縮小版を作らせる頼みを回線ごとに数えて絞る（続けて頼むと 2 枚目から 429）。必ず作られて
  # いる幅は無い（作られているかは頼むまで分からない）が、330px は記事の代表の写真を
  # プレビューや検索で出すときの幅で、作り置きの見込みがいちばん高い（試しに 330px を 12 枚
  # 続けて頼むと全部取れ、250px は 3 枚目から断られた）
  @photo_width 330

  @doc """
  収集の中で写真が作れなかった料理に、**Chidori が 1 枚ずつ頼んだ写し**を付けます
  （`Chidori.Relations.Faces`。顔写真と同じ置き場と取り方）。まだ写しの無い写真はその場で
  取りに行く列に並べ、次に読んだときから出る。Commons の写真だけ。
  """
  def with_photos(recipes) do
    waiting = for r <- recipes, r.thumb == nil, is_binary(r[:image]), do: r.image

    photos =
      if waiting == [], do: %{}, else: Chidori.Relations.Faces.faces(waiting, @photo_width)

    Enum.map(recipes, fn r ->
      case r.thumb == nil && photos[r[:image]] do
        path when is_binary(path) -> %{r | thumb: path}
        _none -> r
      end
    end)
  end

  @doc false
  def to_recipe(doc) do
    tags = Enum.map(doc["tags"] || [], &to_string/1)
    extra = if is_map(doc["extra"]), do: doc["extra"], else: %{}
    sections = body_sections(doc["body"] || doc["opening"] || "")

    %{
      title: doc["title"],
      country: tag_value(tags, @country_tag),
      regions: tag_values(tags, @region_tag),
      kind: tags |> tag_value(@dish_tag) |> to_kind(),
      ingredients_tags: tag_values(tags, @ingredient_tag),
      canon: tag_value(tags, @canon_tag),
      thumb: Chiezo.thumb_path(extra["thumb"]),
      image: extra["image"],
      image_page: Chidori.Relations.Faces.file_page(extra["image"]),
      url: Chidori.SafeUrl.href(extra["url"]),
      sections: sections,
      # **書いたものだけ見せる**（見出しの区切りが無いのは、まだ百科事典の冒頭のまま）
      written?: Map.has_key?(sections, :canon) or Map.has_key?(sections, :steps)
    }
  end

  @doc """
  本文を見出しで区切ります（`%{about: 文, canon: 文, ingredients: [行], servings: 「2人分」,
  steps: [行], variants: 文, sources: [%{url, label}]}`）。見出しの無い本文は空の地図。
  **見出しは緩く読みます**（「**材料（2人分）**:」「## 作り方：」も読む）—— AI は
  頼んだ書き方から少しずれて返すことがあり、ずれた 1 品だけ本文が読めなくなるのは困る。
  """
  def body_sections(body) when is_binary(body) do
    {sections, current, lines, servings} =
      body
      |> String.split("\n")
      |> Enum.reduce({%{}, nil, [], nil}, fn line, {acc, current, lines, servings} ->
        case heading_of(line) do
          {key, note, rest} ->
            servings = if key == :ingredients and note != "", do: note, else: servings

            {put_section(acc, current, lines), key, if(rest == "", do: [], else: [rest]),
             servings}

          nil ->
            {acc, current, if(current, do: lines ++ [line], else: lines), servings}
        end
      end)

    sections
    |> put_section(current, lines)
    |> Map.new(fn {key, raw} -> {key, shape_section(key, raw)} end)
    |> then(&if(servings, do: Map.put(&1, :servings, servings), else: &1))
  end

  def body_sections(_body), do: %{}

  # 見出しの行なら `{鍵, 見出しに添えた言葉（「2人分」）, 見出しの後ろに続く本文}`
  defp heading_of(line) do
    trimmed = line |> String.trim() |> String.trim_leading("#") |> String.trim()

    Enum.find_value(@sections, fn {key, label} ->
      pattern = ~r/\A\*{0,2}#{Regex.escape(label)}([^:：*]{0,12})\*{0,2}[:：]\*{0,2}\s*(.*)\z/u

      case Regex.run(pattern, trimmed) do
        [_all, note, rest] ->
          {key,
           note
           |> String.trim()
           |> String.trim_leading("（")
           |> String.trim_leading("(")
           |> String.trim_trailing("）")
           |> String.trim_trailing(")"), String.trim(rest)}

        nil ->
          nil
      end
    end)
  end

  defp put_section(acc, nil, _lines), do: acc

  defp put_section(acc, key, lines) do
    case lines |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> acc
      kept -> Map.put(acc, key, kept)
    end
  end

  defp shape_section(:ingredients, lines), do: Enum.map(lines, &strip_marker/1)
  defp shape_section(:steps, lines), do: Enum.map(lines, &strip_number/1)

  defp shape_section(:sources, lines) do
    Enum.flat_map(lines, fn line ->
      text = strip_marker(line)

      case Regex.run(~r{(https?://[^\s（）()]+)\s*[（(]?([^）)]*)[）)]?}u, text) do
        [_all, url, label] ->
          case Chidori.SafeUrl.href(url) do
            nil -> []
            href -> [%{url: href, label: String.trim(label)}]
          end

        nil ->
          [%{url: nil, label: text}]
      end
    end)
  end

  defp shape_section(_key, lines), do: Enum.join(lines, "\n")

  defp strip_marker(line), do: line |> String.trim() |> String.replace(~r/\A[-・*]\s*/u, "")
  defp strip_number(line), do: line |> String.trim() |> String.replace(~r/\A\d+[.．、)）]\s*/u, "")

  defp tag_values(tags, head) do
    for tag <- tags,
        String.starts_with?(tag, head <> ":"),
        value = tag |> String.replace_prefix(head <> ":", "") |> String.trim(),
        value != "",
        do: value
  end

  defp tag_value(tags, head), do: tags |> tag_values(head) |> List.first()

  @doc """
  **名簿の知名度の下限を変えて、名簿を引き直します**（関連図の「名簿を引き直す」と同じ形）。
  Chiezo には抽出の指定だけを送り、名簿の回（機械収集。AI を使わない）を 1 回走らせます。
  **足すだけ**なので、下限を上げても名簿からは消えません。
  """
  def reroster(min_pageviews) when min_pageviews in @pageview_choices do
    with {:ok, _setting} <-
           Chidori.Relations.Settings.put_min_pageviews("recipes", min_pageviews),
         base when is_binary(base) <- Chiezo.base_url(),
         :ok <- Chiezo.patch(base, @collection, %{extract: extract(min_pageviews)}) do
      Chiezo.by_hand(fn -> Chiezo.run(base, @collection, sweep: SweepNames.machine()) end)
    else
      nil -> {:error, :chiezo_not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  def reroster(_min_pageviews), do: {:error, :bad_choice}
end
