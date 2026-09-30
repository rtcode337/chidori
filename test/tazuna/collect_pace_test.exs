defmodule Tazuna.CollectPaceTest do
  @moduledoc """
  巡回の間隔（設定ページで変える）。見ているのは 3 つ —— **巡回を組むときに
  いまの間隔を読むこと**、**区画を回る巡回は一周の日数も同じ比で伸ばすこと**、
  **Chiezo へは間隔だけを、tazuna の収集の該当する巡回にだけ送ること**です。
  """

  use Tazuna.DataCase, async: false

  alias Tazuna.CollectPace
  alias Tazuna.HttpStub

  setup do
    on_exit(fn ->
      for kind <- CollectPace.kinds(), do: :persistent_term.erase({CollectPace, kind})
    end)
  end

  test "決めていなければ既定の間隔" do
    assert CollectPace.minutes(:tidy) == 720
    assert CollectPace.minutes(:scan) == 120
  end

  test "保存した間隔で巡回を組む（コンパイル時の定数にしない）" do
    assert :ok = CollectPace.put(:tidy, 1440)

    assert Tazuna.SweepNames.tidy_minutes() == 1440

    tidy =
      Tazuna.Datasets.Books.sweeps()
      |> Enum.find(&(&1.name == "整理"))

    assert tidy.interval_minutes == 1440
  end

  test "区画を回る巡回は、一周の日数も同じ比で伸ばす（1 回に見る量を変えない）" do
    assert CollectPace.days(:scan, 30) == 30
    assert :ok = CollectPace.put(:scan, 240)
    assert CollectPace.days(:scan, 30) == 60
  end

  test "選べない間隔は断る" do
    assert {:error, :not_a_choice} = CollectPace.put(:tidy, 7)
    assert CollectPace.minutes(:tidy) == 720
  end

  test "保存したものは起動時に読み込む" do
    assert :ok = CollectPace.put(:scan, 360)
    :persistent_term.erase({CollectPace, :scan})
    assert CollectPace.minutes(:scan) == 120

    CollectPace.load_all()

    assert CollectPace.minutes(:scan) == 360
  end

  test "Chiezo には、tazuna の収集の該当する巡回にだけ間隔を送る" do
    parent = self()

    collections = [
      %{
        "name" => "tazuna_tech",
        "requested_by" => "tazuna",
        "sweeps" => [
          %{"name" => "機械収集"},
          %{"name" => "整理"},
          # 時計を持たない巡回には送らない
          %{"name" => "要約", "on_demand" => true}
        ]
      },
      %{"name" => "tazuna_meals", "sweeps" => [%{"name" => "ざっと見る"}, %{"name" => "情報収集"}]},
      # 他のアプリの収集には送らない
      %{"name" => "tl_lunch", "requested_by" => "travel-log", "sweeps" => [%{"name" => "整理"}]}
    ]

    HttpStub.stub(fn
      %{method: :get, url: url} ->
        if String.ends_with?(url, "/v1/collect"),
          do: HttpStub.ok(Jason.encode!(%{"collections" => collections})),
          else: HttpStub.ok("{}")

      %{method: :patch, url: url, body: body} ->
        send(parent, {:patched, URI.decode(url), Jason.decode!(body)})
        HttpStub.ok("{}")
    end)

    assert {:ok, %{sent: sent, failed: []}} = CollectPace.apply("http://chiezo.test")
    assert Enum.sort(sent) == [{"tazuna_meals", "ざっと見る"}, {"tazuna_tech", "整理"}]

    assert_received {:patched, "http://chiezo.test/v1/collect/tazuna_tech/sweeps/整理", body}
    assert body == %{"interval_minutes" => 720, "keep_per_run" => true}
    assert_received {:patched, "http://chiezo.test/v1/collect/tazuna_meals/sweeps/ざっと見る", _}
    refute_received {:patched, _url, _body}
  end
end
