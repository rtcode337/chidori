defmodule Chidori.Relations.Graph do
  @moduledoc """
  Chiezo に溜まった文書を、ネットワーク図の形に読み直します。

  **Chiezo には図の構造を持ち込みません。** 向こうにあるのは「1 画家 = 1 文書」の
  普通のソースで、属性と関係はタグに載せてあります。ノードとエッジという読み方を
  与えるのは Chidori 側の仕事です。判断や見せ方を Chiezo に持たせない、という
  線を崩さないための形です。

  タグの書き方は 3 つ。値に `:` を含められるよう、先頭の 1〜2 個で区切ります。

      様式:ポスト印象派
      年代:1880-1890
      代表作:ひまわり (絵画)         … その画家の絵を出すときの手掛かり
      影響元:クロード・モネ          … その画家から影響を受けた
      影響元:クロード・モネ:光と色彩  … 説明を添える（線の上に出る）

  **「影響元」（受けた側から見る）にしてあります。** 1 つの文書はその画家自身を
  説明するものなので、「誰から受けたか」は自分の属性として書けます。
  「誰に与えたか」にすると、他人の文書を書き換えないと関係を足せません。
  """

  # 図を描く面。**縦に流す年表は残したまま、横を使い切る。**
  #
  # 以前は幅 980 に 3 列だけを置いていたので、横が余っているのに人数ぶん縦へ伸びた
  # （4,250 人で高さ 314,500 = 画面の 350 枚ぶん）。列を人数から決めれば、
  # 同じ人数でも縦は 1/300 で収まる。**上から下へ時代が流れる**のは変わらない ——
  # 1 行が 1 つの時代の区切りになり、行の中は左から右へ並ぶ。
  @canvas_width 1200

  # 左に空ける幅。年表の目盛りとその札が入る
  @gutter 90

  # 面の縦横比（高さ = 幅 × これ）。器を縦長にしてあるので、それに近い比で組むと
  # 全体表示で縦にも横にも余白が出ない
  @canvas_aspect 0.95

  @canvas_height 560

  # 図の上下に空ける余白。**重なる UI のぶん** —— 探す欄と道具は図の上に、
  # 操作の案内は下に重ねてある（`.relation-find` / `.relation-tools` /
  # `.relation-hint`）。余白が無いと、いちばん上と下の行がその下に隠れ、
  # **引きずっても拡大しても出てこない**（重なっているものは図と一緒に動かない）。
  # **帯の名前が貼り付く高さ（`LABEL_TOP`）より大きく取る** —— あれも図の上に
  # 重なるので、同じだけ空けないと行がその裏に入る。
  #
  # **見た目の大きさは器の幅に比例する。** 「全体」は倍率 1 に戻すだけで、図の
  # 1 単位は「器の幅 ÷ 1200」px になる —— 狭い窓ほど余白も縮むので、広い窓で
  # ちょうどよい値だと足りなくなる（700px 幅なら 100 でようやく 58px）
  @canvas_margin 100

  # 1 人ぶんの升目の下限と上限。**下限**はこれ以上詰めると丸が団子になる境目で、
  # **上限**は人数が少ない図が間延びしないための蓋
  @min_cell 12
  @max_cell 110

  # 折り返すまでに要る行数。**縦に流す年表を守るための下限** —— これを割ると
  # 全員が同じ高さに並び、上から下へ時代が流れる、という読み方が成り立たない
  @min_rows 6

  # 横の並びを繋がりへ寄せ直す回数。1 回では、相手がまだ動く前の位置を見て決める
  # ことになる。増やすほど整うが、4 回を超えると見た目がほとんど変わらなかった
  @barycenter_passes 4

  @kind_tag "画家"
  @style_prefix "様式"
  @years_prefix "年代"
  @work_prefix "代表作"
  @influence_prefix "影響元"
  # 記事どうしが相互にリンクしている、というだけの線。**Chiezo が機械的に付ける**ので、
  # AI を待たずに図がつながる。何の関係かまでは分からないので、影響の線とは分けて描く
  @related_prefix "関連"
  # 図の横軸に使う地域。Wikipedia のカテゴリ（「19世紀フランスの画家」）から
  # 機械的に取れるので、AI に判断させない
  @region_prefix "地域"

  # 横軸に使う大きなまとまり。**細かい国名のままでは軸にならない** —— 40 を超える
  # 地域が横に並んでも、どこを見ればいいか分からない。順は西から東へ。
  # **どこにも当てはまらないものは「その他」に入れる**（落とすと図から消える）
  @region_bands [
    {"ヨーロッパ", ~w(フランス ドイツ イタリア イングランド オランダ スペイン ロシア フランドル
        ベルギー オーストリア スコットランド スイス ポーランド スウェーデン デンマーク
        ハンガリー チェコ ノルウェー アイルランド ポルトガル フィンランド イギリス
        ウクライナ ギリシャ ルーマニア セルビア ウェールズ スロベニア クロアチア
        カタルーニャ ソビエト連邦 リトアニア ラトビア エストニア ブルガリア
        スロバキア アイスランド マルタ ルクセンブルク)},
    {"南北アメリカ", ~w(アメリカ合衆国 カナダ メキシコ ブラジル アルゼンチン チリ ペルー キューバ
        ウルグアイ コロンビア ベネズエラ ハイチ エクアドル)},
    {"アジア・その他", ~w(日本 中国 朝鮮 韓国 インド ベトナム フィリピン タイ インドネシア
        オーストラリア ニュージーランド トルコ イラン イスラエル エジプト
        南アフリカ共和国 モロッコ アルメニア ジョージア)}
  ]

  # 丸に出す代表作の数。**1 つに絞らない** —— 多作の画家を 1 枚で代表させると、
  # どれを選んでも「その人らしさ」を外す。ただし並べすぎると読むほうが疲れるので 3 つまで。
  # 絵は 1 枚ずつ Wikipedia に取りに行くので、数がそのまま待ち時間になる
  @max_works 3

  # 押したときに出す説明の長さ。**記事の冒頭をそのまま持つと重い** ——
  # 8,000 人ぶんが画面の裏に載るので、1 人ぶんの読み出しに足りる長さで切る
  @summary_chars 240
  # 絞り込みで置き直す人数の上限。これより多ければ元の位置のまま絞る
  @refocus_max 400
  # 線を押したときに出す、本文から拾う文の数
  @max_mentions 3

  # 名前の後ろに付ける、代表作を持っている印。**札の幅にも数える** ——
  # 幅に入れないと、印のぶんだけ名前が札からはみ出す（札にした意味が消える）
  @work_mark "◆"

  # 丸の大きさ。**知名度で変える** —— どれが中心的な画家かが、読む前に分かる。
  # 知名度そのものは jawiki の月次ページビュー（収集の `extra.pageviews_month`）。
  #
  # **事実と判断を別の鍵に分ける。** ページビューは機械が写す事実で、誰も書き換えない。
  # 日本語版の読まれ方が実態とずれている画家（海外で高名だが日本で知られていない、
  # 逆に最近テレビで扱われた）は、AI が倍率を書いて直す。同じ鍵を書き換えさせると
  # 元の値が失われ、取り込み直しても新しいページビューを反映できなくなる
  @views_key "pageviews_month"
  @fame_scale_key "fame_scale"
  # 倍率の効かせ方の上下。**桁で狂わせない** —— 1 人の書き間違いで図が壊れる
  @min_fame_scale 0.1
  @max_fame_scale 10.0
  #
  # **差は大きく取る。** 全体を眺めるときに読めてほしいのは有名な画家だけで、
  # 残りは「そこに誰かがいる」が分かれば足りる（読みたくなったら拡大する）。
  # 差を詰めると、どれも同じくらいの点が並んで、どこから読めばいいか分からなくなる。
  #
  # **升目に対する比で持つ。** 固定の px にすると、人数が増えて升目が縮んだときに
  # 丸だけが元の大きさで残り、隣と重なって団子になる
  @min_radius_ratio 0.16
  @max_radius_ratio 2.4

  # 知名度を大きさへ写すときの曲がり具合（比を何乗するか）。
  #
  # **1 より小さいほど差が縮み、大きいほど広がる。** 平方根（0.5）で始めたのは
  # ページビューが桁で開くからだが、それだと縮みすぎた —— 全体表示で 1,361 人が
  # 「読める大きさ」に届き、点の海の中から目印を選べなかった。0.65 まで戻すと
  # 272 人になり、有名な画家が浮き上がる。
  #
  # 1.0（そのまま）まで上げると 116 人まで減るが、こんどは図がまばらに見える
  @fame_curve 0.65

  # 大きさの基準にする順位。**いちばん上の 1 人を基準にしない** —— 亡くなった直後の
  # 画家は閲覧が一時に跳ね上がり（実測で 2 位の 8 倍）、ほかの全員が 4 分の 1 に
  # 縮んで、全体表示にその 1 人しか残らなかった。**上位 5 人はみな最大**になる。
  # 5 人目は跳ね上がる前の 1 位とほぼ同じ値なので、上の曲がり具合の調整は崩れない
  @fame_reference_rank 5

  # 名前の字。**丸と同じ升目から決める** —— 丸だけ大きくして字を揃えると、
  # 小さい丸から名前がはみ出し、拡大しても文字が重なったままになる。
  #
  # 下限は**わざと読めない大きさ**にしてある。全体表示で全部読めるようにすると、
  # 数千人ぶんの名前が重なって、有名な画家まで読めなくなる。
  #
  # 上限は**札の幅で決まる**。名前を丸ごと入れる作りなので、字を大きくすると札が
  # 横に伸びて隣を覆う —— 1.3 では「フィンセント・ファン・ゴッホ」の札が幅 331
  # （升目 19 個ぶん）になり、周りの画家が読めなくなった
  # 差は**下限を下げて**取る。上限を上げると札が横に伸びて隣を覆うので、
  # 広げられるのは下だけ
  @min_name_ratio 0.22
  @max_name_ratio 0.85

  # 名前の字の**絶対の上限**（px）。升目に対する比だけでは足りない ——
  # 人数が少ない図（様式で絞ったときなど）は升目が上限いっぱいまで広がり、
  # 字が 93px、札が幅 400px になって隣と重なり、重なりを避ける仕組みが
  # ほとんどの丸を間引いてしまった（39 人のうち 4 人しか出なかった）。
  # **読める大きさに天井を置けば、札が升目に収まる**
  @max_name_px 22.0

  # 絞り込んだ図（凡例を押したとき）で目指す字の大きさ。**列数をここから決める** ——
  # 読ませるための図なので、詰め込むより読めるほうを取る。全体の図は今までどおり
  # 面の縦横比から列を決め、収まらない札は重なりを避ける仕組みが間引く
  @fitted_font 16.0

  # 様式と年代の字。名前より小さく、名前に対する比で決める
  @sub_size_ratio 0.62
  @min_sub_size 4.0

  # 札の高さ（字の大きさの何倍か）と、左右に足す余白（同じく字の大きさに対する比）
  @label_line_height 1.7
  # 様式を入れる 2 行目の高さ（様式の字の大きさの何倍か）。
  # **札の中に入れる** —— 外に置くと、隣の丸の札と重なったときにどちらの様式か
  # 分からなくなる（札の中なら、札ごと重なりを避ける仕組みに乗る）
  @note_line_height 1.35
  @label_padding 0.9

  # 半角文字 1 つを全角何文字ぶんとして数えるか（幅の見積もりに使う）
  @halfwidth_ratio 0.55

  # どの帯にも当てはまらない画家の行き先。**落とさない** —— 地域が取れていない人
  # （時代区分のカテゴリしか持たない人など）は必ずいるので、落とすと図から消える
  @other_band "その他"

  @doc """
  画家の図の読み方（`from_docs/2` の既定）。**図の種類ごとに違うのは、どのタグで札・帯・
  色・線を作るかだけ**で、並べ方（縦は年代、横は帯）と大きさの決め方は同じです。

  - `kind_tag` —— 図に載せる文書の印（読み込みもこのタグで引く）
  - `kinds` / `default_kind` —— 札の種類（`{タグ, 種類}` の並び。当たらなければ既定）
  - `style_prefix` —— 色と凡例に使うタグの頭
  - `band_prefix` / `bands` —— 横の帯に使うタグの頭と、`{帯, 値の並び}`
  - `works?` —— 代表作を持つか
  - `edge_rules` —— 線にするタグ。`from: :named` は名指しされた側から文書の主へ
    （影響元）、`:owner` は文書の主から名指しされた側へ。`undirected` は向きを持たない
    線で、同じ組は 1 本に畳む。`label` は 3 つ目の区切りが無いときの線の字。
    `shared: true` は**同じ値を持つ文書どうし**を結ぶ（値は札ではなく共通項。映画の監督・主演、芸能人のグループ）
  - `clusters` —— 枠にする決まり。`%{tag_prefix: …}` は同じ値を持つ文書を囲む
    （いまはどの図も使っていない。枠は 1 つの高さにしか置けず、縦の年代が崩れたため）
  """
  def painters_spec,
    do: %{
      kind_tag: @kind_tag,
      kinds: [],
      default_kind: :artist,
      style_prefix: @style_prefix,
      band_prefix: @region_prefix,
      bands: @region_bands,
      works?: true,
      edge_rules: [%{prefix: @influence_prefix, kind: :influence, from: :named}]
    }

  @doc "代表作を載せるタグの頭。"
  def work_tag, do: @work_prefix

  @doc "相互リンクの相手を載せるタグの頭。"
  def related_tag, do: @related_prefix

  @doc "影響関係を載せるタグの頭。"
  def influence_tag, do: @influence_prefix

  @doc "地域を載せるタグの頭。"
  def region_tag, do: @region_prefix

  @doc "図の上下に空ける余白。**重なる UI のぶん**。"
  def canvas_margin, do: @canvas_margin

  @doc "年代を載せるタグの頭。縦軸（時代）はこれで決まる。"
  def years_tag, do: @years_prefix

  @doc "様式を載せるタグの頭。色と凡例はこれで決まる。"
  def style_tag, do: @style_prefix

  @doc """
  その図に出てくる様式へ色を振ります（様式 → 色相 0〜359）。

  **名前のハッシュでは近い色になります。** 実測では印象派が 159、フランス象徴派が
  164 で、並べてもほとんど同じ緑でした。**人数の多い順に黄金角（137.5°）ずつ
  ずらす**と、何色あっても隣どうしが離れます。

  **表は持ちません。** 様式は AI が足していくので、いくつ増えるか分からない ——
  表にすると、載っていない様式だけ色が無くなります。
  """
  def style_hues(nodes) do
    nodes
    |> Enum.flat_map(&styles_of/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {style, count} -> {-count, style} end)
    |> Enum.with_index()
    |> Map.new(fn {{style, _count}, index} -> {style, rem(round(index * 137.508), 360)} end)
  end

  @doc "その画家の色（様式を持たなければ nil）。"
  def hue_of(node), do: node[:hue]

  @doc """
  ひとつの様式だけを取り出して、**その人たちだけで置き直した図**を返します。

  **絞るだけでは足りません。** 位置はもとのままなので、39 人が高さ 2,500 の面に
  散らばって、拡大しないと読めない —— 絞ったのに読めないなら絞った意味がありません。
  置き直せば人数に合う升目になり、全部が一度に読める大きさになります。

  縦軸（年代）と横軸（地域）はそのままです。
  """
  def only(relation, style) when is_binary(style) do
    kept = Enum.filter(relation.nodes, &(style in styles_of(&1)))
    refocus(relation, kept)
  end

  def only(relation, _style), do: relation

  @doc """
  直近の巡回で動いたものだけを取り出して、置き直した図を返します。

  絞り方が違うだけで、やっていることは `only/2` と同じです
  （**絞るだけでは読めない**ので置き直す）。
  """
  def only_changed(relation) do
    case Enum.filter(relation.nodes || [], & &1[:changed?]) do
      [] -> relation
      kept -> refocus(relation, kept)
    end
  end

  @doc """
  AI がまだ目を通していない人だけを取り出して、置き直した図を返します
  （`only_changed/1` と同じ考え方）。
  """
  def only_unreviewed(relation) do
    case Enum.filter(relation.nodes || [], & &1[:unreviewed?]) do
      [] -> relation
      kept -> refocus(relation, kept)
    end
  end

  @doc "AI が目を通した人だけを取り出して、置き直した図を返します。"
  def only_reviewed(relation) do
    case Enum.reject(relation.nodes || [], & &1[:unreviewed?]) do
      [] -> relation
      kept -> refocus(relation, kept)
    end
  end

  @doc """
  名前で挙げた札を除いて、置き直した図を返します（映画の図の「見ていない作品だけ」）。

  **共通項の線（`shared`）はつなぎ直します。** 同じ監督・同じ主演の線は公開年の順に
  隣どうしだけを結んでいるので、間の作品を抜いて線を捨てるだけだと鎖がそこで切れる
  （A → 見た B → C から B を抜くと、A と C が同じ監督なのに線が無くなる）。
  残った作品を鎖ごとに並べ直して隣どうしを結び直します。ほかの線は両端が残るものだけ。
  """
  def without(relation, names) do
    drop = MapSet.new(names)
    nodes = relation.nodes || []

    case Enum.reject(nodes, &MapSet.member?(drop, &1.name)) do
      kept when length(kept) == length(nodes) ->
        relation

      [] ->
        relation

      kept ->
        ids = MapSet.new(kept, & &1.id)
        refocus(relation, kept, rebridged(relation.edges || [], relation.nodes, ids))
    end
  end

  # 共通項の線を、残った作品だけでつなぎ直す（`rule_edges` と同じ形の線を作る）
  defp rebridged(edges, nodes, ids) do
    {shared, plain} = Enum.split_with(edges, &Map.has_key?(&1, :value))
    by_id = Map.new(nodes, &{&1.id, &1})

    bridged =
      shared
      |> Enum.flat_map(fn edge ->
        for value <- edge[:values] || [edge.value],
            id <- [edge.from, edge.to],
            do: {{edge.kind, edge.via, value}, id}
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.flat_map(fn {{kind, via, value}, chain} ->
        chain
        |> Enum.uniq()
        |> Enum.filter(&MapSet.member?(ids, &1))
        |> Enum.map(&by_id[&1])
        |> Enum.sort_by(&sort_key/1)
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [from, to] ->
          %{
            from: from.id,
            to: to.id,
            label: display_name(value),
            kind: kind,
            via: via,
            value: value,
            excerpt: []
          }
        end)
      end)
      |> Enum.group_by(&{&1.kind, Enum.sort([&1.from, &1.to])})
      |> Enum.map(fn {_pair, [first | _] = same} ->
        Map.put(first, :values, Enum.map(same, & &1.value))
      end)
      |> Enum.sort_by(&{&1.value, &1.from, &1.to})

    Enum.filter(plain, &(MapSet.member?(ids, &1.from) and MapSet.member?(ids, &1.to))) ++
      bridged
  end

  defp refocus(%{nodes: []} = relation, _kept), do: relation

  defp refocus(relation, []), do: relation

  defp refocus(relation, kept) do
    ids = MapSet.new(kept, & &1.id)

    edges =
      Enum.filter(relation.edges, fn edge ->
        MapSet.member?(ids, edge.from) and MapSet.member?(ids, edge.to)
      end)

    refocus(relation, kept, edges)
  end

  defp refocus(relation, kept, edges) do
    # **人数が多ければ置き直さない。** 置き直しは読める大きさの升目に並べ直すので、
    # 数千人を並べると図の高さが桁違いに伸び（レビュー済み 3,637 人で約 3 万）、
    # 全体表示では札が 1 枚も描けなくなる。そこまで多いなら元の位置のまま絞る
    if length(kept) > @refocus_max do
      keep = MapSet.new(kept, & &1.id)
      %{relation | nodes: Enum.filter(relation.nodes, &MapSet.member?(keep, &1.id)), edges: edges}
    else
      relaid(relation, kept, edges)
    end
  end

  # 読ませる置き方（`fitted_columns` と `refit`）にする絞り込みの上限。これより多く残る絞り方は全体の図と同じ置き方
  @fitted_max 150

  defp relaid(relation, kept, edges) do
    # 升目が変わるので、大きさも付け直す（知名度は `sized` が残しておいたものを使う）
    bare = Enum.map(kept, &Map.drop(&1, [:cell]))

    # **数十人に絞った図だけ、読ませる置き方にする**（いちばん長い名前に合わせた列の数・大きい字）。
    # 数百残る絞り方（見ていない作品だけ・知名度の下限）にそれを当てると、列が数本しか取れず、
    # 縦に何千と伸びて札が読めない大きさになった。多いときは全体の図と同じ置き方（升目と知名度）
    fitted? = length(bare) <= @fitted_max

    laid =
      arrange(
        bare,
        edges,
        if(fitted?, do: fitted_columns(bare)),
        relation[:band_order] || region_bands(),
        relation[:cluster_rule]
      )
      |> oriented(relation[:newest_first] == true)

    fame = Map.new(laid.nodes, &{&1.article, &1[:views] || 0})

    relation
    |> Map.merge(%{
      nodes: if(fitted?, do: refit(laid.nodes, fame), else: sized(laid.nodes)),
      edges: mark_framed(edges, laid[:clusters] || []),
      ticks: laid.ticks,
      bands: laid.bands,
      clusters: paint_clusters(laid[:clusters] || [], laid.nodes),
      height: laid.height
    })
  end

  @doc "横軸に並べる地域のまとまり（西から東へ）。"
  def region_bands, do: Enum.map(@region_bands, &elem(&1, 0)) ++ [@other_band]

  @doc """
  その画家をどの帯に入れるか。**1 つに決めます**。

  複数の地域に跨る画家（移り住んだ人）はいますが、横軸は 1 人 1 か所でないと
  軸として読めません。**先に出てきた帯を採る**ので、並びが優先順位になります。
  """
  def band_of(%{band: band}) when is_binary(band), do: band
  def band_of(node), do: band_in(node[:tags] || [], painters_spec())

  # 図の種類の帯（`spec.bands`）で、タグから帯を決める
  defp band_in(tags, spec) do
    values = tag_values(tags, spec.band_prefix)

    Enum.find_value(spec.bands, @other_band, fn {band, members} ->
      if Enum.any?(values, &(&1 in members)), do: band
    end)
  end

  # 帯の並び（図の種類の帯の順に、最後に「その他」）
  defp band_order(spec), do: Enum.map(spec.bands, &elem(&1, 0)) ++ [@other_band]

  @doc """
  Chiezo の `filter` が返した文書の並びを、図のデータにします。`spec` は図の読み方
  （既定は画家。`painters_spec/0`）。
  """
  def from_docs(docs, spec \\ painters_spec())

  def from_docs(docs, spec) when is_list(docs) do
    nodes =
      docs
      |> Enum.flat_map(&to_node(&1, spec))
      |> Enum.uniq_by(& &1.name)
      |> Enum.sort_by(&sort_key/1)
      |> Enum.with_index()
      |> Enum.map(fn {node, index} -> Map.put(node, :id, "n#{index}") end)

    by_name = Map.new(nodes, &{&1.name, &1})

    # **線を先に組む。** 置き方が線の形を見るようになったので、順序が逆だと
    # 何も繋がっていない前提で並べることになる
    edges = edges(docs, by_name, spec)
    order = band_order(spec)
    clusters = spec[:clusters]
    newest_first = spec[:newest_first] == true
    laid = nodes |> arrange(edges, nil, order, clusters) |> oriented(newest_first)
    hues = style_hues(laid.nodes)
    counts = laid.nodes |> Enum.flat_map(&styles_of/1) |> Enum.frequencies()

    # **色は 1 人 1 つ。** 丸は 1 つしか無いので、複数の様式を持つ人はどれかに決める
    # しかない。どれを選んでも同じくらい正しくないので、**選び方が毎回同じ**である
    # ことのほうを取る（人数の多い様式を採る）。名前の下には全部書いてある
    coloured =
      Enum.map(laid.nodes, fn node ->
        Map.put(node, :hue, node |> styles_of() |> Enum.map(&hues[&1]) |> Enum.min(fn -> nil end))
      end)

    {marked, changed_at} = mark_changed(coloured)

    %{
      nodes: marked,
      # 直近の巡回で動いたぶん。**時刻と件数の両方を出す** —— 件数だけでは
      # いつの話か分からず、時刻だけでは何件動いたのか分からない
      changed_at: changed_at,
      changed: Enum.count(marked, & &1[:changed?]),
      # AI がまだ目を通していない人の数（凡例と絞り込みに使う）
      unreviewed: Enum.count(marked, & &1[:unreviewed?]),
      # **消えた画家。** 図には出さないが、消し間違いを戻す頼みごとは
      # ここからしか出せない（名簿から消えると、押せる丸が無くなる）
      removed: removed_of(docs, spec),
      # 横の帯の並び（絞り込んで置き直すときにも同じ並びを使う）
      band_order: order,
      # グループを枠にする決まり（絞り込んで置き直すときにも同じ決まりを使う）
      cluster_rule: clusters,
      # グループの枠（`arrange/5`）。色はそのグループの札と同じ
      clusters: paint_clusters(laid[:clusters] || [], coloured),
      # **枠に入っているメンバーへの線は描かない**（枠で分かる。印を付けるだけで、
      # 線そのものは残す —— 絞り込んで置き直すときに、枠をこの線から組み直す）
      edges: mark_framed(edges, laid[:clusters] || []),
      ticks: laid.ticks,
      # 上を新しい年にする図か（映画）。絞り込んで置き直すときも同じ向きにする
      newest_first: newest_first,
      bands: laid.bands,
      # 色の凡例に使う（様式・人数・色相）。**図に出ているものだけ**を数える
      styles:
        hues
        |> Enum.map(fn {style, hue} -> {style, Map.get(counts, style, 0), hue} end)
        |> Enum.sort_by(fn {style, count, _hue} -> {-count, style} end),
      width: canvas_width(length(nodes)),
      # **高さは置いてみないと分からない** —— 行の数は年代の混み具合で決まる
      height: laid.height
    }
  end

  def from_docs(_docs, _spec), do: empty()

  def empty,
    do: %{
      nodes: [],
      edges: [],
      removed: [],
      ticks: [],
      bands: [],
      styles: [],
      changed_at: nil,
      changed: 0,
      width: @canvas_width,
      # 空でも余白のぶんは持つ。**中身のある図と同じ面**にしておかないと、
      # 読み込みの前後で図の器の高さが跳ねる
      height: @canvas_height + 2 * @canvas_margin
    }

  defp styles_of(node) do
    case Map.get(node, :styles) do
      list when is_list(list) -> list
      _ -> List.wrap(node.note)
    end
  end

  # **いちばん長い名前が収まる列数。** 絞り込んだ図は読ませるためのものなので、
  # 1 行に何人詰められるかではなく、名前が読めるかで決める
  defp fitted_columns(nodes) do
    widest =
      nodes
      |> Enum.map(&text_width(label_of(&1), @fitted_font))
      |> Enum.max(fn -> 0.0 end)

    ((@canvas_width - @gutter) / max(widest + @fitted_font * @label_padding, 1))
    |> floor()
    |> max(1)
    |> min(length(nodes))
  end

  # 絞り込んだ図の字の大きさ。**読ませるための図なので、下を持ち上げる** ——
  # 全体の図の決め方（升目 × 知名度）をそのまま使うと、無名の画家が 7px になって
  # 読めない。`@fitted_font` を基準にして知名度で上下させ、**名前が長くて升目から
  # はみ出すぶんだけ縮める**（縮めないと隣と重なり、重なりを避ける仕組みが間引く）。
  defp refit(nodes, fame) do
    top = fame |> Map.values() |> reference_top()

    Enum.map(nodes, fn node ->
      ratio = fame_ratio(Map.get(fame, node.article, 0), top)
      want = @fitted_font * (0.75 + 0.75 * ratio)
      budget = (node[:cell_w] || @max_cell) * 0.96
      # その名前を書いたときに札が升目へ収まる字の大きさ
      fits = budget / max(text_width(label_of(node), 1.0) + @label_padding, 1.0)

      # **升目と知名度はそのまま渡す。** ここで 0 を渡すと丸の半径まで潰れ、
      # 「小さすぎる丸は描かない」仕組みが全部を間引いてしまう（絞り込むと
      # 図が真っ白になった）。差し替えるのは字の大きさだけ
      node
      |> Map.merge(scale(ratio, cell_of(node), label_of(node), note?(node), min(want, fits)))
      |> Map.put(:views, Map.get(fame, node.article, 0))
    end)
  end

  @doc """
  縦軸に置く年表の目盛り。`%{year:, y:}` を古い順に返します。

  **等間隔には置きません。** 丸は年代の順に等間隔で並べてあって、年代そのものに
  比例してはいない（比例させると、画家が集中する 19 世紀後半だけ団子になり、
  空いている世紀に何もない余白ができる）。目盛りは前後の丸の年代から位置を割り出して
  置くので、**人が多い年代ほど間隔が広がります**。混み合った時代ほど紙面を取る、
  という読み方になります。

  刻みは、図が収める幅に合わせて 50 年か 100 年のどちらかにします。
  """
  def ticks(nodes) do
    # **上から順に、年代が戻らないものだけ**を拾う。グループの枠はメンバーをまとめて
    # 置くので、行の中に少し外れた年代が混ざる —— そのまま拾うと目盛りが行きつ戻りつする
    dated =
      for(node <- nodes, year = year_of(node), do: {year, node.y})
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.reduce([], fn
        {_year, _y} = point, [] -> [point]
        {year, _y} = point, [{last, _} | _] = acc when year >= last -> [point | acc]
        _point, acc -> acc
      end)
      |> Enum.reverse()

    case dated do
      [] ->
        []

      [_single] ->
        []

      _ ->
        {first, _} = List.first(dated)
        {last, _} = List.last(dated)
        step = tick_step(last - first)

        Stream.iterate(ceil_to(first, step), &(&1 + step))
        |> Enum.take_while(&(&1 <= last))
        |> Enum.map(&%{year: &1, y: y_at(&1, dated)})
    end
  end

  # 前後の丸のあいだを比例で割って、その年が来る高さを出す
  defp y_at(year, dated) do
    {before, rest} = Enum.split_while(dated, fn {y, _} -> y <= year end)

    case {List.last(before), List.first(rest)} do
      {nil, {_year, y}} -> y
      {{_year, y}, nil} -> y
      {{y1, top}, {y2, bottom}} when y2 > y1 -> top + (bottom - top) * (year - y1) / (y2 - y1)
      {{_y1, top}, _} -> top
    end
  end

  defp tick_step(span) when span > 400, do: 100
  defp tick_step(span) when span > 120, do: 50
  defp tick_step(_span), do: 25

  defp ceil_to(year, step), do: ceil(year / step) * step

  defp year_of(node) do
    case node.years && Regex.run(~r/\d{3,4}/, node.years) do
      [year] -> String.to_integer(year)
      _ -> nil
    end
  end

  @doc "この図に取り込む文書かどうかの目印。Chiezo からはこのタグで引きます。"
  def kind_tag, do: @kind_tag

  @doc """
  知名度を丸の大きさに変えます。**いちばん有名な人を基準にした比**で決めます。

  **知名度は収集の中に入っています**（`extra.pageviews_month`）。集める回が
  長期記憶から写してくるので、図を出すたびに外へ引きに行きません —— 引いていた頃は
  画家の数だけ往復していました（初回で 9,000 回以上）。

  絶対値で決めると、題材が変わったときに全部が大きくなったり小さくなったりします。
  平方根を挟むのは、ページビューが桁で開くため —— そのまま面積に使うと、
  1 人だけが巨大になって他が点になります。
  """
  def sized(nodes) do
    top = nodes |> Enum.map(&views_of/1) |> reference_top()

    Enum.map(nodes, fn node ->
      views = views_of(node)

      node
      |> Map.merge(scale(fame_ratio(views, top), cell_of(node), label_of(node), note?(node)))
      # **知られている度合いは残す。** 絞り込みで置き直すときに、もう一度
      # 数え直さずに大きさを付け直せる
      |> Map.put(:views, views)
    end)
  end

  defp views_of(node), do: node[:views] || 0

  # その図の升目。置く前のノード（テストが直に渡す場合）は既定の大きさで扱う
  defp cell_of(node), do: Map.get(node, :cell) || @max_cell

  # 知名度を 0.0〜1.0 に均す。**そのままの比では使わない**のはページビューが桁で
  # 開くためで、曲げ具合は `@fame_curve` が持つ（強く曲げると差が縮み、
  # 弱くすると広がる）
  # 基準の閲覧数（上から `@fame_reference_rank` 番目）。**人数が足りなければ
  # いちばん上の人**（数人の図で下の人を基準にすると、全員が最大になる）
  defp reference_top(views) do
    sorted = Enum.sort(views, :desc)
    Enum.at(sorted, @fame_reference_rank - 1) || List.first(sorted) || 0
  end

  defp fame_ratio(_views, top) when top <= 0, do: 0.0

  # **基準より上の人は 1 で止める**（上位の何人かはみな最大の大きさ）
  defp fame_ratio(views, top) when is_integer(views) and views > 0,
    do: min(:math.pow(views / top, @fame_curve), 1.0)

  defp fame_ratio(_views, _top), do: 0.0

  # **札も字も同じ升目から決める。** 別々に決めると、小さい札から名前がはみ出す
  # 札に実際に書かれるもの。**印のぶんまで数える** —— 数えないと、印を付けた丸だけ
  # 名前がはみ出す
  defp label_of(node) do
    if node[:works] in [nil, []], do: node.name, else: node.name <> @work_mark
  end

  defp note?(node), do: node[:note] not in [nil, ""]

  defp scale(ratio, cell, name, note?, forced \\ nil) do
    radius = cell * (@min_radius_ratio + (@max_radius_ratio - @min_radius_ratio) * ratio)

    # **天井は升目の側に置く。** 字そのものを切ると、上限に当たった人どうしの
    # 差が消える —— 人数の少ない図では全員が上限に当たり、知名度で大きさを
    # 変えている意味がまるごと無くなった（有名も無名も同じ 22px になった）
    font =
      forced ||
        cell
        |> min(@max_name_px / @max_name_ratio)
        |> Kernel.*(@min_name_ratio + (@max_name_ratio - @min_name_ratio) * ratio)

    sub = max(font * @sub_size_ratio, @min_sub_size)

    # **札の大きさは字だけで決める。** 丸はもう描いていないので、半径を下限に
    # 使うと札が中身と関係なく膨らむ —— 人数の少ない図では半径が 264 まで育ち、
    # 札が幅 528 になって隣と重なり、ほとんどの丸が間引かれた。
    # 半径は「小さすぎるものを描かない」「大きい順に描く」ための物差しとして残す
    height = font * @label_line_height + if note?, do: sub * @note_line_height, else: 0.0

    %{
      # 札の中の 2 行の置き場所。**ここで出す** —— 画面側で組み直すと、
      # 高さの決め方と 2 か所で辻褄を合わせることになる
      name_dy: Float.round(if(note?, do: -sub * @note_line_height / 2, else: 0.0), 1),
      note_dy: Float.round(font * @label_line_height / 2, 1),
      # 大きさの物差しは残す（描く数を絞るのも、並べ替えるのもこれで決める）
      radius: max(round(radius), 2),
      name_size: Float.round(font, 1),
      sub_size: Float.round(sub, 1),
      # 名前が収まる札の大きさ。**丸だと名前がはみ出す** —— 円は角へ行くほど
      # 内側が痩せるので、横に長い名前を入れるには不釣り合いに大きな円が要る
      label_width: Float.round(text_width(name, font) + font * @label_padding, 1),
      label_height: Float.round(height, 1)
    }
  end

  @doc """
  その字の大きさで名前を書いたときの、おおよその横幅。

  **測らずに見積もります。** 実際の幅はブラウザのフォントで決まるので、サーバー側では
  分かりません。日本語は全角 1 文字ぶん、半角の英数字と記号は約 0.55 文字ぶんとして
  数えます。**足りないより余るほうへ倒す** —— 狭く見積もると名前が札からはみ出し、
  はみ出さないようにするというこの仕組みの目的そのものが崩れます。
  """
  def text_width(name, font_size) when is_binary(name) do
    name
    |> String.graphemes()
    |> Enum.reduce(0.0, fn ch, acc ->
      acc + if ch =~ ~r/^[\x20-\x7E]$/, do: @halfwidth_ratio, else: 1.0
    end)
    |> Kernel.*(font_size)
  end

  def text_width(_name, _font_size), do: 0.0

  # 出典が Wikipedia の記事なら、その記事名。知名度も絵もここから辿る。
  #
  # **壊れた URL は使わない。** URL は AI が書くので崩れていることがある
  # （`/wiki/%E3%83%9 territorial_link/…` のように途中で符号が切れたもの）。
  # 戻した記事名が正しい文字列にならないと、画面へ送る JSON が作れずに
  # LiveView ごと落ち、押すたびに画面が読み直されていた
  defp article_title(%{"extra" => %{"url" => url}}) when is_binary(url), do: wikipedia_title(url)
  defp article_title(_doc), do: nil

  defp wikipedia_title(url) do
    # **空白はそのまま通す**（`/wiki/AKI (画家)` のように符号にせず書いた URL は多く、
    # ブラウザでも開ける）。見るのは、戻した記事名が正しい文字列になるかだけ
    with %URI{host: host, path: "/wiki/" <> raw} when is_binary(host) <- URI.parse(url),
         true <- String.ends_with?(host, "wikipedia.org"),
         {:ok, title} <- decoded(raw),
         true <- String.valid?(title) and title != "" do
      title
    else
      _broken -> nil
    end
  end

  defp decoded(raw) do
    {:ok, URI.decode(raw)}
  rescue
    ArgumentError -> :error
  end

  # URL が書いてあるのに読めない（壊れている）か
  defp broken_url?(%{"extra" => %{"url" => url}}) when is_binary(url),
    do: String.match?(url, ~r/wikipedia\.org/u) and wikipedia_title(url) == nil

  defp broken_url?(_doc), do: false

  # 記事の冒頭。**切ったことは出さない** —— 「…」だけ見せて全文へ誘うより、
  # 出典のリンクがすぐ上にあるほうが早い
  defp summary_of(%{"body" => body}) when is_binary(body) do
    case body |> String.split() |> Enum.join(" ") |> String.slice(0, @summary_chars) do
      "" -> nil
      text -> text
    end
  end

  defp summary_of(_doc), do: nil

  # 壊れた Wikipedia の URL は出さない（画面が記事名から組み立て直す）。
  # http・https 以外もリンクにしない（`Chidori.SafeUrl`）
  defp article_url(%{"extra" => %{"url" => url}} = doc) when is_binary(url) do
    if broken_url?(doc), do: nil, else: Chidori.SafeUrl.href(url)
  end

  defp article_url(_doc), do: nil

  @doc "代表作を持っている印（名前の後ろに出す）。"
  def work_mark, do: @work_mark

  @doc "丸に出す代表作の上限。"
  def max_works, do: @max_works

  defp to_node(%{"title" => title} = doc, spec) when is_binary(title) do
    name = String.trim(title)
    tags = tags_of(doc)

    # **消えたものは出さない。** 未レビューのものを見るために、読み口の既定の
    # 外し方をやめて両方を受け取っている（`Chidori.Relations` の読み込み）ので、
    # 消えたほうはここで落とす
    if name == "" or spec.kind_tag not in tags or Chidori.Chiezo.removed_tag() in tags do
      []
    else
      [
        %{
          name: name,
          # **様式は 1 人にいくつでも付く。** ピカソのように時期で作風が変わる画家を
          # 1 つに決めると、どれを選んでも間違いになる（キュビスムだけの人ではない）
          styles: tag_values(tags, spec.style_prefix),
          note: styles_note(tags, spec.style_prefix, spec[:note_prefix]),
          years: tag_value(tags, @years_prefix),
          # **代表作は複数持つ。** 抽出が人気の順に何枚か拾ってくるので、
          # そのまま並べる（`@max_works` まで）。**記事の無い作品名も入ってくる**
          # （絵が見つからなければ、画面は画像検索へのリンクにする）
          works:
            if(spec.works?,
              do: tags |> tag_values(@work_prefix) |> Enum.take(@max_works),
              else: []
            ),
          # 押したときに出す、その画家の短い説明（記事の冒頭）
          summary: summary_of(doc),
          # 出典（Wikipedia の記事）。知名度を引くのと、絵を探すのに使う
          # **URL が壊れていたら、名前を記事名として使う**（画家は日本語版の記事名で
          # 名簿に入っているので、名前から記事へ辿れる）
          article: article_title(doc) || if(broken_url?(doc), do: name),
          # **押したときに出す出典の URL。** 代表作の記事ではなく画家の記事を指す ——
          # 画家を押したのだから、行き先は画家であるべき
          url: article_url(doc),
          # **Chiezo に入っているタグをそのまま持つ。** どういう条件でこの人が
          # 名簿に入り、何が分かっているのかは、これを見せないと読み取れない
          tags: tags,
          # 記事の画像（顔写真の手掛かり。名簿を引くときに運んだもの。無ければ nil）
          image: image_in(doc),
          # Chiezo が縮めて持っている絵（`/thumbs/…`。映画の図は整理の回に探させたポスター）。
          # あれば記事の画像より先に使う（`Chidori.Relations` の `with_faces`）
          thumb: thumb_in(doc),
          # 上映時間（分。映画の図。整理の回に AI が書く `extra.runtime_minutes`）
          runtime: runtime_in(doc),
          # 映画としての話題度（1〜10。映画の図。整理の回に AI が書く `extra.fame_level`。
          # 閲覧数の当てにならない作品の大きさに使う `Films.with_new_film_views/3`）
          fame_level: fame_level_in(doc),
          # **どれくらい知られているか。** 丸の大きさに使う。集める回が長期記憶の
          # 月次ページビューを写してくるので、ここで外へ引きに行かない
          views: views_in(doc),
          # **いつ動いたか。** Chiezo は 1 回の巡回で触れた文書に同じ刻みを打つので、
          # これが揃っているものが「その回で動いたぶん」になる
          changed_at: stamp_of(doc),
          # **AI がまだ目を通していないか。** 機械で名簿に入っただけの人は、説明も
          # 影響元もまだ無いことが多い。図には出すが、見分けられるようにする
          unreviewed?: Chidori.Chiezo.unreviewed_tag() in tags,
          kind: kind_in(tags, spec),
          # 横の帯（図の種類の帯で決める。置いたあとも同じ帯に入る）
          band: band_in(tags, spec)
        }
      ]
    end
  end

  defp to_node(_doc, _spec), do: []

  defp kind_in(tags, spec) do
    Enum.find_value(spec.kinds, spec.default_kind, fn {tag, kind} -> if tag in tags, do: kind end)
  end

  # 消えた画家（名前・消した理由・いつ）。**新しく消えた順** —— 見直したいのは
  # たいてい直近の回が消したもの
  defp removed_of(docs, spec) do
    docs
    |> Enum.flat_map(fn
      %{"title" => title} = doc when is_binary(title) ->
        tags = tags_of(doc)
        extra = if is_map(doc["extra"]), do: doc["extra"], else: %{}

        if spec.kind_tag in tags and Chidori.Chiezo.removed_tag() in tags do
          [
            %{
              name: String.trim(title),
              reason: to_string(extra["removed_reason"] || ""),
              removed_at: to_string(extra["removed_at"] || "")
            }
          ]
        else
          []
        end

      _doc ->
        []
    end)
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.removed_at, :desc)
  end

  # 月次ページビュー（bot 除外）に、AI が付けた倍率を掛けたもの。
  # **持っていない画家もいる**ので、無ければ 0 —— 図が出ないより、丸が小さいほうがまし
  defp views_in(%{"extra" => extra}) when is_map(extra) do
    case extra[@views_key] do
      views when is_integer(views) and views > 0 -> round(views * scale_in(extra))
      _other -> 0
    end
  end

  defp views_in(_doc), do: 0

  defp image_in(%{"extra" => %{"image" => url}}) when is_binary(url) and url != "", do: url
  defp image_in(_doc), do: nil

  defp thumb_in(%{"extra" => %{"thumb" => thumb}}) when is_binary(thumb),
    do: Chidori.Chiezo.thumb_path(thumb)

  defp thumb_in(_doc), do: nil

  defp runtime_in(%{"extra" => %{"runtime_minutes" => minutes}})
       when is_integer(minutes) and minutes > 0,
       do: minutes

  defp runtime_in(_doc), do: nil

  defp fame_level_in(%{"extra" => %{"fame_level" => level}})
       when is_integer(level) and level in 1..10,
       do: level

  defp fame_level_in(_doc), do: nil

  # 知名度の倍率。**書かれていなければ 1.0**（ほとんどの画家には要らない）。
  # 読めない値も 1.0 —— 図が壊れるより、補正が効かないほうがまし
  defp scale_in(extra) do
    case extra[@fame_scale_key] do
      value when is_number(value) and value > 0 ->
        value |> max(@min_fame_scale) |> min(@max_fame_scale) |> :erlang.float()

      _other ->
        1.0
    end
  end

  @doc "知名度に使う鍵（機械が写す事実と、AI が付ける倍率）。"
  def views_key, do: @views_key
  def fame_scale_key, do: @fame_scale_key

  defp stamp_of(doc) do
    case doc["updated_at"] do
      text when is_binary(text) -> String.trim(text)
      _ -> nil
    end
  end

  @doc """
  直近の巡回で動いたものに印を付け、その時刻を返します。

  Chiezo は**1 回の巡回で触れた文書に同じ刻みを打つ**ので、いちばん新しい刻みを
  持つものが、その回で足された・直されたぶんになります。

  **全部が同じ刻みなら、印は付けません。** 最初の一括作成がそれで、比べる先が
  無いまま「全部が動いた」と出しても読む人には何も言えていません。
  """
  def mark_changed(nodes) do
    stamps =
      nodes |> Enum.map(& &1[:changed_at]) |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()

    case stamps do
      list when length(list) < 2 ->
        {nodes, nil}

      list ->
        latest = Enum.max_by(list, &stamp_value/1)
        {Enum.map(nodes, &Map.put(&1, :changed?, &1[:changed_at] == latest)), latest}
    end
  end

  # 並べるための値。**読めないものは最古として扱う**（印は「いちばん新しい」に
  # 付くので、読めなかったぶんが最新に化けるより、付かないほうが害が小さい）
  defp stamp_value(text) do
    case DateTime.from_iso8601(to_string(text)) do
      {:ok, at, _offset} -> DateTime.to_unix(at)
      _ -> 0
    end
  end

  # 丸の下に出す様式。**いくつあっても並べる** —— 1 つに切り詰めると、
  # 枠が 2 つ掛かっている画家の丸だけ、片方の様式しか書かれていないことになる
  # 札の 2 行目。様式（映画は国）に、`note_prefix` の値（映画はジャンル。3 つまで）を添える
  defp styles_note(tags, prefix, extra_prefix) do
    extra = if extra_prefix, do: tags |> tag_values(extra_prefix) |> Enum.take(3), else: []

    case tag_values(tags, prefix) ++ extra do
      [] -> nil
      values -> values |> Enum.uniq() |> Enum.join("・")
    end
  end

  # 年代の始まりで並べる。左から右へ時代が流れる図なので、並びがそのまま意味になる
  defp sort_key(node), do: {year_of(node) || 9999, node.name}

  defp edges(docs, by_name, spec) do
    labelled = Enum.flat_map(spec.edge_rules, &rule_edges(docs, by_name, &1))

    # 記事どうしの相互リンクの薄い線は、図ごとに外せる（`related: false`。映画の図は
    # 同じ監督・同じ主演の線で読むので、続編やシリーズのリンクの線は邪魔になる）
    if Map.get(spec, :related, true),
      do: labelled ++ related(docs, by_name, labelled),
      else: labelled
  end

  # **同じ値を持つ文書どうしの線**（`shared: true`。映画の図の「同じ監督」「同じ主演」、芸能人の図の「同じグループ」）。タグの値は
  # 札ではなく、札どうしをつなぐ共通項なので、名指しされた札を探しても見つからない。
  # **年代の順に隣どうしだけを結ぶ** —— 全部の組を結ぶと、作品の多い俳優で線が網になる
  defp rule_edges(docs, by_name, %{shared: true} = rule) do
    docs
    |> Enum.flat_map(fn doc ->
      case by_name[String.trim(to_string(doc["title"] || ""))] do
        nil -> []
        node -> for value <- tag_values(tags_of(doc), rule.prefix), do: {value, node}
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
    |> Enum.flat_map(fn {value, nodes} ->
      nodes
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&sort_key/1)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] ->
        %{
          from: from.id,
          to: to.id,
          label: display_name(value),
          kind: rule.kind,
          via: rule.prefix,
          # 共通項そのもの。札を押したときに、同じ値の作品を鎖ごと立たせる（画面の `pick_of/2`）
          value: value,
          excerpt: []
        }
      end)
    end)
    # 同じ 2 本を 2 人の主演が共にしていても 1 本（字は先に来た人）。**共通項は全部持たせる**
    # （`values`）—— 1 つに畳むと、捨てた人の鎖がこの線で途切れ、札を押してもその人の
    # ほかの作品が立たなかった
    |> Enum.group_by(&Enum.sort([&1.from, &1.to]))
    |> Enum.map(fn {_pair, [first | _] = same} ->
      Map.put(first, :values, Enum.map(same, & &1.value))
    end)
    |> Enum.sort_by(&{&1.value, &1.from, &1.to})
  end

  # 1 つの決まりぶんの線。**名指しされた側か、文書の主か**から向きを決める
  defp rule_edges(docs, by_name, rule) do
    for doc <- docs,
        owner = by_name[String.trim(to_string(doc["title"] || ""))],
        owner != nil,
        {other_name, label} <- labelled(tags_of(doc), rule.prefix),
        other = by_name[other_name],
        other != nil,
        other.id != owner.id do
      {from, to} = if rule.from == :named, do: {other, owner}, else: {owner, other}

      %{
        from: from.id,
        to: to.id,
        label: label || rule[:label],
        # 字で種類を分ける線（夫婦は家族の線の中でいちばん目立たせる）
        kind: Map.get(rule[:kinds_by_label] || %{}, label, rule.kind),
        # どのタグから引いた線か（グループの枠は「今のメンバー」の線から組む）
        via: rule.prefix,
        # 文書の主の説明のうち、相手の名前が出てくる文。**線を押したときに出す** ——
        # AI の一言だけでは、何を根拠にした線なのかが読めない
        excerpt: mentions(doc["body"], other.name)
      }
    end
    # 同じ組の線は 1 本に畳む（同じ相手を 2 つのタグで挙げても重ならない）。
    # **向きを持たない線は、両側の文書に書かれていても 1 本**
    |> Enum.uniq_by(fn edge ->
      if rule[:undirected], do: Enum.sort([edge.from, edge.to]), else: {edge.from, edge.to}
    end)
  end

  # 相互リンクの線。**古いほうから新しいほうへ向ける** —— 記事どうしのリンクに
  # 向きは無いが、時代の流れは分かっているので、こちらで向きを与える。
  #
  # **影響の線がある組には引かない。** AI が「何を受けたか」まで書いた組は、
  # そちらのほうが濃い情報なので、上に薄い線を重ねない。
  defp related(docs, by_name, labelled) do
    known = MapSet.new(labelled, fn edge -> Enum.sort([edge.from, edge.to]) end)

    for doc <- docs,
        node = by_name[String.trim(to_string(doc["title"] || ""))],
        node != nil,
        other_name <- tag_values(tags_of(doc), @related_prefix),
        other = by_name[other_name],
        other != nil,
        other.id != node.id,
        not MapSet.member?(known, Enum.sort([node.id, other.id])),
        # 古い側から新しい側へ 1 本だけ（相互リンクなので両方の文書に出てくる）
        {from, to} = order_by_age(node, other),
        from.id == node.id do
      # 相互リンクの線にも、本文でその相手に触れている文を添える（あれば）
      %{
        from: from.id,
        to: to.id,
        label: nil,
        kind: :related,
        excerpt: mentions(doc["body"], other.name)
      }
    end
    |> Enum.uniq_by(&{&1.from, &1.to})
  end

  # 本文のうち、その名前が出てくる文（多くて @max_mentions 文）。
  # 本文では姓だけで呼ぶことが多い（「クロード・モネ」を「モネ」）ので、
  # 中黒で区切った最後の語でも探す
  defp mentions(body, name) when is_binary(body) and is_binary(name) do
    short = name |> String.replace(~r/\s*\(.*\)$/u, "") |> String.split("・") |> List.last()
    names = Enum.uniq([name, short]) |> Enum.filter(&(String.length(&1) >= 2))

    body
    |> String.split(~r/(?<=。)|\n/u, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn sentence -> Enum.any?(names, &String.contains?(sentence, &1)) end)
    |> Enum.take(@max_mentions)
  end

  defp mentions(_body, _name), do: []

  defp order_by_age(a, b) do
    if (year_of(a) || 9999) <= (year_of(b) || 9999), do: {a, b}, else: {b, a}
  end

  defp tag_values(tags, prefix) do
    for tag <- tags, String.starts_with?(tag, prefix <> ":") do
      tag |> String.split(":", parts: 2) |> List.last() |> String.trim()
    end
  end

  defp labelled(tags, prefix) do
    for tag <- tags, String.starts_with?(tag, prefix <> ":") do
      case String.split(tag, ":", parts: 3) do
        [_, name, label] -> {String.trim(name), trimmed(label)}
        [_, name] -> {String.trim(name), nil}
      end
    end
  end

  defp tags_of(%{"tags" => tags}) when is_list(tags), do: Enum.map(tags, &to_string/1)
  defp tags_of(_doc), do: []

  defp tag_value(tags, prefix) do
    tags
    |> Enum.find(&String.starts_with?(&1, prefix <> ":"))
    |> case do
      nil -> nil
      tag -> tag |> String.split(":", parts: 2) |> List.last() |> trimmed()
    end
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_value), do: nil

  # 置き方の入口。**グループを枠にする図**（`clusters`）は横の帯を持たず、
  # メンバーをまとめて置く（`cluster_layout/4`）。それ以外は帯に割る（`layout/4`）
  # **上下の向き。** 置き方は古い年を上から並べる。上を新しい年にする図（映画。
  # `newest_first`）は、置き終えた図を上下に裏返す —— 置き方そのものを変えると、
  # 混み具合で行を詰める決まりまで書き直すことになる。目盛りは裏返す前の向きで
  # 拾ってから裏返す（`ticks/1` は上から年が戻らないものを拾う）
  defp oriented(laid, false), do: Map.put(laid, :ticks, ticks(laid.nodes))

  defp oriented(laid, true) do
    height = laid.height
    flip = fn y -> Float.round(height - y * 1.0, 1) end

    laid
    |> Map.put(:nodes, Enum.map(laid.nodes, &%{&1 | y: flip.(&1.y)}))
    |> Map.put(
      :clusters,
      Enum.map(laid[:clusters] || [], fn cluster ->
        %{cluster | y: flip.(cluster.y + Map.get(cluster, :height, 0))}
      end)
    )
    |> Map.put(:ticks, laid.nodes |> ticks() |> Enum.map(&%{&1 | y: flip.(&1.y)}))
  end

  defp arrange(nodes, edges, columns, order, nil), do: layout(nodes, edges, columns, order)

  defp arrange(nodes, edges, columns, _order, rule),
    do: cluster_layout(nodes, edges, columns, rule)

  # 枠にグループの札と同じ色を付ける
  defp paint_clusters(clusters, nodes) do
    hues = Map.new(nodes, &{&1.id, &1[:hue]})
    Enum.map(clusters, &Map.put(&1, :hue, hues[&1.id]))
  end

  # 枠に入っているメンバーへの線に印を付ける（画面はこの印の線を描かない）
  defp mark_framed(edges, []), do: edges

  defp mark_framed(edges, clusters) do
    framed =
      for cluster <- clusters, id <- cluster.members, into: MapSet.new(), do: {cluster.id, id}

    Enum.map(edges, fn edge ->
      if MapSet.member?(framed, {edge.from, edge.to}),
        do: Map.put(edge, :framed?, true),
        else: edge
    end)
  end

  # グループを 1 行に収めるために、少なくとも取る列の数
  @cluster_min_columns 8

  # 枠の内側に空ける幅（升目に対する比）
  @frame_inset 0.06

  # **グループを枠にする置き方**（芸能人の図）。
  #
  # - **横の帯は持たない。** 種別は札の色で分かるので、帯に割ると夫婦が左右の端に離れる
  # - **グループのメンバーは隣り合わせに置き、枠で囲む。** 1 人ずつ生年で置くと、
  #   コンビの 2 人が年の差のぶん別の行へ散って、枠が組めない。グループは
  #   **メンバーの生年の中ほど**の高さに 1 かたまりで置く（縦は「何となく年齢順」になる）
  # - 1 行に収まらない大きなグループは、行を改めて何行かに折り返す（枠もその行ぶん）
  # - 行の中は、**つながっている相手の真上・真下へ寄せる**（かたまりごと動かす）。
  #   夫婦は年の差のぶん別の行に入るので、縦に並ぶと線が短くなる
  # - グループの札は枠の上の縁に置く（枠の名前になる）
  defp cluster_layout([], _edges, _columns, _rule),
    do: %{nodes: [], height: @canvas_height + 2 * @canvas_margin, bands: [], clusters: []}

  defp cluster_layout(nodes, edges, wanted, rule) do
    %{columns: from_aspect, cell: cell} = grid(length(nodes))
    units = cluster_units(nodes, edges, rule)

    # **小さいグループは 1 行に収める。** 人数の少ない図は 1 列になることがあり、
    # そのままだとコンビの 2 人が縦に割れて枠が行をまたぐ
    widest = units |> Enum.map(&length(&1.members)) |> Enum.max(fn -> 1 end)
    columns = max(wanted || from_aspect, min(widest, @cluster_min_columns))
    packed = pack(units, columns)
    rows = packed |> Enum.flat_map(fn {_unit, seats} -> Enum.map(seats, &elem(&1, 1)) end)
    row_count = Enum.max(rows, fn -> 0 end) + 1

    # 枠の材料にした線（今のメンバー）は寄せる手掛かりにしない（枠の中で隣り合っている）
    member = rule[:member_prefix]
    others = Enum.reject(edges, &(member != nil and &1[:via] == member))
    columns_by_id = shift_units(packed, adjacency(others))

    drawn_height = max(@canvas_height, row_count * cell)
    height = drawn_height + 2 * @canvas_margin
    x_step = (@canvas_width - @gutter) / columns
    y_step = drawn_height / row_count

    member_spots =
      for {_unit, seats} <- packed, {node, row, _column} <- seats, into: %{} do
        column = Map.fetch!(columns_by_id, node.id)

        {node.id,
         %{
           x: @gutter + (column + 0.5) * x_step,
           y: @canvas_margin + (row + 0.5) * y_step,
           row: row,
           seat: column
         }}
      end

    clusters =
      for {%{group: group, members: members}, seats} <- packed, group != nil do
        frame(group, members, seats, columns_by_id, columns, x_step, y_step)
      end

    group_spots =
      Map.new(clusters, fn cluster ->
        {cluster.id, %{x: cluster.x + cluster.width / 2, y: cluster.y, row: cluster.row, seat: 0}}
      end)

    spots = Map.merge(member_spots, group_spots)

    placed =
      packed
      |> Enum.flat_map(fn {%{group: group}, seats} ->
        # タグから組んだ枠（`tag_units/2`）には札が無い（名前は枠に書く）
        List.wrap(if group && !group[:tag?], do: group) ++ Enum.map(seats, &elem(&1, 0))
      end)
      |> Enum.with_index(fn node, index ->
        Map.merge(node, Map.fetch!(spots, node.id))
        |> Map.merge(%{
          band: band_of(node),
          cell_w: x_step,
          cell_h: y_step,
          cell: cell,
          index: index
        })
      end)

    %{nodes: placed, height: height, bands: [], clusters: clusters}
  end

  # **人のタグからかたまりを組む**（`clusters: %{tag_prefix: …}`。芸能人の図）。
  # グループを文書として持たず、メンバーの「グループ:<名前>」で枠を作る —— グループを
  # 名簿に入れていた頃は、ざっと見る回がグループの文書ばかり回って、人が育たなかった。
  # 名簿にいるメンバーが 2 人以上のグループだけを枠にする（1 人の枠は囲む意味が無い）。
  # **同じ人が 2 つのグループにいたら、名簿にいるメンバーの多いほうに入れる**
  defp cluster_units(nodes, _edges, %{tag_prefix: prefix}) do
    groups_of = Map.new(nodes, &{&1.id, tag_values(&1[:tags] || [], prefix)})

    sizes =
      groups_of |> Map.values() |> List.flatten() |> Enum.frequencies()

    {framed, singles} =
      nodes
      |> Enum.group_by(fn node ->
        groups_of[node.id]
        |> Enum.filter(&(sizes[&1] >= 2))
        |> Enum.max_by(&{sizes[&1], &1}, fn -> nil end)
      end)
      |> Enum.split_with(fn {name, _members} -> name != nil end)

    frames =
      for {name, members} <- framed do
        %{
          group: %{id: "group:" <> name, name: display_name(name), years: nil, tag?: true},
          members: Enum.sort_by(members, &sort_key/1)
        }
      end

    alone = for {nil, members} <- singles, node <- members, do: %{group: nil, members: [node]}
    Enum.sort_by(frames ++ alone, &{unit_year(&1), unit_name(&1)})
  end

  # かたまりに分ける。グループは今のメンバーと 1 かたまり、ほかの人は 1 人で 1 かたまり。
  # **同じ人が 2 つのグループにいたら、名簿にいるメンバーの多いほうに入れる**（枠は
  # 重ねられない）。メンバーが名簿に 1 人もいないグループは、札のまま 1 かたまり
  defp cluster_units(nodes, edges, rule) do
    by_id = Map.new(nodes, &{&1.id, &1})

    members_of =
      edges
      |> Enum.filter(&(&1[:via] == rule.member_prefix))
      |> Enum.group_by(& &1.from, & &1.to)

    groups =
      nodes
      |> Enum.filter(&(&1[:kind] == rule.kind and Map.has_key?(members_of, &1.id)))
      |> Enum.sort_by(&{-length(members_of[&1.id]), &1.name})

    {framed, taken} =
      Enum.map_reduce(groups, MapSet.new(), fn group, taken ->
        members =
          members_of[group.id]
          |> Enum.uniq()
          |> Enum.reject(&MapSet.member?(taken, &1))
          |> Enum.map(&by_id[&1])
          |> Enum.reject(&(is_nil(&1) or &1[:kind] == rule.kind))
          |> Enum.sort_by(&sort_key/1)

        {%{group: group, members: members}, Enum.reduce(members, taken, &MapSet.put(&2, &1.id))}
      end)

    framed = Enum.reject(framed, &(&1.members == []))
    frames = MapSet.new(framed, & &1.group.id)

    singles =
      for node <- nodes,
          not MapSet.member?(taken, node.id),
          not MapSet.member?(frames, node.id),
          do: %{group: nil, members: [node]}

    Enum.sort_by(framed ++ singles, &{unit_year(&1), unit_name(&1)})
  end

  # かたまりの高さを決める年。**メンバーの生年の中ほど**（無ければグループの結成年）
  defp unit_year(%{group: group, members: members}) do
    case members |> Enum.map(&year_of/1) |> Enum.reject(&is_nil/1) |> Enum.sort() do
      [] -> (group && year_of(group)) || 9999
      years -> Enum.at(years, div(length(years) - 1, 2))
    end
  end

  defp unit_name(%{group: nil, members: [node | _]}), do: node.name
  defp unit_name(%{group: group}), do: group.name

  # かたまりを上から順に詰める。`[{かたまり, [{人, 行, 列}]}]`。
  # **1 行に収まるかたまりは行をまたがせない**（収まらなければ次の行へ）。
  # 1 行より大きいかたまりは行頭から折り返し、次のかたまりは行を改めて始める
  # （枠の中に他人が入らないように）
  defp pack(units, columns) do
    {packed, _row, _column} =
      Enum.reduce(units, {[], 0, 0}, fn unit, {acc, row, column} ->
        size = length(unit.members)

        {row, column} =
          if column == 0 or column + size <= columns, do: {row, column}, else: {row + 1, 0}

        seats =
          unit.members
          |> Enum.with_index()
          |> Enum.map(fn {node, i} ->
            {node, row + div(column + i, columns), rem(column + i, columns)}
          end)

        {_node, last_row, last_column} = List.last(seats)

        next =
          cond do
            size > columns -> {last_row + 1, 0}
            last_column + 1 >= columns -> {last_row + 1, 0}
            true -> {last_row, last_column + 1}
          end

        {[{unit, seats} | acc], elem(next, 0), elem(next, 1)}
      end)

    Enum.reverse(packed)
  end

  # 行の中で、かたまりを**つながっている相手の平均の列**の順に並べ替える（重心法。
  # `reorder/3` のかたまり版）。かたまりの中の並びと、行をまたぐかたまりは動かさない
  defp shift_units(packed, adjacency) do
    initial =
      for {_unit, seats} <- packed,
          {node, _row, column} <- seats,
          into: %{},
          do: {node.id, column}

    rows =
      packed
      |> Enum.filter(fn {_unit, seats} ->
        seats |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1
      end)
      |> Enum.group_by(fn {_unit, [{_node, row, _column} | _]} -> row end)

    Enum.reduce(1..@barycenter_passes, initial, fn _pass, positions ->
      Enum.reduce(rows, positions, fn {_row, blocks}, positions ->
        start = blocks |> Enum.map(fn {_u, [{_n, _r, c} | _]} -> c end) |> Enum.min()

        blocks
        |> Enum.map(fn {_unit, seats} ->
          ids = Enum.map(seats, &elem(&1, 0).id)
          here = Enum.map(ids, &positions[&1])
          {unit_center(ids, positions, adjacency, Enum.sum(here) / length(here)), ids}
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.reduce({positions, start}, fn {_center, ids}, {acc, column} ->
          acc =
            ids
            |> Enum.with_index()
            |> Enum.reduce(acc, fn {id, i}, acc -> Map.put(acc, id, column + i) end)

          {acc, column + length(ids)}
        end)
        |> elem(0)
      end)
    end)
  end

  # かたまりの寄せ先。**メンバーの相手の平均**（相手がいなければ今の位置のまま）
  defp unit_center(ids, positions, adjacency, here) do
    inside = MapSet.new(ids)

    case for(
           id <- ids,
           other <- Map.get(adjacency, id, []),
           not MapSet.member?(inside, other),
           do: positions[other]
         )
         |> Enum.reject(&is_nil/1) do
      [] -> here
      columns -> Enum.sum(columns) / length(columns)
    end
  end

  # 枠に書く名前。**記事名の括弧書きは落とす**（「かまいたち (お笑いコンビ)」→「かまいたち」）
  defp display_name(name), do: name |> String.replace(~r/\s*\([^)]*\)$/u, "") |> String.trim()

  # グループの枠（左上・幅・高さ）。行をまたぐかたまりは、その行ぶんの幅いっぱい
  defp frame(group, members, seats, columns_by_id, columns, x_step, y_step) do
    rows = Enum.map(seats, &elem(&1, 1))
    {top, bottom} = Enum.min_max(rows)

    {left, right} =
      if top == bottom,
        do: members |> Enum.map(&columns_by_id[&1.id]) |> Enum.min_max(),
        else: {0, columns - 1}

    inset = @frame_inset * min(x_step, y_step)

    %{
      id: group.id,
      name: group.name,
      # 札の無い枠（名前は枠に書く）
      labelled: group[:tag?] == true,
      x: Float.round(@gutter + left * x_step + inset, 1),
      y: Float.round(@canvas_margin + top * y_step + inset, 1),
      width: Float.round((right - left + 1) * x_step - 2 * inset, 1),
      height: Float.round((bottom - top + 1) * y_step - 2 * inset, 1),
      row: top,
      members: Enum.map(members, & &1.id)
    }
  end

  # **時代は縦に流す。** 人数が増えても幅が要らないので、たくさん並べられる
  # （横に流していた頃は 12 人で幅 2400 になり、画面に収まらなかった）。
  # 左右は重なりを避けるためだけに振る
  @doc false
  # 置き方。**縦は年代、横は地域**。
  #
  # 横を地域の帯に割ると、縦の年表と噛み合わせるところが難しくなる。帯ごとに
  # 格子を持たせると、同じ高さが帯ごとに別の年代を指してしまう（日本の画家は
  # 近代に偏っているので、帯の先頭どうしが 300 年ずれる）。
  #
  # **行を「年代のまとまり」にして解く。** 生年順に並べたものを上から詰め、
  # **どこかの帯が自分の列を使い切ったところで行を切る**。こうすると 1 行は
  # どの帯でも同じ年代を指し、行の高さは「その年代でいちばん混んでいる帯」で決まる。
  # 目盛りの間隔が一定でないのは元からの性質で、そこは変わらない。
  #
  # **帯の幅は人数の比で決める。** 等分すると、人数の多い帯だけが縦に伸びる。
  defp layout(nodes, edges, columns, order)

  defp layout([], _edges, _columns, _order),
    do: %{nodes: [], height: @canvas_height + 2 * @canvas_margin, bands: []}

  defp layout(nodes, edges, wanted, order) do
    %{columns: from_aspect, cell: cell} = grid(length(nodes))
    columns = wanted || from_aspect
    plan = band_plan(nodes, columns, order)
    ranks = style_ranks(nodes)
    caps = Map.new(plan, &{&1.band, &1.columns})
    offsets = Map.new(plan, &{&1.band, &1.offset})
    total_columns = Enum.sum(Enum.map(plan, & &1.columns))
    x_step = (@canvas_width - @gutter) / total_columns

    rows = buckets(nodes, caps)

    # **行を置く高さと、面の高さは別**。行を面いっぱいに割ると、いちばん上と下が
    # 重なっている UI の裏へ入る
    drawn_height = max(@canvas_height, length(rows) * cell)
    height = drawn_height + 2 * @canvas_margin
    y_step = drawn_height / length(rows)

    seats =
      for {row, index} <- Enum.with_index(rows),
          {band, members} <- row,
          {node, slot} <- Enum.with_index(members),
          into: %{},
          do: {node.id, {index, Map.fetch!(offsets, band) + slot}}

    groups =
      for {row, index} <- Enum.with_index(rows),
          {band, members} <- row,
          into: %{},
          do: {{index, band}, Enum.map(members, &{&1, 0})}

    initial = Map.new(seats, fn {id, {_row, column}} -> {id, column} end)

    # **まず繋がりで寄せ、そのうえで様式ごとにまとめ直す。** 色で様式を見せるので、
    # 同じ色が隣り合っていたほうが読める（席を予約すると図が 4 割伸びるので、
    # 並べ替えだけで寄せる）
    columns_by_id =
      groups
      |> reorder(initial, adjacency(edges))
      |> group_by_style(groups, ranks)

    placed =
      Enum.with_index(nodes, fn node, index ->
        {row, _column} = Map.fetch!(seats, node.id)
        seat = Map.fetch!(columns_by_id, node.id)

        Map.merge(node, %{
          x: @gutter + (seat + 0.5) * x_step,
          y: @canvas_margin + (row + 0.5) * y_step,
          band: band_of(node),
          # 枠を作るのに要る升目の座標と大きさ（枠は升目の並びから作る）
          row: row,
          seat: seat,
          cell_w: x_step,
          cell_h: y_step,
          # 丸と字の大きさは升目に対する比で決めるので、1 人ずつ持たせる
          cell: cell,
          # 並び順（生年順）。目盛りを切るときに使う
          index: index
        })
      end)

    %{
      nodes: placed,
      height: height,
      bands:
        Enum.map(plan, fn band ->
          %{
            band: band.band,
            members: band.members,
            x: @gutter + band.offset * x_step,
            width: band.columns * x_step
          }
        end)
    }
  end

  # 帯ごとの列数と、左からの位置。**人数の比で割る**（等分すると多い帯だけ縦に伸びる）。
  # 1 人でもいる帯には必ず 1 列は与える —— 0 列だと置き場が無くなる
  defp band_plan(nodes, columns, order) do
    counts = Enum.frequencies_by(nodes, &band_of/1)
    total = Enum.sum(Map.values(counts))

    order
    |> Enum.filter(&Map.has_key?(counts, &1))
    |> Enum.map_reduce(0, fn band, offset ->
      members = Map.fetch!(counts, band)
      share = max(1, round(columns * members / total))
      {%{band: band, columns: share, offset: offset, members: members}, offset + share}
    end)
    |> elem(0)
  end

  # 行に切る。**どこかの帯が自分の列を使い切ったところで切る**ので、
  # 1 行はどの帯でも同じ年代を指す
  defp buckets(nodes, caps) do
    {done, current} =
      Enum.reduce(nodes, {[], %{}}, fn node, {done, current} ->
        band = band_of(node)

        if length(Map.get(current, band, [])) >= Map.fetch!(caps, band),
          do: {[current | done], %{band => [node]}},
          else: {done, Map.update(current, band, [node], &[node | &1])}
      end)

    [current | done]
    |> Enum.reject(&(&1 == %{}))
    |> Enum.reverse()
    |> Enum.map(fn row ->
      Map.new(row, fn {band, members} -> {band, Enum.reverse(members)} end)
    end)
  end

  # 行 × 帯の中を、様式ごとにまとめ直す。**席の数は変えない**（並べ替えるだけ）。
  # 様式を持たない画家は後ろへ回す
  defp group_by_style(positions, groups, ranks) do
    Enum.reduce(groups, positions, fn {_key, members}, positions ->
      nodes = Enum.map(members, &elem(&1, 0))
      seats = nodes |> Enum.map(&positions[&1.id]) |> Enum.sort()

      nodes
      |> Enum.sort_by(&{style_rank(&1, ranks), positions[&1.id]})
      |> Enum.zip(seats)
      |> Enum.reduce(positions, fn {node, seat}, acc -> Map.put(acc, node.id, seat) end)
    end)
  end

  defp style_rank(node, ranks) do
    case styles_of(node) do
      [] -> :infinity
      styles -> styles |> Enum.map(&Map.get(ranks, &1, 0.0)) |> Enum.min()
    end
  end

  # 様式に順位を振る。**その様式の画家の平均の位置**（＝おおよその年代）で並べるので、
  # どの行でも同じ様式がだいたい同じ席に来る —— これが無いと、行ごとに様式の並びが
  # 変わって、枠が 1 行ぶんに割れる
  defp style_ranks(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.flat_map(fn {node, index} -> for style <- styles_of(node), do: {style, index} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {style, indexes} -> {style, Enum.sum(indexes) / length(indexes)} end)
  end

  defp adjacency(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      acc
      |> Map.update(edge.from, [edge.to], &[edge.to | &1])
      |> Map.update(edge.to, [edge.from], &[edge.from | &1])
    end)
  end

  # 各行の中で、**繋がっている相手の平均の位置**へ寄せ直す（重心法）。
  #
  # 行そのものは動かさないので、上から下へ時代が流れる読み方は変わらない。動くのは
  # 行の中の左右だけで、**繋がりの濃い者どうしが縦に並ぶ**ようになる —— 生年順に
  # 機械的に置いていた頃は、隣り合う丸に何の関係も無く、線が図の端から端まで
  # 走っていた（格子に見えていた原因）。
  #
  # 何度か繰り返す。1 回では、相手の位置がまだ動く前の値を見て決めることになる。
  # 線を持たない者はその場に留める（動かす根拠が無いうえ、動かすと繋がっている
  # 者どうしのあいだに割り込む）。
  defp reorder(rows, initial, adjacency) do
    Enum.reduce(1..@barycenter_passes, initial, fn _pass, positions ->
      Enum.reduce(rows, positions, fn {_row, members}, positions ->
        # 席は行が元から持っていたものを使い回す（行の幅は変えない）。
        # **並べ替える前に取っておく** —— 入れ替えながら数えると席が動く
        seats = members |> Enum.map(fn {node, _i} -> positions[node.id] end) |> Enum.sort()

        members
        |> Enum.map(fn {node, _i} -> {node.id, barycenter(node.id, positions, adjacency)} end)
        |> Enum.sort_by(&elem(&1, 1))
        |> Enum.zip(seats)
        |> Enum.reduce(positions, fn {{id, _center}, seat}, acc -> Map.put(acc, id, seat) end)
      end)
    end)
  end

  defp barycenter(id, positions, adjacency) do
    case Map.get(adjacency, id, []) do
      [] ->
        Map.fetch!(positions, id) * 1.0

      neighbours ->
        Enum.sum(Enum.map(neighbours, &Map.get(positions, &1, 0))) / length(neighbours)
    end
  end

  @doc """
  人数から決まる升目。`%{columns:, rows:, x_step:, y_step:, cell:, height:}`。

  **列は人数から決めます。** 固定にすると、増えたぶんがそのまま縦に伸びます
  （3 列だった頃は 4,250 人で高さ 314,500 になり、全体表示では潰れて読めず、
  引きずっても端まで遠かった）。面の縦横比を先に決めて、そこへ人数を敷き詰めます。

  **行は必ず面いっぱいに広げます**（`y_step` は高さ ÷ 行数）。人数が少ない図で
  行間だけ詰まって上に固まるのを避けるためです。
  """
  def grid(count) when count > 0 do
    usable = @canvas_width - @gutter
    target_height = @canvas_width * @canvas_aspect

    # 面の比に合う列数。1 人ぶんが正方形に近くなる並べ方。
    #
    # **行数の下限で頭を押さえる。** 人数が少ないと「横一列」がいちばん比に近くなるが、
    # それでは縦に流している年表が意味を失う（全員が同じ高さに並ぶ）。少なくとも
    # `@min_rows` 行は作り、人数がそれに満たなければ 1 列（＝ただの縦並び）にする
    columns =
      (count * usable / target_height)
      |> :math.sqrt()
      |> ceil()
      |> min(div(count, @min_rows))
      |> max(1)
      |> min(count)

    rows = ceil(count / columns)
    x_step = usable / columns

    # 升目は上下で挟む。**上限が要る** —— 人数が少ないと 1 人あたりの取り分が
    # 面の半分にもなり、丸も字も画面いっぱいの大きさになる
    cell = x_step |> max(@min_cell) |> min(@max_cell)
    height = max(@canvas_height, rows * cell)
    y_step = height / rows

    %{
      columns: columns,
      rows: rows,
      x_step: x_step,
      y_step: y_step,
      # 丸が入る大きさは、狭いほうの辺で決まる
      cell: min(cell, y_step),
      height: height
    }
  end

  def grid(_count),
    do: %{
      columns: 1,
      rows: 1,
      x_step: @canvas_width - @gutter,
      y_step: @canvas_height,
      cell: @max_cell,
      height: @canvas_height
    }

  defp canvas_width(_count), do: @canvas_width
end
