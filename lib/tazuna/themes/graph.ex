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
  @radius 232
  @center %{x: 480, y: 300}

  # 図に置ける上限。増やすと札が重なって読めなくなる
  @max_nodes 24

  # 丸の大きさの幅。**下は 0 件のときの大きさ** —— 静かになった語も図に残す
  @min_radius 12
  @max_radius 36

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

      Map.merge(node, %{
        x: @center.x + radius * :math.cos(angle),
        y: @center.y + radius * :math.sin(angle),
        r: size(node, busiest),
        degree: degree,
        hue: hue(node.field),
        # 札は円の外側へ逃がす（丸の上に重ねると、名前も数字も読めない）
        label_x: @center.x + (radius + 34) * :math.cos(angle),
        label_y: @center.y + (radius + 34) * :math.sin(angle),
        anchor: anchor(:math.cos(angle))
      })
    end)
  end

  # 丸の大きさ。**直近の件数を、いちばん動いている語との割合で**。
  # **0 件でも消さずに小さく描く** —— 静かになったことも、図から読めるほうがよい
  defp size(_node, 0), do: @min_radius

  defp size(node, busiest) do
    @min_radius + (@max_radius - @min_radius) * node.recent / busiest
  end

  defp anchor(cos) when cos > 0.25, do: "start"
  defp anchor(cos) when cos < -0.25, do: "end"
  defp anchor(_cos), do: "middle"

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
