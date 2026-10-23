defmodule ChidoriWeb.DiningAreasLiveTest do
  @moduledoc """
  食事処の範囲を決める画面。見ているのは、**地図に描いた四角が範囲の欄に入ること**、
  **名前を付けて作るとその範囲の画面へ移ること**、**広すぎる範囲は断ること**です。
  """

  use ChidoriWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Chidori.Datasets.DiningAreas

  setup do
    System.delete_env("CHIEZO_BASE_URL")
    :ok
  end

  test "描いた四角が範囲の欄に入る", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/collect/apps/areas")

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

  test "名前を付けて作ると、その範囲の画面へ移る", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/collect/apps/areas")

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

    [area] = DiningAreas.list()
    assert area.name == "東京駅"
    assert {:error, {:live_redirect, %{to: to}}} = result
    assert to == "/collect/apps?view=dining-#{area.id}"
  end

  test "広すぎる範囲は断る（日本全体と同じことになる）", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/collect/apps/areas")

    render_hook(live, "drawn", %{
      "south" => 34.0,
      "west" => 135.0,
      "north" => 36.0,
      "east" => 140.0
    })

    html = live |> form("#area-form", area: %{name: "広すぎ"}) |> render_submit()

    assert html =~ "範囲が広すぎます"
    assert DiningAreas.list() == []
  end

  test "作った範囲は他アプリ用のタブに並べず、食事処のタブ 1 つにまとめる", %{conn: conn} do
    # 並べると、範囲を足すたびにご当地グルメやアニメ聖地のタブが押し出される
    Chidori.AreaFixture.area!()

    {:ok, _live, html} = live(conn, ~p"/collect/apps?view=gourmet")
    [_, tabs] = String.split(html, ~s(id="dataset-tabs"), parts: 2)
    [tabs, _] = String.split(tabs, "</nav>", parts: 2)

    refute tabs =~ "view=dining-1"
    refute html =~ ~s(id="dining-tabs")
    assert tabs =~ ~r|href="/collect/apps/areas"[^>]*>\s*食事処\s*<|

    # データ収集（Chidori で読むもの）には食事処を出さない
    {:ok, _live, html} = live(conn, ~p"/collect/datasets")
    refute html =~ ~s(href="/collect/apps/areas")
  end

  test "読む画面のデータ収集には、食事処のタブも範囲のタブも出さない（読むのは travel-log）", %{conn: conn} do
    Chidori.AreaFixture.area!()

    {:ok, _live, html} = live(conn, ~p"/datasets")

    refute html =~ ~s(href="/collect/apps/areas")
    refute html =~ ~s(view=dining-1)
    refute html =~ ~s(id="dining-tabs")
  end

  test "前の範囲の一覧の URL は、収集の画面へ送る", %{conn: conn} do
    assert conn |> get("/datasets/areas") |> redirected_to() == "/collect/apps/areas"
    assert conn |> get("/collect/datasets/areas") |> redirected_to() == "/collect/apps/areas"
  end

  test "範囲を開いているときは、食事処のタブと、その下の段の範囲のタブを選んだ状態にする", %{conn: conn} do
    Chidori.AreaFixture.area!()

    {:ok, _live, html} = live(conn, ~p"/collect/apps?view=dining-1")

    assert html =~ ~r|href="/collect/apps/areas"[^>]*class="selected"[^>]*>\s*食事処|
    assert html =~ ~s(id="dining-tabs")
    assert html =~ ~r|href="/collect/apps\?view=dining-1"[^>]*class="selected"[^>]*>\s*テスト範囲|
    # 「全体」へもタブから戻れる
    assert html =~ ~r|href="/collect/apps/areas"[^>]*>\s*全体\s*<|
  end

  test "範囲の一覧の画面は、食事処の中の「全体」のタブとして出る", %{conn: conn} do
    Chidori.AreaFixture.area!()

    {:ok, _live, html} = live(conn, ~p"/collect/apps/areas")

    assert html =~ ~s(id="dataset-tabs")
    assert html =~ ~r|class="selected"[^>]*>\s*食事処|
    assert html =~ ~r|href="/collect/apps/areas"[^>]*class="selected"[^>]*>\s*全体|
    # 範囲は下の段のタブ（と「作った範囲」の名前の欄）から開く
    assert html =~ ~r|href="/collect/apps\?view=dining-1"[^>]*>\s*テスト範囲|
  end

  test "作った範囲は、地図に名前の札つきで出る", %{conn: conn} do
    Chidori.AreaFixture.area!()

    {:ok, _live, html} = live(conn, ~p"/collect/apps/areas")

    assert html =~ ~s(class="area-rect")
    assert html =~ ~r|class="area-label"[^>]*data-pin|
    assert html =~ "<text x=\"9\" y=\"-11\">テスト範囲</text>"
  end

  describe "範囲を直す" do
    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      test_pid = self()

      item = %{
        "name" => "chidori_dining_1",
        "enabled" => true,
        "sweeps" => [],
        "partitions" => []
      }

      Chidori.HttpStub.stub(fn
        %{method: :patch, url: url, body: body} ->
          send(test_pid, {:patched, url, Jason.decode!(body)})
          Chidori.HttpStub.ok("{}")

        %{method: :post, url: url} ->
          send(test_pid, {:posted, url})
          Chidori.HttpStub.ok("{}")

        %{url: "http://chiezo.test:7010/v1/collect"} ->
          Chidori.HttpStub.ok(Jason.encode!(%{"collections" => [item]}))

        %{url: "http://chiezo.test:7010/v1/sources"} ->
          Chidori.HttpStub.ok(~s({"sources":[]}))

        %{url: "http://chiezo.test:7010/v1/collect/" <> _detail} ->
          Chidori.HttpStub.ok(Jason.encode!(item))

        # 店の数の見込み（数えられなくても直すのは止めない）
        %{url: _other} ->
          Chidori.HttpStub.ok(~s({"total":0,"results":[]}))
      end)

      %{area: Chidori.AreaFixture.area!()}
    end

    test "押すと四角が欄に入り、地図がその範囲へ寄る", %{conn: conn, area: area} do
      {:ok, live, _html} = live(conn, ~p"/collect/apps/areas")

      html = live |> element(~s|button[phx-click="edit_area"]|) |> render_click()

      assert html =~ "範囲「テスト範囲」を直す"
      assert html =~ ~s(name="area[south]" value="35.50000")
      assert html =~ ~s(name="area[east]" value="139.90000")
      assert html =~ "この範囲に直す"
      assert_push_event(live, "map_frame", %{w: w, h: h})
      assert w > 0 and h > 0
      assert DiningAreas.get(area.id)
    end

    test "四角を変えると、範囲で決まるところだけを送り、機械収集から走らせ直す", %{
      conn: conn,
      area: area
    } do
      {:ok, live, _html} = live(conn, ~p"/collect/apps/areas")
      live |> element(~s|button[phx-click="edit_area"]|) |> render_click()

      live
      |> form("#area-form", area: %{north: "35.8"})
      |> render_submit()

      assert DiningAreas.get(area.id).north == 35.8

      assert_receive {:patched, url, sent}, 2_000
      assert url =~ "/v1/collect/chidori_dining_1"
      # 巡回は送らない（画面で選んだ相手を既定に戻さないため）
      assert Map.keys(sent) |> Enum.sort() == ["description", "extract", "partition"]
      assert sent["partition"]["bbox"] == [35.5, 139.5, 35.8, 139.9]

      assert_receive {:posted, run_url}, 2_000
      assert URI.decode(run_url) =~ "/v1/collect/chidori_dining_1/run?sweep=機械収集"

      assert render_async(live) =~ "機械収集から走らせ直しました"
    end

    test "名前だけ直したときは走らせ直さない", %{conn: conn, area: area} do
      {:ok, live, _html} = live(conn, ~p"/collect/apps/areas")
      live |> element(~s|button[phx-click="edit_area"]|) |> render_click()

      html =
        live
        |> form("#area-form", area: %{name: "東京駅"})
        |> render_submit()

      assert DiningAreas.get(area.id).name == "東京駅"
      assert html =~ "走らせ直しません"
      refute_receive {:patched, _url, _sent}, 200
    end
  end

  describe "travel-log からの依頼" do
    test "1 件ずつ座標の入る範囲に控え、どこにも入らないものは控えずに出す", %{conn: conn} do
      Chidori.Repo.insert!(%DiningAreas{
        id: 1,
        name: "東京駅",
        south: 35.67,
        west: 139.75,
        north: 35.69,
        east: 139.78
      })

      Chidori.Repo.insert!(%DiningAreas{
        id: 2,
        name: "大阪",
        south: 34.6,
        west: 135.4,
        north: 34.8,
        east: 135.6
      })

      {:ok, live, _html} = live(conn, ~p"/collect/apps/areas")

      text = """
      - [修正] 東京駅の店 (35.6812,139.7671): 閉店している
      - [修正] 大阪の店 (34.7000,135.5000): 営業時間が違う
      - [追加] (43.0600,141.3500): 札幌の店
      """

      html = live |> form("form[phx-submit=route_requests]", %{text: text}) |> render_submit()

      assert html =~ "東京駅: 1 件を控えました"
      assert html =~ "大阪: 1 件を控えました"
      assert html =~ "どの範囲にも入らなかったので控えていません"
      assert html =~ "札幌の店"
      # 範囲の一覧に、控えている依頼の数が出る
      assert html =~ "控えている依頼 1 件"

      assert Chidori.Datasets.Requests.pending_count(%{collection: "chidori_dining_1"}) == 1
      assert Chidori.Datasets.Requests.pending_count(%{collection: "chidori_dining_2"}) == 1
    end

    test "全範囲をまとめて書き出す口がある", %{conn: conn} do
      Chidori.Repo.insert!(%DiningAreas{
        id: 1,
        name: "東京駅",
        south: 35.67,
        west: 139.75,
        north: 35.69,
        east: 139.78
      })

      {:ok, _live, html} = live(conn, ~p"/collect/apps/areas")
      assert html =~ ~p"/datasets/areas/travel-log.zip"
    end
  end

  test "位置を固定できた範囲にだけ、AI を使わずにいま反映する口を出す" do
    tokyo = %DiningAreas{id: 1, name: "東京駅"}
    osaka = %DiningAreas{id: 2, name: "大阪"}

    results = [
      {tokyo, {:ok, %{held: ["駅前うどん"], missed: [], failed: []}}},
      {osaka, {:ok, %{held: [], missed: ["見つからない店"], failed: []}}}
    ]

    assert ChidoriWeb.DiningAreasLive.held_areas(results) == [tokyo]
    assert ChidoriWeb.DiningAreasLive.held_areas(:holding) == []
  end
end
