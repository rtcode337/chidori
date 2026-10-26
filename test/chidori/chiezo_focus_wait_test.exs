defmodule Chidori.ChiezoFocusWaitTest do
  @moduledoc """
  人が押した割り込みは、Chiezo が取り込み中で断っても（409）、空くまで Chidori が待って頼み直す
  （`Chidori.Chiezo.focus/8`）。Chiezo は取り込み中の割り込みを積まずに断るため。
  """

  use ExUnit.Case, async: false

  alias Chidori.Chiezo
  alias Chidori.HttpStub

  @base "http://chiezo.test:7010"

  setup do
    {:ok, tries} = Agent.start_link(fn -> 0 end)
    me = self()

    # 2 回目までは取り込み中、3 回目で受け付ける
    HttpStub.stub(fn %{method: :post, url: url} ->
      n = Agent.get_and_update(tries, &{&1 + 1, &1 + 1})
      send(me, {:asked, n, url})

      if n < 3,
        do: {:ok, %{status: 409, body: ~s({"error":"busy"})}},
        else: {:ok, %{status: 200, body: "{}"}}
    end)

    :ok
  end

  test "人が押した 1 回は、空きしだい頼み直す（押した人には待っていると返す）" do
    assert Chiezo.by_hand(fn -> Chiezo.focus(@base, "chidori_x", "直して", ["甲"]) end) ==
             {:error, :chiezo_busy_queued}

    # 裏で頼み直し、3 回目で通る（押した 1 回のまま）
    assert_receive {:asked, 3, url}, 2_000
    assert url =~ "/v1/collect/chidori_x/focus?manual=true"
  end

  test "時計の回（人が押していない）は待たずに断られたと返す（呼ぶ側が自分で待つ）" do
    assert Chiezo.focus(@base, "chidori_x", "直して", ["甲"]) == {:error, :chiezo_busy}
    refute_receive {:asked, 2, _url}, 100
  end

  test "待つのを自分で持つ呼び手（when_free の中）には、裏で待たせない" do
    deadline = System.monotonic_time(:millisecond) + 5_000

    assert Chiezo.by_hand(fn ->
             Chiezo.when_free(fn -> Chiezo.focus(@base, "chidori_x", "直して", ["甲"]) end, deadline)
           end) == :ok

    # 頼み直したのは when_free の 3 回だけ（裏の 1 本が重ならない）
    refute_receive {:asked, 4, _url}, 200
  end
end
