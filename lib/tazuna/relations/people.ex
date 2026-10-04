defmodule Tazuna.Relations.People do
  @moduledoc """
  芸能人の関連図（関連図の画面の「芸能人のつながり」）。**いちばん知りたいのは夫婦**で、
  親子・きょうだいとグループのメンバーがそれに続きます。**画家の図と同じ仕組み**で、
  Chiezo に名簿を持たせて育てます —— 名簿は Wikipedia のカテゴリから機械で取り込み、
  つながりを AI に足させます。

  ## 名簿

  俳優・歌手・タレント・お笑い芸人と、グループ（お笑いコンビ・トリオ、アイドル
  グループ、バンド）。**知名度で下を切ります**（Wikipedia の月の閲覧数。既定は 1 万。
  `Tazuna.Relations.Settings`）—— カテゴリだけで 3 万人に届き、全部を AI に回すと
  一周に何週間もかかる。落ち着いたら下限を下げて広げます。

  お笑いコンビだけを名簿にしていた頃は、図の 9 割がコンビで、知りたい夫婦の線は
  1 本も無かった。

  ## 札と線

  - 札は**人**だけ。グループは札ではなく、**メンバーを囲む枠**（クラスタ）として描き、
    名前は枠の上に出す（メンバーが名簿にいないグループは札のまま）
  - 線は**夫婦**（配偶者・元配偶者。いちばん目立たせる）、**家族**（親子・きょうだい）、
    **元メンバー**。今のメンバーは枠で分かるので線を引かない
  - 記事どうしが相互にリンクしている組は、AI を待たずに薄い線で引く（画家と同じ「関連」）

  ## 並べ方

  縦は年代（人は生年、グループはメンバーの生年の中ほど）。**横の帯は持ちません** ——
  種別は札の色で分かるので、帯に割ると夫婦が左右の端に離れる。行の中は、つながって
  いる相手の真上・真下へ寄せます。区画は「種別 × 年代」で切る（画家の「地域 × 生年」と
  同じ切り方）。

  ## 守ること

  **公表されている関係だけ**を、出典の取れるものだけ書かせます。未成年の家族と、
  芸能人でない家族（一般の人）は図に載せません —— 名簿にいない人への線は出ない
  仕組みなので、一般の人を名簿に足させないことで守ります。
  """

  alias Tazuna.Chiezo
  alias Tazuna.Relations.Graph

  @kind_tag "芸能人"
  # 札の種類（グループかどうか）。カテゴリから機械で付ける
  @group_tag "区分:グループ"
  # 色と区画に使う種別
  @category_prefix "種別"
  @family_prefix "家族"
  @member_prefix "メンバー"
  @former_prefix "元メンバー"

  # 名簿の元にするカテゴリ（日本語版 Wikipedia）と、付ける種別。**人**
  @person_categories [
    {"日本の男優", "俳優"},
    {"21世紀日本の男優", "俳優"},
    {"20世紀日本の女優", "俳優"},
    {"21世紀日本の女優", "俳優"},
    {"日本の男性歌手", "歌手"},
    {"日本の女性歌手", "歌手"},
    {"日本のタレント", "タレント"},
    {"日本の女性タレント", "タレント"},
    {"お笑い芸人", "お笑い芸人"}
  ]

  # **グループ**（枠になる）。`{カテゴリの正規表現, 種別}`
  @group_categories [
    {"^日本の(?:女性|男女|夫婦)?お笑いコンビ$", "お笑いコンビ", ~w(日本のお笑いコンビ 日本の女性お笑いコンビ 日本の男女お笑いコンビ 日本の夫婦お笑いコンビ)},
    {"^日本の(?:女性)?お笑いトリオ$", "お笑いトリオ", ~w(日本のお笑いトリオ 日本の女性お笑いトリオ)},
    {"^日本の(?:女性|男性|ポップ・)アイドルグループ$", "アイドルグループ", ~w(日本の女性アイドルグループ 日本の男性アイドルグループ 日本のポップ・アイドルグループ)},
    {"^日本のロック・バンド$", "バンド", ~w(日本のロック・バンド)}
  ]

  # 区画の割り方。**種別 × 年代で 25 人ずつ**（画家と同じ大きさ。1 回の答えが
  # 長くなりすぎない）
  @partition %{by: "band", prefix: @category_prefix, value: Graph.years_tag(), target: 25}

  # 一周の日数（既定の間隔のとき）。名簿は約 3,000 で画家の 3 割ほどなので、画家より短い
  @rough_days_at_default 3
  @survey_days_at_default 21

  @doc "収集の名前（`TAZUNA_PEOPLE_COLLECTION` で変えられる）。"
  def collection do
    case System.get_env("TAZUNA_PEOPLE_COLLECTION", "") |> String.trim() do
      "" -> "tazuna_people"
      name -> name
    end
  end

  @doc "図に載せる文書の印。"
  def kind_tag, do: @kind_tag

  @doc "種別のタグの頭（色と区画）。"
  def category_tag, do: @category_prefix

  @doc "区画の割り方。"
  def partition, do: @partition

  @doc "名簿の元にするカテゴリ（人とグループ）。"
  def categories,
    do:
      Enum.map(@person_categories, &elem(&1, 0)) ++
        Enum.flat_map(@group_categories, &elem(&1, 2))

  @doc """
  図の読み方（`Tazuna.Relations.Graph.from_docs/2`）。**横の帯は持たず、グループは
  メンバーを囲む枠にする**（`clusters`）。
  """
  def graph_spec,
    do: %{
      kind_tag: @kind_tag,
      kinds: [{@group_tag, :group}],
      default_kind: :person,
      style_prefix: @category_prefix,
      band_prefix: @category_prefix,
      bands: [],
      works?: false,
      # グループ（`:group`）の今のメンバーを、そのグループの枠に入れる
      clusters: %{kind: :group, member_prefix: @member_prefix},
      edge_rules: [
        # 夫婦は線の種類を分ける（いちばん知りたい線なので、いちばん目立たせる）
        %{
          prefix: @family_prefix,
          kind: :family,
          from: :owner,
          undirected: true,
          kinds_by_label: %{"配偶者" => :spouse, "元配偶者" => :spouse}
        },
        %{prefix: @member_prefix, kind: :duo, from: :owner, label: "メンバー"},
        %{prefix: @former_prefix, kind: :duo, from: :owner, label: "元メンバー"}
      ]
    }

  @doc "収集の巡回（画家と同じ 3 本。名簿 → 材料を埋める → 区画ごとに仕上げる）。"
  def sweeps do
    [
      %{
        name: Tazuna.SweepNames.machine(),
        interval_minutes: 10_080,
        use_extract: true,
        only_new: true,
        once: true
      },
      %{
        name: Tazuna.SweepNames.scan(),
        interval_minutes: Tazuna.SweepNames.scan_minutes(),
        cover_days: Tazuna.CollectPace.days(:scan, @rough_days_at_default),
        after: Tazuna.SweepNames.machine(),
        one_lap: true
      },
      %{
        name: Tazuna.SweepNames.tidy(),
        interval_minutes: Tazuna.SweepNames.tidy_minutes(),
        cover_days: Tazuna.CollectPace.days(:tidy, @survey_days_at_default),
        prompt: survey_prompt(),
        after: Tazuna.SweepNames.scan()
      }
    ]
  end

  @doc "Chiezo に送る設定（関連図の画面の「収集の設定を更新」と同じもの）。"
  def attrs(choices \\ %{}) do
    %{
      name: collection(),
      description: "tazuna の関連図（芸能人のつながり）",
      prompt: prompt(),
      interval_minutes: Tazuna.SweepNames.scan_minutes(),
      partition: @partition,
      sweeps: with_choices(sweeps(), choices),
      extract: extract(),
      kind: "stock",
      # 名簿にいない相手を指す関連のタグは、Chiezo が焼く前に落とす
      verify_tags: [%{prefix: Graph.related_tag(), source: "jawiki"}],
      requested_by: "tazuna"
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
  名簿の引き方（Chiezo の「抽出の指定」）。**カテゴリから種別とグループの印を機械で付ける**
  （色と区画の材料なので、AI に判断させない）。年代は生年のカテゴリから
  （グループの結成年はカテゴリに無いので、ざっと見る回に埋めさせる）。

  **知名度で下を切ります**（`min_pageviews`。月の閲覧数）。顔写真の手掛かりに、
  記事の画像（`image`）も運びます。
  """
  def extract(min_pageviews \\ Tazuna.Relations.Settings.min_pageviews("people")) do
    %{
      source: "jawiki",
      tag: Enum.join(categories(), ","),
      body: "opening",
      url: "https://ja.wikipedia.org/wiki/{title}",
      min_extra: %{pageviews_month: min_pageviews},
      tags:
        [%{const: @kind_tag}] ++
          years_rules() ++
          person_rules() ++
          group_rules() ++
          [
            # 相互リンクだけを線にする（画家と同じ。片側だと有名どうしが軒並み繋がる）
            %{linked: "mutual", format: "#{Graph.related_tag()}:{1}"}
          ],
      extra: ["pageviews_month", "image"]
    }
  end

  # 人の種別。同じ種別のカテゴリは 1 つの規則にまとめる（規則の数に上限がある）
  defp person_rules do
    @person_categories
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.sort()
    |> Enum.map(fn {kind, names} ->
      %{
        pattern: "^(?:" <> Enum.map_join(names, "|", &Regex.escape/1) <> ")$",
        format: "#{@category_prefix}:#{kind}"
      }
    end)
  end

  defp group_rules do
    Enum.flat_map(@group_categories, fn {pattern, kind, _names} ->
      [
        %{pattern: pattern, format: "#{@category_prefix}:#{kind}"},
        %{pattern: pattern, format: @group_tag}
      ]
    end)
  end

  # 年代の規則。**生年と没年のカテゴリだけ**（画家の世紀のカテゴリは芸能人には無い）
  defp years_rules do
    tag = Graph.years_tag()

    [
      %{patterns: ["^(\\d{4})年生$", "^(\\d{4})年没$"], format: "#{tag}:{1}-{2}"},
      %{pattern: "^(\\d{4})年生$", format: "#{tag}:{1}-", fallback: true}
    ]
  end

  # 依頼文に共通の、守ること
  defp ground_rules do
    """
    **守ること**
    - **公表されている関係だけ**を書いてください。報道で確かめられないもの・推測・噂は書かない
    - **未成年の家族と、芸能人でない家族（一般の人）は書かないでください**。名簿にも足さない
    - 住所・連絡先・私生活の詳細は書かない
    """
  end

  defp years_rule do
    tag = Graph.years_tag()

    """
    **「#{tag}」は必ず西暦の数で書いてください**（区画はこのタグの最初の数で決まります）。
    - 人は "#{tag}:生年-没年"（存命なら "#{tag}:1963-"）
    - グループは結成年で "#{tag}:結成年-解散年"（活動中なら "#{tag}:1991-"）
    """
  end

  # 種別の書き方
  defp kinds_rule do
    people = @person_categories |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    groups = Enum.map(@group_categories, &elem(&1, 1))

    """
    種別は、人なら #{Enum.map_join(people, " / ", &~s("#{@category_prefix}:#{&1}"))} のどれか
    （いくつもで知られる人は全部）、グループなら #{Enum.map_join(groups, " / ", &~s("#{@category_prefix}:#{&1}"))} のどれかと "#{@group_tag}"。
    """
  end

  # つながりの書き方。**夫婦がいちばん大事**なので、先に・確かめてから書かせる
  defp ties_rule do
    """
    **いちばん大事なのは夫婦です。** 一人ずつ、**結婚しているか・結婚していたか**を
    確かめてください。
    - **夫婦は "#{@family_prefix}:<相手の名前>:配偶者"**（離婚・死別した相手は
      "#{@family_prefix}:<相手の名前>:元配偶者"）。**相手が芸能人で日本語版 Wikipedia に
      記事がある人なら、相手が名簿にいなくても書いてください**（相手も名簿に足します）
    - **親子・きょうだいは "#{@family_prefix}:<相手の名前>:<親子|きょうだい>"**（相手も芸能人で、
      日本語版 Wikipedia に記事がある人だけ）
    - **グループには、今のメンバーを "#{@member_prefix}:<メンバーの名前>"** で付けてください
      （元メンバーは "#{@former_prefix}:<名前>"）。名前は日本語版 Wikipedia の記事名で
    - **関係は両側に書いてください**（夫婦なら、夫の文書にも妻の文書にも）。片側にしか
      書かないと、もう片方を見たときに抜けて見えます
    """
  end

  @doc """
  ざっと見る回の依頼文（収集の既定の文）。**区画の材料（年代・種別）を先に埋め**、
  そのうえで夫婦を中心につながりを足させる。
  """
  def prompt do
    """
    芸能人の関連図を育ててください。**いちばん知りたいのは、誰と誰が夫婦か**です。

    **今回見る範囲**
    {partition}

    **この範囲の人とグループが、下にすべて並んでいます。** 誰を見るか選ぶ必要は
    ありません —— 並んでいるものを順に詳しくしてください。**範囲の外のものは
    返さないでください**（別の回に回ってきます）。

    {current}

    **まず「#{Graph.years_tag()}」と「#{@category_prefix}」を埋めてください。** この 2 つで区画が決まります。
    #{years_rule()}
    #{kinds_rule()}
    そのうえで、**つながり**を足してください。

    #{ties_rule()}
    #{ground_rules()}
    **関連のタグはそのまま残してください**（消すと線が消えます）。
    **芸能人でない人が混ざっていたら、墓標で消してください**（tags に
    "#{Chiezo.tombstone_tag()}" を入れ、body に消す理由を 1 行）。

    **変えないものを返す必要はありません。** 返すものは次の形にしてください。
    - title: 名前（**上に並んでいる表記をそのまま使う**。足す人は日本語版 Wikipedia の記事名）
    - body: 何をしている人・グループか（1〜2 文）と、夫婦・家族の要点（いつ結婚したか など）
    - url: 日本語版 Wikipedia の記事の URL
    - tags: **いま付いているタグをすべて残したうえで**、上のタグを足す
    """
  end

  @doc """
  区画ごとに仕上げる回の依頼文。**夫婦の漏れを足し、つながりを磨き、要らないものを消す**。
  """
  def survey_prompt do
    """
    芸能人の関連図を、**この区画ぶんだけ仕上げてください**。**いちばん知りたいのは、
    誰と誰が夫婦か**です。

    **今回見る範囲**
    {partition}

    {current}

    **上に並んでいるのが、この範囲の全員です。** 範囲は「種別」と「年代」で区切ってあります。
    範囲に合わない人（タグが間違っている人）は、**消さずに年代と種別のタグを直して**返してください。

    やってほしいことは 3 つです。

    **1. 夫婦の漏れを埋める。** 上の一人ずつについて、**結婚している・していた相手**を
    確かめてください。相手が芸能人で日本語版 Wikipedia に記事があるのに名簿にいなければ、
    **その相手を足してください**（名簿にいない相手への線は出ません）。グループのメンバーで
    名簿にいない人も足して構いません。**思い当たらなければ足さなくて構いません**。

    **2. つながりを磨く。** 夫婦・家族・メンバーのタグが空のものを埋め、明らかに違うもの
    （離婚したのに配偶者のままなど）だけ直してください。**確かめられなかったものは触らないでください。**

    **3. 要らないものを消す。** 芸能人でない人と、表記の揺れで 2 つに分かれた同じ人・同じグループ
    （残すほうに中身をまとめる）だけを墓標で消してください（tags に "#{Chiezo.tombstone_tag()}"、
    body に理由を 1 行）。

    #{ties_rule()}
    #{ground_rules()}
    **触ったものだけ返してください。** いま付いているタグは、直すもの以外そのまま残してください
    （返した内容で丸ごと置き換わるので、書かなかったタグは消えます）。

    足すもの・直すものの形は次のとおりです。
    - title: 名前（**日本語版 Wikipedia の記事名にそろえる**）
    - body: 何をしている人・グループか（1〜2 文）と、夫婦・家族の要点
    - url: 日本語版 Wikipedia の記事の URL
    - tags:
      - "#{@kind_tag}"
      - "#{@category_prefix}:<種別>"（**区画の材料**）。グループなら "#{@group_tag}" も
        #{String.replace(String.trim_trailing(kinds_rule()), "\n", "\n    ")}
      - "#{Graph.years_tag()}:<生年- か 結成年->"（**区画の材料**）
        #{String.replace(String.trim_trailing(years_rule()), "\n", "\n    ")}
      - "#{@family_prefix}:<相手の名前>:<配偶者|元配偶者|親子|きょうだい>"
      - グループは "#{@member_prefix}:<メンバーの名前>" / "#{@former_prefix}:<名前>"
      - "#{Graph.related_tag()}" のタグは**そのまま残してください**
    """
  end
end
