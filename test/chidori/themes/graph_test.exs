defmodule Chidori.Themes.GraphTest do
  @moduledoc """
  トピックの網の描き方。見ているのは、**全部を置くこと**・**親子をクラスタで囲むこと**・
  **いちばん動いている話題が真ん中に来ること**・**先の無い線を引かないこと**・
  **同じ材料なら同じ図になること**です。
  """

  use ExUnit.Case, async: true

  alias Chidori.Themes.Graph

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

  test "札の大きさ（字の大きさ）は、直近の件数で決まる" do
    # 図で真っ先に読みたいのは「いま何が太いか」。件数の合計で決めると、
    # 昔よく出てきた語がいつまでも大きいままになる
    themes = [
      theme("AI", docs: 20, recent: 12),
      theme("LLM", docs: 40, recent: 4),
      theme("MCP", docs: 30, recent: 0)
    ]

    nodes = Map.new(Graph.build(themes).nodes, &{&1.name, &1})

    assert nodes["AI"].font > nodes["LLM"].font
    assert nodes["LLM"].font > nodes["MCP"].font

    # **差は大きく取る**。いちばん動いている話題は、静かな話題の 3 倍の字で書く
    assert nodes["AI"].font >= nodes["MCP"].font * 3
  end

  test "静かになった語も、小さく描いて残す" do
    # 消してしまうと「前は動いていた」が図から読めない
    nodes =
      Map.new(
        Graph.build([theme("AI", recent: 9), theme("MCP", recent: 0)]).nodes,
        &{&1.name, &1}
      )

    assert nodes["MCP"].font > 0
    assert nodes["AI"].font > nodes["MCP"].font
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

  describe "クラスタ" do
    test "全部の話題を置く（間引かない）" do
      themes = Enum.map(1..40, &theme("話題#{&1}", recent: rem(&1, 7)))

      assert length(Graph.build(themes).nodes) == 40
    end

    test "札どうしは重ならない" do
      themes =
        [theme("AI", recent: 9), theme("LLM", parent: "AI", recent: 5)] ++
          Enum.map(
            1..25,
            &theme("話題#{&1}", recent: rem(&1, 5), parent: if(rem(&1, 3) == 0, do: "AI"))
          )

      nodes = Graph.build(themes).nodes

      for a <- nodes, b <- nodes, a.name < b.name do
        apart_x = abs(a.x - b.x) >= (a.w + b.w) / 2 - 0.5
        apart_y = abs(a.y - b.y) >= (a.h + b.h) / 2 - 0.5
        assert apart_x or apart_y, "#{a.name} と #{b.name} が重なっている"
      end
    end

    test "子は親と一緒に囲みの中に入る（孫も）" do
      themes = [
        theme("AI", recent: 3),
        theme("LLM", parent: "AI", recent: 2),
        theme("Jev", parent: "LLM", recent: 1),
        theme("セキュリティ", recent: 1)
      ]

      map = Graph.build(themes)
      nodes = Map.new(map.nodes, &{&1.name, &1})
      clusters = Map.new(map.clusters, &{&1.name, &1})

      inside? = fn node, box ->
        abs(node.x - box.x) + node.w / 2 <= box.w / 2 + 0.5 and
          abs(node.y - box.y) + node.h / 2 <= box.h / 2 + 0.5
      end

      # 親も子も孫も、親の囲みの中。孫は子の囲みの中にも入る
      for name <- ["AI", "LLM", "Jev"], do: assert(inside?.(nodes[name], clusters["AI"]))
      assert inside?.(nodes["Jev"], clusters["LLM"])
      refute inside?.(nodes["セキュリティ"], clusters["AI"])

      # 子を持たない話題は囲まない。**外側の囲みが先**（内側を上に描くため）
      refute Map.has_key?(clusters, "セキュリティ")

      # 枠の上には見出しのぶんの余白がある（中身は見出しの下から始まる）
      assert nodes["AI"].y - nodes["AI"].h / 2 >
               clusters["AI"].y - clusters["AI"].h / 2 + clusters["AI"].font

      assert Enum.map(map.clusters, & &1.name) == ["AI", "LLM"]
    end

    test "いちばん動いている話題を真ん中にして開く" do
      themes = [
        theme("静か", recent: 0),
        theme("いま太い", recent: 30, parent: "親"),
        theme("親", recent: 1),
        theme("ふつう", recent: 4)
      ]

      map = Graph.build(themes)
      top = Enum.find(map.nodes, &(&1.name == "いま太い"))

      assert map.focus == %{x: top.x, y: top.y}
      # 図の中にある
      assert top.x > 0 and top.x < map.width and top.y > 0 and top.y < map.height
    end

    test "親が輪になっていても止まる" do
      themes = [theme("A", parent: "B"), theme("B", parent: "A"), theme("C")]

      assert length(Graph.build(themes).nodes) == 3
    end
  end

  describe "名前の入れ方" do
    test "名前は削らずに札に入れ、札の幅を名前に合わせる" do
      # 丸の中に収めていた頃は、小さい丸で名前が「GitHu…」のように切れた
      short = Graph.card("AI", 12.0)
      long = Graph.card("GitHub Actions", 12.0)

      assert short.lines == ["AI"]
      assert long.w > short.w
      refute Enum.any?(long.lines, &String.ends_with?(&1, "…"))
    end

    test "長い名前だけ 2 行に折る" do
      assert %{lines: ["インフラ"]} = Graph.card("インフラ", 12.0)
      assert %{lines: [_first, _second] = lines} = Graph.card("とても長い名前のトピック", 12.0)
      assert Enum.join(lines) == "とても長い名前のトピック"
    end

    test "英数字は和字より狭く見積もる" do
      # 同じ比で見ると、1 行に入るはずの名前が折られる
      assert %{lines: ["Kubernetes"]} = Graph.card("Kubernetes", 12.0)
    end

    test "字が大きいほど札も大きい" do
      assert Graph.card("AI", 30.0).h > Graph.card("AI", 12.0).h
    end
  end

  test "1 件だけでも、図の中に置いて真ん中から開く" do
    map = Graph.build([theme("AI")])
    assert [node] = map.nodes
    assert map.focus == %{x: node.x, y: node.y}
    assert_in_delta node.x * 2, map.width, 0.2
    assert_in_delta node.y * 2, map.height, 0.2
  end
end
