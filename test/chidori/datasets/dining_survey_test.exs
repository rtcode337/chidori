defmodule Chidori.Datasets.DiningSurveyTest do
  @moduledoc """
  食事処の情報収集を、範囲ごとに決めた時刻に起こす時計（`Chidori.Datasets.DiningSurvey`）。
  """
  use Chidori.DataCase, async: false

  alias Chidori.CollectOverview
  alias Chidori.Datasets.DiningSurvey
  alias Chidori.Datasets.DiningSurveySetting

  # 2026-10-21 04:00（JST）
  @slot ~U[2026-10-20 19:00:00Z]

  defp setting(attrs \\ []),
    do: struct(%DiningSurveySetting{collection: "chidori_dining_1", run_at: "04:00,16:00"}, attrs)

  describe "起こす番か" do
    test "予定を過ぎて 30 分までは起こす" do
      assert DiningSurvey.due(setting(), DateTime.add(@slot, 10, :minute)) == @slot

      # 過ぎすぎた予定は追いかけない（夜中に立ち上げた拍子に朝の回が走らないように）
      assert DiningSurvey.due(setting(), DateTime.add(@slot, 45, :minute)) == nil
    end

    test "起こせなかった予定は次の予定まで試し直し、起こせた予定は二度起こさない" do
      failed = setting(slot_at: @slot, slot_ok: false)
      assert DiningSurvey.due(failed, DateTime.add(@slot, 3, :hour)) == @slot

      done = setting(slot_at: @slot, slot_ok: true)
      assert DiningSurvey.due(done, DateTime.add(@slot, 10, :minute)) == nil
    end

    test "時刻を決めていなければ起こさない（本番とテストの 2 つで二重に起こさない）" do
      assert DiningSurvey.due(setting(run_at: ""), DateTime.add(@slot, 1, :minute)) == nil
      assert DiningSurvey.next_at(setting(run_at: ""), @slot) == nil
    end

    test "次の予定" do
      # 04:00 の直後なら、次は同じ日の 16:00（JST）
      assert DiningSurvey.next_at(setting(), DateTime.add(@slot, 1, :minute)) ==
               ~U[2026-10-21 07:00:00Z]
    end
  end

  describe "設定と記録" do
    test "時刻は範囲ごとに、書き方を揃えて持ち、読めない時刻は断る" do
      assert {:ok, saved} = DiningSurveySetting.put("chidori_dining_1", %{run_at: "4:00, 1600"})
      assert saved.run_at == "04:00,16:00"
      assert {:ok, _} = DiningSurveySetting.put("chidori_dining_2", %{run_at: "04:15"})

      assert DiningSurveySetting.get("chidori_dining_1").run_at == "04:00,16:00"
      assert DiningSurveySetting.get("chidori_dining_2").run_at == "04:15"
      assert DiningSurveySetting.get("chidori_dining_3").run_at == ""

      assert {:error, _changeset} =
               DiningSurveySetting.put("chidori_dining_1", %{run_at: "25:00"})
    end

    test "予定ごとに、起こせたかを残す" do
      {:ok, _} = DiningSurveySetting.record("chidori_dining_1", @slot, true, "起こしました")
      saved = DiningSurveySetting.get("chidori_dining_1")

      assert saved.slot_at == @slot
      assert saved.slot_ok
    end
  end

  describe "設定ページの行" do
    test "食事処の情報収集の行で、その範囲の起こす時刻を出して直せる" do
      {:ok, _} = DiningSurveySetting.put("chidori_dining_1", %{run_at: "04:00,16:00"})
      sweep = %{"name" => "情報収集", "by_caller" => true}

      assert CollectOverview.clock(sweep, "chidori_dining_1") == "Chidori が起こす（04:00・16:00）"
      assert CollectOverview.wake(sweep, "chidori_dining_1") == {:dining_survey, "04:00,16:00"}
      assert CollectOverview.clock(sweep, "chidori_dining_2") == "時刻を決めていない（起こさない）"
      # ほかの収集の情報収集には出さない
      assert CollectOverview.wake(sweep, "chidori_gourmet") == nil
    end
  end
end
