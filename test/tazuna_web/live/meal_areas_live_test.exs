defmodule TazunaWeb.MealAreasLiveTest do
  @moduledoc """
  食事処の範囲を決める画面。見ているのは、**地図に描いた四角が範囲の欄に入ること**、
  **名前を付けて作るとその範囲のタブへ移ること**、**広すぎる範囲は断ること**です。
  """

  use TazunaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tazuna.Datasets.MealAreas

  setup do
    System.delete_env("CHIEZO_BASE_URL")
    :ok
  end

  test "描いた四角が範囲の欄に入る", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/datasets/areas")

    html =
      render_hook(live, "drawn", %{
        "south" => 35.69,
        "west" => 139.78,
        "north" => 35.67,
        "east" => 139.75
      })

    # 描く向きによらず、南 < 北・西 < 東にそろえる
    assert html =~ ~s(name="area[south]" value="35.67000")
    assert html =~ ~s(name="area[north]" value="35.69000")
    assert html =~ ~s(name="area[west]" value="139.75000")
  end

  test "名前を付けて作ると、その範囲のタブへ移る", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/datasets/areas")

    render_hook(live, "drawn", %{
      "south" => 35.67,
      "west" => 139.75,
      "north" => 35.69,
      "east" => 139.78
    })

    result =
      live
      |> form("#area-form", area: %{name: "東京駅"})
      |> render_submit()

    [area] = MealAreas.list()
    assert area.name == "東京駅"
    assert {:error, {:live_redirect, %{to: to}}} = result
    assert to == "/datasets?view=dining-#{area.id}"
  end

  test "広すぎる範囲は断る（日本全体と同じことになる）", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/datasets/areas")

    render_hook(live, "drawn", %{
      "south" => 34.0,
      "west" => 135.0,
      "north" => 36.0,
      "east" => 140.0
    })

    html = live |> form("#area-form", area: %{name: "広すぎ"}) |> render_submit()

    assert html =~ "範囲が広すぎます"
    assert MealAreas.list() == []
  end

  test "作った範囲はデータ収集の画面のタブになる", %{conn: conn} do
    Tazuna.AreaFixture.area!()

    {:ok, _live, html} = live(conn, ~p"/datasets")

    assert html =~ ~s(href="/datasets?view=dining-1")
    assert html =~ "＋ 食事処の範囲"
  end
end
