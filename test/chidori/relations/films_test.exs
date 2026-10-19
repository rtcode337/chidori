defmodule Chidori.Relations.FilmsTest do
  @moduledoc """
  映画の関連図（`Chidori.Relations.Films`）。**芸能人の図と同じ仕組み**で、
  横は国の帯、同じ監督の作品どうしと同じ主演の作品どうしを、別の種類の線で結ぶ。
  """

  use ExUnit.Case, async: true

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

    test "縦は作品ごとの公開年の順", %{graph: graph} do
      y = Map.new(graph.nodes, &{&1.name, &1.y})
      assert y["赤ひげ"] < y["新作"]
      assert y["七人の侍"] <= y["用心棒"]
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

    test "名簿は監督の分類と賞の受賞作の和を知名度で切り、受賞作は下限を免除する", %{attrs: attrs} do
      assert attrs.name == "chidori_films"
      extract = attrs.extract

      assert extract.tag_suffix == "の監督映画"
      assert extract.tag =~ "アカデミー賞作品賞受賞作"
      assert extract.tag =~ "パルム・ドール受賞作"
      assert extract.min_extra == %{pageviews_month: 3_000}
      assert Films.extract(1_000).min_extra == %{pageviews_month: 1_000}

      # 古い名作は今の閲覧数が少ないので、受賞作は知名度で切らない
      assert extract.min_extra_unless_tag == extract.tag
    end

    test "監督・公開年・国は分類から機械で付ける", %{attrs: attrs} do
      rules = attrs.extract.tags

      apply = fn tag ->
        for %{pattern: pattern, format: format} <- rules,
            [_ | captures] <- [Regex.run(Regex.compile!(pattern), tag)] do
          captures
          |> Enum.with_index(1)
          |> Enum.reduce(format, fn {value, i}, acc -> String.replace(acc, "{#{i}}", value) end)
        end
      end

      assert apply.("黒澤明の監督映画") == ["監督:黒澤明"]
      assert apply.("1954年の映画") == ["年代:1954"]
      assert apply.("2001年のアニメ映画") == ["年代:2001"]
      assert apply.("アメリカ合衆国のロマンティック・コメディ映画") == ["国:アメリカ合衆国"]
      assert apply.("東宝製作の映画作品") == ["国:日本"]
      # 監督の分類を国に読まない
      refute "国:黒澤明" in apply.("黒澤明の監督映画")

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
    assert Relations.collection_of("films") == "chidori_films"
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
      assert Films.mark_key(carried, %{}) == "サンプル映画 (映画)"
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
