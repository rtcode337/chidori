defmodule Chidori.Datasets.DiningSurveyTest do
  @moduledoc """
  食事処の情報収集を、決めた時刻に起こす時計（`Chidori.Datasets.DiningSurvey`）。
  """
  use Chidori.DataCase, async: false

  alias Chidori.CollectOverview
  alias Chidori.Datasets.DiningSurvey
  alias Chidori.Datasets.DiningSurveySetting

  @names ["chidori_dining_1", "chidori_dining_2"]
  # 2026-10-21 04:00（JST）
  @slot ~U[2026-10-20 19:00:00Z]

  defp setting(attrs \\ []),
    do: struct(%DiningSurveySetting{run_at: "04:00,16:00"}, attrs)

  describe "起こす番か" do
    test "予定を過ぎて 30 分までは、全部の範囲を起こす" do
      assert DiningSurvey.due(setting(), @names, DateTime.add(@slot, 10, :minute)) ==
               {@slot, @names}

      # 過ぎすぎた予定は追いかけない（夜中に立ち上げた拍子に朝の回が走らないように）
      assert DiningSurvey.due(setting(), @names, DateTime.add(@slot, 45, :minute)) == nil
    end

    test "受け持った予定は、起こし終えていない範囲だけを次の予定まで試し直す" do
      started = setting(slot_at: @slot, done: ["chidori_dining_1"])

      assert DiningSurvey.due(started, @names, DateTime.add(@slot, 3, :hour)) ==
               {@slot, ["chidori_dining_2"]}

      done = setting(slot_at: @slot, done: @names)
      assert DiningSurvey.due(done, @names, DateTime.add(@slot, 10, :minute)) == {@slot, []}
    end

    test "時刻を決めていなければ起こさない（本番とテストの 2 つで二重に起こさない）" do
      assert DiningSurvey.due(setting(run_at: ""), @names, DateTime.add(@slot, 1, :minute)) == nil
      assert DiningSurvey.next_at(setting(run_at: ""), @slot) == nil
    end

    test "次の予定" do
      # 04:00 の直後なら、次は同じ日の 16:00（JST）
      assert DiningSurvey.next_at(setting(), DateTime.add(@slot, 1, :minute)) ==
               ~U[2026-10-21 07:00:00Z]
    end
  end

  describe "設定と記録" do
    test "時刻は書き方を揃えて持ち、読めない時刻は断る" do
      assert {:ok, saved} = DiningSurveySetting.put(%{run_at: "4:00, 1600"})
      assert saved.run_at == "04:00,16:00"
      assert {:error, _changeset} = DiningSurveySetting.put(%{run_at: "25:00"})
    end

    test "予定ごとに、起こし終えた範囲を足していき、予定が変われば数え直す" do
      {:ok, _} = DiningSurveySetting.record(@slot, ["chidori_dining_1"], "起こした 1 範囲")
      {:ok, _} = DiningSurveySetting.record(@slot, ["chidori_dining_2"], "起こした 1 範囲")
      assert DiningSurveySetting.get().done == @names

      later = DateTime.add(@slot, 12, :hour)
      {:ok, _} = DiningSurveySetting.record(later, ["chidori_dining_2"], "起こした 1 範囲")
      assert DiningSurveySetting.get().done == ["chidori_dining_2"]
    end
  end

  describe "設定ページの行" do
    test "食事処の情報収集の行で、起こす時刻を出して直せる" do
      {:ok, _} = DiningSurveySetting.put(%{run_at: "04:00,16:00"})
      sweep = %{"name" => "情報収集", "by_caller" => true}

      assert CollectOverview.clock(sweep, "chidori_dining_1") == "Chidori が起こす（04:00・16:00）"
      assert CollectOverview.wake(sweep, "chidori_dining_1") == {:dining_survey, "04:00,16:00"}
      # ほかの収集の情報収集には出さない
      assert CollectOverview.wake(sweep, "chidori_gourmet") == nil
    end
  end
end
