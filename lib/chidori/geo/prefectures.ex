defmodule Chidori.Geo.Prefectures do
  @moduledoc """
  日本の 47 県の境界。**手元に持ちます**（白地図の `Chidori.Geo.Japan` と同じ理由 ——
  外の地図を読みに行かないので、何を見ているかを誰にも知らせずに開けます）。

  中身は **Natural Earth**（パブリックドメイン）の admin-1（`ne_10m_admin_1_states_provinces`）
  から日本の県を拾い、隣との境目を共有したまま 0.004 度で間引いたものです
  （`priv/geo/japan_prefectures.json`。作り方は `scripts/build_prefectures.py`、
  説明は docs/datasets.md「県の地図」）。**読み込むのは組み立てのとき 1 回だけ**。
  """

  @source_path "priv/geo/japan_prefectures.json"
  @external_resource @source_path

  @data @source_path |> File.read!() |> Jason.decode!()
  @prefectures Enum.map(@data["prefectures"], &%{name: &1["name"], rings: &1["rings"]})

  @doc """
  県の並び（JIS の番号順）。1 つは `%{name: "東京都", rings: [輪, ...]}` で、
  **1 つの輪は `[経度, 緯度]` の並び**（閉じています）。島の数だけ輪があります。

  投影はしません —— どう置くかは図の側の都合なので、ここは座標だけを持ちます。
  """
  def all, do: @prefectures

  @doc "出どころ（画面に添えるため）。"
  def source, do: @data["source"]
end
