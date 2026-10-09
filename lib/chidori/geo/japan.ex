defmodule Chidori.Geo.Japan do
  @moduledoc """
  日本の海岸線（白地図）。**手元に持ちます** —— 外の地図を読みに行かないので、
  何を見ているかを誰にも知らせずに開けます。

  中身は **Natural Earth**（パブリックドメイン）の陸地の輪郭を、日本の範囲で切って
  間引いたものです（`priv/geo/japan_coast.json`。出どころと作り方はその中にも
  書いてあります）。**読み込むのは組み立てのとき 1 回だけ** —— 図を開くたびに
  ファイルを読み直す理由がありません。

  **細かさは 0.012 度**（幅 960 の図で 0.35px ほど）。これより細かくしても図の上では
  見えず、送る量だけが増えます。
  """

  @source_path "priv/geo/japan_coast.json"
  @external_resource @source_path

  @data @source_path |> File.read!() |> Jason.decode!()
  @rings @data["rings"]

  @doc """
  海岸線の輪。**1 つの輪は `[経度, 緯度]` の並び**で、閉じています。

  投影はしません —— どう置くかは図の側の都合なので、ここは座標だけを持ちます。
  """
  def rings, do: @rings

  @doc "出どころ（画面に添えるため）。"
  def source, do: @data["source"]
end
