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

  describe "巡回の行" do
    test "手で回す回は、時計の代わりにそう出す" do
      # 間隔を出すと、勝手に動くように読める
      sweep = %{
        name: "整理",
        backend: nil,
        model: nil,
        interval_minutes: 60,
        by_hand: true,
        enabled: true,
        partitions_visited: 0,
        next_run_at: nil,
        last_run_at: nil,
        last_status: nil,
        last_error: nil
      }

      assert [%{interval: "手で回す"}] =
               Collect.sweep_rows(%{collection: collection(%{sweeps: [sweep]})})
    end

    test "機械で引く回には相手を選ばせないが、検索文を考える回には選ばせる" do
      # 検索文を考える回は、引くのは機械でも、その前に巡回の相手に検索文を考えさせる
      base = %{
        name: "機械収集",
        backend: nil,
        model: nil,
        interval_minutes: 60,
        use_feed: true,
        enabled: true,
        partitions_visited: 0,
        next_run_at: nil,
        last_run_at: nil,
        last_status: nil,
        last_error: nil
      }

      thinks = Map.put(base, :prompt, "これまで:\n{queries}")
      plain = Map.put(base, :prompt, "{cursor}")

      assert [%{mechanical: false}] =
               Collect.sweep_rows(%{collection: collection(%{sweeps: [thinks]})})

      assert [%{mechanical: true}] =
               Collect.sweep_rows(%{collection: collection(%{sweeps: [plain]})})

      # Pi-hole から引く回も AI を呼ばない
      pihole = base |> Map.delete(:use_feed) |> Map.put(:use_pihole, true)

      assert [%{mechanical: true}] =
               Collect.sweep_rows(%{collection: collection(%{sweeps: [pihole]})})
    end
  end

  describe "区画の見終わり具合" do
    defp rows(seen), do: Enum.map(seen, &%{seen_by: &1})

    test "前の巡回が一周するまでは、その巡回の数" do
      rows = rows([["ざっと見る"], [], ["ざっと見る", "整理"]])
      assert Collect.partition_progress(rows, ["ざっと見る", "整理"]) == {"ざっと見る", 2}
    end

    test "前の巡回が一周したら、次の巡回の数" do
      rows = rows([["ざっと見る"], ["ざっと見る", "整理"], ["ざっと見る"]])
      assert Collect.partition_progress(rows, ["ざっと見る", "整理"]) == {"整理", 1}
    end

    test "全部が一周していれば、最後の巡回の数" do
      rows = rows([["ざっと見る", "整理"], ["ざっと見る", "整理"]])
      assert Collect.partition_progress(rows, ["ざっと見る", "整理"]) == {"整理", 2}
    end

    test "区画も巡回も無ければ出さない" do
      assert Collect.partition_progress([], ["ざっと見る"]) == nil
      assert Collect.partition_progress(rows([[]]), []) == nil
    end
  end
end
