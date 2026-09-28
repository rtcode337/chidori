defmodule Tazuna.Datasets.ClosedTwinsScheduler do
  @moduledoc """
  閉店の片割れを確かめてもらう時計（`Tazuna.Datasets.ClosedTwins`）。

  **1 時間ごとに起きて、前に頼めてから 1 日たっていれば探します。** 閉店は
  ざっと見るの回が区画を回りながら少しずつ消していくもので、1 日に何十件も
  増えはしない —— 毎時探しても、同じ墓標の周りを読み直すだけになる。

  **断られたら次の起床でまた試します**（取り込みが混んでいると割り込みは断られる）。
  頼むものが無かった日も「探した」として 1 日空けます。

  対象は定義に `closed_twins: true` を持つ収集だけ（場所を持つ収集でしか探せない）。
  """

  use GenServer

  require Logger

  alias Tazuna.Chiezo
  alias Tazuna.Datasets
  alias Tazuna.Datasets.ClosedTwins

  @tick_ms 60 * 60 * 1000
  @every_ms 24 * 60 * 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    tick()
    {:ok, %{done_at: %{}, task: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    tick()
    {:noreply, if(state.task, do: state, else: start_due(state))}
  end

  def handle_info({ref, {collection, result}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    log(collection, result)

    done_at =
      case result do
        {:ok, _count} -> Map.put(state.done_at, collection, System.monotonic_time(:millisecond))
        {:error, _reason} -> state.done_at
      end

    {:noreply, %{state | task: nil, done_at: done_at}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %{ref: ref}} = state) do
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp tick do
    Process.send_after(self(), :tick, @tick_ms)
  end

  defp start_due(state) do
    now = System.monotonic_time(:millisecond)

    with base when is_binary(base) <- Chiezo.base_url(),
         %{} = dataset <-
           Enum.find(Datasets.defined(), fn dataset ->
             dataset[:closed_twins] == true and
               (is_nil(state.done_at[dataset.collection]) or
                  now - state.done_at[dataset.collection] >= @every_ms)
           end) do
      task =
        Task.Supervisor.async_nolink(Tazuna.TaskSupervisor, fn ->
          {dataset.collection, ClosedTwins.ask(base, dataset)}
        end)

      %{state | task: task}
    else
      _nothing -> state
    end
  end

  defp log(collection, {:ok, 0}), do: Logger.debug("閉店の片割れは見つからなかった（#{collection}）")

  defp log(collection, {:ok, count}),
    do: Logger.info("閉店の片割れ #{count} 件の確認を頼んだ（#{collection}）")

  defp log(collection, {:error, reason}),
    do: Logger.warning("閉店の片割れの確認を頼めなかった（#{collection}）: #{inspect(reason)}")
end
