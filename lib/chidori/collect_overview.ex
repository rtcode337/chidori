defmodule Chidori.CollectOverview do
  @moduledoc """
  Chidori が Chiezo に頼んでいる収集の一覧（設定ページの「Chiezo 収集」）。

  **ワーカーの待ち行列が溜まってきたときに、何がどれだけの間隔で回っているかを
  1 枚で読むため**のものです。収集の設定は Chiezo にあり、Chidori は写しを持たない
  ので、開くたびに Chiezo から読み直します（`GET /v1/collect` と `/v1/collect/queue`）。

  - 収集ごとに、巡回の名前・間隔（頼まれたときだけ・Chidori が決めた時刻）・相手・
    前回・次回・走らない理由
  - ワーカーごとに、起きる間隔・1 回に流す数・次に起きる時刻・待っている回
  - 取り込みの待ち行列
  """

  alias Chidori.Chiezo
  alias Chidori.Notify.Setting
  alias Chidori.Notify.Settings

  @doc """
  Chiezo から読んで、画面に出す形にします。`{:ok, map}` か `{:error, 理由}`。
  **待ち行列が読めなくても収集の一覧は出します**（別の問い合わせなので、片方の失敗で
  もう片方を隠さない）。
  """
  def load(base) do
    with {:ok, collections} <- Chiezo.collections(base) do
      queue =
        case Chiezo.queue(base) do
          {:ok, queue} -> queue
          {:error, reason} -> %{"error" => reason}
        end

      workers = Map.get(queue, "workers", [])

      # ワーカーの名前。待ち行列の口と、相手の一覧の両方から引く —— 待ち行列が
      # 読めなかったときは前者が空で、巡回には id で書いてあるので名前が引けない
      # （画面に「w-58a4f85c」のような鍵がそのまま出ていた）
      backends = Chiezo.backends(base)

      names =
        backends
        |> Enum.filter(&(&1.kind == "worker"))
        |> Map.new(fn backend ->
          {String.replace_prefix(backend.id, "worker:", ""), backend.label}
        end)
        |> Map.merge(Map.new(workers, &{&1["id"], &1["name"]}))

      {:ok,
       %{
         # 巡回ごとに選べる相手（収集の表の欄）
         backends: backends,
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

  @doc """
  Chidori が頼んだ収集か（Chiezo には他のアプリの収集も並ぶ）。
  """
  def ours?(collection),
    do:
      collection["requested_by"] == "chidori" or
        String.starts_with?(collection["name"] || "", "chidori_")

  defp collection_row(collection, worker_names) do
    %{
      name: collection["name"],
      label: label(collection),
      enabled: collection["enabled"] == true,
      last_status: collection["last_status"],
      last_error: collection["last_error"],
      # Chiezo の今の設定そのもの（Chidori の定義と突き合わせる。`Chidori.CollectDrift`）
      config: collection,
      sweeps:
        Enum.map(collection["sweeps"] || [], fn sweep ->
          %{
            name: sweep["name"],
            enabled: sweep["enabled"] != false,
            # 時計を外した巡回（依頼元が名指しで起こす。整理を自動で回さない収集など）
            by_caller: sweep["by_caller"] == true,
            clock: clock(sweep, collection["name"]),
            # **Chidori が起こす回の時刻**（画面で直せる）。`{:digest, 時刻の文字列}`。
            # 時刻を持つのは Chidori で、Chiezo の側には時計が無い
            wake: wake(sweep, collection["name"]),
            # **ワーカーは `worker` の欄に入っている**（`backend` は相手を名指ししたときだけ）
            backend:
              who(
                blank(sweep["worker"] || "") && "worker:" <> sweep["worker"],
                sweep["backend"] || collection["backend"],
                worker_names
              ),
            model: sweep["model"] || collection["model"],
            # 選ぶ欄に入れる値（相手の一覧の id。ワーカーは `worker:<id>`）。
            # **収集の既定に任せている巡回は空**（既定の名前を入れると、送り直したときに
            # 既定ではなく名指しに変わる）
            pick:
              if(blank(sweep["worker"] || ""),
                do: "worker:" <> sweep["worker"],
                else: sweep["backend"] || ""
              ),
            pick_model: sweep["model"] || "",
            # **機械で引く回は相手を選ばせない**（AI を呼ばないので、選んでも読まれない）。
            # 検索文を考えさせる回（依頼文に `{queries}`）は例外
            mechanical:
              sweep["use_extract"] == true or sweep["by_hand"] == true or
                sweep["use_pihole"] == true or
                (sweep["use_feed"] == true and
                   not String.contains?(to_string(sweep["prompt"] || ""), "{queries}")),
            last_run_at: sweep["last_run_at"],
            next_run_at: if(sweep["on_demand"], do: nil, else: sweep["next_run_at"]),
            last_status: sweep["last_status"],
            blocked: blank(sweep["blocked"])
          }
        end)
    }
  end

  @doc """
  画面に出す名前。**Chidori が置いた説明の頭から取ります** —— 話題は「Chidori の「〜」」、
  トピックの網は「〜のトピック」、関連図とデータ収集は括弧の中。読めなければ収集の名前のまま。
  """
  def label(collection) do
    description = collection["description"] || ""

    cond do
      match = Regex.run(~r/^Chidori の「([^」]+)」のトピック/u, description) ->
        Enum.at(match, 1) <> "のトピック"

      match = Regex.run(~r/^Chidori の「([^」]+)」/u, description) ->
        Enum.at(match, 1)

      match = Regex.run(~r{^Chidori の(?:関連図|データ収集)（([^。／/）]+)}u, description) ->
        match |> Enum.at(1) |> String.trim()

      true ->
        collection["name"]
    end
  end

  @doc """
  巡回の回り方の一言。**時計を持たない回は、誰が起こすのかまで言う** —— 要約の回は
  Chidori が決めた時刻に起こすので、その時刻を出す（Chiezo の側には時計が無い）。
  """
  def clock(sweep, collection) do
    cond do
      sweep["on_demand"] ->
        case digest_times(collection) do
          [] -> "頼まれたときだけ"
          times -> "Chidori が起こす（" <> Enum.join(times, "・") <> "）"
        end

      sweep["once"] ->
        "一度きり"

      sweep["by_caller"] ->
        "自動では回さない"

      is_integer(sweep["interval_minutes"]) ->
        every(sweep["interval_minutes"])

      true ->
        "—"
    end
  end

  @doc """
  Chidori が起こす回の時刻。**要約の回**（`on_demand`。各話題の「要約を作る時刻」）だけ。
  ほかの回は nil。
  """
  def wake(sweep, collection) do
    if sweep["on_demand"], do: {:digest, Settings.get(collection).digest_at || ""}
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
