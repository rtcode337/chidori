defmodule Tazuna.Relations.PeopleTest do
  @moduledoc """
  芸能人の関連図（`Tazuna.Relations.People`）。**画家の図と同じ仕組み**で、札と線の
  語彙だけが違う。
  """

  use ExUnit.Case, async: true

  alias Tazuna.Relations
  alias Tazuna.Relations.Graph
  alias Tazuna.Relations.People

  defp doc(title, tags, body \\ ""), do: %{"title" => title, "tags" => tags, "body" => body}

  describe "図の読み方" do
    setup do
      docs = [
        doc("〇〇コンビ", ~w(芸能人 区分:グループ 種別:お笑いコンビ 年代:1991- メンバー:甲山 メンバー:乙川)),
        doc("甲山", ~w(芸能人 種別:お笑い芸人 年代:1965- 家族:丙田:配偶者)),
        doc("乙川", ~w(芸能人 種別:お笑い芸人 年代:1966-)),
        doc("丙田", ~w(芸能人 種別:俳優 年代:1970- 家族:甲山:配偶者)),
        # 図に載せる印の無いもの（画家の名簿など）は出さない
        doc("誰か", ~w(画家 年代:1840-1926))
      ]

      %{graph: Graph.from_docs(docs, People.graph_spec())}
    end

    test "グループと人を札の種類で分け、印の無いものは載せない", %{graph: graph} do
      kinds = Map.new(graph.nodes, &{&1.name, &1.kind})

      assert kinds == %{"〇〇コンビ" => :group, "甲山" => :person, "乙川" => :person, "丙田" => :person}
    end

    test "メンバーはグループから、家族は向きを持たずに 1 本の線にする", %{graph: graph} do
      names = Map.new(graph.nodes, &{&1.id, &1.name})

      lines =
        for edge <- graph.edges, do: {names[edge.from], names[edge.to], edge.kind, edge.label}

      assert {"〇〇コンビ", "甲山", :duo, "メンバー"} in lines
      assert {"〇〇コンビ", "乙川", :duo, "メンバー"} in lines
      # 両方の文書に書かれていても 1 本
      assert Enum.count(lines, fn {_a, _b, kind, _l} -> kind == :family end) == 1
      assert Enum.any?(lines, &match?({_, _, :family, "配偶者"}, &1))
    end

    test "横の帯はお笑いと俳優", %{graph: graph} do
      assert Enum.map(graph.bands, & &1.band) == ["お笑い", "俳優"]
    end

    test "代表作は持たない", %{graph: graph} do
      assert Enum.all?(graph.nodes, &(&1.works == []))
    end
  end

  test "画家の図はこれまでどおり（既定の読み方）" do
    graph = Graph.from_docs([doc("A", ~w(画家 年代:1840-1926 地域:フランス))])
    assert [%{kind: :artist, band: "ヨーロッパ"}] = graph.nodes
  end

  describe "Chiezo に送る設定" do
    setup do
      %{attrs: People.attrs()}
    end

    test "名簿はお笑いコンビ・トリオと俳優のカテゴリから、種別とグループの印を機械で付ける", %{
      attrs: attrs
    } do
      assert attrs.name == "tazuna_people"
      assert attrs.extract.tag =~ "日本のお笑いコンビ"
      assert attrs.extract.tag =~ "21世紀日本の女優"
      formats = Enum.map(attrs.extract.tags, &Map.get(&1, :format))
      assert "種別:お笑いコンビ" in formats
      assert "区分:グループ" in formats
      assert "種別:俳優" in formats
    end

    test "区画は種別 × 年代で、巡回は画家と同じ 3 本", %{attrs: attrs} do
      assert attrs.partition == %{by: "band", prefix: "種別", value: "年代", target: 25}

      assert Enum.map(attrs.sweeps, & &1.name) == [
               Tazuna.SweepNames.machine(),
               Tazuna.SweepNames.scan(),
               Tazuna.SweepNames.tidy()
             ]
    end

    test "公表されている関係だけで、未成年と一般の家族は載せない", %{attrs: attrs} do
      tidy = List.last(attrs.sweeps)

      for prompt <- [attrs.prompt, tidy.prompt] do
        assert prompt =~ "公表されている関係だけ"
        assert prompt =~ "未成年の家族と、芸能人でない家族（一般の人）は書かないでください"
        assert prompt =~ "{partition}"
        assert prompt =~ "{current}"
      end
    end
  end

  test "関連図の一覧に並び、収集の名前と設定を引ける" do
    assert {"people", "芸能人のつながり"} in Relations.views()
    assert Relations.chiezo_view?("people")
    assert Relations.collection_of("people") == "tazuna_people"
    assert Relations.attrs_of("people", %{}).name == "tazuna_people"
    assert Relations.collection_of("painters") == Relations.painters_collection()
  end
end
