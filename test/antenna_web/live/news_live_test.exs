defmodule AntennaWeb.NewsLiveTest do
  use AntennaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "ニュースのページを表示する", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/news")

    assert html =~ "今日、押さえておきたいニュース"
    # 集めるのは Chiezo だと画面から読めること
    assert html =~ "集めるのは Chiezo です"
  end

  test "Chiezo が未設定なら、その旨を出して依頼を押させない", %{conn: conn} do
    System.delete_env("CHIEZO_BASE_URL")

    {:ok, _live, html} = live(conn, ~p"/news")

    assert html =~ "CHIEZO_BASE_URL"
    assert html =~ "収集を依頼する"
    assert html =~ "disabled"
  end

  test "頼んでいる内容が画面から読める", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/news")

    assert html =~ "AI に頼んでいる内容"
    # まだ依頼していないので、これから送る雛形が出る
    assert html =~ "next_cursor"
    assert html =~ "この内容で Chiezo に頼みます"
  end

  test "関連図への行き来ができる", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/news")

    assert html =~ ~p"/relations"
  end

  describe "話題のタブ" do
    test "既定の話題がタブに並ぶ", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/news")

      assert html =~ "ニュース"
      assert html =~ "技術"
      assert html =~ ~s(href="/news?view=antenna_tech")
    end

    test "タブを切り替えると、その話題の画面になる", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/news")

      html = live |> element(~s|a[href="/news?view=antenna_tech"]|) |> render_click()

      assert html =~ "今日、押さえておきたい技術"
      # 依頼の本文も話題の関心から作る（話題ごとに文面を持たせない）
      assert html =~ "ソフトウェア開発"
    end

    test "知らない話題は先頭に丸める", %{conn: conn} do
      # 消した話題のリンクを踏んだだけで、空白の画面を出す理由が無い
      {:ok, _live, html} = live(conn, ~p"/news?view=nosuch")

      assert html =~ "今日、押さえておきたいニュース"
    end
  end
end
