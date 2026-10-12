defmodule Chidori.SingleFlightTest do
  @moduledoc """
  同じ仕事を同時に 2 本走らせない札。見ているのは、**走っている間は同じ鍵を断り、
  終われば（落ちても）また押せること**と、鍵が違えば重なってよいこと。
  """

  use ExUnit.Case, async: true

  # 落ちる仕事・断った接続のログは、見ているものではないので出さない
  @moduletag :capture_log

  alias Chidori.SingleFlight

  # 鍵を持ったまま止まっているプロセス（走っている最中の仕事の代わり）
  defp hold(key) do
    me = self()

    pid =
      spawn(fn ->
        SingleFlight.run(key, fn ->
          send(me, :holding)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :holding
    pid
  end

  test "走っている間は同じ鍵を断り、終わればまた走らせる" do
    key = {:test, make_ref()}
    holder = hold(key)

    assert SingleFlight.busy?(key)
    assert SingleFlight.run(key, fn -> :ran end) == {:error, :busy}
    assert SingleFlight.start(key, fn -> :ran end) == {:error, :busy}

    ref = Process.monitor(holder)
    send(holder, :release)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    refute SingleFlight.busy?(key)
    assert SingleFlight.run(key, fn -> :ran end) == :ran
  end

  test "落ちても札は外れる（二度と押せなくならない）" do
    key = {:test, make_ref()}

    {pid, ref} =
      spawn_monitor(fn -> SingleFlight.run(key, fn -> raise "途中で落ちた" end) end)

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    refute SingleFlight.busy?(key)
  end

  test "鍵が違えば重なってよい" do
    key = {:test, make_ref()}
    _holder = hold(key)

    assert SingleFlight.run({:test, make_ref()}, fn -> :ran end) == :ran
  end

  test "start は鍵を取れたかをその場で返し、仕事は裏で走らせる" do
    key = {:test, make_ref()}
    me = self()

    assert {:ok, pid} =
             SingleFlight.start(key, fn ->
               send(me, :started)
               receive do: (:release -> :ok)
             end)

    assert_receive :started
    assert SingleFlight.busy?(key)
    assert SingleFlight.start(key, fn -> :ran end) == {:error, :busy}

    ref = Process.monitor(pid)
    send(pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    refute SingleFlight.busy?(key)
  end
end
