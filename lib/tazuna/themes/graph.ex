defmodule Tazuna.Themes.Graph do
  @moduledoc """
  トピックの網を図にするところ。**置き場所を決めるだけ**で、描くのは画面です。

  **全部のトピックを置きます。** 図は関連図と同じく引きずって動かし、つまんで
  拡大するので、画面に収める数の上限は要りません —— 収めるために間引いていた頃は、
  135 件のうち 16 件しか図に出ませんでした。

  **親子はクラスタで表します。** 親（`親:` のタグで上位に挙がった語）の札を真ん中に
  置き、子をそのまわりに詰めて、薄い角丸の枠で囲みます。孫も同じ形で、子のまわりに入れ子に
  なります。線で結ぶより、どれが同じ仲間かが一目で読めます。

  **いちばん動いている語のクラスタを真ん中に置き**、ほかのクラスタはそのまわりへ、
  動いている順に外へ詰めていきます。画面は最初そこを真ん中にして開くので、
  そこから引きずって周りを見に行く形になります（`focus`）。

  **置き方は決まった手順で詰めるだけ**（力で散らさない）。開くたびに形が変わると
  「昨日と同じ図か」が読めなくなるためで、**同じ材料なら同じ図**になります。
  詰め方は、置いたものの上下左右に接する位置のうち、ほかと重ならず真ん中に近いところ。
  **札もクラスタも長方形のまま詰めます**（囲む円で詰めると、横長の札の上下が空いて
  図が間延びした）。

  **話題は角丸の札で描き、札の大きさ（字の大きさ）は直近の窓に入る記事の件数です**
  （機械が数えます）。丸にしていた頃は、入る字数が丸の大きさで決まって名前が切れ、
  大きさの差も 1.75 倍しかなく、どれが話題なのかが一目で読めませんでした。件数の合計だと、
  昔よく出てきた語がいつまでも大きいままになる —— 図で真っ先に読みたいのは
  「いま何が太いか」です。**いちばん動いている語を基準に、そこからの割合**で描くので、
  静かな日でも図は潰れません。

  **線は全部出します**（網であることが見えないと、話題が箱に並んでいるだけに見える）。
  数百本あるので画面は薄く描き、札を押すとその話題の線だけを濃く残します。
  **線の中身は「一緒に出てきた回数」です。** AI に関連を書かせると思いついた相手が並ぶので、
  一度も一緒に出ていない組が線になりました —— 一緒に出た回数は数えられるのだから
  数えます。太さもその回数です。**先の無い線は引きません**（AI が存在しないトピックを
  指すことはあるので、両端が図にあるものだけを線にします）。
  """

  # 札どうしの隙間・クラスタの縁と中身の隙間・クラスタどうしの隙間（図の単位）
  @gap 6
  @pad 12
  @cluster_gap 24

  # 図の縁の余白
  @margin 40

  # クラスタの見出し（枠の左上に書く上位の話題の名前）の字の大きさと、そのぶん空ける高さ。
  # **何のクラスタかを枠に書く** —— 枠だけだと、中の札のどれが上位の話題なのかを
  # 大きさや位置から推し量ることになる
  @cluster_font 13
  @cluster_label_h 20

  # 親をたどる深さの上限。**AI が親を輪にすることがある**ので、そこで止める
  @max_depth 12

  # 札の字の大きさ。**大きさの差は字で付ける**（札の幅と高さは名前と字から決まる）。
  # 下は 0 件の話題で、読める最小。上はいちばん動いている話題 —— **差を大きく取る**
  # （24〜42 の丸では 1.75 倍しか違わず、どれが話題なのかが一目で読めなかった）
  @min_font 11.0
  @max_font 34.0

  # 札の余白（字の大きさに対する比）と角の丸み
  @pad_x 0.8
  @pad_y 0.45
  @line_height 1.25

  # これより幅のある名前は 2 行に折る（和字の字数ぶん）。**折るのは 2 行まで**
  @wrap_at 9

  # 文字の幅（字の大きさに対する比）。**和字と英数字で倍ちがう** —— 同じ比で見ると、
  # 英数字の名前が実際より広く見積もられ、入るはずの「Kubernetes」が削られる
  @wide_glyph 1.0
  @narrow_glyph 0.56

  # 線の太さの幅。一緒に出てきた回数をそのまま太さにする
  @min_stroke 1.0
  @max_stroke 4.5

  @doc """
  トピックの一覧から、図に出す札・線・クラスタを組み立てます。

  返すのは `nodes`（札）・`edges`（線）・`clusters`（親子の囲み。外側から順）・
  `width` / `height`（図の大きさ）・`focus`（最初に真ん中へ置く札の座標）。
  """
  def build(themes) do
    busiest = Enum.reduce(themes, 0, &max(&1.recent, &2))

    by_name =
      themes
      |> Enum.uniq_by(& &1.name)
      |> Map.new(&{&1.name, sized(&1, busiest)})

    parents = parents_of(by_name)
    children = children_of(parents, by_name)
    roots = by_name |> Map.keys() |> Enum.reject(&Map.has_key?(parents, &1))

    case Enum.sort_by(Map.values(by_name), &rank/1) do
      [] ->
        %{nodes: [], edges: [], clusters: [], width: 0, height: 0, focus: nil}

      [top | _rest] ->
        focus_root = root_of(top.name, parents)
        packed = Map.new(roots, &{&1, pack(&1, children, by_name)})

        order =
          [
            focus_root
            | roots |> List.delete(focus_root) |> Enum.sort_by(&weight(&1, packed, by_name))
          ]

        placed =
          order
          |> Enum.map(&%{name: &1, w: packed[&1].w, h: packed[&1].h})
          |> pack_rects(@cluster_gap)

        {nodes, clusters} =
          Enum.reduce(placed, {[], []}, fn %{name: name, x: x, y: y}, {nodes, clusters} ->
            {more_nodes, more_clusters} = absolute(packed[name], x, y)
            {nodes ++ more_nodes, clusters ++ more_clusters}
          end)

        # 置いた位置に、札の大きさ・名前・色を載せ直す
        nodes = Enum.map(nodes, &Map.merge(by_name[&1.name], &1))
        frame(nodes, clusters, links(themes, by_name), top.name)
    end
  end

  # 並びの鍵。**いま動いている順**（同じ数なら件数の合計、それも同じなら名前の順。
  # 回すたびに並びが変わらないように）
  defp rank(theme), do: {-theme.recent, -theme.docs, theme.name}

  # クラスタの並びの鍵。**中身ぜんぶの動きで比べる**（親だけ静かで子が沸いていることがある）
  defp weight(root, packed, by_name) do
    total = packed[root].members |> Enum.map(&by_name[&1.name].recent) |> Enum.sum()
    {-total, -by_name[root].docs, root}
  end

  defp sized(theme, busiest) do
    font = font_of(theme, busiest)
    card = card(theme.name, font)

    Map.merge(theme, %{
      hue: hue(theme.field),
      w: card.w,
      h: card.h,
      lines: card.lines,
      font: font,
      # 行の高さぶん上へ寄せて、札の中心で釣り合わせる
      label_y: -(length(card.lines) - 1) * font * @line_height / 2
    })
  end

  # 親。**図にある語を指しているものだけ**（無い親を指されたら根として扱う）。
  # **輪になっていたら切る** —— たどって自分に戻る親は、無いものとみなす
  defp parents_of(by_name) do
    raw =
      for {name, theme} <- by_name,
          parent = theme.parent,
          parent != name,
          Map.has_key?(by_name, parent),
          into: %{},
          do: {name, parent}

    raw
    |> Enum.reject(fn {name, _parent} -> loops?(name, raw) end)
    |> Map.new()
  end

  defp loops?(name, parents), do: loops?(Map.get(parents, name), parents, name, 0)
  defp loops?(nil, _parents, _start, _depth), do: false
  defp loops?(_at, _parents, _start, depth) when depth > @max_depth, do: true
  defp loops?(start, _parents, start, _depth), do: true

  defp loops?(at, parents, start, depth),
    do: loops?(Map.get(parents, at), parents, start, depth + 1)

  defp children_of(parents, by_name) do
    parents
    |> Enum.group_by(fn {_child, parent} -> parent end, fn {child, _parent} -> child end)
    |> Map.new(fn {parent, kids} -> {parent, Enum.sort_by(kids, &rank(by_name[&1]))} end)
  end

  defp root_of(name, parents) do
    case Map.get(parents, name) do
      nil -> name
      parent -> root_of(parent, parents)
    end
  end

  # 1 つのクラスタを詰める。**親の札を最初に置き**、子（とその下のクラスタ）を
  # そのまわりへ。返すのは、囲みの中心を原点にした中身の位置と、囲みの幅と高さ
  defp pack(name, children, by_name) do
    node = by_name[name]
    kids = Enum.map(Map.get(children, name, []), &pack(&1, children, by_name))

    if kids == [] do
      %{name: name, w: node.w, h: node.h, members: [%{name: name, x: 0.0, y: 0.0}], clusters: []}
    else
      placed =
        [
          %{name: name, w: node.w, h: node.h, kid: nil}
          | Enum.map(kids, &%{name: &1.name, w: &1.w, h: &1.h, kid: &1})
        ]
        |> pack_rects(@gap)

      # 囲みは詰めたものぜんぶの外枠に余白を足したもの。**中心を原点に取り直す**
      {left, top, right, bottom} = bounds(placed)
      cx = (left + right) / 2

      # 見出しのぶん枠の上を空けるので、中身は枠の真ん中より下へずらす
      cy = (top + bottom) / 2 - @cluster_label_h / 2

      members =
        Enum.flat_map(placed, fn
          %{kid: nil, x: x, y: y} ->
            [%{name: name, x: x - cx, y: y - cy}]

          %{kid: kid, x: x, y: y} ->
            Enum.map(kid.members, &%{&1 | x: &1.x + x - cx, y: &1.y + y - cy})
        end)

      inner =
        Enum.flat_map(placed, fn
          %{kid: nil} ->
            []

          %{kid: kid, x: x, y: y} ->
            Enum.map(kid.clusters, &%{&1 | x: &1.x + x - cx, y: &1.y + y - cy})
        end)

      label_w = String.length(name) * @cluster_font + 2 * @pad
      w = max(right - left + 2 * @pad, label_w)
      h = bottom - top + 2 * @pad + @cluster_label_h
      own = %{name: name, x: 0.0, y: 0.0, w: w, h: h, font: @cluster_font}
      %{name: name, w: w, h: h, members: members, clusters: [own | inner]}
    end
  end

  defp bounds(rects) do
    {
      rects |> Enum.map(&(&1.x - &1.w / 2)) |> Enum.min(),
      rects |> Enum.map(&(&1.y - &1.h / 2)) |> Enum.min(),
      rects |> Enum.map(&(&1.x + &1.w / 2)) |> Enum.max(),
      rects |> Enum.map(&(&1.y + &1.h / 2)) |> Enum.max()
    }
  end

  # クラスタを図の座標へ。**囲みは外側から順**に並べる（内側を上に描くため）
  defp absolute(packed, x, y) do
    nodes = Enum.map(packed.members, &%{name: &1.name, x: &1.x + x, y: &1.y + y})
    clusters = Enum.map(packed.clusters, &%{&1 | x: &1.x + x, y: &1.y + y})
    {nodes, clusters}
  end

  @doc false
  # 長方形を詰める。**並べた順に 1 つずつ、真ん中に近いところへ**。
  # 置き場所の候補は、置いたものの上下左右に隙間ぶん離して接する位置（辺の真ん中・
  # 両端に揃えた 3 通りずつ）。そのうちほかと重ならず、原点にいちばん近いものを採る。
  # **最初の 1 つは原点**。
  #
  # **円で詰めない。** 札は横に長いので、囲む円で詰めると上下が空き、クラスタも
  # 図ぜんたいも間延びした（開いた画面にほとんど札が入らなかった）
  def pack_rects(rects, gap) do
    Enum.reduce(rects, [], fn rect, placed ->
      {x, y} = spot(rect, placed, gap)
      placed ++ [Map.merge(rect, %{x: x * 1.0, y: y * 1.0})]
    end)
  end

  defp spot(_rect, [], _gap), do: {0.0, 0.0}

  defp spot(rect, placed, gap) do
    candidates =
      for p <- placed,
          point <- beside(p, rect, gap),
          free?(point, rect, placed, gap),
          do: point

    case candidates do
      [] ->
        # 候補が無い（まず起きない）ときは、いちばん外の右へ
        {_left, _top, right, _bottom} = bounds(placed)
        {right + gap + rect.w / 2, 0.0}

      _found ->
        Enum.min_by(candidates, fn {x, y} -> {Float.round(x * x + y * y, 6), x, y} end)
    end
  end

  # p の上下左右に接する位置。それぞれ辺の真ん中と両端に揃えた 3 通り
  defp beside(p, r, gap) do
    right = p.x + p.w / 2 + gap + r.w / 2
    left = p.x - p.w / 2 - gap - r.w / 2
    below = p.y + p.h / 2 + gap + r.h / 2
    above = p.y - p.h / 2 - gap - r.h / 2
    ys = [p.y, p.y - p.h / 2 + r.h / 2, p.y + p.h / 2 - r.h / 2]
    xs = [p.x, p.x - p.w / 2 + r.w / 2, p.x + p.w / 2 - r.w / 2]

    for(y <- ys, x <- [right, left], do: {x, y}) ++ for(x <- xs, y <- [below, above], do: {x, y})
  end

  defp free?({x, y}, r, placed, gap) do
    Enum.all?(placed, fn c ->
      abs(x - c.x) >= (c.w + r.w) / 2 + gap - 0.001 or
        abs(y - c.y) >= (c.h + r.h) / 2 + gap - 0.001
    end)
  end

  # 図の大きさを決め、左上が余白ぶんの位置に来るようにずらす
  defp frame(placed, clusters, links, focus_name) do
    by_name = Map.new(placed, &{&1.name, &1})

    {left, top, right, bottom} = bounds(clusters ++ placed)
    shift_x = @margin - left
    shift_y = @margin - top

    move = fn item ->
      %{item | x: Float.round(item.x + shift_x, 1), y: Float.round(item.y + shift_y, 1)}
    end

    %{
      nodes: Enum.map(placed, &Map.merge(&1, move.(&1))),
      clusters: Enum.map(clusters, move),
      edges: Enum.map(links, &line(&1, by_name, shift_x, shift_y)),
      width: Float.round(right - left + 2 * @margin, 1),
      height: Float.round(bottom - top + 2 * @margin, 1),
      focus: by_name[focus_name] |> move.() |> Map.take([:x, :y])
    }
  end

  # 線。**同じ 2 つを結ぶ線は 1 本**にします（一緒に出てくる語は両側に入る）
  defp links(themes, by_name) do
    found =
      for theme <- themes,
          related <- theme.related,
          related.to != theme.name,
          Map.has_key?(by_name, related.to),
          Map.has_key?(by_name, theme.name) do
        [from, to] = Enum.sort([theme.name, related.to])
        %{from: from, to: to, n: related.n}
      end

    Enum.uniq_by(found, &{&1.from, &1.to})
  end

  defp line(link, at, shift_x, shift_y) do
    from = at[link.from]
    to = at[link.to]

    %{
      from: link.from,
      to: link.to,
      n: link.n,
      # **太さは一緒に出てきた回数**
      width: stroke(link.n),
      x1: Float.round(from.x + shift_x, 1),
      y1: Float.round(from.y + shift_y, 1),
      x2: Float.round(to.x + shift_x, 1),
      y2: Float.round(to.y + shift_y, 1)
    }
  end

  @doc false
  # 名前の札。返すのは**行の並びと、札の幅と高さ**。
  #
  # **名前は削らない。** 丸の中に収めていた頃は、入る字数が丸の大きさで決まり、
  # 小さい丸では名前が「GitHu…」のように切れた。札なら幅を名前に合わせられる。
  # 長い名前だけ 2 行に折る（横に長すぎる札は、並べたときに隣を押しのける）
  def card(name, font) do
    name = String.trim(name)
    lines = if width(name) > @wrap_at, do: wrap(name), else: [name]
    widest = lines |> Enum.map(&width/1) |> Enum.max(fn -> 1.0 end)

    %{
      lines: lines,
      w: Float.round(widest * font + 2 * @pad_x * font, 1),
      h: Float.round(length(lines) * font * @line_height + 2 * @pad_y * font, 1)
    }
  end

  # その行の幅（字の大きさ 1 に対して）。和字は 1、英数字はおよそ半分
  defp width(line) do
    line
    |> String.graphemes()
    |> Enum.reduce(0.0, fn char, total ->
      total + if char =~ ~r/^[\x20-\x7E]$/, do: @narrow_glyph, else: @wide_glyph
    end)
    |> max(1.0)
  end

  # 折り方。**3 文字までは折らない**（それ以上短くすると、折る意味が無い）。
  # 折ったほうが大きく書けるかは `label/2` が両方あてて決めます —— 同じ大きさで
  # 書けるなら 1 行を選ぶので、ここでは「折った形」を作るだけです
  defp wrap(name) do
    length = String.length(name)

    if length <= 3 do
      [name]
    else
      # 真ん中で折る。**区切りが近くにあればそこで**（語の途中で折らずに済む）
      at = break_at(name, div(length + 1, 2))
      [String.slice(name, 0, at), String.slice(name, at, length - at)]
    end
  end

  # 折る位置。真ん中の前後 2 文字に区切りがあれば、そこで折る
  defp break_at(name, middle) do
    Enum.find(sorted_around(middle), middle, fn at ->
      at > 0 and at < String.length(name) and String.at(name, at) in [" ", "-", "・", "/"]
    end)
  end

  defp sorted_around(middle),
    do: Enum.sort_by(max(middle - 2, 1)..(middle + 2), &abs(&1 - middle))

  # 字の大きさ。**直近の件数を、いちばん動いている語との割合で**。
  # **0 件でも消さずに小さく描く** —— 静かになったことも、図から読めるほうがよい
  defp font_of(_node, 0), do: @min_font

  defp font_of(node, busiest) do
    Float.round(@min_font + (@max_font - @min_font) * node.recent / busiest, 1)
  end

  # 分野の色。**名前から決めます** —— 分野は増えるので、一覧を持つと足すたびに
  # 色の無い分野が出ます
  defp hue(nil), do: nil
  defp hue(""), do: nil
  defp hue(field), do: rem(:erlang.phash2(field), 360)

  # 太さ。**上は早めに頭打ちにする** —— 1 つ飛び抜けた組があると、他の線が
  # 全部同じ細さに潰れる
  defp stroke(n) when is_integer(n) and n > 0 do
    @min_stroke + (@max_stroke - @min_stroke) * min(n, 12) / 12
  end

  defp stroke(_n), do: @min_stroke
end
