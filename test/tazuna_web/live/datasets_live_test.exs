defmodule TazunaWeb.DatasetsLiveTest do
  use TazunaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TazunaWeb.DatasetsLive

  setup do
    System.delete_env("CHIEZO_BASE_URL")

    # 読んだ本棚はテストをまたいで残る（常駐プロセスが覚える）ので、毎回まっさらにする
    Tazuna.Datasets.ShelfCache.clear()
    Tazuna.AreaFixture.area!()
    :ok
  end

  # 画面を開き、**設定欄も開いて読み終えるまで進める**。設定は開いたときに初めて
  # Chiezo から読むので、設定の中身を見るテストはここを通る
  defp open_live(conn, path) do
    {:ok, live, _html} = live(conn, path)
    live |> element("#settings-toggle") |> render_click()
    {:ok, live, render_async(live)}
  end

  test "データ収集のページを表示する（既定は技術書）", %{conn: conn} do
    {:ok, _live, html} = open_live(conn, ~p"/datasets")
    assert html =~ "定番の技術書の設定"

    {:ok, _live, html} = open_live(conn, ~p"/datasets?view=dining-1")
    assert html =~ "テスト範囲の食事処"

    # 集めるのは Chiezo で、どこに残り誰が読むのかを、設定の頭で読めること
    [_, settings] = String.split(html, "テスト範囲の食事処の設定", parts: 2)
    assert settings =~ ~r|collect-origin.*「集める」層です.*tazuna_dining_1.*読むのはtravel-logです|s
  end

  test "travel-log 用の書き出しを、リンクと分かる形で出す", %{conn: conn} do
    # ブラウザから Chiezo を直接読ませない代わりの道。押すと降ってくるだけなので、
    # リンクと分かる見た目のまま、周りの注記より一段強く出す
    {:ok, _live, html} = open_live(conn, ~p"/datasets?view=dining-1")

    assert html =~ ~p"/datasets/dining-1/travel-log.zip"
    assert html =~ "download-link"
  end

  test "関連図と最新情報から行き来できる", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/relations")
    assert html =~ ~p"/datasets"

    {:ok, _live, html} = live(conn, ~p"/news")
    assert html =~ ~p"/datasets"
  end

  test "技術書の画面も開ける（抽出の指定と区画を持たない対象）", %{conn: conn} do
    # 技術書は記事を溜めてからタグで数えるので、辞典から引く指定も区画も持たない。
    # 持つ前提で描いていて、開くと落ちていた
    {:ok, _live, html} = open_live(conn, ~p"/datasets?view=books")

    assert html =~ "Chiezo への依頼文"
    refute html =~ "抽出の指定（辞典から機械的に引く条件）"
    refute html =~ "区画の割り方"
  end

  test "知らない種類は先頭の集めものに丸める", %{conn: conn} do
    # `?view=` は人が触れるところなので、書き換えられても画面が壊れない
    {:ok, _live, html} = open_live(conn, ~p"/datasets?view=%2E%2E%2F")

    assert html =~ "定番の技術書の設定"
  end

  test "溜まったものは、この画面には出さない", %{conn: conn} do
    # 読むのは travel-log。同じものを 2 つの画面で見せると、
    # どちらが本当の状態なのか読めなくなる
    {:ok, _live, html} = open_live(conn, ~p"/datasets?view=dining-1")

    assert html =~ "travel-log に渡す中身"
    refute html =~ "relation-canvas"
  end

  test "Chiezo が未設定なら、その理由を出す", %{conn: conn} do
    {:ok, live, _html} = open_live(conn, ~p"/datasets")

    assert render_async(live) =~ "CHIEZO_BASE_URL"
  end

  test "押しただけでは AI が動かないことを、押す前に読める", %{conn: conn} do
    {:ok, _live, html} = open_live(conn, ~p"/datasets")

    assert html =~ "収集を依頼する"
    assert html =~ "止まった状態"
  end

  test "機械で引くところと AI が書くところの線引きが読める", %{conn: conn} do
    # どちらが入れた値かが読めないと、地図辞典の間違いを AI のせいにしてしまう
    {:ok, _live, html} = open_live(conn, ~p"/datasets?view=dining-1")

    assert html =~ "抽出の指定"
    assert html =~ "overture_japan"
    assert html =~ "区画の割り方"
  end

  describe "Chiezo の収集の枠" do
    @collection %{
      "name" => "tazuna_dining_1",
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
          "visits" => %{
            "ざっと見る" => "2026-08-20T00:00:00Z",
            "情報収集" => "2026-09-01T00:00:00Z"
          }
        },
        %{
          "key" => "43.0,141.3/43.1,141.4",
          "count" => 90,
          "visits" => %{"情報収集" => "2026-08-01T00:00:00Z"}
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
        # tazuna が起こす回。Chiezo 側では止めてあり、間隔は収集のものが入って返る
        %{
          "name" => "情報収集",
          "interval_minutes" => 60,
          "partitions_per_run" => 5,
          "enabled" => false,
          "blocked" => "止めている"
        }
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
            Jason.encode!(%{"sources" => [%{"name" => "tazuna_dining_1", "docs" => 42}]})
          )

        # 変更履歴。**依頼した区画をちょうど見た回**が 1 つある（依頼の結果として引き当たる）
        %{method: :get, url: "http://chiezo.test:7010/v1/collect/changes?" <> _query} ->
          Tazuna.HttpStub.ok(
            Jason.encode!(%{
              "changes" => [
                %{
                  "at" => "2099-01-01T00:00:00+00:00",
                  "status" => "ok",
                  "sweep" => "情報収集",
                  "scope" => ["35.6,139.7/35.7,139.8"],
                  "added" => 25,
                  "updated" => 1,
                  "removed" => 1,
                  "added_titles" => ["そば屋"],
                  "updated_titles" => ["駅前うどん"],
                  "removed_titles" => ["閉店した店"],
                  "backend" => "antigravity"
                },
                # 定時の回（Chiezo が選んだ別の区画）は結果にしない
                %{
                  "at" => "2099-01-01T01:00:00+00:00",
                  "status" => "ok",
                  "sweep" => "情報収集",
                  "scope" => ["35.0,135.7/35.1,135.8"],
                  "added" => 9
                }
              ]
            })
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
      {:ok, live, _html} = open_live(conn, ~p"/datasets?view=dining-1")
      {live, render_async(live)}
    end

    test "巡回ごとに 1 行出て、相手を選んで送れる", %{conn: conn} do
      {_live, html} = shown(conn)

      assert html =~ "sweep-table"
      assert html =~ ~s(name="sweep|ざっと見る|backend")
      assert html =~ "収集の設定を更新"
    end

    test "機械で引く巡回には相手を選ばせない", %{conn: conn} do
      # 選んでも何も起きない —— その回は AI を呼ばずに返す
      {_live, html} = shown(conn)

      refute html =~ ~s(name="sweep|機械収集|backend")
      assert html =~ "AI を使いません"
    end

    test "手で回す巡回にも相手を選ばせない", %{conn: conn} do
      # 走らせるのは、人が持ち帰った答えを読み込んだとき —— Chiezo から相手へ
      # 投げる道が無いので、ここで選んでも読まれない
      {_live, html} = shown(conn)

      refute html =~ ~s(name="sweep|整理|backend")
    end

    test "集め方は網羅だと出す", %{conn: conn} do
      {_live, html} = shown(conn)

      # 呼び名は Chiezo の管理画面と揃える
      assert html =~ "網羅（"
      refute html =~ "流れ（"
    end

    test "区画は、まだ見ていないものが先に並ぶ", %{conn: conn} do
      {_live, html} = shown(conn)

      assert html =~ "partition-table"
      assert html =~ "35.6,139.7/35.7,139.8"
      # 並びがそのまま「次に回ってくる順」になる
      assert :binary.match(html, "35.6,139.7/35.7,139.8") <
               :binary.match(html, "34.6,135.4/34.8,135.6")
    end

    test "区画の見出しは「いま回っている巡回が見終わった数 / 総数」", %{conn: conn} do
      # ざっと見るが一周するまでは、ざっと見るの数（4 区画のうち 2 つ）
      {_live, html} = shown(conn)

      assert html =~ ~r|区画（<span[^>]*>2 / </span>4）|
      assert html =~ "「ざっと見る」が見終わった区画の数です"
      assert html =~ "まだ見ていないものが先に表示されます"
      refute html =~ "— まだ見ていないものが先"
    end

    test "既にある収集には、設定を送り直す", %{conn: conn} do
      # 作るときの POST は「もうある」で断られるので、それだけだと
      # tazuna 側で依頼文や区画を直しても永遠に届かない
      {live, _html} = shown(conn)

      live |> element("#collect-form") |> render_submit()
      render_async(live)

      assert_receive {:patched, url, sent}, 2_000
      assert url =~ "/v1/collect/tazuna_dining_1"
      assert sent["kind"] == "stock"

      # 辞典は 3 つ。**書いた順がそのまま優先の順**なので、並びごと送る
      assert Enum.map(sent["extract"], & &1["source"]) ==
               ["jawiki", "osm_japan", "overture_japan"]

      assert length(sent["sweeps"]) == 3
    end

    test "tazuna が起こす回も「どの巡回として」に出す（機械で引く回は出さない）", %{conn: conn} do
      # 情報収集は Chiezo 側では止めてあるが、名前で起こせばふつうの回として走る ——
      # 選んだ区画を情報収集で 1 回見てもらうことはできる。
      # 機械で引く回は区画を回らないので、選べるのに効かない欄になる
      {live, _html} = shown(conn)

      html =
        live
        |> element(~s|.partition-table tbody tr:first-child button|)
        |> render_click()

      assert html =~ ~s(<option value="ざっと見る")
      assert html =~ ~s(<option value="情報収集")
      refute html =~ ~s(<option value="機械収集")
    end

    test "tazuna が起こす回は、要約と同じく時計なし・頼まれたときと出す", %{conn: conn} do
      # Chiezo 側では止めてあるので、そのまま出すと間隔と「止めている」が並び、
      # 動かないように読める。いつ起こすかは「情報収集の時刻」の欄が出す
      {live, _html} = shown(conn)

      row =
        live
        |> element(~s|#collect-form .sweep-table tbody tr:nth-child(3)|)
        |> render()

      assert row =~ "情報収集"
      assert row =~ "時計なし"
      assert row =~ "頼まれたとき"
      refute row =~ "60 分ごと"
      refute row =~ "止めている"
    end

    test "一覧からも、その区画を選べる", %{conn: conn} do
      # 一覧と地図は同じ 1 つの口へ繋ぐ（押した先で何が起きるかが変わらないように）
      {live, _html} = shown(conn)

      html =
        live
        |> element(~s|.partition-table tbody tr:first-child button|)
        |> render_click()

      assert html =~ "選んだ区画"
      assert html =~ "この区画で 1 回走らせる"
    end

    test "区画は地図にもなる", %{conn: conn} do
      # 「8,185 区画のうち 2 つ見終わり」と数で言われても、どこなのかは読めない
      {_live, html} = shown(conn)

      assert html =~ "partition-map"
      # 見終わった区画は色を変える（進み具合は数では読めない）
      assert html =~ "is-seen"
      assert html =~ ~s(phx-value-key="35.6,139.7/35.7,139.8")
    end

    test "色は、どの巡回まで見たかで決まる", %{conn: conn} do
      # ざっと見るだけが見た区画は薄い黄色、情報収集まで見た区画は薄い緑。
      # 何本が見たかで濃さを変えていた頃は、どちらの巡回が済んだのかが読めなかった
      {_live, html} = shown(conn)

      # ざっと見るだけ
      assert html =~ ~r|<rect[^>]*is-seen[^>]*phx-value-key="35.0,135.7/35.1,135.8"|
      # 両方
      assert html =~ ~r|<rect[^>]*is-done[^>]*phx-value-key="34.6,135.4/34.8,135.6"|
      # 情報収集だけ（情報収集が済んでいれば緑）
      assert html =~ ~r|<rect[^>]*is-done[^>]*phx-value-key="43.0,141.3/43.1,141.4"|
      assert html =~ "薄い黄色が「ざっと見る」まで、薄い緑が「情報収集」まで見終わった区画"
      # 起点にピンが立つ（決めていなければ範囲の真ん中）
      assert html =~ ~s(class="origin-pin")
      assert html =~ "起点：テスト範囲の真ん中"
      assert html =~ "ざっと見る 済み"
    end

    test "地図の上で地名を探すと、その場所へ寄って印を立てる", %{conn: conn} do
      collection = @collection

      Tazuna.HttpStub.stub(fn %{url: url} ->
        cond do
          String.contains?(url, "/v1/osm_japan/search?") ->
            Tazuna.HttpStub.ok(Jason.encode!(%{"results" => [%{"title" => "札幌駅 (node:1)"}]}))

          String.contains?(url, "/v1/osm_japan/doc?") ->
            Tazuna.HttpStub.ok(
              Jason.encode!(%{
                "title" => "札幌駅 (node:1)",
                "extra" => %{"lat" => 43.05, "lon" => 141.35, "area" => "北海道"}
              })
            )

          String.ends_with?(url, "/v1/collect") ->
            Tazuna.HttpStub.ok(Jason.encode!(%{"collections" => [collection]}))

          String.contains?(url, "/v1/collect/") ->
            Tazuna.HttpStub.ok(Jason.encode!(collection))

          true ->
            Tazuna.HttpStub.ok(~s({"backends":[],"sources":[],"changes":[]}))
        end
      end)

      {live, _html} = shown(conn)

      live |> element("#map-search") |> render_change(%{"q" => "札幌"})
      html = render_async(live)
      assert html =~ ~s(phx-click="focus_map_place")
      assert html =~ "札幌駅"

      html = live |> element(~s([phx-click="focus_map_place"])) |> render_click()

      # 図へ「ここへ寄って」を送り、探した場所に印を立てる（区画と同じ投影で）
      assert_push_event(live, "map_focus", %{x: x, y: y})
      assert html =~ ~s(class="find-pin")
      assert html =~ ~s(data-x="#{x}")
      assert html =~ ~s(data-y="#{y}")
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

      # **ふつうの回として走らせる。** 割り込みは進み具合にも印にも触らないので、
      # 押しても画面が変わらず「何が起きたのか分からない」になっていた
      live
      |> form(~s|.partition-picked form|, %{
        "sweep" => "ざっと見る",
        "run|backend" => "antigravity"
      })
      |> render_submit()

      assert_receive {:posted, url, sent}, 2_000
      assert url =~ "/run"
      assert url =~ "sweep=%E3%81%96%E3%81%A3%E3%81%A8%E8%A6%8B%E3%82%8B"
      assert sent["partitions"] == ["43.0,141.3/43.1,141.4"]
      assert sent["backend"] == "antigravity"
    end

    test "travel-log からの依頼を、座標を含む区画の情報収集として頼める", %{conn: conn} do
      {live, _html} = shown(conn)

      text = """
      # 修正・追加の依頼(日本の食事処) 3件

      - [修正] 駅前うどん (35.65000,139.75000): 閉店している
      - [追加] (35.68000,139.76000): そば屋がある
      - [追加] (26.20000,127.68000): 区画の外
      """

      live
      |> form(~s|form[phx-submit="travel_log_request"]|, %{text: text})
      |> render_submit()

      # **ふつうの回として走らせる**（割り込みではない）。区画は座標から引き、
      # 同じ区画に入る 2 件は 1 つにまとめる。補足は**区画ごと**に渡す
      assert_receive {:posted, url, sent}, 2_000
      assert url =~ "/v1/collect/tazuna_dining_1/run"
      assert url =~ URI.encode_query(%{"sweep" => "情報収集"})
      assert sent["partitions"] == ["35.6,139.7/35.7,139.8"]
      note = sent["notes"]["35.6,139.7/35.7,139.8"]
      assert note =~ "閉店している"
      assert note =~ "そば屋がある"
      # 区画の外の依頼は、どの区画にも渡さない
      refute note =~ "区画の外"
      refute Map.has_key?(sent, "note")

      # **外れた座標を黙って落とさない**
      html = render_async(live, 2_000)
      assert html =~ "区画 1 つで情報収集を頼みました"
      assert html =~ "(26.2,127.68)"

      # **依頼と、その結果を並べる**（頼んだ区画をちょうど見た回を引き当てる）
      assert [log] = Tazuna.Datasets.Requests.recent("tazuna_dining_1")
      assert log.keys == ["35.6,139.7/35.7,139.8"]
      assert log.status == "sent"
      assert html =~ "依頼の結果"
      assert html =~ "足した 25 ・直した 1 ・消した 1"
      assert html =~ "そば屋"
      assert html =~ "閉店した店"
      # 見出しは Chiezo の画面の「直す前との違い」へ
      assert html =~ "/admin/collect/tazuna_dining_1/doc?title="
      # Chiezo の控えは頭のほうだけ（足した 25 件のうち 1 件だけ並ぶ）
      assert html =~ "ほか 24 件"
    end

    test "座標の無いテキストでは頼まない", %{conn: conn} do
      {live, _html} = shown(conn)

      html =
        live
        |> form(~s|form[phx-submit="travel_log_request"]|, %{text: "駅前のうどん屋が閉店"})
        |> render_submit()

      assert html =~ "座標が見つかりませんでした"
      refute_receive {:posted, _url, _sent}, 300
    end

    test "travel-log が読む収集には、割り込みの欄を出さない", %{conn: conn} do
      # 「travel-log からの依頼」がその役を引き受ける（同じ頼みごとの行き先が 2 つあると迷う）
      {_live, html} = shown(conn)

      assert html =~ "travel-log からの依頼"
      refute html =~ ~s(phx-submit="ask")
    end
  end

  describe "この収集から作る収集（本棚）" do
    # 親の収集と同じ形で出す —— 状態・巡回ごとの相手・送る
    @shelf %{
      "name" => "tazuna_books",
      "enabled" => false,
      "interval_minutes" => 1440,
      "kind" => "stock",
      "sweeps" => [
        %{"name" => "機械収集", "interval_minutes" => 360, "use_extract" => true, "enabled" => true},
        %{"name" => "整理", "interval_minutes" => 1440, "enabled" => true}
      ]
    }

    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      test_pid = self()

      Tazuna.HttpStub.stub(fn
        %{url: "http://chiezo.test:7010/v1/ai/backends"} ->
          Tazuna.HttpStub.ok(~s({"backends":[{"id":"antigravity","label":"Antigravity"}]}))

        %{method: :get, url: "http://chiezo.test:7010/v1/collect"} ->
          Tazuna.HttpStub.ok(Jason.encode!(%{"collections" => [@shelf]}))

        %{method: :get, url: "http://chiezo.test:7010/v1/collect/tazuna_books" <> _rest} ->
          Tazuna.HttpStub.ok(Jason.encode!(@shelf))

        %{method: :get, url: "http://chiezo.test:7010/v1/tazuna_book_posts/filter?" <> _query} ->
          Tazuna.HttpStub.ok(
            Jason.encode!(%{
              "results" => [
                %{
                  "title" => "おすすめの本 10 冊",
                  "extra" => %{"url" => "https://example.com/a", "published_at" => "2026-01-07"}
                }
              ]
            })
          )

        %{method: :get, url: "http://chiezo.test:7010/v1/tazuna_books/filter?" <> _query} ->
          Tazuna.HttpStub.ok(
            Jason.encode!(%{
              "results" => [
                %{
                  "title" => "本:入門 監視",
                  "tags" => ["技術書", "話題:監視"],
                  "extra" => %{"docs" => 2}
                },
                # 整理の回が見出しを書き換えて足してしまったもの（数を持たない）
                %{"title" => "リーダブルコード", "tags" => ["技術書"], "extra" => %{}},
                %{
                  "title" => "本:リーダブルコード",
                  "tags" => ["技術書", "分野:設計・アーキテクチャ"],
                  "opening" => "読みやすいコードの書き方",
                  "extra" => %{"docs" => 5, "isbn" => "9784873115658"}
                }
              ]
            })
          )

        %{method: :patch, url: url, body: body} ->
          send(test_pid, {:patched, url, Jason.decode!(body)})
          Tazuna.HttpStub.ok(~s({}))

        %{method: :post, url: url, body: body} ->
          send(test_pid, {:posted, url, Jason.decode!(body)})
          Tazuna.HttpStub.ok(~s({}))

        %{method: :get, url: _other} ->
          Tazuna.HttpStub.ok(~s({"collections":[],"sources":[],"changes":[]}))
      end)

      :ok
    end

    test "本棚の本を、表紙つきでおすすめ度の高い順に並べる", %{conn: conn} do
      {:ok, live, _html} = open_live(conn, ~p"/datasets?view=books")
      html = render_async(live)

      [_, shelf] = String.split(html, ~s(class="bookshelf"), parts: 2)
      assert shelf =~ "https://www.hanmoto.com/bd/img/9784873115658.jpg"
      assert shelf =~ "記事 5 本が勧めている"
      assert shelf =~ "定番"
      {first, _} = :binary.match(shelf, "リーダブルコード")
      {second, _} = :binary.match(shelf, "入門 監視")
      assert first < second
      # 数を持たない本（見出しを書き換えて足されたもの）は並べない
      refute shelf =~ ~s(phx-value-title="リーダブルコード")
    end

    test "興味トピックに近い本を強調し、絞り込める", %{conn: conn} do
      Tazuna.News.Interests.toggle("tazuna_tech", "設計・アーキテクチャ")
      Tazuna.News.Interests.toggle("tazuna_tech", "監視")

      {:ok, live, _html} = open_live(conn, ~p"/datasets?view=books")
      html = render_async(live)

      assert html =~ "★ 興味: 監視"
      assert html =~ "興味トピックに近い本だけ（1 冊）"

      html = live |> element(".shelf-near-toggle") |> render_click()
      [_, rest] = String.split(html, ~s(class="book-list"), parts: 2)
      [shelf, _] = String.split(rest, "</ol>", parts: 2)
      assert shelf =~ "入門 監視"
      refute shelf =~ "リーダブルコード"
    end

    test "本を押すと詳細が開き、勧めている記事へのリンクが出る", %{conn: conn} do
      {:ok, live, _html} = open_live(conn, ~p"/datasets?view=books")
      render_async(live)

      refute render(live) =~ "https://example.com/a"

      live
      |> element(~s(button.book-name[phx-value-title="本:リーダブルコード"]))
      |> render_click()

      html = render_async(live)
      assert html =~ ~s(role="dialog")
      assert html =~ ~s(href="https://example.com/a")
      assert html =~ "おすすめの本 10 冊"
      assert html =~ "ISBN 9784873115658"

      refute live |> element(~s(button[phx-click="close_book"])) |> render_click() =~
               ~s(role="dialog")
    end

    test "詳細から、その本だけを本棚の整理の回に調べ直してもらえる", %{conn: conn} do
      # 「いま頼む」はどの収集に頼むのか読めなかった。本を見ながら、その本について頼む
      {:ok, live, _html} = open_live(conn, ~p"/datasets?view=books")
      render_async(live)

      live
      |> element(~s(button.book-name[phx-value-title="本:リーダブルコード"]))
      |> render_click()

      live
      |> element("#book-ask")
      |> render_submit(%{"title" => "本:リーダブルコード", "note" => "表紙が違う"})

      assert render_async(live) =~ "Chiezo に頼みました"
      assert_receive {:posted, url, body}, 2_000
      assert url =~ "/v1/collect/tazuna_books/focus"
      assert body["titles"] == ["本:リーダブルコード"]
      assert body["sweep"] == "整理"
      assert body["note"] =~ "リーダブルコードについて"
      assert body["note"] =~ "補足: 表紙が違う"
      # 調べ終えた本でも並ぶように、名指しした 1 冊を {current} で見せる
      assert body["prompt"] =~ "{current}"
      refute body["prompt"] =~ "{unreviewed}"
    end

    test "「いま頼む」の欄は出さず、依頼文は収集ごとの節に出す", %{conn: conn} do
      {:ok, live, _html} = open_live(conn, ~p"/datasets?view=books")
      html = render_async(live)

      refute html =~ "いま頼む（割り込み）"
      [before_shelf, shelf] = String.split(html, "本棚（定番の技術書）", parts: 2)
      assert before_shelf =~ "Chiezo への依頼文"
      assert shelf =~ "Chiezo への依頼文"
      assert shelf =~ "抽出の指定（記事のタグを機械で数える条件）"
      # 読む人に渡す中身は、設定の枠の一番下
      [_, tail] = String.split(shelf, "Chiezo への依頼文", parts: 2)
      assert tail =~ "読む人 に渡す中身"
    end

    test "巡回ごとに相手を選んで送れる", %{conn: conn} do
      {:ok, live, _html} = open_live(conn, ~p"/datasets?view=books")
      html = render_async(live)

      [_, shelf] = String.split(html, "本棚（定番の技術書）", parts: 2)
      assert shelf =~ "止まっている"
      assert shelf =~ ~s(name="sweep|整理|backend")
      # 機械収集の回は AI を呼ばないので選ばせない
      refute shelf =~ ~s(name="sweep|機械収集|backend")
      assert shelf =~ "収集の設定を更新"

      live
      |> element("#derived-collect-form")
      |> render_submit(%{"sweep|整理|backend" => "antigravity"})

      render_async(live)

      assert_receive {:patched, url, sent}, 2_000
      assert url =~ "/v1/collect/tazuna_books"
      tidy = Enum.find(sent["sweeps"], &(&1["name"] == "整理"))
      assert tidy["backend"] == "antigravity"
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

  describe "起点と情報収集の時刻" do
    # 起点は区画の地図の下、時刻は Chiezo の収集の下（巡回の表の近く）に分けて置く
    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

      Tazuna.HttpStub.stub(fn %{url: url} ->
        cond do
          String.contains?(url, "/v1/osm_japan/search?") ->
            Tazuna.HttpStub.ok(
              Jason.encode!(%{
                "results" => [%{"title" => "銀座 (node:1)"}, %{"title" => "座標の無い銀座"}]
              })
            )

          String.contains?(url, "/v1/osm_japan/doc?") and String.contains?(url, "node") ->
            Tazuna.HttpStub.ok(
              Jason.encode!(%{
                "title" => "銀座 (node:1)",
                "extra" => %{
                  "lat" => 35.6728,
                  "lon" => 139.7631,
                  "area" => "東京都",
                  "feature" => "railway=station"
                }
              })
            )

          String.contains?(url, "/v1/osm_japan/doc?") ->
            Tazuna.HttpStub.ok(Jason.encode!(%{"title" => "座標の無い銀座", "extra" => %{}}))

          true ->
            Tazuna.HttpStub.ok(~s({"collections":[],"backends":[],"sources":[]}))
        end
      end)

      :ok
    end

    test "地名で探して起点を決め、時刻を保存する", %{conn: conn} do
      {:ok, live, html} = open_live(conn, ~p"/datasets?view=dining-1")
      assert html =~ ~s(aria-label="起点")
      assert html =~ ~s(aria-label="情報収集の時刻")
      # 並びは 起点 → Chiezo の収集 → 情報収集の時刻（地図は起点の上）
      at = fn needle -> html |> :binary.match(needle) |> elem(0) end
      assert at.(~s(aria-label="起点")) < at.("<h3>Chiezo の収集</h3>")
      assert at.("<h3>Chiezo の収集</h3>") < at.(~s(aria-label="情報収集の時刻"))
      # 決めていなければ範囲の真ん中
      assert html =~ "テスト範囲の真ん中（35.7, 139.7）"

      # 座標を Google マップで開ける（同じ名前の別の場所を選んでいないか確かめるため）
      assert html =~ "https://www.google.com/maps/search/?api=1&amp;query=35.7%2C139.7"
      assert html =~ "既定のままです"

      live |> form("#place-search", %{"q" => "銀座"}) |> render_submit()
      html = render_async(live)

      # 座標の取れない候補は出さない。見出しの重複を避ける番号も見せない
      assert html =~ ~s(phx-click="pick_place")
      refute html =~ "座標の無い銀座"
      refute html =~ "node:1"

      html = live |> element(~s([phx-click="pick_place"])) |> render_click()
      assert html =~ "銀座（35.6728, 139.7631）"
      assert Tazuna.Datasets.SurveyPlans.get("tazuna_dining_1").place_set_at

      # 収集がまだ無いので Chiezo へは送らない（作るときに載る）。送れなかった旨も出さない
      refute html =~ "Chiezo へ送れませんでした"

      html =
        live
        |> form("#survey-times", %{"survey_plan" => %{"run_at" => "3:00"}})
        |> render_submit()

      assert Tazuna.Datasets.SurveyPlans.get("tazuna_dining_1").run_at == "03:00"
      refute html =~ "時刻が決まっていません"
    end

    test "読めない時刻は保存せず、理由を出す", %{conn: conn} do
      {:ok, live, _html} = open_live(conn, ~p"/datasets?view=dining-1")

      html =
        live
        |> form("#survey-times", %{"survey_plan" => %{"run_at" => "朝"}})
        |> render_submit()

      assert html =~ "24 時間制で書いてください"
    end
  end
end
