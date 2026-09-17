defmodule Tazuna.Themes.Graph do
  @moduledoc """
  トピックの網を図にするところ。**置き場所を決めるだけ**で、描くのは画面です。

  **円環に並べます。** 力で散らす作りにしていないのは、開くたびに形が変わると
  「昨日と同じ図か」が読めなくなるためです —— 並びは分野ごとにまとめ、同じ分野の
  中は名前の順にするので、**同じ材料なら同じ図**になります。

  **丸の大きさはつながりの数です。** 記事の件数はこの収集が持っていないので、
  持っている事実のうち「その話題がどれだけ他とつながっているか」で決めます。

  **先の無い線は引きません。** AI が存在しないトピックを指すことはあるので、
  両端が図にあるものだけを線にします（整える回が直すまで、図は黙って耐えます）。
  """

  @width 960
  @height 620
  @radius 232
  @center %{x: 480, y: 300}

  # 図に置ける上限。増やすと札が重なって読めなくなる
  @max_nodes 24

  @doc "図の大きさ（画面はこの座標系で描きます）。"
  def size, do: %{width: @width, height: @height}

  @doc """
  トピックの一覧から、図に出す丸と線を組み立てます。

  **つながりの多い順に選びます** —— 図に置ける数には限りがあるので、網の真ん中に
  いるものから出します（同じ数なら名前の順。回すたびに並びが変わらないように）。
  """
  def build(themes, opts \\ []) do
    limit = Keyword.get(opts, :limit, @max_nodes)
    names = MapSet.new(themes, & &1.name)
    links = links(themes, names)
    degrees = degrees(links)

    nodes =
      themes
      |> Enum.sort_by(&{-Map.get(degrees, &1.name, 0), &1.name})
      |> Enum.take(limit)
      |> Enum.sort_by(&{&1.field || "～", &1.name})

    shown = MapSet.new(nodes, & &1.name)
    edges = Enum.filter(links, &(MapSet.member?(shown, &1.from) and MapSet.member?(shown, &1.to)))
    placed = place(nodes, degrees)
    at = Map.new(placed, &{&1.name, &1})

    %{
      nodes: placed,
      edges: Enum.map(edges, &line(&1, at)),
      width: @width,
      height: @height,
      hidden: max(length(themes) - length(placed), 0)
    }
  end

  # 線。**同じ 2 つを結ぶ線は 1 本**にします（両側から「関連」を書かれることがある）
  defp links(themes, names) do
    from_related =
      for theme <- themes,
          related <- theme.related,
          related.to != theme.name,
          MapSet.member?(names, related.to),
          do: %{from: theme.name, to: related.to, note: related.note, kind: :related}

    from_parent =
      for theme <- themes,
          parent = theme.parent,
          parent != theme.name,
          MapSet.member?(names, parent),
          do: %{from: parent, to: theme.name, note: "", kind: :parent}

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

  defp place([], _degrees), do: []

  defp place(nodes, degrees) do
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
        r: 16 + min(degree, 8) * 2.5,
        degree: degree,
        hue: hue(node.field),
        # 札は円の外側へ逃がす（丸の上に重ねると、名前も数字も読めない）
        label_x: @center.x + (radius + 34) * :math.cos(angle),
        label_y: @center.y + (radius + 34) * :math.sin(angle),
        anchor: anchor(:math.cos(angle))
      })
    end)
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
      note: link.note,
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
end
