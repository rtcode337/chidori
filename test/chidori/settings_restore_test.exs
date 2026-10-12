defmodule Chidori.SettingsRestoreTest do
  @moduledoc """
  Chiezo の収集に残っている設定から、Chidori の設定を戻す。見ているのは、
  **巡回の間隔はいちばん多いものを戻すこと**、**整理の時計の有無に揃えること**、
  **知名度の下限を名簿の指定から戻すこと**、**変えたものだけを返すこと**です。
  """

  use Chidori.DataCase, async: false

  alias Chidori.CollectPace
  alias Chidori.Relations.Settings
  alias Chidori.SettingsRestore

  setup do
    on_exit(fn ->
      for kind <- CollectPace.kinds(), do: :persistent_term.erase({CollectPace, kind})
      :persistent_term.erase({CollectPace, :tidy_stops})
    end)
  end

  defp sweep(name, minutes, opts \\ []),
    do: Map.merge(%{"name" => name, "interval_minutes" => minutes}, Map.new(opts))

  defp collection(name, sweeps, extra \\ %{}),
    do: Map.merge(%{"name" => name, "requested_by" => "chidori", "sweeps" => sweeps}, extra)

  test "Chiezo に残っている間隔・整理の止め方・知名度の下限に揃える" do
    collections = [
      collection("chidori_news", [sweep("整理", 1440)]),
      collection("chidori_tech", [sweep("整理", 1440)]),
      # 送れなかった収集が混ざっていても、いちばん多い間隔を戻す
      collection("chidori_market", [sweep("整理", 720)]),
      # 時計を外した巡回の間隔は数えない（止める前の値のまま残っている）
      collection("chidori_books", [sweep("整理", 360, %{"by_caller" => true})]),
      collection("chidori_people", [sweep("ざっと見る", 240), sweep("整理", 1440)], %{
        "extract" => %{"source" => "jawiki", "min_extra" => %{"pageviews_month" => 3000}}
      }),
      # 他のアプリの収集は見ない
      %{"name" => "other", "requested_by" => "sample-app", "sweeps" => [sweep("整理", 2880)]}
    ]

    assert {:ok, result} = SettingsRestore.run(fn -> {:ok, collections} end)

    assert result.paces == [{:tidy, 1440}, {:scan, 240}]
    assert CollectPace.minutes(:tidy) == 1440
    assert result.stopped == ["chidori_books"]
    assert CollectPace.tidy_stopped?("chidori_books")
    assert result.min_pageviews == 3000
    assert Settings.min_pageviews("people") == 3000
  end

  test "Chiezo で整理の時計が戻っていれば、手元の「回さない」を外す" do
    CollectPace.stop_tidy("chidori_news", true, nil)

    assert {:ok, %{resumed: ["chidori_news"], stopped: []}} =
             SettingsRestore.run(fn -> {:ok, [collection("chidori_news", [sweep("整理", 720)])]} end)

    refute CollectPace.tidy_stopped?("chidori_news")
  end

  test "同じなら何も変えない" do
    collections = [collection("chidori_news", [sweep("整理", 720), sweep("ざっと見る", 120)])]

    assert {:ok, %{paces: [], stopped: [], resumed: [], min_pageviews: nil}} =
             SettingsRestore.run(fn -> {:ok, collections} end)
  end

  test "Chiezo を読めなければ何もしない" do
    assert {:error, :chiezo_unavailable} =
             SettingsRestore.run(fn -> {:error, :chiezo_unavailable} end)
  end
end
