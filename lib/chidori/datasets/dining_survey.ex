defmodule Chidori.Datasets.DiningSurvey do
  @moduledoc """
  **食事処の情報収集を、決めた時刻に起こす時計**（範囲ごとの収集のぜんぶ）。

  食事処は 1 件ずつ web で営業を確かめ、足りない店を外から探す仕事なので、重い相手
  （外部の検索が得意な相手に、考える量を多く）で回します（`Chidori.Datasets.Dining`）。
  **何時に何回起こすかを Chidori の側で決めて費用を抑える**ので、Chiezo の巡回の時計は
  外してあり（`by_caller`）、ここが名指しで 1 回ずつ起こします（`Chidori.Chiezo.run/3`。
  **ふつうの回として走る**ので、区画の印も進み具合も進む）。

  ## 時計

  **決めた時刻（JST）に起こします**（設定ページの「Chiezo 収集」の表、食事処の
  「情報収集」の行。`Chidori.Datasets.DiningSurveySetting`）。**時刻を書いていなければ
  起こしません（既定）** —— 時計は Chidori の中にあるので、本番とテストの 2 つを
  立てていると同じ回が二重に走る。時刻を書いた Chidori だけが起こす。

  5 分ごとに起きて、予定を過ぎた回があれば範囲ごとに起こします。**過ぎて 30 分までの
  回だけ拾います**（要約の時計と同じ。夜中に立ち上げた拍子に朝の回が走らないように）。
  **起こせなかった範囲は、次の予定まで起きるたびに試し直します**（起こし終えた範囲は
  予定ごとに控えるので、試し直しで同じ範囲を二度起こさない）。**止めた範囲は起こしません**
  （Chiezo が断る。時計は人が押した 1 回ではないので `by_hand` で囲まない）。
  """

  use GenServer

  require Logger

  alias Chidori.Chiezo
  alias Chidori.Datasets.Dining
  alias Chidori.Datasets.DiningAreas
  alias Chidori.Datasets.DiningSurveySetting

  @tick_ms 5 * 60 * 1000
  # 起動直後は少し待つ（立ち上げの最中に Chiezo を叩かない）
  @first_tick_ms 60 * 1000
  # 予定を過ぎてから拾う長さ（要約の時計と同じ）
  @grace_seconds 30 * 60

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, @first_tick_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    maybe_wake(DateTime.utc_now())
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp maybe_wake(now) do
    setting = DiningSurveySetting.get()
    collections = Enum.map(DiningAreas.list(), &Dining.collection/1)

    with {slot, waiting} when waiting != [] <- due(setting, collections, now),
         base when is_binary(base) <- Chiezo.base_url() do
      results = Enum.map(waiting, &{&1, wake(base, &1)})
      done = for {name, result} <- results, result in [:ok, :stopped], do: name
      DiningSurveySetting.record(slot, done, summary(results))
    else
      _nothing -> :ok
    end
  end

  # 1 つの範囲を起こす。止めた範囲は「済んだ」に数える（起こさないと決めてあるので、試し直さない）
  defp wake(base, name) do
    case Chiezo.run(base, name, sweep: Dining.survey_sweep(), timeout: 60_000) do
      :ok ->
        :ok

      {:error, :collection_disabled} ->
        :stopped

      {:error, reason} ->
        Logger.info("食事処の情報収集を起こせませんでした（#{name}）: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp summary(results) do
    count = fn want -> Enum.count(results, fn {_name, result} -> result == want end) end
    failed = Enum.count(results, fn {_name, result} -> match?({:error, _}, result) end)

    "起こした #{count.(:ok)} 範囲" <>
      if(count.(:stopped) > 0, do: "・止めてある #{count.(:stopped)} 範囲", else: "") <>
      if(failed > 0, do: "・起こせなかった #{failed} 範囲（次の起床で試し直します）", else: "")
  end

  @doc """
  起こす番か。`{予定の時刻, まだ起こしていない収集}` か nil。

  直近の予定（今以前で最も新しい時刻）を、**まだ受け持っていなければ 30 分まで**拾い、
  **受け持ったあとは次の予定まで**、起こし終えていない収集を試し直す。
  """
  def due(%DiningSurveySetting{} = setting, collections, now) do
    with %DateTime{} = slot <- last_slot(setting, now) do
      started? = setting.slot_at != nil and DateTime.compare(setting.slot_at, slot) == :eq
      done = if started?, do: setting.done || [], else: []
      waiting = Enum.reject(collections, &(&1 in done))

      if started? or DateTime.diff(now, slot, :second) <= @grace_seconds,
        do: {slot, waiting},
        else: nil
    end
  end

  @doc "次に起こす予定（UTC）。時刻を決めていなければ nil。"
  def next_at(%DiningSurveySetting{} = setting, now \\ DateTime.utc_now()) do
    setting
    |> slots(now, [0, 1])
    |> Enum.filter(&(DateTime.compare(&1, now) == :gt))
    |> Enum.min(DateTime, fn -> nil end)
  end

  # 今以前で最も新しい予定（今日と昨日の JST から）。時刻が無ければ nil
  defp last_slot(setting, now) do
    setting
    |> slots(now, [-1, 0])
    |> Enum.filter(&(DateTime.compare(&1, now) != :gt))
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp slots(setting, now, days) do
    today = Chidori.Jst.today(now)

    for offset <- days,
        {hour, minute} <- DiningSurveySetting.times(setting),
        do: Chidori.Jst.utc_at(Date.add(today, offset), hour, minute)
  end
end
