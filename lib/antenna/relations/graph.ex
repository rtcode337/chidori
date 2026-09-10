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

  # 様式と年代の字。名前より小さく、名前に対する比で決める
  @sub_size_ratio 0.62
  @min_sub_size 4.0

  # 札の高さ（字の大きさの何倍か）と、左右に足す余白（同じく字の大きさに対する比）
  @label_line_height 1.7
  @label_padding 0.9

  # 半角文字 1 つを全角何文字ぶんとして数えるか（幅の見積もりに使う）
  @halfwidth_ratio 0.55

  # 枠の内側に足す余白。丸と札が枠線に触れると、囲われているのか重なっているのかが
  # 読めなくなる
  @cluster_padding 26

  # 枠を描く最小の人数。**1 人を囲っても意味が増えない**（様式は丸の下に書いてある）
  @cluster_min_members 2

  # 同じ様式が並びの上でこれだけ離れたら、別の塊として扱う（間に何人挟まるまで許すか）。
  #
  # **離れた 2 人を 1 つの枠で囲うと嘘になる。** 並びは生年順なので、間には
  # 別の様式の画家が何十人も入る —— 実測では、2 人しかいない様式が高さ 2,994 の枠に
  # なり、無関係な画家を丸ごと囲っていた。
  #
  # **少しの挟まりは許す。** 1 人挟まるたびに割ると、枠だらけになって読めない
  @cluster_index_gap 4

  # 枠の中身のうち、その様式の人が占めるべき割合。これを下回る枠は行ごとに割り直す
  @cluster_purity 0.5

  @doc "代表作を載せるタグの頭。"
  def work_tag, do: @work_prefix

  @doc "相互リンクの相手を載せるタグの頭。"
  def related_tag, do: @related_prefix

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
    placed = layout(nodes, edges)

    %{
      nodes: placed,
      edges: edges,
      ticks: ticks(placed),
      clusters: clusters(placed),
      width: canvas_width(length(nodes)),
      height: canvas_height(length(nodes))
    }
  end

  def from_docs(_docs), do: empty()

  def empty,
    do: %{
      nodes: [],
      edges: [],
      ticks: [],
      clusters: [],
      width: @canvas_width,
      height: @canvas_height
    }

  @doc """
  同じ様式の画家を囲う枠。`%{style:, x:, y:, width:, height:}` を返します。

  **丸の位置は動かしません。** 並びは生年順のままで、枠はその上から囲うだけです ——
  様式でまとめ直すと、いつの人かが図から読めなくなります（様式は時代とおおむね
  対応するので、生年順に並べた時点で同じ様式の人は近くに来ます）。

  **1 人が複数の枠に入ります。** 時期で作風の変わった画家（キュビスムも新古典主義も
  やった人）を 1 つの様式に決めると、どれを選んでも間違いになります。そのぶん枠は
  重なりますが、重なっているのが事実です。

  **1 人の様式は囲いません**（`@cluster_min_members`）。様式は丸の下にも書いてあるので、
  囲っても増える情報が無く、枠だけが増えます。

  **離れて現れる同じ様式は、別の枠に分けます**（`@cluster_index_gap`）。並びは生年順なので、
  1 つの様式が図の上と下に散っていることがあります。それを 1 つの枠で囲うと、
  あいだにいる無関係な画家まで囲ってしまい、枠が嘘になります。

  枠は重なりえます。同じ時代に複数の様式が並走していれば実際に重なっているので、
  そこを避けて描くと嘘になります。**広い枠から先に描く**ので、狭い枠は上に乗ります。
  """
  def clusters(nodes) do
    nodes
    # **1 人が複数の枠に入る。** 時期で作風の変わった画家は、そのどれもが本当なので、
    # 1 つに決めずに全部の枠へ入れる（そのぶん枠は重なる）
    |> Enum.flat_map(fn node -> for style <- styles_of(node), do: {style, node} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {style, members} ->
      members
      |> segments(nodes)
      |> Enum.filter(&(length(&1) >= @cluster_min_members))
      |> Enum.map(&box(style, &1))
    end)
    # 広いものから描く。狭い枠が広い枠に隠れると、囲われていないように見える
    |> Enum.sort_by(&(-(&1.width * &1.height)))
  end

  @doc false
  # 囲える塊に分ける。
  #
  # **まず並び順で切る。** 生年順に置いてあるので、並びが続いている者どうしは
  # 図の上でも隣り合う。あいだに他の様式が少し挟まるのは許す（`@cluster_index_gap`）——
  # 1 人挟まるたびに枠が割れると、枠だらけになって読めない。
  #
  # **囲った中身が他人ばかりなら、行ごとに割り直す。** 折り返しをまたぐ塊を 1 つの
  # 四角で囲うと、行の端から端までが入り、あいだの無関係な画家まで囲ってしまう
  # （実測では、2 人しかいない様式が高さ 2,994 の枠になって数十人を巻き込んでいた）。
  # 縦 1 列に並ぶ図では折り返しが無いので、この割り直しは働かない。
  defp segments(members, all) do
    members
    |> Enum.sort_by(&index_of/1)
    |> runs()
    |> Enum.flat_map(&split_unless_pure(&1, all))
  end

  # 並びが続いている者をひと続きにする
  defp runs([]), do: []

  defp runs([first | rest]) do
    {last_run, done} =
      Enum.reduce(rest, {[first], []}, fn node, {[previous | _] = run, done} ->
        if index_of(node) - index_of(previous) <= @cluster_index_gap,
          do: {[node | run], done},
          else: {[node], [Enum.reverse(run) | done]}
      end)

    Enum.reverse([Enum.reverse(last_run) | done])
  end

  defp split_unless_pure(run, all) do
    if pure?(run, all),
      do: [run],
      else: run |> Enum.group_by(& &1.y) |> Enum.map(fn {_y, row} -> row end)
  end

  # 囲いの中に、その様式の人がどれくらい入っているか
  defp pure?(run, all) do
    %{x: x, y: y, width: width, height: height} = box(nil, run)

    inside =
      Enum.count(all, fn node ->
        node.x >= x and node.x <= x + width and node.y >= y and node.y <= y + height
      end)

    inside == 0 or length(run) / inside >= @cluster_purity
  end

  defp index_of(node), do: Map.get(node, :index) || 0

  defp box(style, members) do
    lefts = for n <- members, do: n.x - radius_of(n)
    rights = for n <- members, do: n.x + radius_of(n)

    # 下側は年代の札のぶんまで見る（枠が札を切ると、誰の年代か分からなくなる）
    tops = for n <- members, do: n.y - radius_of(n)
    bottoms = for n <- members, do: n.y + radius_of(n) + 20

    x = Enum.min(lefts) - @cluster_padding
    y = Enum.min(tops) - @cluster_padding

    %{
      style: style,
      members: length(members),
      x: x,
      y: y,
      width: Enum.max(rights) + @cluster_padding - x,
      height: Enum.max(bottoms) + @cluster_padding - y
    }
  end

  # 枠を測るときの半径。大きさが決まる前のノード（`sized/2` を通す前）は、
  # その図の升目から出る最小の丸として扱う
  defp radius_of(node), do: Map.get(node, :radius) || cell_of(node) * @min_radius_ratio

  # 古い形（様式を 1 つしか持たない図）も読めるようにしておく
  defp styles_of(node) do
    case Map.get(node, :styles) do
      list when is_list(list) -> list
      _ -> List.wrap(node.note)
    end
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
      Map.merge(
        node,
        scale(fame_ratio(Map.get(fame, node.article, 0), top), cell_of(node), node.name)
      )
    end)
  end

  def sized(nodes, _fame),
    do: Enum.map(nodes, &Map.merge(&1, scale(0.0, cell_of(&1), &1.name)))

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
  defp scale(ratio, cell, name) do
    radius = cell * (@min_radius_ratio + (@max_radius_ratio - @min_radius_ratio) * ratio)
    font = cell * (@min_name_ratio + (@max_name_ratio - @min_name_ratio) * ratio)
    height = max(font * @label_line_height, radius * 2)

    %{
      # 大きさの物差しは残す（描く数を絞るのも、並べ替えるのもこれで決める）
      radius: max(round(radius), 2),
      name_size: Float.round(font, 1),
      sub_size: Float.round(max(font * @sub_size_ratio, @min_sub_size), 1),
      # 名前が収まる札の大きさ。**丸だと名前がはみ出す** —— 円は角へ行くほど
      # 内側が痩せるので、横に長い名前を入れるには不釣り合いに大きな円が要る
      label_width: Float.round(max(text_width(name, font) + font * @label_padding, height), 1),
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
          work: tag_value(tags, @work_prefix),
          # 出典（Wikipedia の記事）。知名度を引くのと、絵を探すのに使う
          article: article_title(doc),
          kind: :artist
        }
      ]
    end
  end

  defp to_node(_doc), do: []

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
  defp layout([], _edges), do: []

  defp layout(nodes, edges) do
    %{columns: columns, x_step: x_step, y_step: y_step, cell: cell} = grid(length(nodes))

    # 行は生年順のまま。**横の並びだけ、繋がりの形で決め直す**
    rows = Enum.group_by(Enum.with_index(nodes), fn {_node, i} -> div(i, columns) end)
    initial = Map.new(Enum.with_index(nodes), fn {node, i} -> {node.id, rem(i, columns)} end)
    columns_by_id = reorder(rows, initial, adjacency(edges))

    Enum.with_index(nodes, fn node, index ->
      Map.merge(node, %{
        x: @gutter + (Map.fetch!(columns_by_id, node.id) + 0.5) * x_step,
        y: (div(index, columns) + 0.5) * y_step,
        # 丸と字の大きさは升目に対する比で決めるので、1 人ずつ持たせる
        cell: cell,
        # 並び順（生年順）。枠を切るときに「隣り合っているか」の判断に使う
        index: index
      })
    end)
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

  defp canvas_height(count), do: grid(count).height
end
