defmodule TazunaWeb.CollectTest do
  use ExUnit.Case, async: true

  alias TazunaWeb.Collect

  defp collection(attrs) do
    Map.merge(
      %{
        enabled: true,
        kind: "stock",
        keep_days: 0,
        docs: 3,
        partitions_total: 0,
        prompt: "",
        cursor: "",
        sweeps: []
      },
      attrs
    )
  end

  defp fact(c, label) do
    %{collection: c} |> Collect.collection_facts() |> List.keyfind(label, 0)
  end

  describe "集め方" do
    # 同じ収集を Chiezo の管理画面でも見るので、呼び名を揃える
    test "Chiezo と同じく「網羅」「流れ」と呼ぶ" do
      assert {"集め方", "網羅（" <> _} = fact(collection(%{}), "集め方")

      assert {"集め方", "流れ（時とともに増えるものを追う。30 日ぶんを持ち、古いものは順に落とす）"} =
               fact(collection(%{kind: "flow", keep_days: 30}), "集め方")
    end
  end

  describe "進み具合" do
    test "依頼文が {cursor} を使う収集では出す" do
      c = collection(%{prompt: "{cursor} 以降のニュースを集めて", cursor: "2026-09-23"})
      assert fact(c, "進み具合") == {"進み具合", "2026-09-23"}
    end

    test "巡回の依頼文が使っていても出す" do
      c = collection(%{cursor: "2026-09-23", sweeps: [%{prompt: "{cursor} から"}]})
      assert fact(c, "進み具合") == {"進み具合", "2026-09-23"}
    end

    test "使わない収集では出さない（AI が答えに添えただけの値なので）" do
      # 区画で回る画家の図に「1879-」とだけ出ていた
      c = collection(%{prompt: "{partition} を見てください", cursor: "1879-", sweeps: [%{prompt: ""}]})
      assert fact(c, "進み具合") == nil
    end
  end
end
