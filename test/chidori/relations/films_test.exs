defmodule Chidori.Relations.FilmsTest do
  @moduledoc """
  名作映画の関連図（`Chidori.Relations.Films`）。**芸能人の図と同じ仕組み**で、
  同じ監督の作品を枠で囲み、同じ主演の作品どうしを線で結ぶ。
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
        # 監督が 1 本だけの作品は枠にしない
        doc("ローマの休日", ~w(映画 監督:ウィリアム・ワイラー 年代:1953 国:アメリカ合衆国)),
        # 図に載せる印の無いものは出さない
        doc("誰か", ~w(芸能人 年代:1950-))
      ]

      %{graph: Graph.from_docs(docs, Films.graph_spec())}
    end

    test "札は作品だけ", %{graph: graph} do
      assert graph.nodes |> Enum.map(& &1.kind) |> Enum.uniq() == [:film]
      refute Enum.any?(graph.nodes, &(&1.name == "誰か"))
    end

    test "同じ監督の作品を枠で囲み、隣り合わせに置く", %{graph: graph} do
      nodes = Map.new(graph.nodes, &{&1.name, &1})

      assert [frame] = graph.clusters
      assert frame.name == "黒澤明"

      assert Enum.sort(frame.members) ==
               Enum.sort(for name <- ~w(七人の侍 用心棒 赤ひげ), do: nodes[name].id)

      for name <- ~w(七人の侍 用心棒 赤ひげ) do
        node = nodes[name]
        assert node.x > frame.x and node.x < frame.x + frame.width
        assert node.y > frame.y and node.y < frame.y + frame.height
      end
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
    assert {"films", "名作映画のつながり"} in Relations.views()
    assert Relations.valid_key("films") == "films"
    assert Relations.collection_of("films") == "chidori_films"
  end
end
