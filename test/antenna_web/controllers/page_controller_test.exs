defmodule AntennaWeb.PageControllerTest do
  use AntennaWeb.ConnCase

  test "GET / は antenna のトップ画面を表示する", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "情報の波から"
  end
end
