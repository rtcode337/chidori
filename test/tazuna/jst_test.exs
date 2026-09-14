defmodule Tazuna.JstTest do
  use ExUnit.Case, async: true

  alias Tazuna.Jst

  test "UTC の日時を日本時間で書く" do
    assert Jst.format(~U[2026-09-07 09:38:00Z]) == "2026-09-07 18:38 JST"
  end

  test "Chiezo から届く文字列もそのまま渡せる" do
    # 収集の予定や前回の時刻は文字列で届く
    assert Jst.format("2026-09-07T09:38:00+00:00") == "2026-09-07 18:38 JST"
  end

  test "元から時差が付いていれば、それを踏まえて直す" do
    assert Jst.format("2026-09-07T09:38:00+09:00") == "2026-09-07 09:38 JST"
  end

  test "読めなければ渡されたものをそのまま返す" do
    # 表示を止めるより、元の文字列が出ているほうが状況を追える
    assert Jst.format("いつか") == "いつか"
    assert Jst.format(nil) == nil
  end

  test "「今日」も日本時間で数える" do
    # UTC のままだと、日本の朝 9 時までが前日になる
    assert Jst.today(~U[2026-09-12 00:30:00Z]) == ~D[2026-09-12]
    assert Jst.today(~U[2026-09-11 15:00:00Z]) == ~D[2026-09-12]
    assert Jst.today(~U[2026-09-11 14:59:00Z]) == ~D[2026-09-11]
  end
end
