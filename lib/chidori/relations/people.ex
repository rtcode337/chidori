defmodule Chidori.Relations.People do
  @moduledoc """
  芸能人の関連図（関連図の画面の「芸能人のつながり」）。**いちばん知りたいのは夫婦**で、
  親子・きょうだいと、同じグループ（コンビ・アイドルグループ・バンド）の仲間がそれに続きます。**画家の図と同じ仕組み**で、
  Chiezo に名簿を持たせて育てます —— 名簿は Wikipedia のカテゴリから機械で取り込み、
  つながりを AI に足させます。

  ## 名簿

  **人だけ**（俳優・歌手・タレント・お笑い芸人。**俳優は海外の人も**）。**グループは名簿に入れません** ——
  入れていた頃は、ざっと見る回がお笑いコンビの文書ばかり回って、人が育たなかった。
  グループは人のタグ（「グループ:<名前>」）から枠を組みます。**知名度で下を切ります**（Wikipedia の月の閲覧数。既定は 1 万。
  `Chidori.Relations.Settings`）—— カテゴリだけで 3 万人に届き、全部を AI に回すと
  一周に何週間もかかる。落ち着いたら下限を下げて広げます。

  お笑いコンビだけを名簿にしていた頃は、図の 9 割がコンビで、知りたい夫婦の線は
  1 本も無かった。

  **海外の俳優は「〜の男優」「〜の女優」で終わる分類をまとめて指します**（`tag_suffix`。
  「アメリカ合衆国の男優」「イングランドの女優」など。分類は男優 53・女優 127）。名作映画の
  図の主演から、その人へ飛べるようにするため。月 1 万以上で約 270 人増える（日本の分類に
  入っていない人だけで数えて。5,000 以上なら約 690 人。実測）

  **夫婦の相手は、名簿の外からも足させます**（芸能人でなくても、日本語版 Wikipedia に
  記事のある有名人なら。種別は「著名人」）。名簿を知名度で切ると相手が抜けることが多く、
  名簿にいない相手への線は出ないため。区画の外でも足してよいことにしてあります。

  ## 札と線

  - 札は**人**だけ。グループは**同じ「グループ:<名前>」を持つ人を囲む枠**（クラスタ）で、
    名前は枠に書く（名簿にいるメンバーが 2 人以上のときだけ）
  - 線は**夫婦**（配偶者・元配偶者。いちばん目立たせる）と**家族**（親子・きょうだい）
  - 記事どうしが相互にリンクしている組は、AI を待たずに薄い線で引く（画家と同じ「関連」）

  ## 並べ方

  縦は年代（人は生年、グループはメンバーの生年の中ほど）。**横の帯は持ちません** ——
  種別は札の色で分かるので、帯に割ると夫婦が左右の端に離れる。行の中は、つながって
  いる相手の真上・真下へ寄せます。区画は「種別 × 年代」で切る（画家の「地域 × 生年」と
  同じ切り方）。

  ## 守ること

  **公表されている関係だけ**を、出典の取れるものだけ書かせます。未成年の家族と、
  記事の無い家族（一般の人）は図に載せません —— 名簿にいない人への線は出ない
  仕組みなので、一般の人を名簿に足させないことで守ります。
  """

  alias Chidori.Chiezo
  alias Chidori.Relations.Graph

  @kind_tag "芸能人"
  # 色と区画に使う種別
  @category_prefix "種別"
  @family_prefix "家族"
  # 今所属しているグループ（枠を組む材料。値は日本語版 Wikipedia の記事名）
  @group_prefix "グループ"

  # 芸能人ではない夫婦の相手の種別（スポーツ選手・政治家・作家など）。**名簿のカテゴリには
  # 無く、AI が夫婦の相手として足したときだけ付く**
  @notable_kind "著名人"

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

  # 海外の俳優も拾う分類の末尾（日本の俳優の分類もこれに当たるが、種別は同じ「俳優」）
  @actor_suffixes ["の男優", "の女優"]

  # 区画の割り方。**種別 × 年代で 25 人ずつ**（画家と同じ大きさ。1 回の答えが
  # 長くなりすぎない）
  @partition %{by: "band", prefix: @category_prefix, value: Graph.years_tag(), target: 25}

  # 一周の日数（既定の間隔のとき）。名簿は約 3,000 で画家の 3 割ほどなので、画家より短い
  @rough_days_at_default 3
  @survey_days_at_default 21

  @doc "収集の名前。"
  def collection, do: "chidori_people"

  @doc "図に載せる文書の印。"
  def kind_tag, do: @kind_tag

  @doc "種別のタグの頭（色と区画）。"
  def category_tag, do: @category_prefix

  @doc "区画の割り方。"
  def partition, do: @partition

  @doc "名簿の元にするカテゴリ（人だけ）。"
  def categories, do: Enum.map(@person_categories, &elem(&1, 0))

  @doc """
  図の読み方（`Chidori.Relations.Graph.from_docs/2`）。**横の帯は持たず、同じグループの
  人を枠で囲む**（`clusters`。人の「グループ:<名前>」から組む）。
  """
  def graph_spec,
    do: %{
      kind_tag: @kind_tag,
      kinds: [],
      default_kind: :person,
      style_prefix: @category_prefix,
      band_prefix: @category_prefix,
      bands: [],
      works?: false,
      # 同じ「グループ:<名前>」を持つ人を、そのグループの枠に入れる
      clusters: %{tag_prefix: @group_prefix},
      edge_rules: [
        # 夫婦は線の種類を分ける（いちばん知りたい線なので、いちばん目立たせる）
        %{
          prefix: @family_prefix,
          kind: :family,
          from: :owner,
          undirected: true,
          kinds_by_label: %{"配偶者" => :spouse, "元配偶者" => :spouse}
        }
      ]
    }

  @doc "収集の巡回（画家と同じ 3 本。名簿 → 材料を埋める → 区画ごとに仕上げる）。"
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
      description: "Chidori の関連図（芸能人のつながり）",
      prompt: prompt(),
      interval_minutes: Chidori.SweepNames.scan_minutes(),
      partition: @partition,
      sweeps: with_choices(sweeps(), choices),
      extract: extract(),
      kind: "stock",
      # 名簿にいない相手を指す関連のタグは、Chiezo が焼く前に落とす
      verify_tags: [%{prefix: Graph.related_tag(), source: "jawiki"}],
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
  名簿の引き方（Chiezo の「抽出の指定」）。**人のカテゴリだけ**から引き、**種別を機械で付ける**
  （色と区画の材料なので、AI に判断させない）。年代は生年のカテゴリから。

  **知名度で下を切ります**（`min_pageviews`。月の閲覧数）。顔写真の手掛かりに、
  記事の画像（`image`）も運びます。
  """
  def extract(min_pageviews \\ Chidori.Relations.Settings.min_pageviews("people")) do
    %{
      source: "jawiki",
      tag: Enum.join(categories(), ","),
      tag_suffix: Enum.join(@actor_suffixes, ","),
      body: "opening",
      url: "https://ja.wikipedia.org/wiki/{title}",
      min_extra: %{pageviews_month: min_pageviews},
      tags:
        [%{const: @kind_tag}] ++
          years_rules() ++
          person_rules() ++
          [
            # 相互リンクだけを線にする（画家と同じ。片側だと有名どうしが軒並み繋がる）
            %{linked: "mutual", format: "#{Graph.related_tag()}:{1}"}
          ],
      extra: ["pageviews_month", "image"]
    }
  end

  # 人の種別。同じ種別のカテゴリは 1 つの規則にまとめる（規則の数に上限がある）。
  # **俳優は「〜の男優」「〜の女優」で終わる分類も**（海外の俳優）
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
    |> Kernel.++([
      %{
        pattern: "^.+(?:" <> Enum.map_join(@actor_suffixes, "|", &Regex.escape/1) <> ")$",
        format: "#{@category_prefix}:俳優"
      }
    ])
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
    - **未成年の家族と、日本語版 Wikipedia に記事の無い家族（一般の人）は書かないでください**。名簿にも足さない
    - 住所・連絡先・私生活の詳細は書かない
    """
  end

  defp years_rule do
    tag = Graph.years_tag()

    """
    **「#{tag}」は必ず西暦の数で書いてください**（区画はこのタグの最初の数で決まります）。
    - "#{tag}:生年-没年"（存命なら "#{tag}:1963-"）
    """
  end

  # 種別の書き方
  defp kinds_rule do
    people = @person_categories |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    """
    種別は #{Enum.map_join(people, " / ", &~s("#{@category_prefix}:#{&1}"))} のどれか
    （いくつもで知られる人は全部。芸能人ではない夫婦の相手は "#{@category_prefix}:#{@notable_kind}"）。
    """
  end

  # つながりの書き方。**夫婦がいちばん大事**なので、先に・確かめてから書かせる
  defp ties_rule do
    """
    **いちばん大事なのは夫婦です。** 一人ずつ、**結婚しているか・結婚していたか**を
    確かめてください。
    - **夫婦は "#{@family_prefix}:<相手の名前>:配偶者"**（離婚・死別した相手は
      "#{@family_prefix}:<相手の名前>:元配偶者"）。**相手が日本語版 Wikipedia に記事のある
      有名人なら、芸能人でなくても（スポーツ選手・政治家・作家・実業家など）書いてください**
    - **夫婦の相手が上に並んでいなければ、その相手も 1 件として足してください。**
      名簿は知名度で切ってあるので、相手が抜けていることがよくあります（足さないと線が
      出ません）。**範囲の外でも構いません**（夫婦の相手だけの例外です）。足す 1 件には
      "#{@kind_tag}"、種別（芸能人でなければ "#{@category_prefix}:#{@notable_kind}"）、年代、
      "#{@family_prefix}:<名簿の人の名前>:配偶者"（元なら 元配偶者）を付けてください
    - **親子・きょうだいは "#{@family_prefix}:<相手の名前>:<親子|きょうだい>"**（相手も芸能人で、
      日本語版 Wikipedia に記事がある人だけ）
    - **今所属しているグループ（お笑いコンビ・トリオ、アイドルグループ、バンドなど）は
      "#{@group_prefix}:<グループの名前>"** で付けてください。**グループの名前は日本語版
      Wikipedia の記事名そのまま**（「かまいたち (お笑いコンビ)」のような括弧書きも含めて）——
      同じグループの人どうしで書き方が揃わないと、同じグループだと分かりません。
      抜けたグループは付けません。**グループそのものは 1 件として足さないでください**（人だけの図です）
    - **関係は両側に書いてください**（夫婦なら、夫の文書にも妻の文書にも）。片側にしか
      書かないと、もう片方を見たときに抜けて見えます。**ただし両側に書くのは、上に並んでいる
      人どうしのときだけです。** 上に並んでいない人の文書は返さないでください（新しく足す
      夫婦の相手は除く）—— いま付いているタグが見えないまま返すことになるので取り込まれず、
      線はこちら側に書くだけで引けます（相手側は、相手の範囲の回で書かれます）
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

    **この範囲の人が、下にすべて並んでいます。** 誰を見るか選ぶ必要は
    ありません —— 並んでいるものを順に詳しくしてください。**範囲の外のものは
    返さないでください**（別の回に回ってきます。**夫婦の相手を足すときだけは例外**です）。

    {current}

    **まず「#{Graph.years_tag()}」と「#{@category_prefix}」を埋めてください。** この 2 つで区画が決まります。
    #{years_rule()}
    #{kinds_rule()}
    そのうえで、**つながり**を足してください。

    #{ties_rule()}
    #{ground_rules()}
    **関連のタグはそのまま残してください**（消すと線が消えます）。
    **芸能人でも、名簿の人の夫婦の相手でもない人が混ざっていたら、墓標で消してください**（tags に
    "#{Chiezo.tombstone_tag()}" を入れ、body に消す理由を 1 行）。

    **変えないものを返す必要はありません。** 返すものは次の形にしてください。
    - title: 名前（**上に並んでいる表記をそのまま使う**。足す人は日本語版 Wikipedia の記事名）
    - body: 何をしている人か（1〜2 文）と、夫婦・家族の要点（いつ結婚したか など）
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
    確かめてください。相手が日本語版 Wikipedia に記事のある有名人（芸能人でなくてよい）なのに
    名簿にいなければ、**その相手を足してください**（名簿にいない相手への線は出ません）。
    **思い当たらなければ足さなくて構いません**。

    **2. つながりを磨く。** 夫婦・家族・グループのタグが空のものを埋め、明らかに違うもの
    （離婚したのに配偶者のままなど）だけ直してください。**確かめられなかったものは触らないでください。**

    **3. 要らないものを消す。** 芸能人でも名簿の人の夫婦の相手でもないもの（グループそのものの 1 件も）と、表記の揺れで 2 つに分かれた同じ人
    （残すほうに中身をまとめる）だけを墓標で消してください（tags に "#{Chiezo.tombstone_tag()}"、
    body に理由を 1 行）。

    #{ties_rule()}
    #{ground_rules()}
    **触ったものだけ返してください。** いま付いているタグは、直すもの以外そのまま残してください
    （返した内容で丸ごと置き換わるので、書かなかったタグは消えます）。

    足すもの・直すものの形は次のとおりです。
    - title: 名前（**日本語版 Wikipedia の記事名にそろえる**）
    - body: 何をしている人か（1〜2 文）と、夫婦・家族の要点
    - url: 日本語版 Wikipedia の記事の URL
    - tags:
      - "#{@kind_tag}"
      - "#{@category_prefix}:<種別>"（**区画の材料**）
        #{String.replace(String.trim_trailing(kinds_rule()), "\n", "\n    ")}
      - "#{Graph.years_tag()}:<生年->"（**区画の材料**）
        #{String.replace(String.trim_trailing(years_rule()), "\n", "\n    ")}
      - "#{@family_prefix}:<相手の名前>:<配偶者|元配偶者|親子|きょうだい>"
      - "#{@group_prefix}:<今所属しているグループの、日本語版 Wikipedia の記事名>"
      - "#{Graph.related_tag()}" のタグは**そのまま残してください**
    """
  end
end
