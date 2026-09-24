defmodule Tazuna.Datasets.Survey do
  @moduledoc """
  整理の回を、**tazuna が決めた起点から放射状に**、決めた時刻に頼むところ。

  Chiezo の側の整理は止めておき（自分の時計では走らない）、tazuna が時刻に起きて
  区画を選び、名指しで 1 回走らせます（`Chiezo.run/3` の `partitions`）。名指しの回も
  **ふつうの回として走る**ので、見た印も進み具合も Chiezo 側に付きます。

  **区画の選び方は「ざっと見る」と同じ**です（Chiezo の `partition.pick`）——
  その巡回で見た時刻の古い順、同じなら起点に近い順。違うのは 2 つだけです。

  - 起点は収集の `origin` ではなく、tazuna で決めたもの（ざっと見るの起点は動かさない）
  - **起点を決めた時刻より前に見た区画は「まだ見ていない」として扱う** ——
    起点を変えたら、新しい起点のまわりから回り直す

  **取り込み中なら空くまで待ちます**（`Chiezo.when_free/2`）。待つのは次の予定の
  時刻までで、それを過ぎたらその回は諦めます。
  """

  alias Tazuna.Chiezo
  alias Tazuna.Datasets
  alias Tazuna.Datasets.SurveyPlan

  @doc """
  次に見る区画を `count` 件。**まだ見ていないもの（起点を決めてから）が先、
  同じなら起点に近い順**。
  """
  def pick(partitions, sweep, count, {lat, lon}, since) do
    scale = :math.cos(lat * :math.pi() / 180)

    partitions
    |> Enum.sort_by(fn partition ->
      {seen_since(partition, sweep, since), distance(partition.key, lat, lon, scale),
       partition.key}
    end)
    |> Enum.take(max(count, 0))
    |> Enum.map(& &1.key)
  end

  # その巡回で見た時刻（ISO8601）。**起点を決める前のものは空**（まだ見ていない扱い）
  defp seen_since(partition, sweep, since) do
    with at when is_binary(at) <- (partition[:visits] || %{})[sweep],
         {:ok, seen, _offset} <- DateTime.from_iso8601(at),
         true <- is_nil(since) or DateTime.compare(seen, since) != :lt do
      DateTime.to_iso8601(seen)
    else
      _other -> ""
    end
  end

  # 区画の真ん中までの遠さ（並べるためだけの値。平らな地図とみなした近似）。
  # 読めない鍵は末尾へ
  defp distance(key, lat0, lon0, scale) do
    with [south_west, north_east] <- String.split(key, "/"),
         [s, w] <- numbers(south_west),
         [n, e] <- numbers(north_east) do
      dy = (s + n) / 2 - lat0
      dx = ((w + e) / 2 - lon0) * scale
      dy * dy + dx * dx
    else
      _other -> :infinity
    end
  end

  defp numbers(text) do
    text
    |> String.split(",")
    |> Enum.map(&Float.parse/1)
    |> Enum.map(fn
      {value, ""} -> value
      _other -> nil
    end)
  end

  @doc """
  いま 1 回頼みます。`{:ok, 頼んだ区画}` か `{:error, 理由}`。

  `deadline` は `System.monotonic_time(:millisecond)` の値で、**取り込みが空くのを
  そこまで待ちます**。
  """
  def run(%{collection: name} = dataset, %SurveyPlan{} = plan, deadline) do
    sweep = dataset.survey_plan_sweep

    with {:ok, base} <- Datasets.base_url(),
         true <- SurveyPlan.placed?(plan) || {:error, :no_place},
         {:ok, collection} <- Chiezo.collection(base, name),
         %{} <- collection || {:error, :not_requested},
         [_ | _] = keys <- keys_for(collection, sweep, plan),
         :ok <-
           Chiezo.when_free(
             fn -> Chiezo.run(base, name, sweep: sweep, partitions: keys) end,
             deadline
           ) do
      {:ok, keys}
    else
      [] -> {:error, :no_partitions}
      {:error, reason} -> {:error, reason}
    end
  end

  # 1 回に見る区画の数は、巡回の設定から Chiezo が決めたもの（ざっと見ると同じ）
  defp keys_for(collection, sweep, plan) do
    count =
      case Enum.find(collection.sweeps || [], &(&1.name == sweep)) do
        %{partitions_per_run: n} when is_integer(n) and n > 0 -> n
        _other -> 1
      end

    pick(collection.partitions || [], sweep, count, {plan.lat, plan.lon}, plan.place_set_at)
  end

  @doc """
  画面と通知に出す一言。**いつ・どうなったか**を 1 行で。
  """
  def result_text(result, now \\ DateTime.utc_now()) do
    Tazuna.Jst.format(now) <> " — " <> outcome(result)
  end

  defp outcome({:ok, keys}), do: "#{length(keys)} 区画を頼みました（#{Enum.join(keys, "、")}）。"
  defp outcome({:error, reason}), do: "頼めませんでした。そのときの理由: " <> error_text(reason)

  @doc "頼めなかった理由の言い方。"
  def error_text(:no_place), do: "起点がまだ決まっていません。"
  def error_text(:no_partitions), do: "収集がまだ区画を持っていません。"
  def error_text(:not_requested), do: "まだ収集を依頼していません。"
  def error_text(:collection_disabled), do: "この収集は Chiezo 側で止まっています。"

  def error_text(:chiezo_busy),
    do: "次の予定の時刻まで待ちましたが、Chiezo の取り込みが空きませんでした。"

  def error_text(:chiezo_not_configured), do: "Chiezo の場所が設定されていません。"
  def error_text(:chiezo_unavailable), do: "Chiezo に接続できませんでした。"
  def error_text(other), do: "#{inspect(other)}"
end
