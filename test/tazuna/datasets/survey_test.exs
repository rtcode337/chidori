defmodule Tazuna.Datasets.SurveyTest do
  @moduledoc """
  情報収集を、決めた時刻に tazuna が起こすところ。見ているのは 3 つ ——
  **区画は名指しせず Chiezo に選ばせること**、**起点はざっと見ると共通で Chiezo へ送ること**、
  **取り込み中なら空くまで待つこと**です。
  """

  use Tazuna.DataCase, async: false

  alias Tazuna.Datasets
  alias Tazuna.Datasets.Survey
  alias Tazuna.Datasets.SurveyPlan
  alias Tazuna.Datasets.SurveyPlans
  alias Tazuna.Datasets.SurveyScheduler
  alias Tazuna.HttpStub

  @near "35.6700,139.7600/35.6900,139.7800"
  @far "34.6000,135.4000/34.7000,135.6000"

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
        "sweeps" => [%{"name" => "情報収集", "enabled" => false, "partitions_per_run" => 2}],
        "partitions" => [
          %{"key" => @far, "count" => 1, "visits" => %{}},
          %{"key" => @near, "count" => 1, "visits" => %{}}
        ]
      }

      HttpStub.stub(fn
        %{method: :post, url: url, body: body} ->
          send(test_pid, {:run, url, if(body in [nil, ""], do: nil, else: Jason.decode!(body))})
          Agent.get_and_update(runs, fn [reply | rest] -> {reply, rest} end)

        %{url: "http://chiezo.test:7010/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => [item]}))

        %{url: "http://chiezo.test:7010/v1/sources"} ->
          HttpStub.ok(~s({"sources":[]}))

        %{url: _detail} ->
          HttpStub.ok(Jason.encode!(item))
      end)
    end

    test "情報収集の回を名前で起こし、区画は Chiezo に選ばせる", %{dataset: dataset, plan: plan} do
      {:ok, runs} = Agent.start_link(fn -> [HttpStub.ok("{}")] end)
      stub(dataset, runs)

      assert :ok = Survey.run(dataset, plan, System.monotonic_time(:millisecond) + 1_000)

      assert_received {:run, url, body}
      assert URI.decode(url) =~ "sweep=情報収集"
      # 区画を名指ししない（選び方を tazuna に書き写さない）
      assert body == nil
    end

    test "取り込み中なら、空くまで待って頼む", %{dataset: dataset, plan: plan} do
      busy = {:ok, %{status: 409, body: "{}"}}
      {:ok, runs} = Agent.start_link(fn -> [busy, busy, HttpStub.ok("{}")] end)
      stub(dataset, runs)

      assert :ok = Survey.run(dataset, plan, System.monotonic_time(:millisecond) + 5_000)
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

    test "起点が無ければ頼まない", %{dataset: dataset} do
      # 画面からは既定（東京駅）が入るので、ここへ来るのは起点を持たない対象だけ
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

  describe "起点はざっと見ると共通" do
    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      %{dataset: Datasets.get("meals")}
    end

    defp stub_existing(test_pid) do
      item = %{"name" => "tazuna_meals", "enabled" => true, "sweeps" => [], "partitions" => []}

      HttpStub.stub(fn
        %{method: :patch, body: body} ->
          send(test_pid, {:patched, Jason.decode!(body)})
          HttpStub.ok("{}")

        %{url: "http://chiezo.test:7010/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => [item]}))

        %{url: "http://chiezo.test:7010/v1/sources"} ->
          HttpStub.ok(~s({"sources":[]}))

        %{url: _detail} ->
          HttpStub.ok(Jason.encode!(item))
      end)
    end

    test "決めていなければ東京駅", %{dataset: dataset} do
      plan = Datasets.plan(dataset)
      assert {plan.place, plan.lat, plan.lon} == {"東京駅", 35.681, 139.767}

      # 既定を返すだけで、決めたことにはしない（回り直しの起点にならない）
      assert plan.place_set_at == nil
    end

    test "起点を決め直すと、Chiezo の収集の起点も書き換える", %{dataset: dataset} do
      stub_existing(self())

      assert {:ok, _plan} =
               Datasets.put_origin(dataset, %{name: "京都駅", lat: 34.985, lon: 135.758})

      assert_received {:patched, %{"partition" => %{"origin" => [34.985, 135.758]}}}
    end

    test "送り直すときも、決めた起点を送る（東京駅へ戻さない）", %{dataset: dataset} do
      {:ok, _plan} =
        SurveyPlans.put_place(dataset.collection, %{name: "京都駅", lat: 34.985, lon: 135.758})

      stub_existing(self())

      assert :ok = Datasets.push(dataset)
      assert_received {:patched, %{"partition" => %{"origin" => [34.985, 135.758]}}}
    end
  end
end
