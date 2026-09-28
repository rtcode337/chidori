defmodule TazunaWeb.StockResearchControllerTest do
  @moduledoc """
  銘柄調査を頼む口。見ているのは、**一覧が Chiezo の割り込みとして情報収集の回へ
  渡ること**と、**断るときに理由を返すこと**です。
  """

  use TazunaWeb.ConnCase, async: false

  setup do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
    :ok
  end

  defp stub_focus(test_pid, status \\ 202) do
    Tazuna.HttpStub.stub(fn %{method: :post, url: url, body: body} ->
      send(test_pid, {:focus, url, Jason.decode!(body)})
      {:ok, %{status: status, body: ~s({"ok":true})}}
    end)
  end

  test "一覧を情報収集の回へ、その回だけの頼みごととして渡す", %{conn: conn} do
    stub_focus(self())

    conn =
      post(conn, ~p"/api/stock-research", %{
        "targets" => [
          %{"code" => "7203", "name" => "トヨタ自動車", "reason" => "決算が近い", "move_pct" => -3.2},
          %{"code" => "130A", "name" => "新しい銘柄"}
        ]
      })

    assert %{"ok" => true, "collection" => "tazuna_stocks"} = json_response(conn, 202)
    assert_received {:focus, "http://chiezo.test:7010/v1/collect/tazuna_stocks/focus", body}
    assert body["sweep"] == "情報収集"
    assert body["note"] =~ "- 7203 トヨタ自動車（騰落率 -3.2%）：決算が近い"
    assert body["note"] =~ "- 130A 新しい銘柄"
  end

  test "形の分からない銘柄は、依頼文に入れる前に断る", %{conn: conn} do
    stub_focus(self())

    conn =
      post(conn, ~p"/api/stock-research", %{"targets" => [%{"code" => "72; rm", "name" => "x"}]})

    assert %{"error" => _} = json_response(conn, 400)
    refute_received {:focus, _, _}
  end

  test "多すぎる一覧は黙って切らずに断る", %{conn: conn} do
    stub_focus(self())
    targets = for i <- 1..21, do: %{"code" => "#{1000 + i}", "name" => "銘柄#{i}"}

    conn = post(conn, ~p"/api/stock-research", %{"targets" => targets})

    assert json_response(conn, 400)["error"] =~ "20 銘柄まで"
  end

  test "Chiezo 側で止まっていれば、そう返す", %{conn: conn} do
    stub_focus(self(), 403)

    conn =
      post(conn, ~p"/api/stock-research", %{"targets" => [%{"code" => "7203", "name" => "トヨタ"}]})

    assert json_response(conn, 409)["error"] =~ "止まっています"
  end
end
