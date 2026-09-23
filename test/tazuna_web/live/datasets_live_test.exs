defmodule TazunaWeb.DatasetsLiveTest do
  use TazunaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TazunaWeb.DatasetsLive

  setup do
    System.delete_env("CHIEZO_BASE_URL")
    :ok
  end

  test "データ収集のページを表示する", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/datasets")

    assert html =~ "日本の食事処"
    # 集めるのは Chiezo だと画面から読めること
    assert html =~ "Chiezo"
  end

  test "travel-log 用の書き出しを、リンクと分かる形で出す", %{conn: conn} do
    # ブラウザから Chiezo を直接読ませない代わりの道。押すと降ってくるだけなので、
    # リンクと分かる見た目のまま、周りの注記より一段強く出す
    {:ok, _live, html} = live(conn, ~p"/datasets")

    assert html =~ ~p"/datasets/meals/travel-log.zip"
    assert html =~ "download-link"
  end

  test "関連図と最新情報から行き来できる", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/relations")
    assert html =~ ~p"/datasets"

    {:ok, _live, html} = live(conn, ~p"/news")
    assert html =~ ~p"/datasets"
  end

  test "知らない種類は先頭の集めものに丸める", %{conn: conn} do
    # `?view=` は人が触れるところなので、書き換えられても画面が壊れない
    {:ok, _live, html} = live(conn, ~p"/datasets?view=%2E%2E%2F")

    assert html =~ "日本の食事処"
  end

  test "溜まったものは、この画面には出さない", %{conn: conn} do
    # 読むのは travel-log。同じものを 2 つの画面で見せると、
    # どちらが本当の状態なのか読めなくなる
    {:ok, _live, html} = live(conn, ~p"/datasets")

    assert html =~ "travel-log に渡す中身"
    refute html =~ "relation-canvas"
  end

  test "Chiezo が未設定なら、その理由を出す", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/datasets")

    assert render_async(live) =~ "CHIEZO_BASE_URL"
  end

  test "押しただけでは AI が動かないことを、押す前に読める", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/datasets")

    assert html =~ "収集を依頼する"
    assert html =~ "止まった状態"
  end

  test "機械で引くところと AI が書くところの線引きが読める", %{conn: conn} do
    # どちらが入れた値かが読めないと、地図辞典の間違いを AI のせいにしてしまう
    {:ok, _live, html} = live(conn, ~p"/datasets")

    assert html =~ "抽出の指定"
    assert html =~ "overture_japan"
    assert html =~ "区画の割り方"
  end

  describe "Chiezo の収集の枠" do
    @collection %{
      "name" => "tazuna_meals",
      "description" => "tazuna のデータ収集（日本の食事処 / travel-log 向け）",
      "enabled" => true,
      "interval_minutes" => 60,
      "kind" => "stock",
      "partitions_total" => 4,
      "partitions" => [
        %{"key" => "35.6,139.7/35.7,139.8", "count" => 180, "visits" => %{}},
        %{
          "key" => "35.0,135.7/35.1,135.8",
          "count" => 120,
          "visits" => %{"ざっと見る" => "2026-09-20T00:00:00Z"}
        },
        %{
          "key" => "34.6,135.4/34.8,135.6",
          "count" => 150,
          "visits" => %{"整理" => "2026-09-01T00:00:00Z"}
        },
        %{
          "key" => "43.0,141.3/43.1,141.4",
          "count" => 90,
          "visits" => %{"整理" => "2026-08-01T00:00:00Z"}
        }
      ],
      "sweeps" => [
        %{
          "name" => "機械収集",
          "interval_minutes" => 10_080,
          "use_extract" => true,
          "enabled" => true
        },
        %{"name" => "ざっと見る", "interval_minutes" => 60, "cover_days" => 3, "enabled" => true},
        %{"name" => "整理", "interval_minutes" => 360, "cover_days" => 14, "enabled" => true}
      ]
    }

    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      test_pid = self()

      Tazuna.HttpStub.stub(fn
        %{url: "http://chiezo.test:7010/v1/ai/backends"} ->
          Tazuna.HttpStub.ok(~s({"backends":[{"id":"antigravity","label":"Antigravity"}]}))

        %{url: "http://chiezo.test:7010/v1/sources"} ->
          Tazuna.HttpStub.ok(
            Jason.encode!(%{"sources" => [%{"name" => "tazuna_meals", "docs" => 42}]})
          )

        %{method: :get, url: "http://chiezo.test:7010/v1/collect"} ->
          Tazuna.HttpStub.ok(Jason.encode!(%{"collections" => [@collection]}))

        %{method: :patch, url: url, body: body} ->
          send(test_pid, {:patched, url, Jason.decode!(body)})
          Tazuna.HttpStub.ok(~s({}))

        %{method: :post, url: url, body: body} ->
          send(test_pid, {:posted, url, Jason.decode!(body)})
          Tazuna.HttpStub.ok(~s({}))

        %{method: :get, url: _detail} ->
          Tazuna.HttpStub.ok(Jason.encode!(@collection))
      end)

      :ok
    end

    defp shown(conn) do
      {:ok, live, _html} = live(conn, ~p"/datasets")
      {live, render_async(live)}
    end

    test "巡回ごとに 1 行出て、相手を選んで送れる", %{conn: conn} do
      {_live, html} = shown(conn)

      assert html =~ "sweep-table"
      assert html =~ ~s(name="sweep|整理|backend")
      assert html =~ "収集の設定を更新"
    end

    test "機械で引く巡回には相手を選ばせない", %{conn: conn} do
      # 選んでも何も起きない —— その回は AI を呼ばずに返す
      {_live, html} = shown(conn)

      refute html =~ ~s(name="sweep|機械収集|backend")
      assert html =~ "AI を使いません"
    end

    test "集め方は網羅だと出す", %{conn: conn} do
      {_live, html} = shown(conn)

      assert html =~ "全部を精査する"
      refute html =~ "流れを追う"
    end

    test "区画は、まだ見ていないものが先に並ぶ", %{conn: conn} do
      {_live, html} = shown(conn)

      assert html =~ "partition-table"
      assert html =~ "35.6,139.7/35.7,139.8"
      # 並びがそのまま「次に回ってくる順」になる
      assert :binary.match(html, "35.6,139.7/35.7,139.8") <
               :binary.match(html, "34.6,135.4/34.8,135.6")
    end

    test "既にある収集には、設定を送り直す", %{conn: conn} do
      # 作るときの POST は「もうある」で断られるので、それだけだと
      # tazuna 側で依頼文や区画を直しても永遠に届かない
      {live, _html} = shown(conn)

      live |> element("#collect-form") |> render_submit()
      render_async(live)

      assert_receive {:patched, url, sent}, 2_000
      assert url =~ "/v1/collect/tazuna_meals"
      assert sent["kind"] == "stock"

      # 辞典は 3 つ。**書いた順がそのまま優先の順**なので、並びごと送る
      assert Enum.map(sent["extract"], & &1["source"]) ==
               ["jawiki", "osm_japan", "overture_japan"]

      assert length(sent["sweeps"]) == 3
    end

    test "この区画を先に調べて、を頼める", %{conn: conn} do
      {live, _html} = shown(conn)

      # 区画ごとに 1 つずつあるので、先頭の行（いちばん長く見ていない区画）を押す
      live
      |> element(~s|.partition-table tbody tr:first-child form|)
      |> render_submit()

      assert_receive {:posted, url, sent}, 2_000
      assert url =~ "/focus"

      # **必ず区画の名前で始める** —— 指示文だけを読んだ人には、どこ宛てか分からない
      assert sent["note"] =~ "35.6,139.7/35.7,139.8"
      assert sent["partition"] == "35.6,139.7/35.7,139.8"
      # 頼むのは同じ仕事なので、設定も依頼文もじっくりのものでよい
      assert sent["sweep"] == "整理"
    end

    test "区画は地図にもなる", %{conn: conn} do
      # 「8,185 区画のうち 2 つ見終わり」と数で言われても、どこなのかは読めない
      {_live, html} = shown(conn)

      assert html =~ "partition-map"
      # 見終わった区画は色を変える（進み具合は数では読めない）
      assert html =~ "is-seen"
      assert html =~ ~s(phx-value-key="35.6,139.7/35.7,139.8")
    end

    test "先に回る巡回が見終えた区画も色が変わる", %{conn: conn} do
      # **後の回はしばらく走らない**（前の回が一周するまで待つ）ので、
      # 後の回だけで進み具合を測ると、回っているのにどこも「まだ」のままになる
      {_live, html} = shown(conn)

      assert html =~ ~r|<rect[^>]*is-seen[^>]*phx-value-key="35.0,135.7/35.1,135.8"|
      # じっくりまで済んだ区画は、もう一段濃くする
      assert html =~ ~r|<rect[^>]*is-done[^>]*phx-value-key="34.6,135.4/34.8,135.6"|
      assert html =~ "ざっと見る 済み"
    end

    test "地図で押した区画から、その場で頼める", %{conn: conn} do
      {live, _html} = shown(conn)

      # **押しただけでは走らない** —— 何件あるのか、見終わっているのかを読んでから頼む
      html =
        live
        |> element(~s|.partition-map rect[phx-value-key="43.0,141.3/43.1,141.4"]|)
        |> render_click()

      assert html =~ "選んだ区画"
      assert html =~ "43.0,141.3/43.1,141.4"
      assert html =~ "90 件"

      live |> form(~s|.partition-picked form|, %{note: "閉店を見て"}) |> render_submit()

      assert_receive {:posted, url, sent}, 2_000
      assert url =~ "/focus"
      assert sent["partition"] == "43.0,141.3/43.1,141.4"
      assert sent["note"] =~ "閉店を見て"
    end

    test "定時の巡回とは別に、1 回だけ頼める", %{conn: conn} do
      {live, _html} = shown(conn)

      live
      |> form(~s|form[phx-submit="ask"]|, %{note: "駅前にうどんの名店が抜けていないか"})
      |> render_submit()

      assert_receive {:posted, _url, sent}, 2_000
      assert sent["note"] =~ "うどん"
    end

    test "何も書かずに頼ませない", %{conn: conn} do
      {live, _html} = shown(conn)

      live |> form(~s|form[phx-submit="ask"]|, %{note: "   "}) |> render_submit()

      refute_receive {:posted, _url, _sent}, 300
    end
  end

  describe "画面の文言" do
    test "区画への頼みごとは、必ず区画の名前で始まる" do
      assert DatasetsLive.partition_note("35.6,139.7/35.7,139.8", nil) =~ "35.6,139.7/35.7,139.8"

      assert DatasetsLive.partition_note("35.6,139.7/35.7,139.8", "閉店を見て") =~ "閉店を見て"
    end

    test "読めていない状態と、収集が無い状態を区別する" do
      # 読めていないのに「まだ作られていません」と出すと、押した人は作り直そうとする
      idle = DatasetsLive.status_message(%{collection: nil, status: :idle, reason: nil})
      none = DatasetsLive.status_message(%{collection: nil, status: :ready, reason: nil})

      assert idle =~ "読んでいません"
      assert none =~ "まだ Chiezo にありません"
    end
  end
end
