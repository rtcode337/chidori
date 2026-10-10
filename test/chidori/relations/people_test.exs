defmodule Chidori.Relations.PeopleTest do
  @moduledoc """
  芸能人の関連図（`Chidori.Relations.People`）。**画家の図と同じ仕組み**で、札と線の
  語彙と並べ方が違う（横の帯を持たず、グループはメンバーを囲む枠にする）。
  """

  use ExUnit.Case, async: true

  alias Chidori.Relations
  alias Chidori.Relations.Graph
  alias Chidori.Relations.People

  defp doc(title, tags, body \\ ""), do: %{"title" => title, "tags" => tags, "body" => body}

  describe "図の読み方" do
    setup do
      docs = [
        doc("甲山", ["芸能人", "種別:お笑い芸人", "年代:1965-", "グループ:〇〇コンビ (お笑いコンビ)", "家族:丙田:配偶者"]),
        doc("乙川", ["芸能人", "種別:お笑い芸人", "年代:1966-", "グループ:〇〇コンビ (お笑いコンビ)"]),
        doc("丙田", ~w(芸能人 種別:俳優 年代:1970- 家族:甲山:配偶者)),
        # 名簿にいるメンバーが 1 人だけのグループは枠にしない
        doc("丁野", ~w(芸能人 種別:歌手 年代:1980- グループ:△△バンド)),
        # 図に載せる印の無いもの（画家の名簿など）は出さない
        doc("誰か", ~w(画家 年代:1840-1926))
      ]

      %{graph: Graph.from_docs(docs, People.graph_spec())}
    end

    test "札は人だけで、印の無いものは載せない", %{graph: graph} do
      kinds = Map.new(graph.nodes, &{&1.name, &1.kind})

      assert kinds == %{"甲山" => :person, "乙川" => :person, "丙田" => :person, "丁野" => :person}
    end

    test "夫婦は家族の線と種類を分け、向きを持たずに 1 本の線にする", %{graph: graph} do
      names = Map.new(graph.nodes, &{&1.id, &1.name})

      lines =
        for edge <- graph.edges, do: {names[edge.from], names[edge.to], edge.kind, edge.label}

      # 両方の文書に書かれていても 1 本
      assert Enum.count(lines, fn {_a, _b, kind, _l} -> kind == :spouse end) == 1
      assert Enum.any?(lines, &match?({_, _, :spouse, "配偶者"}, &1))
    end

    test "横の帯は持たず、同じグループの人を枠で囲む", %{graph: graph} do
      # 種別は色で分かるので、帯に割ると夫婦が左右の端に離れる
      assert graph.bands == []

      nodes = Map.new(graph.nodes, &{&1.name, &1})

      # グループは文書として持たず、人の「グループ:<記事名>」から組む。名前は括弧書きを落とす
      assert [frame] = graph.clusters
      assert frame.name == "〇〇コンビ"
      assert frame.labelled
      assert Enum.sort(frame.members) == Enum.sort([nodes["甲山"].id, nodes["乙川"].id])

      # メンバーは隣り合わせで、枠の中にいる
      for name <- ["甲山", "乙川"] do
        node = nodes[name]
        assert node.x > frame.x and node.x < frame.x + frame.width
        assert node.y > frame.y and node.y < frame.y + frame.height
      end

      assert nodes["甲山"].y == nodes["乙川"].y
      assert abs(nodes["甲山"].seat - nodes["乙川"].seat) == 1
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

    test "名簿は俳優・歌手・タレント・お笑い芸人だけから引き、種別を機械で付ける", %{
      attrs: attrs
    } do
      assert attrs.name == "chidori_people"

      for category <- ~w(日本の男優 20世紀日本の女優 日本の女性歌手 日本のタレント お笑い芸人),
          do: assert(attrs.extract.tag =~ category)

      # グループは名簿に入れない（入れていた頃は、ざっと見る回がコンビの文書ばかり回った）
      refute attrs.extract.tag =~ "お笑いコンビ"
      refute attrs.extract.tag =~ "アイドルグループ"

      formats = Enum.map(attrs.extract.tags, &Map.get(&1, :format))

      for kind <- ~w(俳優 歌手 タレント お笑い芸人), do: assert("種別:#{kind}" in formats)

      refute "区分:グループ" in formats
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
        # 並んでいない既存の人は返させない（見えていない 1 件は Chiezo が置き換えずに弾く）
        assert prompt =~ "上に並んでいない人の文書は返さないでください"

        # 夫婦の相手は名簿の外からも足させる（知名度で切ると相手が抜ける）。芸能人でなくてよい
        assert prompt =~ "夫婦の相手が上に並んでいなければ、その相手も 1 件として足してください"
        assert prompt =~ "範囲の外でも構いません"
        assert prompt =~ "種別:著名人"

        # グループは人のタグから枠を組む。書き方を揃えさせ、グループ自体は足させない
        assert prompt =~ "グループ:<グループの名前>"
        assert prompt =~ "Wikipedia の記事名そのまま"
        assert prompt =~ "グループそのものは 1 件として足さないでください"
      end
    end

    test "区画は種別 × 年代で、巡回は画家と同じ 3 本", %{attrs: attrs} do
      assert attrs.partition == %{by: "band", prefix: "種別", value: "年代", target: 25}

      assert Enum.map(attrs.sweeps, & &1.name) == [
               Chidori.SweepNames.machine(),
               Chidori.SweepNames.scan(),
               Chidori.SweepNames.tidy()
             ]
    end

    test "公表されている関係だけで、未成年と一般の家族は載せない", %{attrs: attrs} do
      tidy = List.last(attrs.sweeps)

      for prompt <- [attrs.prompt, tidy.prompt] do
        assert prompt =~ "公表されている関係だけ"
        assert prompt =~ "未成年の家族と、日本語版 Wikipedia に記事の無い家族（一般の人）は書かないでください"
        assert prompt =~ "{partition}"
        assert prompt =~ "{current}"
      end
    end
  end

  test "関連図の一覧に並び、収集の名前と設定を引ける" do
    assert {"people", "芸能人のつながり"} in Relations.views()
    assert Relations.chiezo_view?("people")
    assert Relations.collection_of("people") == "chidori_people"
    assert Relations.attrs_of("people", %{}).name == "chidori_people"
    assert Relations.collection_of("painters") == Relations.painters_collection()
  end
end
