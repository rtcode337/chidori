defmodule Tazuna.Themes.Graph do
  @moduledoc """
  トピックの網を図にするところ。**置き場所を決めるだけ**で、描くのは画面です。

  **円環に並べます。** 力で散らす作りにしていないのは、開くたびに形が変わると
  「昨日と同じ図か」が読めなくなるためです —— 並びは分野ごとにまとめ、同じ分野の
  中は名前の順にするので、**同じ材料なら同じ図**になります。

  **丸の大きさは、直近の窓に入る記事の件数です**（機械が数えます）。件数の合計だと、
  昔よく出てきた語がいつまでも大きいままになる —— 図で真っ先に読みたいのは
  「いま何が太いか」です。**いちばん動いている語を基準に、そこからの割合**で描くので、
  静かな日でも図は潰れません。

  **線は「一緒に出てきた回数」です。** AI に関連を書かせると思いついた相手が並ぶので、
  一度も一緒に出ていない組が線になりました —— 一緒に出た回数は数えられるのだから
  数えます。太さもその回数です。

  **先の無い線は引きません。** AI が存在しないトピックを指すことはあるので、
  両端が図にあるものだけを線にします（整える回が直すまで、図は黙って耐えます）。
  """

  @width 960
  @height 620
  @radius 240
  @center %{x: 480, y: 300}

  # 図に置ける上限。**名前を丸の中に入れるので、置ける数は前より少ない** ——
  # 円周を頭数で割った幅より丸が大きいと、隣と重なって名前が読めなくなる
  @max_nodes 16

  # 丸の大きさの幅。**下は 0 件のときの大きさ** —— 静かになった語も図に残す。
  # **下を上げてあるのは、名前を中に入れるから** —— 小さすぎる丸は、字を縮めても
  # 数文字しか入らず、読めない名前が並ぶだけになる。
  # **上は円周に並べられる幅で決まる**（半径 240 の円に 16 個なら 1 つあたり 94）
  @min_radius 24
  @max_radius 42

  # 名前の字の大きさ。**上は読みやすさ、下はこれ以上小さくしても読めない線**
  @max_font 14.0
  @min_font 8.5

  # 丸に内接する四角の一辺は、直径のおよそ 0.7 倍。**名前はそこへ収める**
  @inner 0.7

  # 文字の幅（字の大きさに対する比）。**和字と英数字で倍ちがう** —— 同じ比で見ると、
  # 英数字の名前が実際より広く見積もられ、入るはずの「Kubernetes」が削られる
  @wide_glyph 1.0
  @narrow_glyph 0.56

  # 線の太さの幅。一緒に出てきた回数をそのまま太さにする
  @min_stroke 1.0
  @max_stroke 4.5

  @doc "図の大きさ（画面はこの座標系で描きます）。"
  def size, do: %{width: @width, height: @height}

  @doc """
  トピックの一覧から、図に出す丸と線を組み立てます。

  **いま動いている順に選びます** —— 図に置ける数には限りがあるので、直近の窓に
  入る件数の多いものから出します（同じ数なら件数の合計、それも同じなら名前の順。
  回すたびに並びが変わらないように）。
  """
  def build(themes, opts \\ []) do
    limit = Keyword.get(opts, :limit, @max_nodes)

    nodes =
      themes
      |> Enum.sort_by(&{-&1.recent, -&1.docs, &1.name})
      |> Enum.take(limit)
      |> Enum.sort_by(&{&1.field || "～", &1.name})

    shown = MapSet.new(nodes, & &1.name)
    links = links(themes, shown)
    degrees = degrees(links)
    edges = Enum.filter(links, &(MapSet.member?(shown, &1.from) and MapSet.member?(shown, &1.to)))
    placed = place(nodes, degrees, busiest(nodes))
    at = Map.new(placed, &{&1.name, &1})

    %{
      nodes: placed,
      edges: Enum.map(edges, &line(&1, at)),
      width: @width,
      height: @height,
      hidden: max(length(themes) - length(placed), 0)
    }
  end

  # 線。**同じ 2 つを結ぶ線は 1 本**にします（一緒に出てくる語は両側に入る）
  defp links(themes, names) do
    from_related =
      for theme <- themes,
          related <- theme.related,
          related.to != theme.name,
          MapSet.member?(names, related.to),
          do: %{from: theme.name, to: related.to, n: related.n, kind: :related}

    from_parent =
      for theme <- themes,
          parent = theme.parent,
          parent != theme.name,
          MapSet.member?(names, parent),
          do: %{from: parent, to: theme.name, n: 0, kind: :parent}

    (from_parent ++ from_related)
    |> Enum.uniq_by(&Enum.sort([&1.from, &1.to]))
  end

  defp degrees(links) do
    Enum.reduce(links, %{}, fn link, counted ->
      counted
      |> Map.update(link.from, 1, &(&1 + 1))
      |> Map.update(link.to, 1, &(&1 + 1))
    end)
  end

  # いちばん動いている語の件数。**そこからの割合で描く** —— 決め打ちの大きさだと、
  # 静かな日は全部が小さく、沸いた日は全部が大きくなる
  defp busiest(nodes), do: Enum.reduce(nodes, 0, &max(&1.recent, &2))

  defp place([], _degrees, _busiest), do: []

  defp place(nodes, degrees, busiest) do
    count = length(nodes)

    nodes
    |> Enum.with_index()
    |> Enum.map(fn {node, index} ->
      # 真上から時計回り。**1 つだけのときは真ん中**（円に 1 点だけ置くと寂しい）
      angle = index / count * 2 * :math.pi() - :math.pi() / 2
      radius = if count == 1, do: 0, else: @radius
      degree = Map.get(degrees, node.name, 0)

      r = size(node, busiest)
      {lines, font} = label(node.name, r)

      Map.merge(node, %{
        x: @center.x + radius * :math.cos(angle),
        y: @center.y + radius * :math.sin(angle),
        r: r,
        degree: degree,
        hue: hue(node.field),
        # **名前は丸の中**。外へ逃がしていた頃は、丸と名前を目で結び直すことになった
        # （線の上の字とも紛れる）。入り切らない名前は折って、それでも入らなければ
        # 端を落とす —— 全部を出そうとして字を小さくすると、どれも読めなくなる
        lines: lines,
        font: font,
        # 行の高さぶん上へ寄せて、丸の中心で釣り合わせる
        label_y: -(length(lines) - 1) * font * 0.6
      })
    end)
  end

  @doc false
  # 名前を丸の中に収める。返すのは**行の並びと字の大きさ**。
  #
  # **折るのは 2 行まで。** 3 行にすると、丸を大きくしても字が小さくなるだけで
  # 読みやすさが戻らない（1 行と 2 行を両方あてて、大きく書けるほうを採ります）。
  def label(name, r) do
    room = 2 * r * @inner
    name = String.trim(name)

    # 1 行と 2 行を両方あてて、**大きく書けるほう**を採る
    [{lines, font} | _rest] =
      [[name], wrap(name)]
      |> Enum.uniq()
      |> Enum.map(&{&1, fits(&1, room)})
      |> Enum.sort_by(fn {lines, font} -> {-font, length(lines)} end)

    if font >= @min_font do
      {lines, Float.round(font, 1)}
    else
      # これ以上小さくしても読めないので、**字の大きさを守って名前を削る**。
      # 削るのは 1 行に畳んでから —— 2 行とも削ると、どちらも途中で切れた断片になる
      {[clip(name, room)], @min_font}
    end
  end

  # その行数で書けるいちばん大きい字。**幅と高さの厳しいほう**で決まる
  defp fits(lines, room) do
    widest = lines |> Enum.map(&width/1) |> Enum.max(fn -> 1.0 end)

    Enum.min([room / widest, room / (length(lines) * 1.2), @max_font])
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

  # 削る。**入る幅まで落としてから「…」を足す**
  defp clip(name, room) do
    room = room / @min_font

    name
    |> String.graphemes()
    |> Enum.reduce_while({"", 0.0}, fn char, {kept, used} ->
      step = if char =~ ~r/^[\x20-\x7E]$/, do: @narrow_glyph, else: @wide_glyph

      if used + step + @wide_glyph > room,
        do: {:halt, {kept, used}},
        else: {:cont, {kept <> char, used + step}}
    end)
    |> then(fn {kept, _used} -> if kept == name, do: name, else: kept <> "…" end)
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

  # 丸の大きさ。**直近の件数を、いちばん動いている語との割合で**。
  # **0 件でも消さずに小さく描く** —— 静かになったことも、図から読めるほうがよい
  defp size(_node, 0), do: @min_radius

  defp size(node, busiest) do
    @min_radius + (@max_radius - @min_radius) * node.recent / busiest
  end

  # 分野の色。**名前から決めます** —— 分野は増えるので、一覧を持つと足すたびに
  # 色の無い分野が出ます
  defp hue(nil), do: nil
  defp hue(""), do: nil
  defp hue(field), do: rem(:erlang.phash2(field), 360)

  defp line(link, at) do
    from = at[link.from]
    to = at[link.to]

    %{
      from: link.from,
      to: link.to,
      n: link.n,
      # **太さは一緒に出てきた回数**。上下のつながりは数を持たないので細いまま
      width: stroke(link.n),
      kind: link.kind,
      x1: from.x,
      y1: from.y,
      x2: to.x,
      y2: to.y,
      # 札は線の真ん中。**内側へ寄せる** —— 円周の近くは丸と札で混み合う
      label_x: (from.x + to.x) / 2 * 0.86 + @center.x * 0.14,
      label_y: (from.y + to.y) / 2 * 0.86 + @center.y * 0.14
    }
  end

  # 太さ。**上は早めに頭打ちにする** —— 1 つ飛び抜けた組があると、他の線が
  # 全部同じ細さに潰れる
  defp stroke(n) when is_integer(n) and n > 0 do
    @min_stroke + (@max_stroke - @min_stroke) * min(n, 12) / 12
  end

  defp stroke(_n), do: @min_stroke
end
