defmodule Tazuna.Relations.People do
  @moduledoc """
  芸能人の関連図（関連図の画面の「芸能人のつながり」）。**画家の図と同じ仕組み**で、
  Chiezo に名簿を持たせて育てます —— 名簿は Wikipedia のカテゴリから機械で取り込み、
  家族とコンビ・グループのつながりを AI に足させます。

  ## 札と線

  - 札は 2 種類。**人**（お笑い芸人・俳優）と、**グループ**（お笑いコンビ・トリオ）
  - 線は 2 種類。**家族**（親子・配偶者・きょうだい。向きを持たない）と、
    **メンバー**（グループからそのメンバーへ。元メンバーも）
  - 記事どうしが相互にリンクしている組は、AI を待たずに薄い線で引く（画家と同じ「関連」）

  ## 並べ方

  縦は年代（人は生年、グループは結成年）、横は種別の帯（お笑い・俳優）。区画も
  「種別 × 年代」で切る（画家の「地域 × 生年」と同じ切り方）。

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
  # 横の帯と区画に使う種別（お笑いコンビ・お笑いトリオ・お笑い芸人・俳優）
  @category_prefix "種別"
  @family_prefix "家族"
  @member_prefix "メンバー"
  @former_prefix "元メンバー"

  # 名簿の元にするカテゴリ（日本語版 Wikipedia）
  @categories ~w(日本のお笑いコンビ 日本の女性お笑いコンビ 日本の男女お笑いコンビ 日本の夫婦お笑いコンビ
                 日本のお笑いトリオ 日本の女性お笑いトリオ 21世紀日本の男優 21世紀日本の女優)

  # 区画の割り方。**種別 × 年代で 25 人ずつ**（画家と同じ大きさ。1 回の答えが
  # 長くなりすぎない）
  @partition %{by: "band", prefix: @category_prefix, value: Graph.years_tag(), target: 25}

  # 一周の日数（既定の間隔のとき）。名簿は約 2,700 で画家の 3 割ほどなので、画家より短い
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

  @doc "種別のタグの頭（横の帯と区画）。"
  def category_tag, do: @category_prefix

  @doc "区画の割り方。"
  def partition, do: @partition

  @doc "図の読み方（`Tazuna.Relations.Graph.from_docs/2`）。"
  def graph_spec,
    do: %{
      kind_tag: @kind_tag,
      kinds: [{@group_tag, :group}],
      default_kind: :person,
      style_prefix: @category_prefix,
      band_prefix: @category_prefix,
      bands: [{"お笑い", ["お笑いコンビ", "お笑いトリオ", "お笑い芸人"]}, {"俳優", ["俳優"]}],
      works?: false,
      edge_rules: [
        %{prefix: @family_prefix, kind: :family, from: :owner, undirected: true},
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
  （横の帯と区画の材料なので、AI に判断させない）。年代は生年のカテゴリから
  （グループの結成年はカテゴリに無いので、ざっと見る回に埋めさせる）。
  """
  def extract do
    %{
      source: "jawiki",
      tag: Enum.join(@categories, ","),
      body: "opening",
      url: "https://ja.wikipedia.org/wiki/{title}",
      tags:
        [%{const: @kind_tag}] ++
          years_rules() ++
          [
            %{pattern: "^日本の(?:女性|男女|夫婦)?お笑いコンビ$", format: "#{@category_prefix}:お笑いコンビ"},
            %{pattern: "^日本の(?:女性|男女|夫婦)?お笑いコンビ$", format: @group_tag},
            %{pattern: "^日本の(?:女性)?お笑いトリオ$", format: "#{@category_prefix}:お笑いトリオ"},
            %{pattern: "^日本の(?:女性)?お笑いトリオ$", format: @group_tag},
            %{pattern: "^21世紀日本の(?:男優|女優)$", format: "#{@category_prefix}:俳優"},
            # 相互リンクだけを線にする（画家と同じ。片側だと有名どうしが軒並み繋がる）
            %{linked: "mutual", format: "#{Graph.related_tag()}:{1}"}
          ],
      extra: ["pageviews_month"]
    }
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

  @doc """
  ざっと見る回の依頼文（収集の既定の文）。**区画の材料（年代・種別）を先に埋め**、
  そのうえで家族とメンバーのつながりを足させる。
  """
  def prompt do
    """
    芸能人の関連図を育ててください。

    **今回見る範囲**
    {partition}

    **この範囲の人とグループが、下にすべて並んでいます。** 誰を見るか選ぶ必要は
    ありません —— 並んでいるものを順に詳しくしてください。**範囲の外のものは
    返さないでください**（別の回に回ってきます）。

    {current}

    **まず「#{Graph.years_tag()}」と「#{@category_prefix}」を埋めてください。** この 2 つで区画が決まります。
    #{years_rule()}
    種別は "#{@category_prefix}:お笑いコンビ" / "#{@category_prefix}:お笑いトリオ" / "#{@category_prefix}:お笑い芸人" / "#{@category_prefix}:俳優" のどれか
    （お笑いと俳優の両方で知られる人は両方）。

    そのうえで、**つながり**を足してください。

    - **グループには、メンバーを "#{@member_prefix}:<メンバーの名前>"** で付けてください
      （元メンバーは "#{@former_prefix}:<名前>"）。名前は日本語版 Wikipedia の記事名で
    - **家族は "#{@family_prefix}:<相手の名前>:<親子|配偶者|元配偶者|きょうだい>"** で付けてください。
      相手も芸能人で、日本語版 Wikipedia に記事がある人だけ
    - **線が出るのは、相手が名簿にいるときだけ**です。「#{Graph.related_tag()}」のタグに
      挙がっている相手は名簿にいます

    #{ground_rules()}
    **関連のタグはそのまま残してください**（消すと線が消えます）。
    **芸能人でない人が混ざっていたら、墓標で消してください**（tags に
    "#{Chiezo.tombstone_tag()}" を入れ、body に消す理由を 1 行）。

    **変えないものを返す必要はありません。** 返すものは次の形にしてください。
    - title: 名前（**上に並んでいる表記をそのまま使う**。足す人は日本語版 Wikipedia の記事名）
    - body: 何をしている人・グループか（1〜2 文）と、つながりの要点
    - url: 日本語版 Wikipedia の記事の URL
    - tags: **いま付いているタグをすべて残したうえで**、上のタグを足す
    """
  end

  @doc """
  区画ごとに仕上げる回の依頼文。**漏れを足し、つながりを磨き、要らないものを消す**。
  漏れで多いのは、グループのメンバー（カテゴリが付いていない芸人）。
  """
  def survey_prompt do
    """
    芸能人の関連図を、**この区画ぶんだけ仕上げてください**。

    **今回見る範囲**
    {partition}

    {current}

    **上に並んでいるのが、この範囲の全員です。** 範囲は「種別」と「年代」で区切ってあります。
    範囲に合わない人（タグが間違っている人）は、**消さずに年代と種別のタグを直して**返してください。

    やってほしいことは 3 つです。

    **1. 漏れを足す。** 上のグループのメンバーで名簿にいない人（日本語版 Wikipedia に記事が
    あるのに、カテゴリが付いていない芸人）を足してください。家族のうち、芸能人で
    日本語版 Wikipedia に記事がある人も足して構いません。**思い当たらなければ足さなくて
    構いません**（既にいる人を挙げ直しても名簿は変わりません）。

    **2. つながりを磨く。** メンバーと家族のタグが空のものを埋め、明らかに違うものだけ直してください。
    **確かめられなかったものは触らないでください。**

    **3. 要らないものを消す。** 芸能人でない人と、表記の揺れで 2 つに分かれた同じ人・同じグループ
    （残すほうに中身をまとめる）だけを墓標で消してください（tags に "#{Chiezo.tombstone_tag()}"、
    body に理由を 1 行）。

    #{ground_rules()}
    **触ったものだけ返してください。** いま付いているタグは、直すもの以外そのまま残してください
    （返した内容で丸ごと置き換わるので、書かなかったタグは消えます）。

    足すもの・直すものの形は次のとおりです。
    - title: 名前（**日本語版 Wikipedia の記事名にそろえる**）
    - body: 何をしている人・グループか（1〜2 文）と、つながりの要点
    - url: 日本語版 Wikipedia の記事の URL
    - tags:
      - "#{@kind_tag}"
      - グループなら "#{@group_tag}"
      - "#{@category_prefix}:<お笑いコンビ / お笑いトリオ / お笑い芸人 / 俳優>"（**区画の材料**）
      - "#{Graph.years_tag()}:<生年- か 結成年->"（**区画の材料**）
        #{String.replace(String.trim_trailing(years_rule()), "\n", "\n    ")}
      - グループは "#{@member_prefix}:<メンバーの名前>" / "#{@former_prefix}:<名前>"
      - "#{@family_prefix}:<相手の名前>:<親子|配偶者|元配偶者|きょうだい>"（相手も芸能人で、記事のある人だけ）
      - "#{Graph.related_tag()}" のタグは**そのまま残してください**
    """
  end
end
