defmodule Tazuna.Datasets.SurveyTest do
  @moduledoc """
  整理を、決めた起点から放射状に、決めた時刻に頼むところ。見ているのは 3 つ ——
  **区画の選び方がざっと見ると同じこと**（まだ見ていないものが先、同じなら近い順）、
  **起点を変えたら回り直すこと**、**取り込み中なら空くまで待つこと**です。
  """

  use Tazuna.DataCase, async: false

  alias Tazuna.Datasets
  alias Tazuna.Datasets.Survey
  alias Tazuna.Datasets.SurveyPlan
  alias Tazuna.Datasets.SurveyPlans
  alias Tazuna.Datasets.SurveyScheduler
  alias Tazuna.HttpStub

  # 東京駅のまわり（近い順に 近 → 中 → 遠）
  @near "35.6700,139.7600/35.6900,139.7800"
  @middle "35.7000,139.8000/35.7200,139.8200"
  @far "34.6000,135.4000/34.7000,135.6000"
  @tokyo {35.681, 139.767}

  defp partition(key, visits \\ %{}), do: %{key: key, count: 10, visits: visits}

  describe "区画の選び方" do
    test "まだ見ていない区画を、起点に近い順に" do
      partitions = [partition(@far), partition(@middle), partition(@near)]
      assert Survey.pick(partitions, "整理", 2, @tokyo, nil) == [@near, @middle]
    end

    test "見た区画は、見た時刻の古い順で後に回る（ざっと見ると同じ）" do
      partitions = [
        partition(@near, %{"整理" => "2026-09-20T00:00:00+00:00"}),
        partition(@middle, %{"整理" => "2026-09-19T00:00:00+00:00"}),
        partition(@far)
      ]

      assert Survey.pick(partitions, "整理", 3, @tokyo, nil) == [@far, @middle, @near]
    end

    test "起点を決める前に見た区画は、まだ見ていないものとして扱う" do
      # 起点を変えたら、新しい起点のまわりから回り直す
      since = ~U[2026-09-21 00:00:00Z]

      partitions = [
        partition(@near, %{"整理" => "2026-09-20T00:00:00+00:00"}),
        partition(@middle, %{"整理" => "2026-09-22T00:00:00+00:00"}),
        partition(@far)
      ]

      assert Survey.pick(partitions, "整理", 3, @tokyo, since) == [@near, @far, @middle]
    end

    test "ほかの巡回の印は見ない" do
      partitions = [partition(@near, %{"ざっと見る" => "2026-09-22T00:00:00+00:00"}), partition(@far)]
      assert Survey.pick(partitions, "整理", 1, @tokyo, nil) == [@near]
    end
  end

  describe "時計" do
    defp plan(attrs), do: struct(%SurveyPlan{collection: "c", lat: 35.0, lon: 139.0}, attrs)

    test "予定を過ぎて 30 分までの回を、まだ頼んでいなければ返す" do
      # 03:00 JST = 前日 18:00 UTC
      now = ~U[2026-09-24 18:10:00Z]
      assert SurveyScheduler.due(plan(run_at: "03:00"), now) == ~U[2026-09-24 18:00:00Z]

      assert SurveyScheduler.due(
               plan(run_at: "03:00", last_run_at: ~U[2026-09-24 18:00:00Z]),
               now
             ) ==
               nil

      assert SurveyScheduler.due(plan(run_at: "03:00"), ~U[2026-09-24 19:00:00Z]) == nil
    end

    test "時刻を書いていなければ回らない" do
      assert SurveyScheduler.due(plan(run_at: ""), ~U[2026-09-24 18:10:00Z]) == nil
      assert SurveyScheduler.next(plan(run_at: "")) == nil
    end

    test "次の予定は、今日のうちに過ぎた時刻なら明日のぶん" do
      now = ~U[2026-09-24 18:10:00Z]
      assert SurveyScheduler.next(plan(run_at: "03:00,15:00"), now) == ~U[2026-09-25 06:00:00Z]
    end
  end

  describe "頼む" do
    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

      dataset = Datasets.get("meals")

      {:ok, _plan} =
        SurveyPlans.put_place(dataset.collection, %{name: "東京駅", lat: 35.681, lon: 139.767})

      %{dataset: dataset, plan: SurveyPlans.get(dataset.collection)}
    end

    defp stub(dataset, runs) do
      test_pid = self()

      item = %{
        "name" => dataset.collection,
        "enabled" => true,
        "sweeps" => [%{"name" => "整理", "enabled" => false, "partitions_per_run" => 2}],
        "partitions" => [
          %{"key" => @far, "count" => 1, "visits" => %{}},
          %{"key" => @middle, "count" => 1, "visits" => %{}},
          %{"key" => @near, "count" => 1, "visits" => %{}}
        ]
      }

      HttpStub.stub(fn
        %{method: :post, url: url, body: body} ->
          send(test_pid, {:run, url, Jason.decode!(body)})
          Agent.get_and_update(runs, fn [reply | rest] -> {reply, rest} end)

        %{url: "http://chiezo.test:7010/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => [item]}))

        %{url: "http://chiezo.test:7010/v1/sources"} ->
          HttpStub.ok(~s({"sources":[]}))

        %{url: _detail} ->
          HttpStub.ok(Jason.encode!(item))
      end)
    end

    test "起点に近い区画を、整理の回として名指しで頼む", %{dataset: dataset, plan: plan} do
      {:ok, runs} = Agent.start_link(fn -> [HttpStub.ok("{}")] end)
      stub(dataset, runs)

      assert {:ok, [@near, @middle]} =
               Survey.run(dataset, plan, System.monotonic_time(:millisecond) + 1_000)

      assert_received {:run, url, body}
      assert URI.decode(url) =~ "sweep=整理"
      assert body["partitions"] == [@near, @middle]
    end

    test "取り込み中なら、空くまで待って頼む", %{dataset: dataset, plan: plan} do
      busy = {:ok, %{status: 409, body: "{}"}}
      {:ok, runs} = Agent.start_link(fn -> [busy, busy, HttpStub.ok("{}")] end)
      stub(dataset, runs)

      assert {:ok, _keys} = Survey.run(dataset, plan, System.monotonic_time(:millisecond) + 5_000)
      assert Agent.get(runs, & &1) == []
    end

    test "次の予定までに空かなければ諦める", %{dataset: dataset, plan: plan} do
      busy = {:ok, %{status: 409, body: "{}"}}
      {:ok, runs} = Agent.start_link(fn -> List.duplicate(busy, 1_000) end)
      stub(dataset, runs)

      assert {:error, :chiezo_busy} =
               Survey.run(dataset, plan, System.monotonic_time(:millisecond) + 50)

      assert Survey.result_text({:error, :chiezo_busy}) =~ "空きませんでした"
    end

    test "起点が決まっていなければ頼まない", %{dataset: dataset} do
      assert {:error, :no_place} =
               Survey.run(dataset, %SurveyPlan{collection: dataset.collection}, 0)
    end
  end

  describe "時刻の保存" do
    test "書き方を揃えて持ち、読めないものは弾く" do
      assert {:ok, plan} = SurveyPlans.put_times("c", "3:00、1500")
      assert plan.run_at == "03:00,15:00"
      assert {:error, changeset} = SurveyPlans.put_times("c", "朝")
      assert changeset.errors[:run_at]
    end
  end
end
