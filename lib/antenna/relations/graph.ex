defmodule Antenna.Relations.Graph do
  @moduledoc """
  Chiezo に溜まった文書を、ネットワーク図の形に読み直します。

  **Chiezo には図の構造を持ち込みません。** 向こうにあるのは「1 画家 = 1 文書」の
  普通のソースで、属性と関係はタグに載せてあります。ノードとエッジという読み方を
  与えるのは antenna 側の仕事です。判断や見せ方を Chiezo に持たせない、という
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
    {"ヨーロッパ",
     ~w(フランス ドイツ イタリア イングランド オランダ スペイン ロシア フランドル
        ベルギー オーストリア スコットランド スイス ポーランド スウェーデン デンマーク
        ハンガリー チェコ ノルウェー アイルランド ポルトガル フィンランド イギリス
        ウクライナ ギリシャ ルーマニア セルビア ウェールズ スロベニア クロアチア
        カタルーニャ ソビエト連邦 リトアニア ラトビア エストニア ブルガリア
        スロバキア アイスランド マルタ ルクセンブルク)},
    {"南北アメリカ",
     ~w(アメリカ合衆国 カナダ メキシコ ブラジル アルゼンチン チリ ペルー キューバ
        ウルグアイ コロンビア ベネズエラ ハイチ エクアドル)},
    {"アジア・その他",
     ~w(日本 中国 朝鮮 韓国 インド ベトナム フィリピン タイ インドネシア
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

  # 名前の後ろに付ける、代表作を持っている印。**札の幅にも数える** ——
  # 幅に入れないと、印のぶんだけ名前が札からはみ出す（札にした意味が消える）
  @work_mark "◆"

  # 丸の大きさ。**知名度で変える** —— どれが中心的な画家かが、読む前に分かる。
  # 知名度そのものは jawiki の月次ページビュー（`Antenna.Fame`）
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

  @doc "代表作を載せるタグの頭。"
  def work_tag, do: @work_prefix

  @doc "相互リンクの相手を載せるタグの頭。"
  def related_tag, do: @related_prefix

  @doc "地域を載せるタグの頭。"
  def region_tag, do: @region_prefix

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

  defp refocus(%{nodes: []} = relation, _kept), do: relation

  defp refocus(relation, []), do: relation

  defp refocus(relation, kept) do
    ids = MapSet.new(kept, & &1.id)

    edges =
      Enum.filter(relation.edges, fn edge ->
        MapSet.member?(ids, edge.from) and MapSet.member?(ids, edge.to)
      end)

    # 升目が変わるので、大きさも付け直す（知名度は `sized` が残しておいたものを使う）
    bare = Enum.map(kept, &Map.drop(&1, [:cell]))
    laid = layout(bare, edges, fitted_columns(bare))
    fame = Map.new(laid.nodes, &{&1.article, &1[:views] || 0})

    %{
      relation
      | nodes: refit(laid.nodes, fame),
        edges: edges,
        ticks: ticks(laid.nodes),
        bands: laid.bands,
        height: laid.height
    }
  end

  @doc "横軸に並べる地域のまとまり（西から東へ）。"
  def region_bands, do: Enum.map(@region_bands, &elem(&1, 0)) ++ [@other_band]

  @doc """
  その画家をどの帯に入れるか。**1 つに決めます**。

  複数の地域に跨る画家（移り住んだ人）はいますが、横軸は 1 人 1 か所でないと
  軸として読めません。**先に出てきた帯を採る**ので、並びが優先順位になります。
  """
  def band_of(node) do
    regions = tag_values(node[:tags] || [], @region_prefix)

    Enum.find_value(@region_bands, @other_band, fn {band, members} ->
      if Enum.any?(regions, &(&1 in members)), do: band
    end)
  end

  @doc "Chiezo の `filter` が返した文書の並びを、図のデータにします。"
  def from_docs(docs) when is_list(docs) do
    nodes =
      docs
      |> Enum.flat_map(&to_node/1)
      |> Enum.uniq_by(& &1.name)
      |> Enum.sort_by(&sort_key/1)
      |> Enum.with_index()
      |> Enum.map(fn {node, index} -> Map.put(node, :id, "n#{index}") end)

    by_name = Map.new(nodes, &{&1.name, &1})

    # **線を先に組む。** 置き方が線の形を見るようになったので、順序が逆だと
    # 何も繋がっていない前提で並べることになる
    edges = edges(docs, by_name)
    laid = layout(nodes, edges)
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
      edges: edges,
      ticks: ticks(laid.nodes),
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

  def from_docs(_docs), do: empty()

  def empty,
    do: %{
      nodes: [],
      edges: [],
      ticks: [],
      bands: [],
      styles: [],
      changed_at: nil,
      changed: 0,
      width: @canvas_width,
      height: @canvas_height
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
    top = fame |> Map.values() |> Enum.max(fn -> 0 end)

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
    dated = for node <- nodes, year = year_of(node), do: {year, node.y}

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

  絶対値で決めると、題材が変わったときに全部が大きくなったり小さくなったりします。
  平方根を挟むのは、ページビューが桁で開くため —— そのまま面積に使うと、
  1 人だけが巨大になって他が点になります。
  """
  def sized(nodes, fame) when is_map(fame) do
    top = fame |> Map.values() |> Enum.max(fn -> 0 end)

    Enum.map(nodes, fn node ->
      views = Map.get(fame, node.article, 0)

      node
      |> Map.merge(scale(fame_ratio(views, top), cell_of(node), label_of(node), note?(node)))
      # **知られている度合いは残す。** 絞り込みで置き直すときに、もう一度
      # 外へ引きに行かずに大きさを付け直せる
      |> Map.put(:views, views)
    end)
  end

  def sized(nodes, _fame),
    do: Enum.map(nodes, &Map.merge(&1, scale(0.0, cell_of(&1), label_of(&1), note?(&1))))

  # その図の升目。置く前のノード（テストが直に渡す場合）は既定の大きさで扱う
  defp cell_of(node), do: Map.get(node, :cell) || @max_cell

  # 知名度を 0.0〜1.0 に均す。**そのままの比では使わない**のはページビューが桁で
  # 開くためで、曲げ具合は `@fame_curve` が持つ（強く曲げると差が縮み、
  # 弱くすると広がる）
  defp fame_ratio(_views, top) when top <= 0, do: 0.0

  defp fame_ratio(views, top) when is_integer(views) and views > 0,
    do: :math.pow(views / top, @fame_curve)

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

  # 出典が Wikipedia の記事なら、その記事名。知名度も絵もここから辿る
  defp article_title(%{"extra" => %{"url" => url}}) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, path: "/wiki/" <> title} when is_binary(host) ->
        if String.ends_with?(host, "wikipedia.org"), do: URI.decode(title), else: nil

      _ ->
        nil
    end
  end

  defp article_title(_doc), do: nil

  # 記事の冒頭。**切ったことは出さない** —— 「…」だけ見せて全文へ誘うより、
  # 出典のリンクがすぐ上にあるほうが早い
  defp summary_of(%{"body" => body}) when is_binary(body) do
    case body |> String.split() |> Enum.join(" ") |> String.slice(0, @summary_chars) do
      "" -> nil
      text -> text
    end
  end

  defp summary_of(_doc), do: nil

  defp article_url(%{"extra" => %{"url" => url}}) when is_binary(url), do: url
  defp article_url(_doc), do: nil

  @doc "代表作を持っている印（名前の後ろに出す）。"
  def work_mark, do: @work_mark

  @doc "丸に出す代表作の上限。"
  def max_works, do: @max_works

  defp to_node(%{"title" => title} = doc) when is_binary(title) do
    name = String.trim(title)
    tags = tags_of(doc)

    if name == "" or @kind_tag not in tags do
      []
    else
      [
        %{
          name: name,
          # **様式は 1 人にいくつでも付く。** ピカソのように時期で作風が変わる画家を
          # 1 つに決めると、どれを選んでも間違いになる（キュビスムだけの人ではない）
          styles: tag_values(tags, @style_prefix),
          note: styles_note(tags),
          years: tag_value(tags, @years_prefix),
          # **代表作は複数持つ。** 抽出が人気の順に何枚か拾ってくるので、
          # そのまま並べる（`@max_works` まで）。**実在しない作品名は入ってこない** ——
          # Chiezo が焼く前に落とす（収集の `verify_tags`）
          works: tags |> tag_values(@work_prefix) |> Enum.take(@max_works),
          # 押したときに出す、その画家の短い説明（記事の冒頭）
          summary: summary_of(doc),
          # 出典（Wikipedia の記事）。知名度を引くのと、絵を探すのに使う
          article: article_title(doc),
          # **押したときに出す出典の URL。** 代表作の記事ではなく画家の記事を指す ——
          # 画家を押したのだから、行き先は画家であるべき
          url: article_url(doc),
          # **Chiezo に入っているタグをそのまま持つ。** どういう条件でこの人が
          # 名簿に入り、何が分かっているのかは、これを見せないと読み取れない
          tags: tags,
          # **いつ動いたか。** Chiezo は 1 回の巡回で触れた文書に同じ刻みを打つので、
          # これが揃っているものが「その回で動いたぶん」になる
          changed_at: stamp_of(doc),
          kind: :artist
        }
      ]
    end
  end

  defp to_node(_doc), do: []

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
    stamps = nodes |> Enum.map(& &1[:changed_at]) |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()

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
  defp styles_note(tags) do
    case tag_values(tags, @style_prefix) do
      [] -> nil
      styles -> Enum.join(styles, "・")
    end
  end

  # 年代の始まりで並べる。左から右へ時代が流れる図なので、並びがそのまま意味になる
  defp sort_key(node), do: {year_of(node) || 9999, node.name}

  defp edges(docs, by_name) do
    influence =
      for doc <- docs,
          to = by_name[String.trim(to_string(doc["title"] || ""))],
          to != nil,
          {from_name, label} <- influences(tags_of(doc)),
          from = by_name[from_name],
          from != nil,
          from.id != to.id do
        %{from: from.id, to: to.id, label: label, kind: :influence}
      end
      # 同じ向きの線は 1 本に畳む（同じ相手を 2 つのタグで挙げても重ならない）
      |> Enum.uniq_by(&{&1.from, &1.to})

    influence ++ related(docs, by_name, influence)
  end

  # 相互リンクの線。**古いほうから新しいほうへ向ける** —— 記事どうしのリンクに
  # 向きは無いが、時代の流れは分かっているので、こちらで向きを与える。
  #
  # **影響の線がある組には引かない。** AI が「何を受けたか」まで書いた組は、
  # そちらのほうが濃い情報なので、上に薄い線を重ねない。
  defp related(docs, by_name, influence) do
    known = MapSet.new(influence, fn edge -> Enum.sort([edge.from, edge.to]) end)

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
      %{from: from.id, to: to.id, label: nil, kind: :related}
    end
    |> Enum.uniq_by(&{&1.from, &1.to})
  end

  defp order_by_age(a, b) do
    if (year_of(a) || 9999) <= (year_of(b) || 9999), do: {a, b}, else: {b, a}
  end

  defp tag_values(tags, prefix) do
    for tag <- tags, String.starts_with?(tag, prefix <> ":") do
      tag |> String.split(":", parts: 2) |> List.last() |> String.trim()
    end
  end

  defp influences(tags) do
    for tag <- tags, String.starts_with?(tag, @influence_prefix <> ":") do
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
  defp layout(nodes, edges, columns \\ nil)

  defp layout([], _edges, _columns), do: %{nodes: [], height: @canvas_height, bands: []}

  defp layout(nodes, edges, wanted) do
    %{columns: from_aspect, cell: cell} = grid(length(nodes))
    columns = wanted || from_aspect
    plan = band_plan(nodes, columns)
    ranks = style_ranks(nodes)
    caps = Map.new(plan, &{&1.band, &1.columns})
    offsets = Map.new(plan, &{&1.band, &1.offset})
    total_columns = Enum.sum(Enum.map(plan, & &1.columns))
    x_step = (@canvas_width - @gutter) / total_columns

    rows = buckets(nodes, caps)
    height = max(@canvas_height, length(rows) * cell)
    y_step = height / length(rows)

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
          y: (row + 0.5) * y_step,
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
  defp band_plan(nodes, columns) do
    counts = Enum.frequencies_by(nodes, &band_of/1)
    total = Enum.sum(Map.values(counts))

    region_bands()
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
    |> Enum.map(fn row -> Map.new(row, fn {band, members} -> {band, Enum.reverse(members)} end) end)
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
