defmodule AntennaWeb.NewsLiveTest do
  use AntennaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # 収集の入れ物は話題ごとに 1 つで、テストをまたいで生き残る。
  # **前のテストで読めた状態が次のテストに漏れる**ので、毎回まっさらから始める
  setup do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Antenna.News.Supervisor) do
      DynamicSupervisor.terminate_child(Antenna.News.Supervisor, pid)
    end

    :ok
  end

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
    # 押す口は枠の中の 1 つだけ（関連図と同じ形）
    assert html =~ "収集を依頼する"
    assert html =~ "disabled"
  end

  test "押す口は 1 つだけ", %{conn: conn} do
    # ボタンを役割ごとに並べていた頃は、どれを押せば何が起きるのかが押す前に
    # 読めなかった（しかも走らせる口が混ざっていた）
    {:ok, _live, html} = live(conn, ~p"/news")

    refute html =~ "いま集めさせる"
    refute html =~ "AI に選ばせる"
    refute html =~ "読み直す"
  end

  test "頼んでいる内容が画面から読める", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/news")

    assert html =~ "Chiezo への依頼文"
    # まだ依頼していないので、これから送る雛形が出る
    assert html =~ "next_cursor"
    assert html =~ "この内容で Chiezo に頼みます"
  end

  test "巡回ごとの依頼文が読める", %{conn: conn} do
    # 回ごとに頼むことが違うので、1 つの文だけを出すと実際と食い違う
    {:ok, _live, html} = live(conn, ~p"/news")

    assert html =~ "漏れ探し"
    assert html =~ "要約"
  end

  describe "Chiezo の収集の枠" do
    @collection %{
      "name" => "antenna_news",
      "description" => "antenna のニュース",
      "enabled" => true,
      "interval_minutes" => 360,
      "mode" => "refine",
      "prompt" => "{cursor} 以降のニュース。{recent}",
      "sweeps" => [
        %{"name" => "見出し", "interval_minutes" => 60, "use_feed" => true, "enabled" => true},
        %{"name" => "集める", "interval_minutes" => 360, "enabled" => true},
        %{"name" => "要約", "interval_minutes" => 720, "enabled" => true},
        %{"name" => "割り込み", "on_demand" => true, "enabled" => true}
      ]
    }

    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")

      Antenna.HttpStub.stub(fn
        %{url: "http://chiezo.test:7010/v1/ai/backends"} ->
          Antenna.HttpStub.ok(~s({"backends":[]}))

        %{url: "http://chiezo.test:7010/v1/sources"} ->
          Antenna.HttpStub.ok(Jason.encode!(%{"sources" => []}))

        %{url: "http://chiezo.test:7010/v1/collect"} ->
          Antenna.HttpStub.ok(Jason.encode!(%{"collections" => [@collection]}))

        %{url: _detail} ->
          Antenna.HttpStub.ok(
            @collection
            |> Map.put("recent", [
              %{"title" => "まとめ: 今日の動き（2026-09-13）", "opening" => "1行目", "tags" => ["まとめ"]},
              %{"title" => "ふつうの記事", "opening" => "要約", "tags" => ["ニュース"]}
            ])
            |> Jason.encode!()
          )
      end)

      :ok
    end

    # 収集の状態は非同期に届く。**届いたことを待ってから見る** ——
    # 待たずに見ると、まだ読めていない画面を見ていることになる
    defp shown(conn) do
      Antenna.News.subscribe("antenna_news")
      {:ok, live, _html} = live(conn, ~p"/news")
      assert_receive {:news_updated, %{status: :ready}}, 2_000
      render(live)
    end

    test "巡回ごとに 1 行出て、相手を選んで送れる", %{conn: conn} do
      html = shown(conn)

      # **相手も進み具合も巡回ごとに違う**ので、収集に 1 つだけ出すと読めない
      assert html =~ "sweep-table"
      assert html =~ "収集の設定を更新"
      assert html =~ ~s(name="sweep|要約|backend")
      # 定時の巡回とは別に頼める口
      assert html =~ "いま頼む（割り込み）"
    end

    test "機械で引く巡回には相手を選ばせない", %{conn: conn} do
      # 選んでも何も起きない —— その回は AI を呼ばずに返すので、相手もモデルも
      # 読まれない。**選べるのに効かない欄は「設定したつもり」を作る**
      html = shown(conn)

      refute html =~ ~s(name="sweep|見出し|backend")
      assert html =~ "AI を使いません"
    end

    test "まとめは記事の一覧に混ぜない", %{conn: conn} do
      html = shown(conn)

      assert html =~ "news-digest"
      assert html =~ "まとめ: 今日の動き（2026-09-13）"
    end
  end

  test "関連図への行き来ができる", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/news")

    assert html =~ ~p"/relations"
  end

  describe "話題のタブ" do
    test "既定の話題がタブに並ぶ", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/news")

      assert html =~ "ニュース"
      assert html =~ "技術ニュース"
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
