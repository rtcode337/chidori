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
end
