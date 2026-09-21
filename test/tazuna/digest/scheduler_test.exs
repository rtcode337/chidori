defmodule Tazuna.Digest.SchedulerTest do
  @moduledoc """
  知らせる時刻の数え方。見ているのは、**JST で書いて UTC で比べること**と、
  **同じ回を二度走らせないこと**です。
  """

  use Tazuna.DataCase, async: false

  alias Tazuna.Digest.Scheduler
  alias Tazuna.Notify.Settings

  @collection "tazuna_tech"

  defp topic, do: Enum.find(Tazuna.Topics.list(), &(&1.collection == @collection))

  test "予定の時刻を過ぎたら走らせる" do
    # JST の 07:00 は UTC の前日 22:00。実行環境の時計に合わせると、
    # UTC で動くコンテナでは 9 時間ずれる
    Settings.put(@collection, %{"digest_at" => "07:00,21:00"})

    assert {_topic, at} = Scheduler.due(topic(), ~U[2026-09-16 22:01:00Z])
    assert at == ~U[2026-09-16 22:00:00Z]
  end

  test "まだ来ていない時刻では走らせない" do
    Settings.put(@collection, %{"digest_at" => "21:00"})

    refute Scheduler.due(topic(), ~U[2026-09-16 22:01:00Z])
  end

  test "時刻を書いていなければ走らせない" do
    Settings.put(@collection, %{"digest_at" => ""})

    refute Scheduler.due(topic(), ~U[2026-09-16 22:01:00Z])
  end

  test "同じ回は二度走らせない" do
    # 段取りは数分かかる。走ってから控えると、その最中にもう一度この回が来る
    Settings.put(@collection, %{"digest_at" => "07:00"})
    Settings.mark_digest(@collection, ~U[2026-09-16 22:00:00Z])

    refute Scheduler.due(topic(), ~U[2026-09-16 22:05:00Z])
  end

  test "過ぎすぎた回は追いかけない" do
    # 夜中に立ち上げた拍子に朝の回が走ると驚く
    Settings.put(@collection, %{"digest_at" => "07:00"})

    refute Scheduler.due(topic(), ~U[2026-09-16 22:45:00Z])
  end

  test "同じ起床で 2 つ過ぎていたら、遅いほうだけ走らせる" do
    Settings.put(@collection, %{"digest_at" => "07:00,07:10"})

    assert {_topic, at} = Scheduler.due(topic(), ~U[2026-09-16 22:11:00Z])
    assert at == ~U[2026-09-16 22:10:00Z]
  end

  describe "次に回る予定" do
    test "まだ来ていないいちばん早い時刻を返す" do
      Settings.put(@collection, %{"digest_at" => "07:00,21:00"})

      # UTC の 22:30 は JST の翌 07:30。次は同じ日の 21:00 JST（= 12:00 UTC）
      assert Scheduler.next(topic(), ~U[2026-09-16 22:30:00Z]) == ~U[2026-09-17 12:00:00Z]
    end

    test "今日のぶんが終わっていたら、明日の最初の回を返す" do
      # もう来ない時刻を「次」として出すと、待っても来ない
      Settings.put(@collection, %{"digest_at" => "07:00"})

      assert Scheduler.next(topic(), ~U[2026-09-16 22:30:00Z]) == ~U[2026-09-17 22:00:00Z]
    end

    test "時刻を書いていなければ予定は無い" do
      Settings.put(@collection, %{"digest_at" => ""})

      refute Scheduler.next(topic(), ~U[2026-09-16 22:30:00Z])
    end
  end

  describe "時刻の書き方" do
    test "書き方は緩く受けて、持ち方は揃える" do
      # 厳しくすると、時刻を書き間違えただけでフォームごと保存されない
      # —— 通知先まで一緒に消える（実際にそうなった）
      for written <- [" 7:00 , 21:00", "0700、2100", "700 2100", "7 21"] do
        {:ok, setting} = Settings.put(@collection, %{"digest_at" => written})
        assert setting.digest_at == "07:00,21:00", written
      end
    end

    test "読めない時刻は断る" do
      # 黙って落とすと、書いたのに回らない理由が画面から読めない
      for written <- ["25:00", "12:99", "あした"] do
        assert {:error, changeset} = Settings.put(@collection, %{"digest_at" => written})
        assert %{digest_at: [_message]} = errors_on(changeset), written
      end
    end
  end
end
