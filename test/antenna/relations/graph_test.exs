defmodule Antenna.Relations.GraphTest do
  use ExUnit.Case, async: true

  alias Antenna.Relations.Graph

  defp doc(title, tags), do: %{"title" => title, "body" => "説明", "tags" => tags}
  defp painter(title, tags), do: doc(title, ["画家" | tags])

  test "1 画家 1 文書をノードにする" do
    graph = Graph.from_docs([painter("クロード・モネ", ["様式:印象派", "年代:1860-1920"])])

    assert [node] = graph.nodes
    assert node.name == "クロード・モネ"
    assert node.note == "印象派"
    assert node.years == "1860-1920"
  end

  test "この図のものでない文書は取り込まない" do
    # 同じ収集に別の題材が混ざっても、図には出さない
    assert Graph.from_docs([doc("誰か", ["人物"])]).nodes == []
  end

  test "影響元のタグからエッジを作る" do
    graph =
      Graph.from_docs([
        painter("クロード・モネ", ["年代:1860-1920"]),
        painter("フィンセント・ファン・ゴッホ", ["年代:1880-1890", "影響元:クロード・モネ:光と色彩"])
      ])

    monet = Enum.find(graph.nodes, &(&1.name == "クロード・モネ"))
    gogh = Enum.find(graph.nodes, &(&1.name == "フィンセント・ファン・ゴッホ"))

    assert [edge] = graph.edges
    # 影響を与えた側から受けた側へ向く
    assert edge.from == monet.id
    assert edge.to == gogh.id
    assert edge.label == "光と色彩"
  end

  test "説明の無い影響元も線にする" do
    graph =
      Graph.from_docs([painter("A", ["年代:1800-1850"]), painter("B", ["年代:1850-1900", "影響元:A"])])

    assert [%{label: nil}] = graph.edges
  end

  test "図にいない相手を指す影響元は落とす" do
    assert Graph.from_docs([painter("A", ["年代:1800-1850", "影響元:居ない人"])]).edges == []
  end

  test "自分自身への影響は線にしない" do
    assert Graph.from_docs([painter("A", ["年代:1800", "影響元:A"])]).edges == []
  end

  test "年代の順に左から並ぶ" do
    graph = Graph.from_docs([painter("あと", ["年代:1890-1950"]), painter("さき", ["年代:1820-1860"])])

    assert Enum.map(graph.nodes, & &1.name) == ["さき", "あと"]
    [first, second] = graph.nodes
    assert first.x < second.x
  end

  test "年代の無いものは末尾に置く" do
    graph = Graph.from_docs([painter("不明", []), painter("あり", ["年代:1900"])])
    assert Enum.map(graph.nodes, & &1.name) == ["あり", "不明"]
  end

  test "同じ名前の文書は 1 つにまとめる" do
    assert length(Graph.from_docs([painter("A", ["年代:1900"]), painter("A", ["年代:1900"])]).nodes) ==
             1
  end

  test "時代は縦に流す。人数が増えても幅は要らない" do
    # 横に流していた頃は 12 人で幅 2400 になり、画面に収まらなかった
    docs = for i <- 10..21, do: painter("画家#{i}", ["年代:19#{i}"])
    graph = Graph.from_docs(docs)

    assert length(graph.nodes) == 12
    assert graph.width == 980
    assert graph.height > 560
    # 古い順に上から下へ
    assert Enum.map(graph.nodes, & &1.y) == Enum.sort(Enum.map(graph.nodes, & &1.y))
    assert Enum.all?(graph.nodes, &(&1.x >= 0 and &1.x <= graph.width))
    assert Enum.all?(graph.nodes, &(&1.y >= 0 and &1.y <= graph.height))
  end

  test "知名度で丸の大きさを変える" do
    graph =
      Graph.from_docs([
        %{
          "title" => "有名",
          "tags" => ["画家", "年代:1900"],
          "extra" => %{"url" => "https://ja.wikipedia.org/wiki/有名"}
        },
        %{
          "title" => "無名",
          "tags" => ["画家", "年代:1910"],
          "extra" => %{"url" => "https://ja.wikipedia.org/wiki/無名"}
        }
      ])

    [famous, unknown] = Graph.sized(graph.nodes, %{"有名" => 100_000, "無名" => 100})
    assert famous.radius > unknown.radius
  end

  test "知名度が引けなくても図は出る" do
    graph = Graph.from_docs([painter("A", ["年代:1900"])])
    assert [%{radius: r}] = Graph.sized(graph.nodes, %{})
    assert is_integer(r) and r > 0
  end

  test "出典が Wikipedia なら記事名を取り出す" do
    graph =
      Graph.from_docs([
        %{
          "title" => "モネ",
          "tags" => ["画家", "年代:1900", "代表作:印象・日の出"],
          "extra" => %{"url" => "https://ja.wikipedia.org/wiki/クロード・モネ"}
        }
      ])

    assert [%{article: "クロード・モネ", work: "印象・日の出"}] = graph.nodes
  end

  test "出典が Wikipedia でなければ記事名は持たない" do
    graph =
      Graph.from_docs([
        %{"title" => "A", "tags" => ["画家"], "extra" => %{"url" => "https://example.com/a"}}
      ])

    assert [%{article: nil}] = graph.nodes
  end

  test "文書が無ければ空の図" do
    assert Graph.from_docs([]).nodes == []
    assert Graph.from_docs(nil).nodes == []
  end

  describe "相互リンクの線" do
    test "古いほうから新しいほうへ 1 本引く" do
      # リンクに向きは無いが、時代の流れは分かっている
      graph =
        Graph.from_docs([
          painter("マネ", ["年代:1832-1883", "関連:モネ"]),
          painter("モネ", ["年代:1840-1926", "関連:マネ"])
        ])

      assert [%{kind: :related} = edge] = graph.edges
      manet = Enum.find(graph.nodes, &(&1.name == "マネ"))
      assert edge.from == manet.id
    end

    test "影響の線がある組には重ねない" do
      # 「何を受けたか」まで分かっている組に、薄い線を重ねても読めるものは増えない
      graph =
        Graph.from_docs([
          painter("マネ", ["年代:1832-1883", "関連:モネ"]),
          painter("モネ", ["年代:1840-1926", "関連:マネ", "影響元:マネ:外光の描き方"])
        ])

      assert [%{kind: :influence, label: "外光の描き方"}] = graph.edges
    end

    test "図に出ない相手への線は引かない" do
      graph = Graph.from_docs([painter("モネ", ["年代:1840-1926", "関連:居ない人"])])

      assert graph.edges == []
    end
  end

  describe "年表の目盛り" do
    defp dated(names_and_years) do
      Graph.from_docs(
        for {name, years} <- names_and_years, do: painter(name, ["年代:#{years}"])
      )
    end

    test "古い順に、その年が来る高さへ置く" do
      graph = dated([{"古い人", "1450-1510"}, {"新しい人", "1960-2020"}])

      assert [_ | _] = graph.ticks
      years = Enum.map(graph.ticks, & &1.year)
      assert years == Enum.sort(years)
      assert List.first(graph.ticks).y < List.last(graph.ticks).y
      # 400 年を超える図は 100 年刻み（50 年だと目盛りが多すぎて図が読めない）
      assert Enum.all?(years, &(rem(&1, 100) == 0))
    end

    test "人が多い年代ほど、目盛りの間隔は広がる" do
      # 丸は年代の順に等間隔で並ぶので、目盛りの側が伸び縮みする。
      # 混み合った時代ほど紙面を取る＝読みやすい側に伸びる
      graph =
        dated([
          {"a", "1800-1850"},
          {"b", "1840-1900"},
          {"c", "1850-1900"},
          {"d", "1860-1910"},
          {"e", "1990-2020"}
        ])

      by_year = Map.new(graph.ticks, &{&1.year, &1.y})
      人が多い年代 = by_year[1850] - by_year[1800]
      誰もいない年代 = by_year[1950] - by_year[1900]

      assert 人が多い年代 > 誰もいない年代
    end

    test "年代の分からない図には目盛りを置かない" do
      assert Graph.from_docs([painter("年代なし", [])]).ticks == []
      # 1 人だけでは幅が決まらない
      assert dated([{"1人", "1900-1950"}]).ticks == []
    end
  end
end