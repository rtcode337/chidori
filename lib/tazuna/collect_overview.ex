defmodule Tazuna.CollectOverview do
  @moduledoc """
  tazuna が Chiezo に頼んでいる収集の一覧（設定ページの「Chiezo 収集」）。

  **ワーカーの待ち行列が溜まってきたときに、何がどれだけの間隔で回っているかを
  1 枚で読むため**のものです。収集の設定は Chiezo にあり、tazuna は写しを持たない
  ので、開くたびに Chiezo から読み直します（`GET /v1/collect` と `/v1/collect/queue`）。

  - 収集ごとに、巡回の名前・間隔（頼まれたときだけ・tazuna が決めた時刻）・相手・
    前回・次回・走らない理由
  - ワーカーごとに、起きる間隔・1 回に流す数・次に起きる時刻・待っている回
  - 取り込みの待ち行列
  """

  alias Tazuna.Chiezo
  alias Tazuna.Notify.Setting
  alias Tazuna.Notify.Settings

  @doc """
  Chiezo から読んで、画面に出す形にします。`{:ok, map}` か `{:error, 理由}`。
  **待ち行列が読めなくても収集の一覧は出します**（古い Chiezo は口を持たない）。
  """
  def load(base) do
    with {:ok, collections} <- Chiezo.collections(base) do
      queue =
        case Chiezo.queue(base) do
          {:ok, queue} -> queue
          {:error, reason} -> %{"error" => reason}
        end

      workers = Map.get(queue, "workers", [])

      # ワーカーの名前。**待ち行列の口と、相手の一覧の両方から引く** —— 待ち行列の口を
      # 持たない Chiezo では前者が空で、巡回には id で書いてあるので名前が引けない
      # （画面に「w-58a4f85c」のような鍵がそのまま出ていた）
      names =
        base
        |> Chiezo.backends()
        |> Enum.filter(&(&1.kind == "worker"))
        |> Map.new(fn backend ->
          {String.replace_prefix(backend.id, "worker:", ""), backend.label}
        end)
        |> Map.merge(Map.new(workers, &{&1["id"], &1["name"]}))

      {:ok,
       %{
         collections:
           collections
           |> Enum.filter(&ours?/1)
           |> Enum.map(&collection_row(&1, names)),
         workers: Enum.map(workers, &worker_row/1),
         waiting: Map.get(queue, "ingest_waiting", []),
         queue_error: Map.get(queue, "error")
       }}
    end
  end

  # **tazuna が頼んだものだけ**（Chiezo には他のアプリの収集も並ぶ）
  defp ours?(collection),
    do:
      collection["requested_by"] == "tazuna" or
        String.starts_with?(collection["name"] || "", "tazuna_")

  defp collection_row(collection, worker_names) do
    %{
      name: collection["name"],
      label: label(collection),
      enabled: collection["enabled"] == true,
      last_status: collection["last_status"],
      last_error: collection["last_error"],
      sweeps:
        Enum.map(collection["sweeps"] || [], fn sweep ->
          %{
            name: sweep["name"],
            enabled: sweep["enabled"] != false,
            clock: clock(sweep, collection["name"]),
            # **ワーカーは `worker` の欄に入っている**（`backend` は相手を名指ししたときだけ）
            backend:
              who(
                blank(sweep["worker"] || "") && "worker:" <> sweep["worker"],
                sweep["backend"] || collection["backend"],
                worker_names
              ),
            model: sweep["model"] || collection["model"],
            last_run_at: sweep["last_run_at"],
            next_run_at: if(sweep["on_demand"], do: nil, else: sweep["next_run_at"]),
            last_status: sweep["last_status"],
            blocked: blank(sweep["blocked"])
          }
        end)
    }
  end

  @doc """
  画面に出す名前。**tazuna が置いた説明の頭から取ります** —— 話題は「tazuna の「〜」」、
  トピックの網は「〜のトピック」、関連図とデータ収集は括弧の中。
  読めなければ収集の名前のまま。
  """
  def label(collection) do
    description = collection["description"] || ""

    cond do
      match = Regex.run(~r/^tazuna の「([^」]+)」のトピック/u, description) ->
        Enum.at(match, 1) <> "のトピック"

      match = Regex.run(~r/^tazuna の「([^」]+)」/u, description) ->
        Enum.at(match, 1)

      match = Regex.run(~r{^tazuna の(?:関連図|データ収集)（([^。／/）]+)}u, description) ->
        match |> Enum.at(1) |> String.trim()

      true ->
        collection["name"]
    end
  end

  @doc """
  巡回の回り方の一言。**時計を持たない回は、誰が起こすのかまで言う** —— 要約の回は
  tazuna が決めた時刻に起こすので、その時刻を出す（Chiezo の側には時計が無い）。
  """
  def clock(sweep, collection) do
    cond do
      sweep["on_demand"] ->
        case digest_times(collection) do
          [] -> "頼まれたときだけ"
          times -> "tazuna が起こす（" <> Enum.join(times, "・") <> "）"
        end

      sweep["once"] ->
        "一度きり"

      is_integer(sweep["interval_minutes"]) ->
        every(sweep["interval_minutes"])

      true ->
        "—"
    end
  end

  defp digest_times(collection) do
    collection
    |> Settings.get()
    |> Setting.digest_times()
    |> Enum.map(fn {hour, minute} ->
      String.pad_leading("#{hour}", 2, "0") <> ":" <> String.pad_leading("#{minute}", 2, "0")
    end)
  end

  @doc "分の間隔を読める形に（「60 分ごと」ではなく「1 時間ごと」）。"
  def every(minutes) when rem(minutes, 1440) == 0, do: "#{div(minutes, 1440)} 日ごと"
  def every(minutes) when rem(minutes, 60) == 0, do: "#{div(minutes, 60)} 時間ごと"
  def every(minutes), do: "#{minutes} 分ごと"

  # 相手の欄。**ワーカーは名前で出す**（鍵の id では誰のことか読めない）
  defp who(worker, _backend, names) when is_binary(worker), do: who(worker, names)
  defp who(_worker, backend, names), do: who(backend, names)

  defp who("worker:" <> id, names), do: "ワーカー「#{Map.get(names, id, id)}」"
  defp who(nil, _names), do: "Chiezo の既定"
  defp who("", _names), do: "Chiezo の既定"
  defp who(backend, _names), do: backend

  defp worker_row(worker) do
    %{
      name: worker["name"],
      every: every(max(worker["interval_minutes"] || 1, 1)),
      per_run: worker["per_run"],
      paused: worker["paused"] == true,
      next_at: blank(worker["next_at"]),
      finished_at: blank(worker["finished_at"]),
      flowing: worker["flowing"] || [],
      queued: worker["queued"] || []
    }
  end

  defp blank(""), do: nil
  defp blank(value), do: value
end
