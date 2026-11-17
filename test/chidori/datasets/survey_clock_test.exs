defmodule Chidori.Datasets.SurveyClockTest do
  @moduledoc """
  食事処の情報収集を、範囲ごとに決めた時刻に起こす時計（`Chidori.Datasets.SurveyClock`）。
  """
  use Chidori.DataCase, async: false

  alias Chidori.CollectOverview
  alias Chidori.Datasets.SurveyClock
  alias Chidori.Datasets.SurveySetting

  # 2026-10-21 04:00（JST）
  @slot ~U[2026-10-20 19:00:00Z]

  defp setting(attrs \\ []),
    do: struct(%SurveySetting{collection: "chidori_dining_1", run_at: "04:00,16:00"}, attrs)

  describe "起こす番か" do
    test "予定を過ぎて 30 分までは起こす" do
      assert SurveyClock.due(setting(), DateTime.add(@slot, 10, :minute)) == @slot

      # 過ぎすぎた予定は追いかけない（夜中に立ち上げた拍子に朝の回が走らないように）
      assert SurveyClock.due(setting(), DateTime.add(@slot, 45, :minute)) == nil
    end

    test "起こせなかった予定は次の予定まで試し直し、起こせた予定は二度起こさない" do
      failed = setting(slot_at: @slot, slot_ok: false)
      assert SurveyClock.due(failed, DateTime.add(@slot, 3, :hour)) == @slot

      done = setting(slot_at: @slot, slot_ok: true)
      assert SurveyClock.due(done, DateTime.add(@slot, 10, :minute)) == nil
    end

    test "時刻を決めていなければ起こさない（本番とテストの 2 つで二重に起こさない）" do
      assert SurveyClock.due(setting(run_at: ""), DateTime.add(@slot, 1, :minute)) == nil
      assert SurveyClock.next_at(setting(run_at: ""), @slot) == nil
    end

    test "次の予定" do
      # 04:00 の直後なら、次は同じ日の 16:00（JST）
      assert SurveyClock.next_at(setting(), DateTime.add(@slot, 1, :minute)) ==
               ~U[2026-10-21 07:00:00Z]
    end
  end

  describe "設定と記録" do
    test "時刻は範囲ごとに、書き方を揃えて持ち、読めない時刻は断る" do
      assert {:ok, saved} = SurveySetting.put("chidori_dining_1", %{run_at: "4:00, 1600"})
      assert saved.run_at == "04:00,16:00"
      assert {:ok, _} = SurveySetting.put("chidori_dining_2", %{run_at: "04:15"})

      assert SurveySetting.get("chidori_dining_1").run_at == "04:00,16:00"
      assert SurveySetting.get("chidori_dining_2").run_at == "04:15"
      assert SurveySetting.get("chidori_dining_3").run_at == ""

      assert {:error, _changeset} =
               SurveySetting.put("chidori_dining_1", %{run_at: "25:00"})
    end

    test "時刻と記録は巡回ごと（巡回を省けば情報収集）" do
      {:ok, _} = SurveySetting.put("chidori_gourmet", %{run_at: "04:00"})
      {:ok, _} = SurveySetting.put("chidori_gourmet", "漏れ探し", %{run_at: "10:00"})

      assert SurveySetting.get("chidori_gourmet").run_at == "04:00"
      assert SurveySetting.get("chidori_gourmet", "情報収集").run_at == "04:00"
      assert SurveySetting.get("chidori_gourmet", "漏れ探し").run_at == "10:00"

      {:ok, _} = SurveySetting.record("chidori_gourmet", "漏れ探し", @slot, true, "起こしました")
      assert SurveySetting.get("chidori_gourmet", "漏れ探し").slot_ok
      refute SurveySetting.get("chidori_gourmet").slot_ok
    end

    test "予定ごとに、起こせたかを残す" do
      {:ok, _} = SurveySetting.record("chidori_dining_1", @slot, true, "起こしました")
      saved = SurveySetting.get("chidori_dining_1")

      assert saved.slot_at == @slot
      assert saved.slot_ok
    end
  end

  describe "設定ページの行" do
    test "時刻で起こす情報収集の行で、その収集の起こす時刻を出して直せる" do
      # 時刻で起こすのは定義に survey_clock を持つ対象（食事処の範囲・ご当地グルメ・アニメ聖地）
      Chidori.AreaFixture.area!()
      assert "chidori_gourmet" in Chidori.Datasets.SurveyClock.clocked()
      assert "chidori_anime_seichi" in Chidori.Datasets.SurveyClock.clocked()

      {:ok, _} = SurveySetting.put("chidori_dining_1", %{run_at: "04:00,16:00"})
      sweep = %{"name" => "情報収集", "by_caller" => true}

      assert CollectOverview.clock(sweep, "chidori_dining_1") == "Chidori が起こす（04:00・16:00）"
      assert CollectOverview.wake(sweep, "chidori_dining_1") == {:survey, "04:00,16:00"}
      assert CollectOverview.clock(sweep, "chidori_anime_seichi") == "時刻を決めていない（起こさない）"
      # 時刻で起こさない収集の情報収集には出さない
      assert CollectOverview.wake(sweep, "chidori_news") == nil
    end

    test "ご当地グルメは漏れ探しも時刻で起こし、時刻は情報収集と別に持つ" do
      assert {"chidori_gourmet", "情報収集"} in SurveyClock.clocked_sweeps()
      assert {"chidori_gourmet", "漏れ探し"} in SurveyClock.clocked_sweeps()
      # ほかの対象は情報収集だけ
      refute {"chidori_anime_seichi", "漏れ探し"} in SurveyClock.clocked_sweeps()

      {:ok, _} = SurveySetting.put("chidori_gourmet", "漏れ探し", %{run_at: "10:00"})
      omission = %{"name" => "漏れ探し", "by_caller" => true}

      assert CollectOverview.clock(omission, "chidori_gourmet") == "Chidori が起こす（10:00）"
      assert CollectOverview.wake(omission, "chidori_gourmet") == {:survey, "10:00"}

      assert CollectOverview.clock(%{"name" => "情報収集", "by_caller" => true}, "chidori_gourmet") ==
               "時刻を決めていない（起こさない）"
    end
  end
end
