defmodule Tazuna.Digest.Scheduler do
  @moduledoc """
  知らせる時刻に、まとめを作らせるところ。**時計を持つのは tazuna です**。

  時刻は話題ごとに画面から決めます（`Tazuna.Notify.Setting` の `digest_at`。
  例 `07:00,21:00`）。空なら、その話題は自分からは回りません。

  **1 分ごとに起きて、予定を過ぎたものがあるかを見ます。** 予定の時刻ちょうどでしか
  起こさない作りだと、立ち上げ直しや取り込みの混雑でその分を逃したときに、その回が
  丸ごと落ちます。逆に、いくら過ぎても追いかけると、夜中に立ち上げた拍子に朝の回が
  走ります —— 過ぎてよいのは 30 分までにしてあります。

  **走らせるのは 1 本ずつです。** Chiezo の取り込みは 1 本ずつしか走らないので、
  同時に頼んでも待たされるだけです（しかも断られます）。

  **走らせる前に控えます**（`last_digest_at`）。数分かかる段取りなので、走ってから
  控えると、その最中に同じ回の時刻がもう一度来て二重に起こします。
  """

  use GenServer

  alias Tazuna.Digest
  alias Tazuna.Jst
  alias Tazuna.Notify.Setting
  alias Tazuna.Notify.Settings
  alias Tazuna.Topics

  @tick_ms 60_000
  @grace_minutes 30

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

  # 走り終えた（結果を残すのは `Tazuna.Digest`。ここは次の回に備えるだけ）
  def handle_info({ref, _result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %{ref: ref}} = state) do
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp tick do
    Process.send_after(self(), :tick, Application.get_env(:tazuna, :digest_tick_ms, @tick_ms))
  end

  defp start_due(state) do
    case Enum.find_value(Topics.list(), &due(&1, DateTime.utc_now())) do
      nil ->
        state

      {topic, at} ->
        Settings.mark_digest(topic.collection, at)
        task = Task.Supervisor.async_nolink(Tazuna.TaskSupervisor, fn -> Digest.run(topic) end)
        %{state | task: task}
    end
  end

  @doc """
  その話題を、いま走らせるべきか。走らせるなら `{話題, 予定の時刻}` を返します。

  **予定は JST で書かれ、比べるのは UTC** です。同じ回を二度走らせないように、
  最後に走らせた予定より後のものだけを見ます。
  """
  def due(topic, now) do
    setting = Settings.get(topic.collection)

    setting
    |> Setting.digest_times()
    |> Enum.map(fn {hour, minute} -> Jst.utc_at(Jst.today(now), hour, minute) end)
    |> Enum.filter(&passed?(&1, now))
    |> Enum.filter(&after_last?(&1, setting.last_digest_at))
    # 同じ起床で 2 つ過ぎていたら、遅いほうだけ走らせる（古い回は追いかけない）
    |> Enum.max(DateTime, fn -> nil end)
    |> then(fn
      nil -> nil
      at -> {topic, at}
    end)
  end

  @doc """
  次に回る予定（UTC）。予定を書いていない話題では `nil` です。

  **画面に「次はいつか」を出すためのもの**です —— 下に並ぶのは前に走った回の記録
  なので、それだけだと、いま動いているのかどうかが読めません。

  **今日のうちに過ぎた時刻は明日のぶんとして返します。** もう来ない時刻を
  「次」として出すと、待っても来ません。
  """
  def next(topic, now \\ DateTime.utc_now()) do
    today = Jst.today(now)

    topic.collection
    |> Settings.get()
    |> Setting.digest_times()
    |> Enum.flat_map(fn {hour, minute} ->
      [Jst.utc_at(today, hour, minute), Jst.utc_at(Date.add(today, 1), hour, minute)]
    end)
    |> Enum.filter(&(DateTime.compare(&1, now) == :gt))
    |> Enum.min(DateTime, fn -> nil end)
  end

  # 予定を過ぎたか。過ぎすぎたものは追いかけない
  defp passed?(at, now) do
    seconds = DateTime.diff(now, at)
    seconds >= 0 and seconds <= @grace_minutes * 60
  end

  defp after_last?(_at, nil), do: true
  defp after_last?(at, last), do: DateTime.compare(at, last) == :gt
end
