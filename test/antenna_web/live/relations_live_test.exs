defmodule AntennaWeb.RelationsLiveTest do
  use AntennaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "人物の関連図を表示する", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/relations")

    assert html =~ "人物のつながり"
    assert html =~ "松田優作"
  end

  test "画家の関連図へ切り替えられる", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/relations")

    html = live |> element(~s|a[href="/relations?view=painters"]|) |> render_click()

    assert html =~ "画家の影響と時代"
    assert html =~ "フィンセント・ファン・ゴッホ"
  end

  test "知らない種類は人物の図に丸める", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/relations?view=%2E%2E%2F")

    assert html =~ "人物のつながり"
  end
end
