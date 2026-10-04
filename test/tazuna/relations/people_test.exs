defmodule Tazuna.Relations.PeopleTest do
  @moduledoc """
  芸能人の関連図（`Tazuna.Relations.People`）。**画家の図と同じ仕組み**で、札と線の
  語彙と並べ方が違う（横の帯を持たず、グループはメンバーを囲む枠にする）。
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

      # 夫婦は家族の線の中で種類を分ける（いちばん目立たせる）。両方の文書に書かれていても 1 本
      assert Enum.count(lines, fn {_a, _b, kind, _l} -> kind == :spouse end) == 1
      assert Enum.any?(lines, &match?({_, _, :spouse, "配偶者"}, &1))
    end

    test "横の帯は持たず、グループはメンバーを囲む枠にする", %{graph: graph} do
      # 種別は色で分かるので、帯に割ると夫婦が左右の端に離れる
      assert graph.bands == []

      nodes = Map.new(graph.nodes, &{&1.name, &1})
      assert [frame] = graph.clusters
      assert frame.name == "〇〇コンビ"
      assert Enum.sort(frame.members) == Enum.sort([nodes["甲山"].id, nodes["乙川"].id])

      # メンバーは隣り合わせで、枠の中にいる
      for name <- ["甲山", "乙川"] do
        node = nodes[name]
        assert node.x > frame.x and node.x < frame.x + frame.width
        assert node.y > frame.y and node.y < frame.y + frame.height
      end

      assert nodes["甲山"].y == nodes["乙川"].y
      assert abs(nodes["甲山"].seat - nodes["乙川"].seat) == 1

      # グループの札は枠の上の縁（枠の名前になる）
      assert nodes["〇〇コンビ"].y == frame.y

      # 枠の中のメンバーへの線は描かない印を付ける（線そのものは残す）
      framed = Enum.filter(graph.edges, & &1[:framed?])
      assert length(framed) == 2
    end

    test "メンバーが名簿にいないグループは、札のまま" do
      docs = [doc("△△トリオ", ~w(芸能人 区分:グループ 種別:お笑いトリオ 年代:2001- メンバー:だれか))]
      graph = Graph.from_docs(docs, People.graph_spec())

      assert graph.clusters == []
      assert [%{name: "△△トリオ", kind: :group}] = graph.nodes
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

    test "名簿は俳優・歌手・タレント・お笑い芸人とグループから、種別とグループの印を機械で付ける", %{
      attrs: attrs
    } do
      assert attrs.name == "tazuna_people"

      for category <- ~w(日本の男優 20世紀日本の女優 日本の女性歌手 日本のタレント お笑い芸人
                         日本のお笑いコンビ 日本の女性アイドルグループ 日本のロック・バンド) do
        assert attrs.extract.tag =~ category
      end

      formats = Enum.map(attrs.extract.tags, &Map.get(&1, :format))

      for kind <- ~w(俳優 歌手 タレント お笑い芸人 お笑いコンビ アイドルグループ バンド),
          do: assert("種別:#{kind}" in formats)

      assert "区分:グループ" in formats
      # Chiezo の規則の上限（20）に収まる
      assert length(attrs.extract.tags) <= 20
    end

    test "名簿は知名度で下を切り、顔写真の手掛かりに記事の画像を運ぶ", %{attrs: attrs} do
      # カテゴリだけで 3 万人に届くので、月の閲覧数で切ってから AI に回す
      assert attrs.extract.min_extra == %{pageviews_month: 10_000}
      assert "image" in attrs.extract.extra
      assert People.extract(3_000).min_extra == %{pageviews_month: 3_000}
    end

    test "いちばん知りたいのは夫婦で、両側に書かせる", %{attrs: attrs} do
      tidy = List.last(attrs.sweeps)

      for prompt <- [attrs.prompt, tidy.prompt] do
        assert prompt =~ ~r/いちばん知りたいのは、\s*誰と誰が夫婦か/
        assert prompt =~ "家族:<相手の名前>:配偶者"
        assert prompt =~ "元配偶者"
        assert prompt =~ "関係は両側に書いてください"
      end
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
