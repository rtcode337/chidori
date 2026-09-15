defmodule Tazuna.Notify.WatcherTest do
  @moduledoc """
  見に行く番人。**誰かが画面を開くのを待たない**ことがここの眼目。
  """

  use Tazuna.DataCase, async: false

  alias Tazuna.Notify.Watcher
  alias Tazuna.Ntfy

  test "宛先を設定した話題だけ見に行く" do
    # 設定していない話題まで読みに行くと、誰も待っていない問い合わせで
    # Chiezo を叩き続けることになる
    assert Watcher.watched() == []

    System.put_env("NTFY_BASE_URL", "http://ntfy.test")
    System.put_env(Ntfy.env_name("tazuna_tech"), "tazuna-tech")

    on_exit(fn ->
      System.delete_env("NTFY_BASE_URL")
      System.delete_env(Ntfy.env_name("tazuna_tech"))
    end)

    assert Enum.map(Watcher.watched(), & &1.collection) == ["tazuna_tech"]
  end

  test "見に行く間隔は変えられる" do
    # まとめができるのは 12 時間ごとなので、既定の 1 時間で十分に細かい
    assert Watcher.interval_minutes() == 60

    System.put_env("TAZUNA_NOTIFY_MINUTES", "15")
    on_exit(fn -> System.delete_env("TAZUNA_NOTIFY_MINUTES") end)

    assert Watcher.interval_minutes() == 15
  end

  test "読めていない状態では知らせない" do
    # 途中の状態で「まとめが無い」と読むと、次の回まで黙ることになる
    {:ok, pid} = Watcher.start_link(name: :watcher_test)
    send(pid, {:news_updated, %{status: :loading, name: "tazuna_tech", digests: []}})

    assert Process.alive?(pid)
    GenServer.stop(pid)
  end
end
