defmodule TazunaWeb.StockResearchController do
  @moduledoc """
  銘柄調査を頼む口（`POST /api/stock-research`）。

  **返すのは「頼んだ」まで**です。調べるのは Chiezo の巡回で、数分かかります ——
  結果は Chiezo の収集（`tazuna_stocks`）に溜まるので、頼んだ側はそこを読みます
  （`GET <Chiezo>/v1/tazuna_stocks/filter?tag=銘柄:<コード>`）。

  受け取る形:

      {"targets": [{"code": "7203", "name": "トヨタ自動車",
                    "reason": "前日比 -3.2%", "move_pct": -3.2}]}
  """

  use TazunaWeb, :controller

  alias Tazuna.News.StockResearch

  @collection "tazuna_stocks"

  def create(conn, params) do
    case StockResearch.request(@collection, Map.get(params, "targets")) do
      :ok ->
        conn
        |> put_status(:accepted)
        |> json(%{ok: true, collection: @collection})

      {:error, reason} ->
        {status, message} = refusal(reason)

        conn
        |> put_status(status)
        |> json(%{error: message})
    end
  end

  # 断った理由。**頼んだ側が次に何をすればよいか分かる言い方で返す**
  defp refusal(:no_targets), do: {:bad_request, "調べる銘柄がありません"}

  defp refusal(:too_many_targets),
    do: {:bad_request, "1 回に頼めるのは #{StockResearch.max_targets()} 銘柄までです"}

  defp refusal(:bad_targets),
    do: {:bad_request, "銘柄は {\"code\": 4 桁の証券コード, \"name\": 銘柄名} の並びで渡してください"}

  defp refusal(:chiezo_not_configured), do: {:service_unavailable, "Chiezo の場所が設定されていません"}

  defp refusal(:not_requested),
    do: {:conflict, "銘柄調査の収集がまだ Chiezo にありません（tazuna の画面から依頼してください）"}

  defp refusal(:collection_disabled),
    do: {:conflict, "銘柄調査の収集が Chiezo 側で止まっています"}

  defp refusal(:chiezo_busy), do: {:conflict, "Chiezo がいま別の割り込みを抱えています。少し待ってください"}
  defp refusal(:collect_disabled), do: {:service_unavailable, "Chiezo の収集が無効です"}
  defp refusal(_reason), do: {:bad_gateway, "Chiezo へ頼めませんでした"}
end
