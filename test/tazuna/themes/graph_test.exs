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
      docs: opts[:docs] || 1,
      recent: opts[:recent] || 0,
      last_seen: opts[:last_seen] || "",
      related: opts[:related] || [],
      tags: []
    }
  end

  defp related(to, n \\ 1), do: %{to: to, n: n}

  test "先の無い線は引かない" do
    # AI が存在しないトピックを指すことはある。整える回が直すまで、図は黙って耐える
    themes = [theme("AI", related: [related("まだ無い語")]), theme("MCP")]

    assert Graph.build(themes).edges == []
  end

  test "両側から書かれたつながりは 1 本にする" do
    # 一緒に出てくる語は、機械が両側の脇書きに入れる
    themes = [
      theme("AI", related: [related("MCP", 4)]),
      theme("MCP", related: [related("AI", 4)])
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

  test "丸の大きさは、直近の件数で決まる" do
    # 図で真っ先に読みたいのは「いま何が太いか」。件数の合計で決めると、
    # 昔よく出てきた語がいつまでも大きいままになる
    themes = [
      theme("AI", docs: 20, recent: 12),
      theme("LLM", docs: 40, recent: 4),
      theme("MCP", docs: 30, recent: 0)
    ]

    nodes = Map.new(Graph.build(themes).nodes, &{&1.name, &1})

    assert nodes["AI"].r > nodes["LLM"].r
    assert nodes["LLM"].r > nodes["MCP"].r
  end

  test "静かになった語も、小さく描いて残す" do
    # 消してしまうと「前は動いていた」が図から読めない
    nodes =
      Map.new(
        Graph.build([theme("AI", recent: 9), theme("MCP", recent: 0)]).nodes,
        &{&1.name, &1}
      )

    assert nodes["MCP"].r > 0
    assert nodes["AI"].r > nodes["MCP"].r
  end

  test "線の太さは、一緒に出てきた回数" do
    themes = [
      theme("AI", recent: 5, related: [related("LLM", 12), related("MCP", 1)]),
      theme("LLM", recent: 4),
      theme("MCP", recent: 3)
    ]

    edges = Map.new(Graph.build(themes).edges, &{&1.to, &1})

    assert edges["LLM"].width > edges["MCP"].width
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

  test "多すぎるときは、いま動いているものから出す" do
    themes =
      [theme("いま太い", recent: 30)] ++
        Enum.map(1..5, &theme("端#{&1}", recent: 6 - &1))

    map = Graph.build(themes, limit: 3)

    assert length(map.nodes) == 3
    assert "いま太い" in Enum.map(map.nodes, & &1.name)
    assert map.hidden == 3
  end

  describe "名前の入れ方" do
    test "名前は丸の中に収める" do
      # 外へ逃がしていた頃は、丸と名前を目で結び直すことになった（線の上の字とも紛れる）
      [node] = Graph.build([theme("AI", recent: 3)]).nodes

      assert node.lines == ["AI"]
      assert node.font > 0
    end

    test "折ったほうが大きく書けるなら折る" do
      {lines, font} = Graph.label("インフラ", 28)

      assert lines == ["イン", "フラ"]
      # 1 行に収めると、丸の幅で字を縮めることになる
      {_one_line, small} = {["インフラ"], 28 * 2 * 0.7 / 4}
      assert font > small
    end

    test "同じ大きさで書けるなら 1 行にする" do
      assert {["AWS"], _font} = Graph.label("AWS", 28)
    end

    test "英数字は和字より狭く見積もる" do
      # 同じ比で見ると、入るはずの名前が削られる
      assert {["Kuber", "netes"], font} = Graph.label("Kubernetes", 30)
      assert font > 10
    end

    test "どうしても入らない名前は、削って印を付ける" do
      # 全部を出そうとして字を小さくすると、どれも読めなくなる
      {[line], _font} = Graph.label("とても長い名前のトピック", 24)

      assert String.ends_with?(line, "…")
      assert String.length(line) < String.length("とても長い名前のトピック")
    end
  end

  test "1 件だけなら、真ん中に置く" do
    assert [node] = Graph.build([theme("AI")]).nodes
    assert node.x == 480
    assert node.y == 300
  end
end
