defmodule Chidori.Datasets.SurveyClock do
  @moduledoc """
  **情報収集（とご当地グルメの漏れ探し）を、決めた時刻に起こす時計**（定義に `survey_clock: true` を
  持つ対象のぜんぶ。食事処の範囲ごとの収集・ご当地グルメ・アニメ聖地）。起こす巡回は定義の
  `clocked_sweeps`（書いていなければ情報収集だけ）。

  ご当地グルメの漏れ探しも重い相手で回す回なので、情報収集と同じく Chiezo の時計を外して
  ここから起こす。Chiezo の時計で回していた頃は、情報収集をいつ何回起こすかを Chidori で
  決めても、後に続く漏れ探しは Chiezo の間隔のまま枠を使っていた。

  情報収集は外の頁を何枚も当たる仕事なので、重い相手（外部の検索が得意な相手に、考える量を
  多く）で回します（`Chidori.Datasets.Dining` / `Gourmet` / `AnimeSeichi`）。
  **何時に何回起こすかを Chidori の側で決めて費用を抑える**ので、Chiezo の巡回の時計は
  外してあり（`by_caller`）、ここが名指しで 1 回ずつ起こします（`Chidori.Chiezo.run/3`。
  **ふつうの回として走る**ので、区画の印も進み具合も進む）。

  ## 時計

  **収集と巡回の組ごとに決めた時刻（JST）に起こします**（収集の一覧（設定の `?tab=chiezo`）の表の
  その巡回の行か、データ収集の画面の「Chiezo の収集」。`Chidori.Datasets.SurveySetting`）。1 回十分ほど
  かかるので、全部を同じ時刻にすると組の数だけ並んで取り込みを占める —— 時刻をずらして書く。
  **時刻を書いていない組は起こしません（既定）** —— 時計は Chidori の中にあるので、
  本番とテストの 2 つを立てていると同じ回が二重に走る。時刻を書いた Chidori だけが起こす。

  5 分ごとに起きて、予定を過ぎた収集があれば起こします。**過ぎて 30 分までの回だけ
  拾います**（要約の時計と同じ。夜中に立ち上げた拍子に朝の回が走らないように）。
  **起こせなかった収集は、次の予定まで起きるたびに試し直します**（予定ごとに起こせたかを
  控えるので、試し直しで同じ収集を二度起こさない）。**止めた収集は起こしません**
  （Chiezo が断る。時計は人が押した 1 回ではないので `by_hand` で囲まない）。
  """

  use GenServer

  require Logger

  alias Chidori.Chiezo
  alias Chidori.Datasets
  alias Chidori.Datasets.SurveySetting
  alias Chidori.SweepNames

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
    for {name, sweep} <- clocked_sweeps(),
        setting = SurveySetting.get(name, sweep),
        %DateTime{} = slot <- [due(setting, now)],
        base = Chiezo.base_url(),
        is_binary(base) do
      result = wake(base, name, sweep)
      SurveySetting.record(name, sweep, slot, result in [:ok, :stopped], summary(result))
    end
  end

  # 1 つの巡回を起こす。止めた収集は「済んだ」に数える（起こさないと決めてあるので、試し直さない）
  defp wake(base, name, sweep) do
    case Chiezo.run(base, name, sweep: sweep, timeout: 60_000) do
      :ok ->
        :ok

      {:error, :collection_disabled} ->
        :stopped

      {:error, reason} ->
        Logger.info("#{sweep}を起こせませんでした（#{name}）: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp summary(:ok), do: "起こしました"
  defp summary(:stopped), do: "収集を止めてあるので起こしませんでした"
  defp summary({:error, reason}), do: "起こせませんでした（次の起床で試し直します）: #{inspect(reason)}"

  @doc "時刻で起こす収集の名前（定義に `survey_clock: true` を持つ対象）。"
  def clocked, do: for(d <- Datasets.list(), d[:survey_clock], do: d.collection)

  @doc "時刻で起こす収集と巡回の組（`{収集の名前, 巡回の名前}`）。"
  def clocked_sweeps,
    do:
      for(
        d <- Datasets.list(),
        d[:survey_clock],
        sweep <- sweeps_of(d),
        do: {d.collection, sweep}
      )

  @doc "その対象で時刻で起こす巡回（定義の `clocked_sweeps`。書いていなければ情報収集だけ）。"
  def sweeps_of(dataset), do: dataset[:clocked_sweeps] || [SweepNames.survey()]

  @doc "その収集のその巡回を、この時計が起こすか。"
  def clocked?(collection, sweep), do: {collection, sweep} in clocked_sweeps()

  @doc """
  起こす番か。起こすなら予定の時刻、そうでなければ nil。

  直近の予定（今以前で最も新しい時刻）を、**まだ受け持っていなければ 30 分まで**拾い、
  **受け持って起こせなかったときは次の予定まで**試し直す。
  """
  def due(%SurveySetting{} = setting, now) do
    with %DateTime{} = slot <- last_slot(setting, now) do
      started? = setting.slot_at != nil and DateTime.compare(setting.slot_at, slot) == :eq

      cond do
        started? and setting.slot_ok -> nil
        started? -> slot
        DateTime.diff(now, slot, :second) <= @grace_seconds -> slot
        true -> nil
      end
    end
  end

  @doc "次に起こす予定（UTC）。時刻を決めていなければ nil。"
  def next_at(%SurveySetting{} = setting, now \\ DateTime.utc_now()) do
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
        {hour, minute} <- SurveySetting.times(setting),
        do: Chidori.Jst.utc_at(Date.add(today, offset), hour, minute)
  end
end
