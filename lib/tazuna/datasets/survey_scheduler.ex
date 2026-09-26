defmodule Tazuna.Datasets.SurveyScheduler do
  @moduledoc """
  情報収集を頼む時刻に起きるところ。**時計を持つのは tazuna です**（要約と同じ立場）。

  時刻は収集ごとに画面から決めます（`Tazuna.Datasets.SurveyPlan` の `run_at`）。
  空か、起点が決まっていなければ、その収集は自分からは回りません。

  **1 分ごとに起きて、予定を過ぎたものがあるかを見ます。** 過ぎてよいのは 30 分まで
  （立ち上げ直した拍子に、半日前の回を追いかけないため）。

  **取り込みが混んでいても、その回を落としません。** 次の予定の時刻まで、空くのを
  待って頼みます（`Tazuna.Datasets.Survey.run/3`）。待つあいだは次の起床でも
  新しく起こさない（1 本ずつ）。

  **走らせる前に控えます**（`last_run_at`）—— 待っている最中に同じ回の時刻が
  もう一度来て、二重に起こさないためです。
  """

  use GenServer

  require Logger

  alias Tazuna.Datasets
  alias Tazuna.Datasets.Survey
  alias Tazuna.Datasets.SurveyPlan
  alias Tazuna.Datasets.SurveyPlans
  alias Tazuna.Jst

  @tick_ms 60_000
  @grace_minutes 30
  # 次の予定が無い（時刻が 1 つだけ）ときに待つ上限
  @longest_wait_ms 24 * 60 * 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    tick()
    {:ok, %{task: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    tick()
    {:noreply, if(state.task, do: state, else: start_due(state))}
  end

  def handle_info({ref, _result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %{ref: ref}} = state) do
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp tick do
    Process.send_after(self(), :tick, Application.get_env(:tazuna, :survey_tick_ms, @tick_ms))
  end

  defp start_due(state) do
    now = DateTime.utc_now()

    found =
      Enum.find_value(Datasets.defined(), fn dataset ->
        with sweep when is_binary(sweep) <- dataset[:survey_plan_sweep],
             plan = Datasets.plan(dataset),
             true <- Datasets.ready_to_survey?(dataset, plan),
             %DateTime{} = at <- due(plan, now) do
          {dataset, plan, at}
        else
          _other -> nil
        end
      end)

    case found do
      nil ->
        state

      {dataset, plan, at} ->
        SurveyPlans.mark_run(dataset.collection, at)
        deadline = deadline(plan, now)

        task =
          Task.Supervisor.async_nolink(Tazuna.TaskSupervisor, fn ->
            result = Survey.run(dataset, plan, deadline)
            SurveyPlans.mark_result(dataset.collection, Survey.result_text(result))
            log(dataset.collection, result)
            result
          end)

        %{state | task: task}
    end
  end

  @doc """
  いま頼むべき予定の時刻（UTC）。無ければ `nil`。

  **予定は JST で書かれ、比べるのは UTC** です。最後に頼んだ予定より後のものだけ、
  過ぎて 30 分以内のものだけを見ます。
  """
  def due(%SurveyPlan{} = plan, now) do
    plan
    |> SurveyPlan.times()
    |> Enum.map(fn {hour, minute} -> Jst.utc_at(Jst.today(now), hour, minute) end)
    |> Enum.filter(fn at ->
      seconds = DateTime.diff(now, at)
      seconds >= 0 and seconds <= @grace_minutes * 60
    end)
    |> Enum.filter(&(is_nil(plan.last_run_at) or DateTime.compare(&1, plan.last_run_at) == :gt))
    |> Enum.max(DateTime, fn -> nil end)
  end

  @doc "次に頼む予定（UTC）。時刻を書いていなければ `nil`。"
  def next(%SurveyPlan{} = plan, now \\ DateTime.utc_now()) do
    today = Jst.today(now)

    plan
    |> SurveyPlan.times()
    |> Enum.flat_map(fn {hour, minute} ->
      [Jst.utc_at(today, hour, minute), Jst.utc_at(Date.add(today, 1), hour, minute)]
    end)
    |> Enum.filter(&(DateTime.compare(&1, now) == :gt))
    |> Enum.min(DateTime, fn -> nil end)
  end

  # **待つのは次の予定まで。** それを過ぎても待つと、次の回と同じ区画を二重に頼む
  defp deadline(plan, now) do
    wait =
      case next(plan, now) do
        nil -> @longest_wait_ms
        at -> max(DateTime.diff(at, now, :millisecond), 0)
      end

    System.monotonic_time(:millisecond) + wait
  end

  defp log(collection, :ok), do: Logger.info("情報収集を頼んだ（#{collection}）")

  defp log(collection, {:error, reason}),
    do: Logger.warning("情報収集を頼めなかった（#{collection}）: #{inspect(reason)}")
end
