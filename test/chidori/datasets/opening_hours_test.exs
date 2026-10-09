defmodule Chidori.Datasets.OpeningHoursTest do
  use ExUnit.Case, async: true

  alias Chidori.Datasets.OpeningHours

  doctest OpeningHours

  test "昼をまたいで開いていればランチ営業" do
    assert OpeningHours.features("Mo-Su,PH 11:00-22:00") == [:lunch]
    assert OpeningHours.features("Mo-Sa 17:00-21:00") == []
  end

  test "22 時より後まで開いていれば深夜営業（日付をまたぐ時間帯も）" do
    assert OpeningHours.features("Mo-Fr 18:00-02:00") == [:late]
    assert OpeningHours.features("Su 11:30-21:00") == [:lunch]
  end

  test "一日中開いている店は両方" do
    assert OpeningHours.features("24/7") == [:lunch, :late]
  end

  test "読めないものは何も付けない" do
    # 付くべき印が付かないことはあっても、付かないはずの印は付けない
    assert OpeningHours.features("sunrise-sunset") == []
    assert OpeningHours.features(nil) == []
  end

  describe "日本語に直す" do
    test "曜日ごとの時間と定休日を読める形にする" do
      assert OpeningHours.to_japanese(
               "Mo-Fr 11:00-14:30,17:30-22:00; Sa,Su,PH 11:00-21:00; We off"
             ) ==
               "月〜金 11:00〜14:30、17:30〜22:00 / 土・日・祝 11:00〜21:00 / 定休日: 水"
    end

    test "曜日の無い決まりは毎日、日付をまたぐ閉店は「翌」" do
      assert OpeningHours.to_japanese("18:00-02:00") == "毎日 18:00〜翌2:00"
      assert OpeningHours.to_japanese("Mo-Su 09:00-26:00") == "毎日 9:00〜翌2:00"
      assert OpeningHours.to_japanese("24/7") == "24時間営業"
    end

    test "続いていない曜日は「・」、2 日だけの並びも「・」" do
      assert OpeningHours.to_japanese("Mo,We,Fr 11:00-15:00; Sa-Su 10:00-20:00") ==
               "月・水・金 11:00〜15:00 / 土・日 10:00〜20:00"

      assert OpeningHours.to_japanese("Tu,Th off; Mo-Su 11:00-20:00") ==
               "毎日 11:00〜20:00 / 定休日: 火・木"
    end

    test "知らない書き方が 1 つでも混ざっていれば直さない（例外を落とさない）" do
      assert OpeningHours.to_japanese("Mo-Fr 11:00-14:00; Dec 31 off") == nil
      assert OpeningHours.to_japanese("Mo[1] off; Mo-Su 11:00-20:00") == nil
      assert OpeningHours.to_japanese("Mo-Fr 11:00-14:00 \"要予約\"") == nil
      assert OpeningHours.to_japanese("") == nil
    end
  end
end
