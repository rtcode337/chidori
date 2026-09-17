defmodule Tazuna.Themes.GraphTest do
  @moduledoc """
  トピックの網の描き方。見ているのは、**先の無い線を引かないこと**と、
  **同じ材料なら同じ図になること**です。
  """

  use ExUnit.Case, async: true

  alias Tazuna.Themes.Graph

  defp theme(name, opts \\ []) do
    %{
      name: name,
      note: "説明。",
      parent: opts[:parent],
      field: opts[:field],
      related: opts[:related] || [],
      tags: []
    }
  end

  defp related(to, note \\ ""), do: %{to: to, note: note}

  test "先の無い線は引かない" do
    # AI が存在しないトピックを指すことはある。整える回が直すまで、図は黙って耐える
    themes = [theme("AI", related: [related("まだ無い語")]), theme("MCP")]

    assert Graph.build(themes).edges == []
  end

  test "両側から書かれたつながりは 1 本にする" do
    themes = [
      theme("AI", related: [related("MCP", "道具の口")]),
      theme("MCP", related: [related("AI")])
    ]

    assert [edge] = Graph.build(themes).edges
    assert Enum.sort([edge.from, edge.to]) == ["AI", "MCP"]
  end

  test "上下のつながりは、横のつながりと分けて出す" do
    themes = [theme("AI"), theme("AIエージェント", parent: "AI")]

    assert [edge] = Graph.build(themes).edges
    assert edge.kind == :parent
    assert edge.from == "AI"
  end

  test "丸の大きさは、つながりの数で決まる" do
    # 記事の件数はこの収集が持っていない。持っている事実で大きさを決める
    themes = [
      theme("AI", related: [related("MCP"), related("LLM")]),
      theme("MCP"),
      theme("LLM")
    ]

    nodes = Map.new(Graph.build(themes).nodes, &{&1.name, &1})

    assert nodes["AI"].degree == 2
    assert nodes["AI"].r > nodes["MCP"].r
  end

  test "同じ材料なら、同じ図になる" do
    # 開くたびに形が変わると「昨日と同じ図か」が読めない
    themes = [
      theme("MCP", field: "AI", related: [related("AI")]),
      theme("AI", field: "AI"),
      theme("観測可能性", field: "インフラ")
    ]

    first = Graph.build(themes)
    again = Graph.build(Enum.reverse(themes))

    assert Enum.map(first.nodes, & &1.name) == Enum.map(again.nodes, & &1.name)
    assert Enum.map(first.nodes, & &1.x) == Enum.map(again.nodes, & &1.x)
  end

  test "多すぎるときは、つながりの多いものから出す" do
    themes =
      [theme("真ん中", related: Enum.map(1..5, &related("端#{&1}")))] ++
        Enum.map(1..5, &theme("端#{&1}"))

    map = Graph.build(themes, limit: 3)

    assert length(map.nodes) == 3
    assert "真ん中" in Enum.map(map.nodes, & &1.name)
    assert map.hidden == 3
  end

  test "1 件だけなら、真ん中に置く" do
    assert [node] = Graph.build([theme("AI")]).nodes
    assert node.x == 480
    assert node.y == 300
  end
end
