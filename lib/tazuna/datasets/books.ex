defmodule Tazuna.Datasets.Books do
  @moduledoc """
  定番の技術書を集めるところ。**「良い本」ではなく「勧められている数」で決めます。**

  1 人が絶賛した本と、10 年のあいだに何十本の記事が挙げてきた本は別物です ——
  後者が「技術者なら読んでいる」に当たるもので、**それは数でしか見分けられません**。
  だから 1 冊ごとに**勧めている出どころ**を並べて持ち、その数で定番かどうかを分けます。

  **AI に「良い本を挙げて」とは頼みません。** それをやると、学習に多く出てくる
  名前が並ぶだけで、**なぜその本なのかを後から確かめられません**（出どころが
  無いので、間違っていても気づけない）。頼むのは「**勧めている記事を探して、
  その URL と一緒に挙げる**」ことです。

  **区画は分野です**（`分野:` のタグ）。分野ごとに回すと、1 回の仕事が
  「この分野の定番は揃っているか」に絞れます —— 全部を一度に見ると、
  毎回同じ有名どころを挙げて終わります（画家の収集と同じ理由）。
  **最初は区画がありません**（まだ 1 冊も無いので）。そのときは全体を 1 回として
  走り、分野のタグが溜まるにつれて区画が立ちます。
  """

  alias Tazuna.Chiezo

  @collection "tazuna_books"

  # 1 冊ごとに必ず付く印。読む側はこれで拾います
  @kind_tag "技術書"

  # 分野のタグの頭。**区画もここで切ります**（`分野:` ごとに 1 区画）
  @field_tag "分野"

  # 定番と候補の印。**数で分けます** —— 出どころが 1 つしか無いものを
  # 定番と呼ぶと、この収集の意味が無くなる
  @classic_tag "定番"
  @candidate_tag "候補"

  # 定番に上げる下限（勧めている出どころの数）。**3 は「たまたま」を外せる数**で、
  # 高すぎると新しい定番が何年も候補のままになる
  @classic_sources 3

  # 分野の語彙。**tazuna が持ちます** —— AI に決めさせると回ごとに表記が割れ、
  # 区画（＝分野）が毎回作り直されます（画家の様式と同じ扱い）
  @fields [
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

  # 探す回。**web を開ける**（勧めている記事を当たるのが仕事なので）
  @hunt_sweep "探す"
  @hunt_minutes 360

  # 整える回。重複を畳み、数を数え直し、定番と候補を付け替える
  @tidy_sweep "整える"
  @tidy_minutes 1440

  # 1 区画（＝分野）に入る冊数の目安。**多すぎると 1 回の答えが切れる**ので、
  # 食事処と同じ考え方で「出口」から決める
  @partition_target 40

  @doc "1 冊ごとに必ず付く印。読む側はこれで拾います。"
  def kind_tag, do: @kind_tag

  @doc "分野のタグの頭（`分野:設計・アーキテクチャ` の形）。"
  def field_tag, do: @field_tag

  @doc "定番の印。"
  def classic_tag, do: @classic_tag

  @doc "候補の印（出どころがまだ足りないもの）。"
  def candidate_tag, do: @candidate_tag

  @doc "定番に上げる下限（勧めている出どころの数）。"
  def classic_sources, do: @classic_sources

  @doc "分野の語彙。"
  def fields_of_study, do: @fields

  @doc """
  溜め先の収集の名前（= Chiezo のソース名）。**後から変えない** ——
  変えると、それまで溜めた先を見失います。
  """
  def collection do
    case System.get_env("TAZUNA_BOOKS_COLLECTION", "") |> String.trim() do
      "" -> @collection
      name -> name
    end
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
        "技術者が繰り返し勧めている本を集めます。" <>
          "良し悪しは AI に決めさせず、勧めている記事の数で定番かどうかを分けます。",
      collection: collection(),
      reader: "読む人",
      unit: "1 冊 1 文書",
      survey_sweep: @tidy_sweep,
      partition_sweeps: [@hunt_sweep, @tidy_sweep]
    }
  end

  @doc """
  1 冊ぶんに入る項目。**何がどこから来るか**が読めないと、間違いを AI のせいに
  してしまいます —— 勧めている数は AI が数えたものではなく、並べた URL の数です。
  """
  def fields do
    [
      %{field: "書名", stored: "title", who: "AI（邦題があれば邦題。原書名は本文へ）"},
      %{
        field: "分野",
        stored: "タグ「#{@field_tag}:<分野>」",
        who: "AI（語彙は tazuna が持つ）"
      },
      %{
        field: "勧めている出どころ",
        stored: "extra.sources（URL を並べたもの）",
        who: "AI（探す回が見つけたぶんを足していく）"
      },
      %{
        field: "勧めている数",
        stored: "extra.recommended",
        who: "並べた URL の数（整える回が数え直す）"
      },
      %{
        field: "定番か候補か",
        stored: "タグ「#{@classic_tag}」/「#{@candidate_tag}」",
        who: "数で決まる（#{@classic_sources} 以上で定番）"
      },
      %{field: "なぜ定番か", stored: "body", who: "AI（勧められている理由をまとめる）"},
      %{field: "著者・出た年・版", stored: "body", who: "AI"}
    ]
  end

  @doc "区画の割り方。**分野ごとに 1 区画**（`#{@field_tag}:` のタグで切る）。"
  def partition do
    %{by: "tag", prefix: "#{@field_tag}:", target: @partition_target}
  end

  @doc """
  巡回 2 本。**探すのと整えるのは別の仕事**です —— 探す回は外を当たるので
  web を開け、整える回は手元のものだけを読んで畳みます。
  """
  def sweeps do
    [
      %{
        name: @hunt_sweep,
        interval_minutes: @hunt_minutes,
        web: true,
        prompt: :hunt
      },
      %{
        name: @tidy_sweep,
        interval_minutes: @tidy_minutes,
        prompt: :tidy
      }
    ]
  end

  @doc """
  探す回の依頼文。**勧めている記事を当たって、URL と一緒に挙げさせます。**

  「良い本を挙げて」と頼まないのは、それだと学習に多く出てくる名前が並ぶだけで、
  **なぜその本なのかを後から確かめられない**ためです。
  """
  def hunt_prompt do
    """
    技術者が繰り返し勧めている本を集めています。**この分野ぶんだけ**見てください。

    **今回見る範囲**
    {partition}

    {current}

    **やってほしいことは 2 つ**です。

    **1. 勧めている記事を探す。** 「◯◯ おすすめ 本」「新人エンジニアに読んでほしい」
    のような記事・社内の推薦リスト・カンファレンスの発表・書評を当たって、
    **そこで挙げられている本**を拾ってください。**本を思い出すのではなく、
    勧めている文章を探すのが仕事**です —— 挙げるときは必ず、
    **どこで勧められていたかの URL** を添えてください。

    **2. 既にあるものに出どころを足す。** 上に並んでいる本が別の記事でも
    勧められていたら、**その URL を足して**ください（`extra.sources` に並べます）。
    **数が増えること自体が、この収集の値打ち**です。

    返す形は 1 冊ごとに次のとおりです。

    - `title` … 書名（訳書があれば邦題。原書名は body に書く）
    - `body` … **なぜ勧められているのか**を 2〜3 行。著者・原著の年・版も 1 行で
    - `url` … 代表的な出どころ 1 本
    - `extra.sources` … 勧めている記事の URL を並べたもの（**最大 20 本**）
    - `extra.recommended` … その本数（`sources` の数と同じにしてください）
    - `tags` … 「#{@kind_tag}」、「#{@field_tag}:<分野>」（下の語彙から 1〜2 個）、
      それに **出どころが #{@classic_sources} 本以上なら「#{@classic_tag}」、
      足りなければ「#{@candidate_tag}」**

    **分野の語彙**（この中から選んでください。新しい語は作らない）
    #{Enum.map_join(@fields, " / ", & &1)}

    **確信の持てないものは挙げないでください。** 出どころの URL を示せない本は、
    この収集には入りません —— **勧められている数で定番を決める**収集なので、
    根拠の無い 1 冊が混ざると、並びの意味がそこで壊れます。
    **心当たりが無ければ、足さなくて構いません。**

    **触ったものと足すものだけ返してください。** 触れなかったものはそのまま残ります。
    """
  end

  @doc """
  整える回の依頼文。**手元のものだけを読んで畳みます**（外は当たりません）。
  """
  def tidy_prompt do
    """
    集めた技術書の一覧を整えます。**この分野ぶんだけ**見てください。

    **今回見る範囲**
    {partition}

    {current}

    **やってほしいことは 4 つ**です。

    **1. 同じ本を 1 つにまとめる。** 原書と訳書、版違い、副題の有無で分かれている
    ものは 1 冊にしてください（残すのは**邦題のあるものを優先**）。
    出どころ（`extra.sources`）は**両方を合わせて**残し、重複した URL は畳みます。
    消すほうには墓標を付けてください（tags に "#{Chiezo.tombstone_tag()}" を入れ、
    body に理由を 1 行）。

    **2. 数を数え直す。** `extra.recommended` は **`extra.sources` に並んでいる
    本数と同じ**にしてください。合っていないものは直します。

    **3. 定番と候補を付け替える。** 出どころが #{@classic_sources} 本以上なら
    「#{@classic_tag}」、足りなければ「#{@candidate_tag}」。**数で決まります** ——
    あなたの評価では決めないでください。

    **4. 技術書でないものを落とす。** 資格の問題集・特定の製品のマニュアル・
    読み物ではない辞典は、この収集の対象ではありません（墓標で消してください）。

    **出どころの URL は消さないでください。** ここが数の根拠で、消すと
    「なぜ定番なのか」を後から誰も確かめられません。

    **触ったものだけ返してください。** 触れなかったものはそのまま残ります。
    """
  end

  @doc "Chiezo へ送る収集の設定ぜんぶ。"
  def attrs(choices \\ %{}) do
    %{
      name: collection(),
      description: "tazuna のデータ収集（定番の技術書）",
      prompt: hunt_prompt(),
      interval_minutes: @hunt_minutes,
      partition: partition(),
      sweeps: with_choices(sweeps(), choices),
      # **網羅。** 古い本が要らなくなることはない（定番はむしろ古い）
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

  defp resolve_prompt(%{prompt: :hunt} = sweep), do: %{sweep | prompt: hunt_prompt()}
  defp resolve_prompt(%{prompt: :tidy} = sweep), do: %{sweep | prompt: tidy_prompt()}
  defp resolve_prompt(sweep), do: sweep

  @doc "巡回ごとの依頼文（画面に出すため）。"
  def prompts, do: [{@hunt_sweep, hunt_prompt()}, {@tidy_sweep, tidy_prompt()}]
end
