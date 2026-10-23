defmodule ChidoriWeb.DatasetsController do
  @moduledoc """
  集めたものを travel-log 用の ZIP で渡す口。

  **LiveView ではなく普通のリクエストにしてあります。** ファイルを渡すのは
  「押したら降ってくる」だけの仕事で、画面の状態を持つ必要がありません
  （LiveView から落とすには、いったんどこかへ置いて URL を返すか、JS を挟むことになる）。

  中身の組み立ては `Chidori.Datasets.TravelLog`。ここは**受け取って返すだけ**にします。
  """
  use ChidoriWeb, :controller

  alias Chidori.Datasets
  alias Chidori.Datasets.DiningAreas
  alias Chidori.Datasets.Dining
  alias Chidori.Datasets.TravelLog

  require Logger

  @doc "前の食事処の「全体」の画面（`/datasets/areas`）は、収集の画面へ送る。"
  def to_collect_areas(conn, _params), do: redirect(conn, to: ~p"/collect/apps/areas")

  def export(conn, %{"key" => key} = params) do
    dataset = Datasets.get(key)

    cond do
      is_nil(dataset) ->
        text(conn, 404, "そのデータ収集はありません")

      not TravelLog.exportable?(dataset) ->
        # 技術ニュースのように地図に載らない収集。画面には出していないが、
        # URL を直に叩かれることはある
        text(conn, 404, "この収集はスポットとして書き出せません")

      true ->
        # **範囲 1 つぶんの ZIP では見た目を上書きさせない** —— travel-log の食事処は範囲で
        # 分かれていないので、1 つの範囲のシリーズだけで見た目を置き換えると、ほかの範囲の
        # シリーズの見た目が壊れる。上書きは全範囲の ZIP（`export_areas`）からだけ
        opts = if dataset[:area], do: [], else: style_opts(params)

        case TravelLog.bundle(dataset, opts) do
          {:ok, filename, binary, _counts} ->
            send_download(conn, {:binary, binary}, filename: filename)

          {:error, :chiezo_not_configured} ->
            text(conn, 503, "Chiezo の場所(CHIEZO_BASE_URL)が設定されていません")

          {:error, reason} ->
            # 押した人には見当だけを返し、細かい理由はログに残す（Chiezo から来た
            # 文言を、そのまま応答に流さない）
            failed(conn, key, reason)
        end
    end
  end

  @doc """
  **食事処の全範囲を 1 つの ZIP に**（範囲の画面の「全範囲をまとめて書き出す」）。
  travel-log では範囲によらず 1 つの種別に読み込むので、範囲ごとに読み込ませない。
  """
  def export_areas(conn, params) do
    case DiningAreas.list()
         |> Enum.map(&Dining.definition/1)
         |> TravelLog.bundle_all("dining-all", style_opts(params)) do
      {:ok, filename, binary, _counts} ->
        send_download(conn, {:binary, binary}, filename: filename)

      {:error, :nothing_to_export} ->
        text(conn, 404, "食事処の範囲がまだありません")

      {:error, :chiezo_not_configured} ->
        text(conn, 503, "Chiezo の場所(CHIEZO_BASE_URL)が設定されていません")

      {:error, reason} ->
        failed(conn, "dining-all", reason)
    end
  end

  # `?styles=replace` のときだけ、travel-log 側のシリーズの見た目も上書きさせる
  # （`TravelLog.settings_json/6`。既定は残してもらう）
  defp style_opts(%{"styles" => "replace"}), do: [keep_styles: false]
  defp style_opts(_params), do: []

  defp failed(conn, key, reason) do
    Logger.warning("travel-log 用の ZIP を書き出せなかった（#{key}）: #{inspect(reason)}")
    text(conn, 502, "書き出せませんでした（#{hint(reason)}）。詳しい理由はサーバーのログにあります。")
  end

  # 押した人が次に何を確かめればよいかの見当
  # 全範囲をまとめたときは、どの収集で止まったかが付いてくる
  defp hint({collection, reason}) when is_binary(collection), do: hint(reason)
  defp hint(:chiezo_unavailable), do: "Chiezo に繋がりませんでした"
  defp hint({:chiezo_status, status}) when is_integer(status), do: "Chiezo が #{status} を返しました"
  defp hint(:nothing_to_export), do: "書き出せるものがまだありません"
  defp hint(_reason), do: "Chiezo とのやり取りに失敗しました"

  # 本文は文字だけで返す（ブラウザに HTML として読ませない）
  defp text(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end
end
