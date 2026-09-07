defmodule Antenna.RelationsTest do
  use ExUnit.Case, async: true

  alias Antenna.Relations

  # 図の面に収まっているか。はみ出したノードは画面から見えない
  defp within_canvas?(relation) do
    Enum.all?(relation.nodes, fn node ->
      node.x >= 0 and node.x <= relation.width and node.y >= 0 and node.y <= relation.height
    end)
  end

  defp fallback(key), do: Relations.current(key)

  defp payload(nodes, edges, sources) do
    Jason.encode!(%{"nodes" => nodes, "edges" => edges, "sources" => sources})
  end

  defp painters_payload do
    payload(
      [
        %{"id" => "a", "name" => "画家A", "note" => "様式A", "years" => "1800–1850"},
        %{"id" => "b", "name" => "画家B", "note" => "様式B", "years" => "1850–1900"}
      ],
      [%{"from" => "a", "to" => "b", "label" => "色彩", "kind" => "influence"}],
      [%{"label" => "出典", "url" => "https://example.com/a"}]
    )
  end

  describe "decode_relation/3" do
    test "素のJSONを読める" do
      assert {:ok, relation} =
               Relations.decode_relation(painters_payload(), "painters", fallback("painters"))

      assert Enum.map(relation.nodes, & &1.id) == ["a", "b"]
      assert [%{from: "a", to: "b", kind: :influence}] = relation.edges
    end

    test "コードブロックで囲まれていても読める" do
      wrapped = "```json\n" <> painters_payload() <> "\n```"

      assert {:ok, relation} =
               Relations.decode_relation(wrapped, "painters", fallback("painters"))

      assert length(relation.nodes) == 2
    end

    test "前後に説明文が付いていても読める" do
      wrapped = "以下が関連図です。\n\n" <> painters_payload() <> "\n\n出典は公開情報です。"

      assert {:ok, relation} =
               Relations.decode_relation(wrapped, "painters", fallback("painters"))

      assert length(relation.nodes) == 2
    end

    test "JSONでなければ断る" do
      assert {:error, :invalid_ai_response} =
               Relations.decode_relation("調べられませんでした", "painters", fallback("painters"))
    end

    test "ノードが1件しかなければ断る" do
      body =
        payload(
          [%{"id" => "a", "name" => "画家A"}],
          [%{"from" => "a", "to" => "a", "label" => "自己", "kind" => "influence"}],
          [%{"label" => "出典", "url" => "https://example.com/a"}]
        )

      assert {:error, :invalid_ai_response} =
               Relations.decode_relation(body, "painters", fallback("painters"))
    end

    test "出典が無ければ断る。出典の無い関係は載せない" do
      body =
        payload(
          [%{"id" => "a", "name" => "画家A"}, %{"id" => "b", "name" => "画家B"}],
          [%{"from" => "a", "to" => "b", "label" => "色彩", "kind" => "influence"}],
          []
        )

      assert {:error, :invalid_ai_response} =
               Relations.decode_relation(body, "painters", fallback("painters"))
    end

    test "http以外の出典と、存在しないノードを指すエッジは落とす" do
      body =
        payload(
          [
            %{"id" => "a", "name" => "画家A"},
            %{"id" => "b", "name" => "画家B"},
            %{"id" => "駄目な id", "name" => "画家C"}
          ],
          [
            %{"from" => "a", "to" => "b", "label" => "色彩", "kind" => "influence"},
            %{"from" => "a", "to" => "zzz", "label" => "無い相手", "kind" => "influence"},
            %{"from" => "a", "to" => "b", "label" => "種類違い", "kind" => "family"}
          ],
          [
            %{"label" => "危ない", "url" => "javascript:alert(1)"},
            %{"label" => "出典", "url" => "https://example.com/a"}
          ]
        )

      assert {:ok, relation} =
               Relations.decode_relation(body, "painters", fallback("painters"))

      assert Enum.map(relation.nodes, & &1.id) == ["a", "b"]
      assert [%{from: "a", to: "b", label: "色彩"}] = relation.edges
      assert [%{url: "https://example.com/a"}] = relation.sources
    end

    test "長すぎるラベルは切って、切ったことが分かるようにする" do
      long = String.duplicate("あ", 80)

      body =
        payload(
          [%{"id" => "a", "name" => "画家A"}, %{"id" => "b", "name" => "画家B"}],
          [%{"from" => "a", "to" => "b", "label" => long, "kind" => "influence"}],
          [%{"label" => "出典", "url" => "https://example.com/a"}]
        )

      assert {:ok, %{edges: [edge]}} =
               Relations.decode_relation(body, "painters", fallback("painters"))

      assert String.length(edge.label) <= 24
      assert String.ends_with?(edge.label, "…")
    end

    test "人物側で上限まで返ってきても、図の面に収まる" do
      nodes = for i <- 1..12, do: %{"id" => "n#{i}", "name" => "人物#{i}"}

      edges =
        for i <- 1..9,
            do: %{"from" => "n#{i}", "to" => "n#{i + 1}", "label" => "親子", "kind" => "family"}

      body = payload(nodes, edges, [%{"label" => "出典", "url" => "https://example.com/a"}])

      assert {:ok, relation} = Relations.decode_relation(body, "people", fallback("people"))

      # 上限で切ったうえで、残った全部が枠の中にある
      assert length(relation.nodes) == 10
      assert within_canvas?(relation)
    end

    test "画家側で上限まで返ってきても、図の面に収まる" do
      nodes = for i <- 1..10, do: %{"id" => "n#{i}", "name" => "画家#{i}"}

      edges =
        for i <- 1..7,
            do: %{"from" => "n#{i}", "to" => "n#{i + 1}", "label" => "影響", "kind" => "influence"}

      body = payload(nodes, edges, [%{"label" => "出典", "url" => "https://example.com/a"}])

      assert {:ok, relation} = Relations.decode_relation(body, "painters", fallback("painters"))

      assert length(relation.nodes) == 8
      assert within_canvas?(relation)
    end
  end

  describe "表示例" do
    test "どちらの表示例も図の面に収まっている" do
      for key <- Relations.keys() do
        assert within_canvas?(Relations.current(key))
      end
    end

    test "表示例のエッジは実在するノードだけを指す" do
      for key <- Relations.keys() do
        relation = Relations.current(key)
        ids = MapSet.new(relation.nodes, & &1.id)

        for edge <- relation.edges do
          assert MapSet.member?(ids, edge.from)
          assert MapSet.member?(ids, edge.to)
        end
      end
    end
  end

  test "知らない種類は人物側へ丸める" do
    assert Relations.valid_key("painters") == "painters"
    assert Relations.valid_key("../etc/passwd") == "people"
  end
end
