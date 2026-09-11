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

  describe "横軸は地域" do
    defp regional(region, year, name),
      do: painter(name, ["年代:#{year}-#{year + 50}", "地域:#{region}"])

    test "帯は人数の比で幅を取る" do
      # 等分すると、人数の多い帯だけが縦に伸びる
      docs =
        for({r, n} <- [{"フランス", 60}, {"アメリカ合衆国", 10}], i <- 1..n,
            do: regional(r, 1800 + i, "#{r}#{i}"))

      graph = Graph.from_docs(docs)
      [europe, americas] = graph.bands
      assert europe.band == "ヨーロッパ"
      assert americas.band == "南北アメリカ"
      assert europe.members == 60 and americas.members == 10
      assert europe.width > americas.width
    end

    test "帯は重ならず、左から順に並ぶ" do
      docs =
        for({r, n} <- [{"フランス", 30}, {"アメリカ合衆国", 20}, {"日本", 25}], i <- 1..n,
            do: regional(r, 1800 + i, "#{r}#{i}"))

      graph = Graph.from_docs(docs)
      assert Enum.map(graph.bands, & &1.band) == ["ヨーロッパ", "南北アメリカ", "アジア・その他"]

      graph.bands
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [left, right] -> assert_in_delta left.x + left.width, right.x, 0.01 end)
    end

    test "画家は自分の帯の中に置かれる" do
      docs =
        for({r, n} <- [{"フランス", 30}, {"日本", 30}], i <- 1..n,
            do: regional(r, 1800 + i, "#{r}#{i}"))

      graph = Graph.from_docs(docs)
      bands = Map.new(graph.bands, &{&1.band, &1})

      for node <- graph.nodes do
        band = Map.fetch!(bands, node.band)
        assert node.x >= band.x and node.x <= band.x + band.width
      end
    end

    test "同じ高さは、どの帯でも同じ年代を指す" do
      # **ここが要。** 帯ごとに格子を持たせると、日本の画家は近代に偏っているので
      # 帯の先頭どうしが何百年もずれる
      docs =
        for({r, years} <- [{"フランス", 1400..1460}, {"日本", 1400..1460}], y <- years,
            do: regional(r, y, "#{r}#{y}"))

      graph = Graph.from_docs(docs)

      for {_y, members} <- Enum.group_by(graph.nodes, & &1.y) do
        years = for m <- members, [a | _] = String.split(m.years, "-"), do: String.to_integer(a)
        # 同じ行に並ぶのは同じころの人（行は年代のまとまり）
        assert Enum.max(years) - Enum.min(years) <= 40
      end
    end

    test "地域が取れていない画家も落とさない" do
      # 時代区分のカテゴリしか持たない人は必ずいる。落とすと図から消える
      graph = Graph.from_docs([painter("地域なし", ["年代:1800-1850"])])
      assert [%{band: "その他"}] = graph.nodes
      assert [%{band: "その他"}] = graph.bands
    end

    test "複数の地域を持つ画家は 1 つの帯に決める" do
      # 横軸は 1 人 1 か所でないと軸として読めない（先に出てきた帯を採る）
      graph =
        Graph.from_docs([
          painter("ピカソ", ["年代:1881-1973", "地域:スペイン", "地域:フランス"])
        ])

      assert [%{band: "ヨーロッパ"}] = graph.nodes
    end
  end

  describe "様式は色で見せる" do
    test "色は隣どうしが離れる" do
      # **名前のハッシュでは近い色になる。** 実測では印象派 159 とフランス象徴派 164 が
      # ほとんど同じ緑だった。人数の多い順に黄金角ずつずらす
      docs =
        for {style, n} <- [{"印象派", 5}, {"ロマン派", 4}, {"象徴派", 3}, {"未来派", 2}],
            i <- 1..n,
            do: painter("#{style}#{i}", ["年代:#{1800 + i}-1900", "様式:#{style}"])

      graph = Graph.from_docs(docs)
      hues = Enum.map(graph.styles, fn {_style, _count, hue} -> hue end)

      assert length(Enum.uniq(hues)) == 4
      assert Enum.all?(hues, &(&1 in 0..359))
      # どの 2 色も、色相環の上で十分に離れている
      for a <- hues, b <- hues, a != b do
        gap = abs(a - b)
        assert min(gap, 360 - gap) >= 30
      end
    end

    test "凡例には図に出ている様式だけを出す" do
      # 名簿にあっても 1 人も描かれていない様式を並べると、探しても見つからない色が載る
      graph = Graph.from_docs([painter("モネ", ["年代:1840-1926", "様式:印象派"])])
      assert [{"印象派", 1, _hue}] = graph.styles
    end

    test "様式を持たない画家には色を当てない" do
      graph = Graph.from_docs([painter("無所属", ["年代:1800-1850"])])
      assert [node] = graph.nodes
      assert Graph.hue_of(node) == nil
    end

    test "複数の様式を持つ画家にも色は 1 つ" do
      # 丸は 1 つしか無い。どれを選んでも同じくらい正しくないので、選び方が毎回
      # 同じであることのほうを取る（名前の下には全部書いてある）
      docs = [painter("ピカソ", ["年代:1881-1973", "様式:キュビスム", "様式:新古典主義"])]
      assert [a] = Graph.from_docs(docs).nodes
      assert [b] = Graph.from_docs(docs).nodes
      assert Graph.hue_of(a) == Graph.hue_of(b)
      assert Graph.hue_of(a) != nil
      assert a.note == "キュビスム・新古典主義"
    end
  end

  describe "ひとつの様式だけを見る" do
    test "その様式の画家だけになり、線もその中だけになる" do
      docs =
        [painter("モネ", ["年代:1840-1926", "地域:フランス", "様式:印象派"]),
         painter("ルノワール", ["年代:1841-1919", "地域:フランス", "様式:印象派",
                            "影響元:モネ:光"])] ++
          for i <- 1..30, do: painter("その他#{i}", ["年代:#{1800 + i}-1900", "地域:フランス"])

      graph = Graph.from_docs(docs)
      only = Graph.only(graph, "印象派")

      assert Enum.map(only.nodes, & &1.name) |> Enum.sort() == ["モネ", "ルノワール"]
      assert length(only.edges) == 1
    end

    test "絞ったら置き直す（拡大しなくても読める大きさになる）" do
      # **絞るだけでは足りない。** 位置がもとのままだと、数人が広い面に散らばって
      # 拡大しないと読めず、絞った意味が無い
      docs =
        [painter("モネ", ["年代:1840-1926", "地域:フランス", "様式:印象派"]),
         painter("ルノワール", ["年代:1841-1919", "地域:フランス", "様式:印象派"])] ++
          for i <- 1..200, do: painter("その他#{i}", ["年代:#{1700 + i}-1900", "地域:フランス"])

      graph = Graph.sized(Graph.from_docs(docs).nodes, %{}) |> then(&%{Graph.from_docs(docs) | nodes: &1})
      only = Graph.only(graph, "印象派")

      [before_node | _] = Enum.filter(graph.nodes, &("印象派" in &1.styles))
      [after_node | _] = only.nodes
      # 升目が広がって、字も札も大きくなる
      assert after_node.name_size > before_node.name_size
      assert only.height <= graph.height
    end

    test "絞ったら全員が描かれる" do
      # **絞ったのに出ないなら、絞った意味が無い。** 一度は丸の半径が 264 まで育って
      # 札が幅 528 になり、隣と重なって 39 人のうち 4 人しか出なかった
      docs =
        for i <- 1..40 do
          styles = if rem(i, 2) == 0, do: ["様式:印象派"], else: []
          painter("とても長い名前の画家#{i}", ["年代:#{1800 + i}-1900", "地域:フランス" | styles])
        end

      graph = Graph.from_docs(docs)
      graph = %{graph | nodes: Graph.sized(graph.nodes, %{})}
      only = Graph.only(graph, "印象派")
      view = %{x: 0, y: 0, w: 1200, h: only.height, ppu: 1.0}

      assert length(AntennaWeb.RelationsLive.drawn_nodes(only, view)) == length(only.nodes)
      # 札が升目に収まっている（収まらないと重なりを避ける仕組みが間引く）
      assert Enum.all?(only.nodes, &(&1.label_width <= &1.cell_w))
    end

    test "知らない様式を渡しても壊さない" do
      graph = Graph.from_docs([painter("モネ", ["年代:1840-1926", "様式:印象派"])])
      assert Graph.only(graph, "そんな派").nodes == graph.nodes
      assert Graph.only(graph, nil).nodes == graph.nodes
    end
  end

  test "様式は札の中に入る（札はそのぶん高くなる）" do
    # 外に置くと、隣の札と重なったときにどちらの様式か分からなくなる。
    # **人数の多い図で比べる** —— 少人数だと升目が上限まで広がり、丸の大きさのほうが
    # 札の高さを決めてしまって、行数の差が出ない
    docs =
      for i <- 1..60 do
        styles = if rem(i, 2) == 0, do: ["様式:印象派"], else: []
        painter("画家#{i}", ["年代:#{1800 + i}-1900" | styles])
      end

    sized = Graph.sized(Graph.from_docs(docs).nodes, %{})
    with_note = Enum.find(sized, &(&1.note != nil))
    without = Enum.find(sized, &(&1.note == nil))

    # 札は 2 行ぶんの高さを必ず持つ（丸のほうが大きければ、そちらで足りている）
    assert with_note.label_height >= with_note.name_size * 1.7 + with_note.sub_size * 1.35
    # 名前は上へ、様式は下へずれる（どちらも札の中）
    assert with_note.name_dy < 0
    assert with_note.note_dy > 0
    assert without.name_dy == 0.0
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

    assert [%{article: "クロード・モネ", works: ["印象・日の出"]}] = graph.nodes
    # 押したときの行き先は**画家の記事**（代表作の記事ではない）
    assert [%{url: "https://ja.wikipedia.org/wiki/クロード・モネ"}] = graph.nodes
  end

  test "代表作は 1 つに絞らない（多くても 3 つ）" do
    # 多作の画家を 1 枚で代表させると、どれを選んでも「その人らしさ」を外す
    graph =
      Graph.from_docs([
        painter("ピカソ", [
          "年代:1881-1973",
          "代表作:ゲルニカ",
          "代表作:アヴィニヨンの娘たち",
          "代表作:泣く女",
          "代表作:игра"
        ])
      ])

    assert [%{works: works}] = graph.nodes
    assert length(works) == Graph.max_works()
    assert "ゲルニカ" in works
  end

  test "タグはそのまま持ち回る（押したときに出す）" do
    # どういう条件でこの人が名簿に入り、何が分かっているのかは、これが無いと読めない
    graph = Graph.from_docs([painter("A", ["年代:1900", "様式:印象派"])])
    assert [%{tags: tags}] = graph.nodes
    assert "様式:印象派" in tags
  end

  test "代表作を持つ丸は、印のぶんまで札を広げる" do
    # 幅に入れないと、印のぶんだけ名前が札からはみ出す（札にした意味が消える）。
    # 人数の多い図で比べるのは、上の「様式は札の中に入る」と同じ理由
    docs =
      for i <- 1..60 do
        works = if rem(i, 2) == 0, do: ["代表作:何か"], else: []
        painter("同じ名前#{i}", ["年代:#{1800 + i}-1900" | works])
      end

    sized = Graph.sized(Graph.from_docs(docs).nodes, %{})
    with_work = Enum.find(sized, &(&1.works != []))
    without = Enum.find(sized, &(&1.works == []))

    assert with_work.label_width > without.label_width
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

  test "文書が無ければ帯も無い" do
    assert Graph.empty().bands == []
    assert Graph.empty().nodes == []
  end
end
