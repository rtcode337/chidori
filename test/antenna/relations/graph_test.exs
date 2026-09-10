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

  test "年代の順に上から並ぶ" do
    graph = Graph.from_docs([painter("あと", ["年代:1890-1950"]), painter("さき", ["年代:1820-1860"])])

    assert Enum.map(graph.nodes, & &1.name) == ["さき", "あと"]
    [first, second] = graph.nodes
    # 年表を縦に振っているので、古いほうが上に来る
    assert first.y < second.y
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
    # 幅は固定。人数は列と行の数で吸収する
    assert graph.width == 1200
    assert graph.height >= 560
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

  test "知名度で字の大きさも変える" do
    # 丸だけ大きくして字を揃えると、小さい丸から名前がはみ出す
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

    # **差は倍率で見る。** 字の大きさは升目に対する比なので、人数が変われば
    # 絶対値も変わる（固定の px で押さえると、図の大きさを変えるたびに落ちる）
    assert famous.name_size > unknown.name_size * 3
    # 全体表示では有名な画家だけが読める大きさ。残りは拡大して読む
    assert unknown.name_size < famous.name_size / 3
    # 様式と年代は名前より小さい
    assert famous.sub_size < famous.name_size
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
      Graph.from_docs(for {name, years} <- names_and_years, do: painter(name, ["年代:#{years}"]))
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

  describe "様式の枠" do
    test "同じ様式の画家をまとめて囲う" do
      graph =
        Graph.from_docs([
          painter("モネ", ["様式:印象派", "年代:1840"]),
          painter("ルノワール", ["様式:印象派", "年代:1841"]),
          painter("ピカソ", ["様式:キュビスム", "年代:1881"]),
          painter("ブラック", ["様式:キュビスム", "年代:1882"])
        ])

      styles = Enum.map(graph.clusters, & &1.style)
      assert "印象派" in styles
      assert "キュビスム" in styles
    end

    test "1 人しかいない様式は囲わない" do
      # 様式は丸の下にも書いてあるので、囲っても増える情報が無い
      graph =
        Graph.from_docs([
          painter("モネ", ["様式:印象派", "年代:1840"]),
          painter("ルノワール", ["様式:印象派", "年代:1841"]),
          painter("ひとり", ["様式:点描", "年代:1859"])
        ])

      refute "点描" in Enum.map(graph.clusters, & &1.style)
    end

    test "様式の無い画家は囲わない" do
      graph =
        Graph.from_docs([
          painter("A", ["年代:1840"]),
          painter("B", ["年代:1841"])
        ])

      assert graph.clusters == []
    end

    test "同じ様式でも離れていれば別の枠にする" do
      # 並びは生年順なので、あいだには別の様式の画家が何十人も入る。
      # 1 つの枠で囲うと、その人たちまで囲ってしまう
      docs =
        [painter("初期の A", ["様式:象徴派", "年代:1500"])] ++
          for i <- 1..12, do: painter("あいだ #{i}", ["年代:#{1600 + i}"])

      graph = Graph.from_docs(docs ++ [painter("後の B", ["様式:象徴派", "年代:1900"])])

      # 離れた 2 人なので、どちらの塊も 1 人ずつ。枠は立たない
      assert graph.clusters == []
    end

    test "近くに並んでいれば 1 つの枠にまとまる" do
      graph =
        Graph.from_docs([
          painter("A", ["様式:象徴派", "年代:1840"]),
          painter("B", ["様式:象徴派", "年代:1841"]),
          painter("C", ["様式:象徴派", "年代:1842"])
        ])

      assert [%{members: 3}] = graph.clusters
    end

    test "1 人が複数の様式に属していれば、どちらの枠にも入る" do
      # 時期で作風が変わった画家を 1 つに決めると、どれを選んでも間違いになる
      graph =
        Graph.from_docs([
          painter("ブラック", ["様式:キュビスム", "年代:1882"]),
          painter("ピカソ", ["様式:キュビスム", "様式:新古典主義", "年代:1881"]),
          painter("アングル風", ["様式:新古典主義", "年代:1880"])
        ])

      by_style = Map.new(graph.clusters, &{&1.style, &1})
      picasso = Enum.find(graph.nodes, &(&1.name == "ピカソ"))

      for style <- ["キュビスム", "新古典主義"] do
        box = Map.fetch!(by_style, style)
        assert picasso.y > box.y and picasso.y < box.y + box.height
      end
    end

    test "複数の様式は丸の下に並べて出す" do
      # 1 つに切り詰めると、枠が 2 つ掛かっている丸だけ片方しか書かれていない
      graph = Graph.from_docs([painter("ピカソ", ["様式:キュビスム", "様式:新古典主義"])])

      assert [%{note: "キュビスム・新古典主義", styles: ["キュビスム", "新古典主義"]}] = graph.nodes
    end

    test "様式を持たない画家は styles が空" do
      assert [%{styles: [], note: nil}] = Graph.from_docs([painter("A", ["年代:1900"])]).nodes
    end

    test "枠はその様式の丸を全部含む" do
      graph =
        Graph.from_docs([
          painter("モネ", ["様式:印象派", "年代:1840"]),
          painter("ルノワール", ["様式:印象派", "年代:1841"]),
          painter("ドガ", ["様式:印象派", "年代:1834"])
        ])

      [box] = graph.clusters
      members = Enum.filter(graph.nodes, &(&1.note == "印象派"))

      for node <- members do
        assert node.x > box.x and node.x < box.x + box.width
        assert node.y > box.y and node.y < box.y + box.height
      end

      assert box.members == 3
    end

    test "丸の大きさが決まってから組み直せる" do
      # 半径まで含めて囲うので、知名度を当てる前に測ると大きい丸がはみ出す
      graph =
        Graph.from_docs([
          %{
            "title" => "有名",
            "tags" => ["画家", "様式:印象派", "年代:1840"],
            "extra" => %{"url" => "https://ja.wikipedia.org/wiki/有名"}
          },
          %{
            "title" => "無名",
            "tags" => ["画家", "様式:印象派", "年代:1841"],
            "extra" => %{"url" => "https://ja.wikipedia.org/wiki/無名"}
          }
        ])

      sized = Graph.sized(graph.nodes, %{"有名" => 100_000, "無名" => 100})
      [box] = Graph.clusters(sized)
      famous = Enum.find(sized, &(&1.name == "有名"))

      assert box.x <= famous.x - famous.radius
      assert box.x + box.width >= famous.x + famous.radius
    end

    test "広い枠から先に描く" do
      # 狭い枠が広い枠に隠れると、囲われていないように見える
      graph =
        Graph.from_docs([
          painter("A", ["様式:広い", "年代:1700"]),
          painter("B", ["様式:狭い", "年代:1800"]),
          painter("C", ["様式:狭い", "年代:1801"]),
          painter("D", ["様式:広い", "年代:1900"])
        ])

      areas = Enum.map(graph.clusters, &(&1.width * &1.height))
      assert areas == Enum.sort(areas, :desc)
    end
  end

  test "文書が無ければ枠も無い" do
    assert Graph.empty().clusters == []
  end
end
