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

  describe "時刻の書き方" do
    test "書き方は揃えて持つ" do
      # "7:0" と "07:00" が別の時刻に見えると、次にいつ走るのかが読めない
      {:ok, setting} = Settings.put(@collection, %{"digest_at" => " 7:00 , 21:00"})

      assert setting.digest_at == "07:00,21:00"
    end

    test "24 時間制でなければ断る" do
      # 黙って落とすと、書いたのに回らない理由が画面から読めない
      assert {:error, changeset} = Settings.put(@collection, %{"digest_at" => "25:00"})
      assert %{digest_at: [_message]} = errors_on(changeset)
    end
  end
end
