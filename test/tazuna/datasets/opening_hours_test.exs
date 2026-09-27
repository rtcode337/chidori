defmodule Tazuna.Datasets.OpeningHoursTest do
  use ExUnit.Case, async: true

  alias Tazuna.Datasets.OpeningHours

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
end
