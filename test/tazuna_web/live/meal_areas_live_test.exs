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

  test "データ収集の画面と同じタブを出し、この画面のタブを選んだ状態にする", %{conn: conn} do
    Tazuna.AreaFixture.area!()

    {:ok, _live, html} = live(conn, ~p"/datasets/areas")

    assert html =~ ~s(id="dataset-tabs")
    assert html =~ ~s(href="/datasets?view=dining-1")
    assert html =~ ~r|class="add-tab selected"[^>]*>\s*＋ 食事処の範囲|
  end

  test "作った範囲は、地図に名前の札つきで出る", %{conn: conn} do
    Tazuna.AreaFixture.area!()

    {:ok, _live, html} = live(conn, ~p"/datasets/areas")

    assert html =~ ~s(class="area-rect")
    assert html =~ ~r|class="area-label"[^>]*data-pin|
    assert html =~ "<text x=\"9\" y=\"-11\">テスト範囲</text>"
  end

  describe "範囲を直す" do
    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      test_pid = self()
      item = %{"name" => "tazuna_dining_1", "enabled" => true, "sweeps" => [], "partitions" => []}

      Tazuna.HttpStub.stub(fn
        %{method: :patch, url: url, body: body} ->
          send(test_pid, {:patched, url, Jason.decode!(body)})
          Tazuna.HttpStub.ok("{}")

        %{method: :post, url: url} ->
          send(test_pid, {:posted, url})
          Tazuna.HttpStub.ok("{}")

        %{url: "http://chiezo.test:7010/v1/collect"} ->
          Tazuna.HttpStub.ok(Jason.encode!(%{"collections" => [item]}))

        %{url: "http://chiezo.test:7010/v1/sources"} ->
          Tazuna.HttpStub.ok(~s({"sources":[]}))

        %{url: "http://chiezo.test:7010/v1/collect/" <> _detail} ->
          Tazuna.HttpStub.ok(Jason.encode!(item))

        # 店の数の見込み（数えられなくても直すのは止めない）
        %{url: _other} ->
          Tazuna.HttpStub.ok(~s({"total":0,"results":[]}))
      end)

      %{area: Tazuna.AreaFixture.area!()}
    end

    test "押すと四角が欄に入り、地図がその範囲へ寄る", %{conn: conn, area: area} do
      {:ok, live, _html} = live(conn, ~p"/datasets/areas")

      html = live |> element(~s|button[phx-click="edit_area"]|) |> render_click()

      assert html =~ "範囲「テスト範囲」を直す"
      assert html =~ ~s(name="area[south]" value="35.50000")
      assert html =~ ~s(name="area[east]" value="139.90000")
      assert html =~ "この範囲に直す"
      assert_push_event(live, "map_frame", %{w: w, h: h})
      assert w > 0 and h > 0
      assert MealAreas.get(area.id)
    end

    test "四角を変えると、範囲で決まるところだけを送り、機械収集から走らせ直す", %{
      conn: conn,
      area: area
    } do
      {:ok, live, _html} = live(conn, ~p"/datasets/areas")
      live |> element(~s|button[phx-click="edit_area"]|) |> render_click()

      live
      |> form("#area-form", area: %{north: "35.8"})
      |> render_submit()

      assert MealAreas.get(area.id).north == 35.8

      assert_receive {:patched, url, sent}, 2_000
      assert url =~ "/v1/collect/tazuna_dining_1"
      # 巡回は送らない（画面で選んだ相手を既定に戻さないため）
      assert Map.keys(sent) |> Enum.sort() == ["description", "extract", "partition"]
      assert sent["partition"]["bbox"] == [35.5, 139.5, 35.8, 139.9]

      assert_receive {:posted, run_url}, 2_000
      assert URI.decode(run_url) =~ "/v1/collect/tazuna_dining_1/run?sweep=機械収集"

      assert render_async(live) =~ "機械収集から走らせ直しました"
    end

    test "名前だけ直したときは走らせ直さない", %{conn: conn, area: area} do
      {:ok, live, _html} = live(conn, ~p"/datasets/areas")
      live |> element(~s|button[phx-click="edit_area"]|) |> render_click()

      html =
        live
        |> form("#area-form", area: %{name: "東京駅"})
        |> render_submit()

      assert MealAreas.get(area.id).name == "東京駅"
      assert html =~ "走らせ直しません"
      refute_receive {:patched, _url, _sent}, 200
    end
  end
end
