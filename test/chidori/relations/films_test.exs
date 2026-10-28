defmodule Chidori.Relations.FilmsTest do
  @moduledoc """
  映画の関連図（`Chidori.Relations.Films`）。**芸能人の図と同じ仕組み**で、
  横は国の帯、同じ監督の作品どうしと同じ主演の作品どうしを、別の種類の線で結ぶ。
  """

  use ExUnit.Case, async: true

  doctest Chidori.Relations.Films, only: [source_kind_of: 1]

  alias Chidori.Relations
  alias Chidori.Relations.Films
  alias Chidori.Relations.Graph

  defp doc(title, tags), do: %{"title" => title, "tags" => tags, "body" => ""}

  describe "図の読み方" do
    setup do
      docs = [
        doc("七人の侍", ~w(映画 監督:黒澤明 年代:1954 国:日本 主演:三船敏郎 主演:志村喬)),
        doc("用心棒", ~w(映画 監督:黒澤明 年代:1961 国:日本 主演:三船敏郎)),
        doc("赤ひげ", ~w(映画 監督:黒澤明 年代:1965 国:日本 主演:三船敏郎)),
        doc("東京物語", ~w(映画 監督:小津安二郎 年代:1953 国:日本 主演:笠智衆)),
        doc("ローマの休日", ~w(映画 監督:ウィリアム・ワイラー 年代:1953 国:アメリカ合衆国)),
        # 監督の新しい作品が、ほかの監督のそれより古い作品より上に来ない（枠で囲まない）
        doc("新作", ~w(映画 監督:小津安二郎 年代:2026 国:日本 国:アメリカ合衆国)),
        # 図に載せる印の無いものは出さない
        doc("誰か", ~w(芸能人 年代:1950-))
      ]

      %{graph: Graph.from_docs(docs, Films.graph_spec())}
    end

    test "札は作品だけ", %{graph: graph} do
      assert graph.nodes |> Enum.map(& &1.kind) |> Enum.uniq() == [:film]
      refute Enum.any?(graph.nodes, &(&1.name == "誰か"))
    end

    test "監督の枠は作らず、同じ監督の作品は公開年の順に隣どうしを線で結ぶ", %{graph: graph} do
      names = Map.new(graph.nodes, &{&1.id, &1.name})
      assert graph.clusters == []

      lines =
        for edge <- graph.edges,
            edge.kind == :director,
            do: {names[edge.from], names[edge.to], edge.label}

      assert Enum.sort(lines) ==
               Enum.sort([
                 {"七人の侍", "用心棒", "黒澤明"},
                 {"用心棒", "赤ひげ", "黒澤明"},
                 {"東京物語", "新作", "小津安二郎"}
               ])
    end

    test "札を押すと、同じ主演・同じ監督の作品は隣どうしでなくても全部立つ", %{graph: graph} do
      ids = Map.new(graph.nodes, &{&1.name, &1.id})
      pick = ChidoriWeb.RelationsLive.pick_of(graph, "七人の侍")

      # 赤ひげは七人の侍の 2 つ先（三船敏郎・黒澤明の鎖の上で、間に用心棒が挟まる）
      assert MapSet.member?(pick.near, ids["赤ひげ"])
      refute MapSet.member?(pick.near, ids["ローマの休日"])

      lit = Enum.filter(graph.edges, &ChidoriWeb.RelationsLive.lit?(pick, &1))
      assert Enum.any?(lit, &(&1.from == ids["用心棒"] and &1.to == ids["赤ひげ"]))
    end

    test "作品の詳細で主演の名前を押すと、その人の作品と線だけが立つ（その人の線を押したときと同じ）",
         %{graph: graph} do
      ids = Map.new(graph.nodes, &{&1.name, &1.id})
      pick = ChidoriWeb.RelationsLive.pick_of(graph, {:chain, {"主演", "三船敏郎"}})

      assert pick.id == nil
      assert pick.near == MapSet.new([ids["七人の侍"], ids["用心棒"], ids["赤ひげ"]])

      lit = Enum.filter(graph.edges, &ChidoriWeb.RelationsLive.lit?(pick, &1))
      assert lit != []
      # 同じ 2 本を結ぶ黒澤明（監督）の鎖は立てない
      assert Enum.all?(lit, &(&1.kind == :costar))

      # 図に作品の無い人は選ばない
      assert ChidoriWeb.RelationsLive.pick_of(graph, {:chain, {"主演", "誰でもない人"}}) == nil
    end

    test "共通項の線を押すと、その人の作品だけが立つ（札を押したときのように全部の共通項は立てない）",
         %{graph: graph} do
      ids = Map.new(graph.nodes, &{&1.name, &1.id})
      [ozu] = Enum.filter(graph.edges, &(&1.kind == :director and &1.label == "小津安二郎"))
      pick = ChidoriWeb.RelationsLive.pick_of(graph, {ozu.from, ozu.to, ozu.kind})

      assert pick.id == nil
      assert pick.near == MapSet.new([ids["東京物語"], ids["新作"]])
      lit = Enum.filter(graph.edges, &ChidoriWeb.RelationsLive.lit?(pick, &1))
      assert lit == [ozu]

      # 黒澤明の線を押すと黒澤明の 3 本だけ（同じ 2 本を結ぶ三船敏郎の線も、共通項の線なので
      # 黒澤明の鎖には載らない）
      kurosawa = Enum.find(graph.edges, &(&1.kind == :director and &1.label == "黒澤明"))
      pick = ChidoriWeb.RelationsLive.pick_of(graph, {kurosawa.from, kurosawa.to, :director})
      assert pick.near == MapSet.new([ids["七人の侍"], ids["用心棒"], ids["赤ひげ"]])

      refute Enum.any?(
               graph.edges,
               &(&1.kind == :costar and ChidoriWeb.RelationsLive.lit?(pick, &1))
             )
    end

    test "2 本の作品が主演を 2 人とも共にしていても、2 人目の主演の先まで立つ" do
      # 線は 1 組 1 本に畳むので、畳んだ線が 2 人目の値を持っていないと、その人の鎖が押した札から始まらない
      docs = [
        doc("一作目", ~w(映画 年代:1950 国:日本 主演:甲 主演:乙)),
        doc("二作目", ~w(映画 年代:1955 国:日本 主演:甲 主演:乙)),
        doc("三作目", ~w(映画 年代:1960 国:日本 主演:甲))
      ]

      graph = Graph.from_docs(docs, Films.graph_spec())
      ids = Map.new(graph.nodes, &{&1.name, &1.id})
      pick = ChidoriWeb.RelationsLive.pick_of(graph, "一作目")

      assert MapSet.member?(pick.near, ids["三作目"])
      lit = Enum.filter(graph.edges, &ChidoriWeb.RelationsLive.lit?(pick, &1))
      assert Enum.any?(lit, &(&1.from == ids["二作目"] and &1.to == ids["三作目"]))

      # 一作目と二作目のあいだは 1 本のまま（網にしない）
      assert Enum.count(
               graph.edges,
               &(Enum.sort([&1.from, &1.to]) == Enum.sort([ids["一作目"], ids["二作目"]]))
             ) == 1
    end

    test "見た作品を除くと、同じ監督・主演の鎖は残った作品でつなぎ直す", %{graph: graph} do
      shown = Graph.without(graph, ["用心棒"])
      names = Map.new(shown.nodes, &{&1.id, &1.name})

      refute Enum.any?(shown.nodes, &(&1.name == "用心棒"))

      lines =
        for edge <- shown.edges,
            edge.kind in [:director, :costar],
            do: {edge.kind, names[edge.from], names[edge.to], edge.label}

      # 用心棒を挟んでいた七人の侍と赤ひげが、黒澤明と三船敏郎の両方で直に結ばれる（1 本に畳む）
      assert {:director, "七人の侍", "赤ひげ", "黒澤明"} in lines

      assert [%{values: values}] =
               Enum.filter(shown.edges, &(&1.kind == :costar and names[&1.to] == "赤ひげ"))

      assert values == ["三船敏郎"]
      assert {:director, "東京物語", "新作", "小津安二郎"} in lines

      # 除くものが無ければそのまま
      assert Graph.without(graph, ["図に無い作品"]) == graph
    end

    test "知名度などで絞った図は、残りが少なくても全体の図と同じ置き方にする" do
      # いちばん長い作品名に合わせて列を決める読ませる置き方だと、数本しか列が取れずに縦に並ぶ
      long = String.duplicate("長い作品名", 8)

      docs =
        [doc(long, ~w(映画 年代:2000 国:日本))] ++
          for i <- 1..30, do: doc("作品#{i}", ["映画", "年代:#{1950 + i}", "国:日本"])

      graph = Graph.from_docs(docs, Films.graph_spec())
      fitted = Graph.without(graph, ["作品1"])
      full = Graph.without(graph, ["作品1"], layout: :full)

      columns = fn g -> g.nodes |> Enum.map(& &1.x) |> Enum.uniq() |> length() end
      assert columns.(full) > columns.(fitted)
      assert full.height < fitted.height
    end

    test "線の人（同じ監督・同じ主演）と、図にあるその人の作品を新しい順に", %{graph: graph} do
      edge = Enum.find(graph.edges, &(&1.kind == :director and &1.label == "黒澤明"))

      assert [%{name: "黒澤明", role: "監督", films: films}] =
               ChidoriWeb.RelationsLive.edge_people(graph, edge, :director)

      assert Enum.map(films, &elem(&1, 0)) == ["赤ひげ", "用心棒", "七人の侍"]

      # 2 人の主演を共にする線は 2 人とも
      costar = %{value: "甲", values: ["甲", "乙"], label: "甲"}

      assert [%{name: "甲", role: "主演"}, %{name: "乙"}] =
               ChidoriWeb.RelationsLive.edge_people(graph, costar, :costar)
    end

    test "コピーする題名は、記事名の見分けの札を外したもの" do
      assert Films.plain_title("別離 (2011年の映画)") == "別離"
      assert Films.plain_title("シャイニング (映画)") == "シャイニング"
      assert Films.plain_title("七人の侍") == "七人の侍"
    end

    test "サブスクを探す Google 検索（題名の括弧書きは外す）" do
      assert Films.subscription_search_url("別離 (2011年の映画)") ==
               "https://www.google.com/search?q=%E5%88%A5%E9%9B%A2+%E3%82%B5%E3%83%96%E3%82%B9%E3%82%AF"
    end

    test "原作の記事は割り引き、閲覧数の無い作品は Wikipedia の閲覧数、記事も無ければ注目度で控えめに大きさを決める" do
      nodes =
        for {name, views} <- [
              {"一", 900},
              {"二", 800},
              {"三", 700},
              {"四", 600},
              {"五", 500},
              {"六", 100}
            ],
            do: %{name: name, views: views, tags: []}

      nodes =
        nodes ++
          [
            %{name: "記事のある新作", views: 0, tags: ["記録:記事のある新作"]},
            %{name: "新作 (映画)", views: 0, tags: ["記録:新作"]},
            %{name: "話題作", views: 0, tags: ["注目度:中", "記録:話題作"]},
            %{name: "手で足した作品", views: 0, tags: ["記録:手で足した作品"]},
            %{name: "名簿の作品", views: 0, tags: []},
            %{name: "閲覧数あり", views: 50, tags: ["注目度:高"]},
            %{name: "原作の漫画", views: 1000, tags: ["記事:漫画"]},
            %{name: "原作の小説の新作", views: 0, tags: ["記事:小説", "記録:原作の小説の新作"]},
            %{name: "転送の新作", views: 0, tags: ["記録:転送の新作"]}
          ]

      sized =
        nodes
        |> Films.with_new_film_views(%{"新作" => :high}, %{
          "記事のある新作" => %{views: 4000, kind: nil},
          "閲覧数あり" => %{views: 9, kind: nil},
          "原作の小説の新作" => %{views: 600, kind: nil},
          # 引き継いだ作品の記事名が、原作の漫画の記事へ転送されている
          "転送の新作" => %{views: 2000, kind: "漫画"}
        })
        |> Map.new(&{&1.name, &1.views})

      # 基準は記事の閲覧数を入れたあとの多い順で 5 番目（4000・900・800・700・600）
      ratio = &round(600 * :math.pow(&1, 1 / 0.65))
      # Wikipedia の閲覧数があればそれ（最大にもなりうる）
      assert sized["記事のある新作"] == 4000

      # 記事が無ければ注目度で控えめに（高 4 割・中 3 割・引き継いだ・足した作品は 2 割の大きさ）
      assert sized["新作 (映画)"] == ratio.(0.4)
      assert sized["話題作"] == ratio.(0.3)
      assert sized["手で足した作品"] == ratio.(0.2)

      # 名簿の作品で何も無ければ、いちばん小さいまま。閲覧数のある作品には触らない
      assert sized["名簿の作品"] == 0
      assert sized["閲覧数あり"] == 50

      # 原作の記事の閲覧数は、漫画などは 2 割・小説は 5 割に（名簿の閲覧数でも、引いた記事の閲覧数でも）
      assert sized["原作の漫画"] == 200
      assert sized["原作の小説の新作"] == 300

      # 引いた記事が原作の記事なら、その種類で割り引く（名簿を通らないのでタグは無い）
      assert sized["転送の新作"] == 400
    end

    test "知名度は控えてある月の中央値（pageviews_median）を先に使う（その月の値は話題に振られる）" do
      docs = [
        Map.put(doc("旧作", ~w(映画 年代:2003 国:日本)), "extra", %{
          "pageviews_month" => 180_000,
          "pageviews_median" => 40_000
        }),
        Map.put(doc("中央値の無い作品", ~w(映画 年代:2003 国:日本)), "extra", %{
          "pageviews_month" => 5_000
        })
      ]

      views =
        docs
        |> Graph.from_docs(Films.graph_spec())
        |> Map.get(:nodes)
        |> Map.new(&{&1.name, &1.views})

      assert views == %{"旧作" => 40_000, "中央値の無い作品" => 5_000}
      assert "pageviews_median" in Films.extract().extra
    end

    test "札の大きさの決め方の言葉（詳細の知名度に添える）" do
      assert Films.size_basis(%{tags: ["記事:小説"], years: "2025"}, 2026) ==
               ["原作（小説）の記事の閲覧数を 5 割に", "公開から間もないので 6 割に"]

      assert Films.size_basis(%{tags: ["記事:漫画"], fame_level: 6, years: "2025"}, 2026) == [
               "AI の話題度 6"
             ]

      assert Films.size_basis(%{tags: [], years: "1990"}, 2026) == []
    end

    test "公開から間もない作品は閲覧数を割り引く（月の閲覧数は公開直後の話題で膨らむ）" do
      nodes =
        for {name, year} <- [{"今年", "2026"}, {"1 年前", "2025"}, {"3 年前", "2023"}, {"昔", "2000"}],
            do: %{name: name, views: 10_000, tags: [], years: year}

      sized =
        nodes |> Films.with_new_film_views(%{}, %{}, 2026) |> Map.new(&{&1.name, &1.views})

      assert sized == %{"今年" => 3_000, "1 年前" => 6_000, "3 年前" => 8_000, "昔" => 10_000}
    end

    test "閲覧数の当てにならない作品は、AI の話題度があればそれで大きさを決める" do
      roster =
        for {name, views} <- [{"一", 900}, {"二", 800}, {"三", 700}, {"四", 600}, {"五", 500}],
            do: %{name: name, views: views, tags: []}

      nodes =
        roster ++
          [
            %{name: "原作の記事の名作", views: 1000, tags: ["記事:小説"], fame_level: 8},
            %{name: "引き継いだ新作", views: 0, tags: ["記録:新作"], fame_level: 3},
            %{name: "映画の記事の作品", views: 400, tags: [], fame_level: 10}
          ]

      sized =
        nodes
        |> Films.with_new_film_views(%{}, %{"引き継いだ新作" => %{views: 90_000, kind: nil}})
        |> Map.new(&{&1.name, &1.views})

      # 基準は話題度で決める作品を除いた多い順で 5 番目（500）。閲覧数相当は話題度が 4 下がるごとに 10 分の 1
      fame = &round(500 * :math.pow(10, (&1 - 10) / 4))
      assert sized["原作の記事の名作"] == fame.(8)
      # 引き継いだ作品は、記事の閲覧数があっても話題度を使う
      assert sized["引き継いだ新作"] == fame.(3)

      # 映画だけの記事を持つ作品は、話題度があっても機械の閲覧数のまま
      assert sized["映画の記事の作品"] == 400
    end

    test "原作の記事の作品は、映画化されていれば消させない（ざっと見る回と整理の回）" do
      for prompt <- [Films.prompt(), Films.survey_prompt()] do
        assert prompt =~ "「小説の記事だから映画ではない」は消す理由になりません"
        assert prompt =~ "同じ作品の映画の記事が目録に別にある"
        refute prompt =~ "映画ではないもの（テレビドラマ・小説・人物の記事など）"
      end
    end

    test "整理の回と引き継ぎの回に、話題度を書かせる" do
      assert Films.survey_prompt() =~ "〔空: fame_level〕"
      assert Films.survey_prompt() =~ ~s("fame_level": 1〜10 の整数)
      assert Films.carry_prompt([%{title: "新作"}]) =~ ~s("fame_level": 1〜10 の整数)
      assert "fame_level" in Films.attrs().show_blanks
    end

    test "名簿を引くときに、記事の 1 文目の主語で原作の記事に印を付けさせる" do
      rule = Enum.find(Films.extract().tags, &(&1[:on] == "lead"))
      assert %{format: "記事:{1}", fill: true} = rule
      assert String.length(rule.pattern) <= 200

      # Chiezo と同じ読み方（捕まえた種類を表で読み替える）
      kind_of = fn lead ->
        case Regex.run(Regex.compile!(rule.pattern, "u"), lead) do
          [_ | [kind | _]] -> rule.map[kind]
          _none -> nil
        end
      end

      # Chiezo が渡す 1 文目（句点の手前まで。丸括弧の中は除いてある）
      for {lead, kind} <- [
            {"『白夜行』は、東野圭吾の小説", "小説"},
            {"『永遠の0』は、百田尚樹による日本の小説、またそれを原作とした漫画・映画・テレビドラマ", "小説"},
            {"『東のエデン』は、2009年に放送されたテレビアニメ", "アニメ"},
            {"『鬼の花嫁』は、クレハによる日本のライト文芸", "ライトノベル"},
            {"『あの星が降る丘で、君とまた出会いたい。』は、汐見夏衛による日本の小説", "小説"},
            # 1 文目の最後に出てくる種類（小説を原作とした漫画は漫画）
            {"『作品』は、作家の小説を原作とした日本の漫画作品", "漫画"},
            {"映画\n\n『作品』は、日本の漫画作品", "漫画"}
          ] do
        assert kind_of.(lead) == kind, lead
      end

      for lead <- [
            "『クローズZERO』は、髙橋ヒロシの漫画『クローズ』を原案とした2007年公開の日本映画",
            "『キングダム』は、2019年4月19日に公開の日本の映画",
            "『探偵はBARにいる』は、日本の探偵映画のシリーズ",
            "『作品』は、日本の劇場アニメ作品",
            "記事の冒頭に作品の種類が無い"
          ] do
        assert kind_of.(lead) == nil, lead
      end
    end

    test "1 文目の取り出し方は Chiezo の抽出と同じ" do
      assert Films.lead_sentence("『君の名は。』（きみのなは。）は、日本の映画。続き。") == "『君の名は。』は、日本の映画"
      assert Films.lead_sentence("A (B (C) D) E。F") == "A  E"
      assert Films.lead_sentence("") == ""

      table = "|-\n| colspan=\"2\" style=\"padding: 0;\"|\n映画\n|-\n\n『作品』は、日本の漫画。"
      assert Films.lead_sentence(table) == "『作品』は、日本の漫画"
      assert Films.source_kind_of(table) == "漫画"
      assert Films.source_kind_of(nil) == nil
    end

    test "引き継ぐときに、最新の映画の注目度をタグに写させる" do
      prompt = Films.carry_prompt([%{title: "新作", attention: :high}])
      assert prompt =~ "新作（注目度 高）"
      assert prompt =~ ~s("注目度:<高・中・低>")
    end

    test "上映時間（整理の回が書く extra.runtime_minutes）を持つ" do
      docs = [
        %{
          "title" => "長い映画",
          "tags" => ~w(映画 年代:1990 国:日本),
          "body" => "",
          "extra" => %{"runtime_minutes" => 207}
        },
        doc("まだの映画", ~w(映画 年代:1991 国:日本))
      ]

      nodes = Map.new(Graph.from_docs(docs, Films.graph_spec()).nodes, &{&1.name, &1})
      assert nodes["長い映画"].runtime == 207
      assert nodes["まだの映画"].runtime == nil
      assert Films.attrs().show_blanks == ["thumb", "runtime_minutes", "fame_level"]
      assert Films.survey_prompt() =~ "〔空: runtime_minutes〕"
    end

    test "Chiezo が縮めて持っている絵（ポスター）を、記事の画像より先に持つ" do
      thumb = "/v1/thumbs/" <> String.duplicate("c", 40) <> ".webp"

      docs = [
        %{
          "title" => "ポスターあり",
          "tags" => ~w(映画 年代:1990 国:日本),
          "body" => "",
          "extra" => %{"thumb" => thumb, "image" => "https://upload.wikimedia.org/x/logo.png"}
        },
        doc("ポスターなし", ~w(映画 年代:1991 国:日本))
      ]

      nodes = Map.new(Graph.from_docs(docs, Films.graph_spec()).nodes, &{&1.name, &1})
      assert nodes["ポスターあり"].thumb == "/thumbs/" <> String.duplicate("c", 40) <> ".webp"
      assert nodes["ポスターなし"].thumb == nil
    end

    test "Wikipedia の相互リンクの線は引かない（同じ監督・同じ主演の線で読む図）" do
      docs = [
        doc("一作目", ~w(映画 年代:1990 国:日本 監督:甲 関連:二作目)),
        doc("二作目", ~w(映画 年代:1995 国:日本 監督:乙 関連:一作目))
      ]

      graph = Graph.from_docs(docs, Films.graph_spec())
      refute Enum.any?(graph.edges, &(&1.kind == :related))
    end

    test "縦は作品ごとの公開年の順で、上が新しい", %{graph: graph} do
      # 見に来るのは最近の作品のほう。古い順だと、新しい作品が図の下の端に溜まる
      y = Map.new(graph.nodes, &{&1.name, &1.y})
      assert y["新作"] < y["赤ひげ"]
      assert y["用心棒"] <= y["七人の侍"]

      # 目盛りも同じ向き（新しい年ほど上）
      ticks = Enum.sort_by(graph.ticks, & &1.y)
      years = Enum.map(ticks, & &1.year)
      assert years == Enum.sort(years, :desc)
      assert Enum.all?(graph.nodes, &(&1.y > 0 and &1.y < graph.height))
    end

    test "札の 2 行目は国にジャンルを添える（3 つまで）" do
      docs = [
        doc("怖い映画", ~w(映画 年代:1980 国:イギリス 国:アメリカ合衆国 ジャンル:スリラー ジャンル:ホラー)),
        doc("多い映画", ~w(映画 年代:1990 国:日本 ジャンル:SF ジャンル:アクション ジャンル:冒険 ジャンル:ドラマ)),
        doc("ジャンル無し", ~w(映画 年代:2000 国:日本))
      ]

      notes =
        docs
        |> Graph.from_docs(Films.graph_spec())
        |> Map.get(:nodes)
        |> Map.new(&{&1.name, &1.note})

      assert notes["怖い映画"] == "イギリス・アメリカ合衆国・スリラー・ホラー"
      assert notes["多い映画"] == "日本・SF・アクション・冒険"
      assert notes["ジャンル無し"] == "日本"
    end

    test "横は国の帯。合作は先に挙げた帯（日本）に入る", %{graph: graph} do
      band = Map.new(graph.nodes, &{&1.name, &1.band})
      assert band["新作"] == "日本"
      assert band["ローマの休日"] == "アメリカ"
      assert Enum.map(graph.bands, & &1.band) == ["日本", "アメリカ"]
    end

    test "同じ主演の作品は、公開年の順に隣どうしを線で結ぶ（網にしない）", %{graph: graph} do
      names = Map.new(graph.nodes, &{&1.id, &1.name})

      lines =
        for edge <- graph.edges,
            edge.kind == :costar,
            do: {names[edge.from], names[edge.to], edge.label}

      assert Enum.sort(lines) ==
               Enum.sort([{"七人の侍", "用心棒", "三船敏郎"}, {"用心棒", "赤ひげ", "三船敏郎"}])
    end
  end

  describe "Chiezo に送る設定" do
    setup do
      %{attrs: Films.attrs()}
    end

    test "名簿は監督の分類・公開年の分類・賞の受賞作の和を知名度で切り、受賞作は下限を免除する", %{attrs: attrs} do
      assert attrs.name == "chidori_movie_catalog"

      # 作品の絵は AI が返した URL から Chiezo が縮めて持つ（ページの og:image は拾わない）
      assert attrs.thumbs == true

      # 整理の回がポスターを探す（どれに絵が無いかを一覧に添えてもらう）
      assert attrs.show_blanks == ["thumb", "runtime_minutes", "fame_level"]
      assert Films.survey_prompt() =~ "〔空: thumb〕"
      assert Films.survey_prompt() =~ "作品のロゴや出演者の写真は入れないでください"
      assert Films.image_prompt() =~ "{current}"
      assert Films.image_prompt() =~ "tags は全部返してください"
      extract = attrs.extract

      # 監督の分類が記事に付いていない有名作も、公開年の分類から入る
      assert extract.tag_suffix == "の監督映画,年の映画,年のアニメ映画"
      assert "日本アカデミー賞最優秀外国作品賞" in String.split(extract.tag, ",")
      assert extract.tag =~ "アカデミー賞作品賞受賞作"
      assert extract.tag =~ "パルム・ドール受賞作"
      assert extract.min_extra == %{pageviews_month: 3_000}
      assert Films.extract(1_000).min_extra == %{pageviews_month: 1_000}

      # 古い名作は今の閲覧数が少ないので、受賞作は知名度で切らない
      assert extract.min_extra_unless_tag == extract.tag
    end

    test "監督・公開年・国・ジャンルは分類から機械で付ける", %{attrs: attrs} do
      # 分類に当てる読み替え（記事の 1 文目に当てる `on: "lead"` は別のテスト）
      rules = Enum.reject(attrs.extract.tags, &(&1[:on] == "lead"))

      # Chiezo と同じ読み方（`map` があれば捕まえた値を表で読み替え、表に無ければ作らない。同じタグは 1 本）
      apply = fn tag ->
        for %{pattern: pattern, format: format} = rule <- rules,
            [_ | captures] <- [Regex.run(Regex.compile!(pattern, "u"), tag)],
            captures = if(rule[:map], do: [rule.map[hd(captures)]], else: captures),
            nil not in captures,
            uniq: true do
          captures
          |> Enum.with_index(1)
          |> Enum.reduce(format, fn {value, i}, acc -> String.replace(acc, "{#{i}}", value) end)
        end
      end

      assert apply.("黒澤明の監督映画") == ["監督:黒澤明"]
      assert apply.("1954年の映画") == ["年代:1954"]
      assert apply.("2001年のアニメ映画") == ["年代:2001", "ジャンル:アニメ"]

      assert apply.("アメリカ合衆国のロマンティック・コメディ映画") ==
               ["国:アメリカ合衆国", "ジャンル:恋愛", "ジャンル:コメディ"]

      assert apply.("東宝製作の映画作品") == ["国:日本"]
      assert apply.("日本のSF映画作品") == ["国:日本", "ジャンル:SF"]
      assert apply.("松竹製作の時代劇映画") == ["国:日本", "ジャンル:時代劇"]
      # 「〜を原作とする」「〜を題材とした」は拾わない
      assert apply.("テレビドラマを原作とする映画") == []
      assert apply.("人形を題材としたホラー映画") == []
      # 既にいる作品にも付くように（Chiezo の `fill`）
      assert Enum.all?(
               rules,
               &(&1[:fill] != true or String.starts_with?(&1.format, ["ジャンル:", "国:"]))
             )

      assert Enum.any?(rules, &(&1[:fill] == true))
      # 監督の分類を国に読まない
      refute "国:黒澤明" in apply.("黒澤明の監督映画")

      # 主な 20 か国の外の国も拾う（表で引く）。表に無い頭（会社・年）は国にしない
      assert apply.("ルーマニアのドラマ映画") == ["国:ルーマニア", "ジャンル:ドラマ"]
      assert apply.("2019年の日本のアニメ映画") == ["年代:2019"]
      assert apply.("ワーナー・ブラザースの作品の映画") == []
      # 既にいる作品にも国が付くように（Chiezo の `fill`）
      assert Enum.any?(rules, &(&1[:fill] == true and String.starts_with?(&1.format, "国:")))
      # 国の表の国は、主な国の外も「ほかの国」の帯に入る
      bands = Map.new(Films.graph_spec().bands)
      assert "ルーマニア" in bands["ほかの国"]
      refute "日本" in bands["ほかの国"]

      # Chiezo の規則の上限（20）に収まる
      assert length(rules) <= 20
    end

    test "主演は AI に書かせ、記事の無い名前は Chiezo が落とす", %{attrs: attrs} do
      assert %{prefix: "主演", source: "jawiki"} in attrs.verify_tags
      assert attrs.prompt =~ "主演:<俳優の名前>"
      assert attrs.prompt =~ "日本語版 Wikipedia の記事名そのまま"
    end

    test "区画は国 × 公開年で、巡回は画家・芸能人と同じ 3 本", %{attrs: attrs} do
      assert attrs.partition.prefix == "国"
      assert length(attrs.sweeps) == 3
    end
  end

  test "関連図の 3 つ目の図として並ぶ" do
    assert {"films", "映画のつながり"} in Relations.views()
    assert Relations.valid_key("films") == "films"
    assert Relations.collection_of("films") == "chidori_movie_catalog"
  end

  describe "主演から芸能人の図へ" do
    alias ChidoriWeb.RelationsLive

    test "芸能人の図に載っている人はその人へ、載っていない人は Wikipedia の記事へ" do
      known = MapSet.new(["三船敏郎"])

      assert {:inside, href} = RelationsLive.star_href("三船敏郎", known)
      assert href =~ "view=people"
      assert URI.decode_query(URI.parse(href).query)["focus"] == "三船敏郎"

      assert {:outside, "https://ja.wikipedia.org/wiki/" <> _} =
               RelationsLive.star_href("志村喬", known)
    end

    test "作品の詳細には監督・国・主演を分けて出す" do
      node = %{name: "七人の侍", tags: ~w(映画 監督:黒澤明 年代:1954 国:日本 主演:三船敏郎 主演:志村喬)}
      groups = Map.new(RelationsLive.tag_groups(node))

      assert groups["監督"] == ["黒澤明"]
      assert groups["国"] == ["日本"]
      assert groups["主演"] == ["三船敏郎", "志村喬"]
      assert groups["その他"] == ["映画"]
    end
  end

  describe "見た記録と引き継ぎ" do
    alias Chidori.Relations.Mark

    defp film(name, tags \\ []), do: %{name: name, tags: tags}

    test "記録は最新情報の映画と同じ置き場" do
      assert Films.mark_view() == Chidori.News.Movies.mark_view()
    end

    test "札の名前で書いた記録が先、無ければ `記録:` の見出しで引く" do
      seen = %Mark{seen: true}
      other = %Mark{note: "メモ"}

      marks = %{"サンプル映画" => seen, "七人の侍" => other}

      nodes = [
        film("サンプル映画 (映画)", ["映画", "記録:サンプル映画"]),
        film("七人の侍", ["映画"]),
        film("用心棒", ["映画"])
      ]

      assert Films.marks_by_node(marks, nodes) == %{
               "サンプル映画 (映画)" => seen,
               "七人の侍" => other
             }
    end

    test "書く見出しは、既に書いてあるものに合わせる（2 つに割らない）" do
      carried = film("サンプル映画 (映画)", ["記録:サンプル映画"])

      assert Films.mark_key(carried, %{"サンプル映画" => %Mark{}}) == "サンプル映画"
      assert Films.mark_key(carried, %{"サンプル映画 (映画)" => %Mark{}}) == "サンプル映画 (映画)"

      # まだ書いていなければ、**元の見出し（最新情報の見出し）で書く** —— 札の名前で書くと、
      # 最新情報の画面では同じ作品に見た印が付かない
      assert Films.mark_key(carried, %{}) == "サンプル映画"
      # 引き継いでいない作品は札の名前
      assert Films.mark_key(film("七人の侍", ["映画"]), %{}) == "七人の侍"
    end

    test "札の名前で書かれてしまった記録を、元の見出しへ移す" do
      nodes = [
        film("サンプル映画 (映画)", ["記録:サンプル映画"]),
        film("両方ある (映画)", ["記録:両方ある"]),
        film("七人の侍", ["映画"])
      ]

      marks = %{
        "サンプル映画 (映画)" => %Mark{seen: true},
        "両方ある (映画)" => %Mark{seen: true},
        "両方ある" => %Mark{note: "こちらにも"},
        "七人の侍" => %Mark{seen: true}
      }

      # 元の見出しに既にあるもの（2 つに割れたもの）と、引き継いでいない作品は動かさない
      assert Films.misplaced_marks(marks, nodes) == [{"サンプル映画 (映画)", "サンプル映画"}]

      {:ok, _} =
        Chidori.Relations.Marks.put(Films.mark_view(), "サンプル映画 (映画)", %{
          "seen" => true,
          "seen_on" => "2026-10-18",
          "note" => "IMAX で見た"
        })

      assert Films.align_marks(nodes) == 1
      moved = Chidori.Relations.Marks.get(Films.mark_view(), "サンプル映画")
      assert moved.seen and moved.seen_on == ~D[2026-10-18] and moved.note == "IMAX で見た"
      refute Chidori.Relations.Marks.get(Films.mark_view(), "サンプル映画 (映画)")
      # 2 回目は何もしない
      assert Films.align_marks(nodes) == 0
    end

    test "図に載っていない記録を拾う" do
      marks = %{"サンプル映画" => %Mark{}, "まだ無い映画" => %Mark{}, "七人の侍" => %Mark{}}
      nodes = [film("サンプル映画 (映画)", ["記録:サンプル映画"]), film("七人の侍")]

      assert Map.keys(Films.unplaced(marks, nodes)) == ["まだ無い映画"]
    end

    test "引き継ぎの依頼文に、作品と元の見出しを残す決まりが載る" do
      prompt =
        Films.carry_prompt([
          %{
            title: "サンプル映画",
            date: ~D[2026-10-01],
            summary: "どんな作品か: 架空の作品。\n注目の理由: なし",
            url: "https://example.com/film"
          },
          %{title: "題名だけの映画"}
        ])

      assert prompt =~ "- サンプル映画（公開日 2026-10-01 / どんな作品か: 架空の作品。 / https://example.com/film）"
      assert prompt =~ "- 題名だけの映画\n"
      assert prompt =~ "記録:<上の見出し>"
      assert prompt =~ "{current}"
    end

    test "定義の依頼文も `記録:` を残させる" do
      assert Films.prompt() =~ "記録:"
      assert Films.survey_prompt() =~ "記録:"
    end
  end
end
