defmodule TazunaWeb.DatasetsController do
  @moduledoc """
  集めたものを travel-log 用の ZIP で渡す口。

  **LiveView ではなく普通のリクエストにしてあります。** ファイルを渡すのは
  「押したら降ってくる」だけの仕事で、画面の状態を持つ必要がありません
  （LiveView から落とすには、いったんどこかへ置いて URL を返すか、JS を挟むことになる）。

  中身の組み立ては `Tazuna.Datasets.TravelLog`。ここは**受け取って返すだけ**にします。
  """
  use TazunaWeb, :controller

  alias Tazuna.Datasets
  alias Tazuna.Datasets.MealAreas
  alias Tazuna.Datasets.Meals
  alias Tazuna.Datasets.TravelLog

  def export(conn, %{"key" => key}) do
    dataset = Datasets.get(key)

    cond do
      is_nil(dataset) ->
        send_resp(conn, 404, "そのデータ収集はありません")

      not TravelLog.exportable?(dataset) ->
        # 技術ニュースのように地図に載らない収集。画面には出していないが、
        # URL を直に叩かれることはある
        send_resp(conn, 404, "この収集はスポットとして書き出せません")

      true ->
        case TravelLog.bundle(dataset) do
          {:ok, filename, binary, _counts} ->
            send_download(conn, {:binary, binary}, filename: filename)

          {:error, :chiezo_not_configured} ->
            send_resp(conn, 503, "Chiezo の場所(CHIEZO_BASE_URL)が設定されていません")

          {:error, reason} ->
            # **理由をそのまま出す。** 押した人がここで詰まると、次に何を直せばよいのか
            # 分からなくなる(Chiezo が落ちている・まだ 1 件も焼けていない、など)
            send_resp(conn, 502, "書き出せませんでした: #{inspect(reason)}")
        end
    end
  end

  @doc """
  **食事処の全範囲を 1 つの ZIP に**（範囲の画面の「全範囲をまとめて書き出す」）。
  travel-log では範囲によらず 1 つの種別に読み込むので、範囲ごとに読み込ませない。
  """
  def export_areas(conn, _params) do
    case MealAreas.list()
         |> Enum.map(&Meals.definition/1)
         |> TravelLog.bundle_all("dining-all") do
      {:ok, filename, binary, _counts} ->
        send_download(conn, {:binary, binary}, filename: filename)

      {:error, :nothing_to_export} ->
        send_resp(conn, 404, "食事処の範囲がまだありません")

      {:error, :chiezo_not_configured} ->
        send_resp(conn, 503, "Chiezo の場所(CHIEZO_BASE_URL)が設定されていません")

      {:error, reason} ->
        send_resp(conn, 502, "書き出せませんでした: #{inspect(reason)}")
    end
  end
end
