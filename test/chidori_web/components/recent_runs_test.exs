defmodule ChidoriWeb.RecentRunsTest do
  @moduledoc "最近の回（Chiezo の変更履歴）。どの区画を回った結果かを出す。"

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ChidoriWeb.RecentRuns

  defp run(attrs) do
    Map.merge(
      %{
        at: ~U[2026-10-26 01:57:04Z],
        status: "ok",
        sweep: "情報収集",
        scope: ["35.6705,139.7675/35.6708,139.7684", "35.6708,139.7675/35.6712,139.7684"],
        visited: ["35.6705,139.7675/35.6708,139.7684"],
        added: 1,
        updated: 0,
        removed: 0,
        added_titles: ["BAR Recette"],
        updated_titles: [],
        removed_titles: [],
        error: "",
        backend: "antigravity",
        model: nil
      },
      attrs
    )
  end

  test "回った区画を並べ、途中で見送った区画には印を付ける" do
    assert RecentRuns.scope_rows(run(%{})) == [
             {"35.6705,139.7675/35.6708,139.7684", true},
             {"35.6708,139.7675/35.6712,139.7684", false}
           ]

    # 見終えた区画を記録していない古い回は、どれも見終えたとして出す
    assert [{_, true}, {_, true}] = RecentRuns.scope_rows(run(%{visited: nil}))
  end

  test "区画を選べる画面では、区画を押すと地図で選ぶ" do
    html =
      render_component(&RecentRuns.recent_runs/1,
        runs: [%{change: run(%{}), by_request: false}],
        collection: "chidori_dining_2",
        reload: "reload_recent_runs",
        pick: "pick_partition"
      )

    assert html =~ "回った区画"

    assert html =~
             ~r|phx-click="pick_partition"\s+phx-value-key="35.6705,139.7675/35.6708,139.7684"|

    assert html =~ "（見送り）"

    # 選べない画面では文字だけ
    html =
      render_component(&RecentRuns.recent_runs/1,
        runs: [%{change: run(%{}), by_request: false}],
        collection: "chidori_people",
        reload: "reload_recent_runs"
      )

    assert html =~ "35.6705,139.7675/35.6708,139.7684"
    refute html =~ "pick_partition"
  end
end
