defmodule ChidoriWeb.DatasetsLiveTest do
  use ChidoriWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ChidoriWeb.DatasetsLive

  setup do
    System.delete_env("CHIEZO_BASE_URL")

    # 読んだ本棚はテストをまたいで残る（常駐プロセスが覚える）ので、毎回まっさらにする
    Chidori.Datasets.ShelfCache.clear()
    Chidori.AreaFixture.area!()
    :ok
  end

  # 届いた POST のうち、URL に `part` を含むものを待つ（ほかの POST は読み捨てる）
  defp receive_post(part) do
    receive do
      {:posted, url, body} -> if url =~ part, do: {url, body}, else: receive_post(part)
    after
      2_000 -> flunk("#{part} への POST が届きませんでした")
    end
  end

  # 収集の画面（/collect/datasets）を開き、設定を読み終えるまで進める。
  # 収集の画面は設定欄を開いた形で出すので、設定の中身を見るテストはここを通る
  defp open_live(conn, path) do
    {:ok, live, _html} = live(conn, path)
    assert has_element?(live, "#chiezo-settings")
    {:ok, live, render_async(live)}
  end

  # 読む画面（/datasets）を開き、溜まったものが届くまで進める
  defp open_read(conn, path) do
    {:ok, live, _html} = live(conn, path)
    {:ok, live, render_async(live)}
  end

  test "収集の画面は設定を開いた状態で出し、読む画面（技術書の本棚）には設定を出さない", %{conn: conn} do
    Chidori.AreaFixture.area!()

    {:ok, _live, html} = live(conn, ~p"/collect/apps?view=dining-1")
    assert html =~ ~s(aria-expanded="true")
    assert html =~ ~s(id="chiezo-settings")

    {:ok, _live, html} = live(conn, ~p"/collect/datasets?view=books")
    assert html =~ ~s(id="chiezo-settings")
    refute html =~ ~s(class="bookshelf")

    {:ok, _live, html} = live(conn, ~p"/datasets?view=books")
    refute html =~ ~s(id="settings-toggle")
    refute html =~ ~s(id="chiezo-settings")
    assert html =~ ~s(href="/collect/datasets?view=books")
  end

  test "読むものを持たない対象を読む画面で開くと、収集の画面へ送る", %{conn: conn} do
    Chidori.AreaFixture.area!()

    for view <- ["dining-1", "anime"] do
      to = "/collect/apps?view=#{view}"
      assert {:error, {:live_redirect, %{to: ^to}}} = live(conn, "/datasets?view=#{view}")
    end
  end

  test "レシピ集の名簿を引き直す口は、収集の画面にだけ置く", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/collect/datasets?view=recipes")
    assert html =~ "名簿を引き直す"

    {:ok, _live, html} = live(conn, ~p"/datasets?view=recipes")
    refute html =~ "名簿を引き直す"
  end

  test "収集の画面では、頭のメニューの「収集」を選んだ状態にする", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/collect/datasets")
    assert html =~ ~r|class="active" href="/collect"|

    {:ok, _live, html} = live(conn, ~p"/datasets")
    assert html =~ ~r|class="active" href="/datasets"|
  end

  test "タブは画面ごとに分ける（読む画面と収集のデータ収集は Chidori で読む対象、他アプリ用はそれ以外）", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/datasets")
    [_, tabs] = String.split(html, ~s(id="dataset-tabs"), parts: 2)
    [tabs, _] = String.split(tabs, "</nav>", parts: 2)

    assert tabs =~ ~s(href="/datasets?view=books")
    assert tabs =~ ~s(href="/datasets?view=recipes")
    refute tabs =~ "view=anime"
    refute tabs =~ "食事処"

    {:ok, _live, html} = live(conn, ~p"/collect/datasets")
    [_, tabs] = String.split(html, ~s(id="dataset-tabs"), parts: 2)
    [tabs, _] = String.split(tabs, "</nav>", parts: 2)

    assert tabs =~ ~s(href="/collect/datasets?view=books")
    assert tabs =~ ~s(href="/collect/datasets?view=recipes")
    refute tabs =~ "view=anime"
    refute tabs =~ "view=gourmet"
    refute tabs =~ "食事処"

    {:ok, _live, html} = live(conn, ~p"/collect/apps?view=anime")
    [_, tabs] = String.split(html, ~s(id="dataset-tabs"), parts: 2)
    [tabs, _] = String.split(tabs, "</nav>", parts: 2)

    assert tabs =~ ~s(href="/collect/apps?view=anime")
    assert tabs =~ ~s(href="/collect/apps?view=gourmet")
    assert tabs =~ ~s(href="/collect/apps/areas")
    refute tabs =~ "view=books"
  end

  test "他アプリ用の対象をデータ収集の道で開くと、他アプリ用へ送る（逆も同じ）", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/collect/apps?view=anime"}}} =
             live(conn, "/collect/datasets?view=anime")

    assert {:error, {:live_redirect, %{to: "/collect/datasets?view=books"}}} =
             live(conn, "/collect/apps?view=books")

    # 他アプリ用を対象なしで開くと、食事処の範囲の一覧へ
    assert {:error, {:live_redirect, %{to: "/collect/apps/areas"}}} = live(conn, "/collect/apps")
  end

  test "他アプリ用の画面では、収集の頭の段の「他アプリ用」を選んだ状態にする", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/collect/apps?view=gourmet")
    [picked] = Regex.run(~r|<a[^>]*href="/collect/apps"[^>]*>|, html)
    assert picked =~ ~s(class="selected")

    {:ok, _live, html} = live(conn, ~p"/collect/datasets?view=books")
    [picked] = Regex.run(~r|<a[^>]*href="/collect/datasets"[^>]*>|, html)
    assert picked =~ ~s(class="selected")
  end

  test "データ収集の収集の画面を表示する（既定は技術書）", %{conn: conn} do
    {:ok, _live, html} = open_live(conn, ~p"/collect/datasets")
    assert html =~ "定番の技術書の設定"

    {:ok, _live, html} = open_live(conn, ~p"/collect/apps?view=dining-1")
    assert html =~ "テスト範囲の食事処"

    # 集めるのは Chiezo で、どこに残り誰が読むのかを、設定の頭で読めること
    [_, settings] = String.split(html, "テスト範囲の食事処の設定", parts: 2)
    assert settings =~ ~r|collect-origin.*「集める」層です.*chidori_dining_1.*読むのはtravel-logです|s
  end

  test "Pi-hole のタブで、いま止めている通信を流せる", %{conn: conn} do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

    Chidori.HttpStub.stub(fn %{method: :get, url: url} ->
      body =
        if url =~ "/v1/pihole/blocked",
          do: %{
            "cursor" => 1_759_600_005.0,
            "queries" => [
              %{
                "id" => 1,
                "at" => "2026-10-04T12:00:05+00:00",
                "domain" => "ads.example.com",
                "client" => "192.0.2.10",
                "client_name" => "tablet",
                "status" => "GRAVITY"
              }
            ]
          },
          else: %{"results" => []}

      Chidori.HttpStub.ok(Jason.encode!(body))
    end)

    {:ok, live, html} = live(conn, ~p"/datasets?view=pihole")
    assert html =~ "いま止めている通信"

    live |> element(~s|button[phx-click="live_start"]|) |> render_click()
    html = render_async(live)

    assert html =~ "ads.example.com"
    assert html =~ "（tablet）"
    assert html =~ ~s(phx-click="live_stop")

    # 止めたら、読みに行かない（行は残る）
    html = live |> element(~s|button[phx-click="live_stop"]|) |> render_click()
    assert html =~ ~s(phx-click="live_start")
    assert html =~ "ads.example.com"
  end

  test "Pi-hole のドメインに「見た」を付けられ、まだ見ていないものだけに絞れる", %{conn: conn} do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

    Chidori.HttpStub.stub(fn %{method: :get, url: url} ->
      body =
        cond do
          url =~ "/filter?" and url =~ "offset=0" ->
            %{
              "results" => [
                %{
                  "title" => "ads.example.com",
                  "tags" => ["Pi-hole", "ブロック"],
                  "extra" => %{"blocked" => 3}
                },
                %{
                  "title" => "tv.example.net",
                  "tags" => ["Pi-hole", "ブロック"],
                  "extra" => %{"blocked" => 1}
                }
              ]
            }

          url =~ "/doc?" ->
            %{"title" => "ads.example.com", "body" => ""}

          true ->
            %{"results" => []}
        end

      Chidori.HttpStub.ok(Jason.encode!(body))
    end)

    {:ok, live, _html} = live(conn, ~p"/datasets?view=pihole")
    render_async(live)

    live |> element(~s|button.domain-name[phx-value-domain="ads.example.com"]|) |> render_click()

    html =
      live
      |> form("#domain-mark", %{
        "domain" => "ads.example.com",
        "seen" => "on",
        "seen_on" => "2026-10-06",
        "note" => "広告"
      })
      |> render_submit()

    assert html =~ "見た（2026-10-06）"
    assert Chidori.Relations.Marks.get("pihole", "ads.example.com").note == "広告"

    html = render_click(live, "filter_domains", %{"filter" => "unseen"})
    assert html =~ "tv.example.net"
    refute html =~ ~s(phx-value-domain="ads.example.com")
  end

  test "travel-log 用の書き出しを、リンクと分かる形で出す", %{conn: conn} do
    # ブラウザから Chiezo を直接読ませない代わりの道。押すと降ってくるだけなので、
    # リンクと分かる見た目のまま、周りの注記より一段強く出す
    {:ok, _live, html} = open_live(conn, ~p"/collect/apps?view=dining-1")

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
    {:ok, _live, html} = open_live(conn, ~p"/collect/datasets?view=books")

    assert html =~ "Chiezo への依頼文"
    refute html =~ "抽出の指定（辞典から機械的に引く条件）"
    refute html =~ "区画の割り方"
  end

  test "知らない種類は先頭の集めものに丸める", %{conn: conn} do
    # `?view=` は人が触れるところなので、書き換えられても画面が壊れない
    {:ok, _live, html} = open_live(conn, ~p"/collect/datasets?view=%2E%2E%2F")

    assert html =~ "定番の技術書の設定"

    {:ok, _live, html} = live(conn, ~p"/datasets?view=%2E%2E%2F")
    assert html =~ ~s(href="/collect/datasets?view=books")
  end

  test "溜まったものは、この画面には出さない", %{conn: conn} do
    # 読むのは travel-log。同じものを 2 つの画面で見せると、
    # どちらが本当の状態なのか読めなくなる
    {:ok, _live, html} = open_live(conn, ~p"/collect/apps?view=dining-1")

    refute html =~ "relation-canvas"

    # 渡す中身はどの範囲も同じなので、範囲のタブではなく「全体」のタブに 1 つだけ出す
    refute html =~ "travel-log に渡す中身"
    {:ok, _live, html} = live(conn, ~p"/collect/apps/areas")
    assert html =~ "travel-log に渡す中身"
  end

  test "アニメ聖地のタブを開ける", %{conn: conn} do
    {:ok, _live, html} = open_live(conn, ~p"/collect/apps?view=anime")

    assert html =~ "アニメ聖地"
    assert html =~ "TV アニメと劇場アニメの舞台になった土地"
  end

  test "Chiezo が未設定なら、その理由を出す", %{conn: conn} do
    {:ok, live, _html} = open_live(conn, ~p"/collect/datasets")

    assert render_async(live) =~ "CHIEZO_BASE_URL"
  end

  test "押しただけでは AI が動かないことを、押す前に読める", %{conn: conn} do
    {:ok, _live, html} = open_live(conn, ~p"/collect/datasets")

    assert html =~ "収集を依頼する"
    assert html =~ "止まった状態"
  end

  test "機械で引くところと AI が書くところの線引きが読める", %{conn: conn} do
    # どちらが入れた値かが読めないと、地図辞典の間違いを AI のせいにしてしまう
    {:ok, _live, html} = open_live(conn, ~p"/collect/apps?view=dining-1")

    assert html =~ "抽出の指定"
    assert html =~ "overture_japan"
    assert html =~ "区画の割り方"
  end

  describe "Chiezo の収集の枠" do
    @collection %{
      "name" => "chidori_dining_1",
      "description" => "Chidori のデータ収集（日本の食事処 / travel-log 向け）",
      "enabled" => true,
      "interval_minutes" => 60,
      "kind" => "stock",
      "partitions_total" => 4,
      "partitions" => [
        %{"key" => "35.6,139.7/35.7,139.8", "count" => 180, "visits" => %{}},
        %{
          "key" => "35.0,135.7/35.1,135.8",
          "count" => 120,
          "visits" => %{"情報収集" => "2026-09-20T00:00:00Z"}
        },
        %{
          "key" => "34.6,135.4/34.8,135.6",
          "count" => 150,
          "visits" => %{"情報収集" => "2026-09-01T00:00:00Z"}
        },
        %{
          "key" => "43.0,141.3/43.1,141.4",
          "count" => 90,
          "visits" => %{}
        }
      ],
      "sweeps" => [
        %{
          "name" => "機械収集",
          "interval_minutes" => 10_080,
          "use_extract" => true,
          "enabled" => true
        },
        %{
          "name" => "情報収集",
          "interval_minutes" => 720,
          "cover_days" => 14,
          "by_caller" => true,
          "enabled" => true
        }
      ]
    }

    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      test_pid = self()

      Chidori.HttpStub.stub(fn
        %{url: "http://chiezo.test:7010/v1/ai/backends"} ->
          Chidori.HttpStub.ok(~s({"backends":[{"id":"antigravity","label":"Antigravity"}]}))

        %{url: "http://chiezo.test:7010/v1/sources"} ->
          Chidori.HttpStub.ok(
            Jason.encode!(%{"sources" => [%{"name" => "chidori_dining_1", "docs" => 42}]})
          )

        # 変更履歴。**依頼した区画をちょうど見た回**が 1 つある（依頼の結果として引き当たる）
        %{method: :get, url: "http://chiezo.test:7010/v1/collect/changes?" <> _query} ->
          Chidori.HttpStub.ok(
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
          Chidori.HttpStub.ok(Jason.encode!(%{"collections" => [@collection]}))

        %{method: :patch, url: url, body: body} ->
          send(test_pid, {:patched, url, Jason.decode!(body)})
          Chidori.HttpStub.ok(~s({}))

        %{method: :post, url: url, body: body} ->
          # 区画も相手も上書きしない回は、本文が空で届く
          send(
            test_pid,
            {:posted, url, if(body in [nil, ""], do: %{}, else: Jason.decode!(body))}
          )

          Chidori.HttpStub.ok(~s({}))

        %{method: :get, url: _detail} ->
          Chidori.HttpStub.ok(Jason.encode!(@collection))
      end)

      :ok
    end

    defp shown(conn) do
      {:ok, live, _html} = open_live(conn, ~p"/collect/apps?view=dining-1")
      {live, render_async(live)}
    end

    test "巡回ごとに 1 行出て、相手を選んで送れる", %{conn: conn} do
      {_live, html} = shown(conn)

      assert html =~ "sweep-table"
      assert html =~ ~s(name="sweep|情報収集|backend")
      assert html =~ "収集の設定を更新"
    end

    test "範囲のタブには、シリーズの見た目も上書きする ZIP を出さない", %{conn: conn} do
      # 1 つの範囲で上書きすると、ほかの範囲の見た目が壊れる（上書きは「全体」のタブから）
      {_live, html} = shown(conn)

      assert html =~ "travel-log 用の ZIP を書き出す"
      refute html =~ "シリーズの見た目も上書きする ZIP"
    end

    test "情報収集が 1 回に回る区画の数を、範囲ごとに決めて送る", %{conn: conn} do
      {live, html} = shown(conn)
      assert html =~ ~s(name="survey_per_run")

      live |> element("#collect-form") |> render_submit(%{"survey_per_run" => "3"})
      render_async(live)

      assert_receive {:patched, _url, sent}, 2_000
      survey = Enum.find(sent["sweeps"], &(&1["name"] == "情報収集"))
      assert survey["partitions_per_run"] == 3
      assert Chidori.Datasets.get("dining-1").area.survey_per_run == 3
    end

    test "情報収集を今すぐ 1 回走らせられる（区画は Chiezo が選ぶ）", %{conn: conn} do
      {live, _html} = shown(conn)

      live |> element(~s|button[phx-click="run_survey_now"]|) |> render_click()

      assert_receive {:posted, url, _sent}, 2_000
      assert url =~ "/v1/collect/chidori_dining_1/run"
      assert url =~ URI.encode_query(%{"sweep" => "情報収集"})
      # 押した人の 1 回（止めている収集でも走る）
      assert url =~ "manual=true"
      assert render_async(live) =~ "情報収集を 1 回頼みました"
    end

    test "情報収集を起こす時刻を、データ収集の画面でも直せる", %{conn: conn} do
      # 設定ページの「Chiezo 収集」の表と同じ値（同じ表を読み書きする）
      {:ok, _} = Chidori.Datasets.SurveySetting.put("chidori_dining_1", %{run_at: "04:00"})
      {live, html} = shown(conn)

      assert html =~ ~s(id="survey-times-form")
      assert html =~ ~s(value="04:00")
      # 時計を外した回に間隔を出さない（勝手に動くように読める）
      assert html =~ "依頼元が起こす"

      html = live |> form("#survey-times-form", %{times: "4:20, 1620"}) |> render_submit()

      assert html =~ "起こす時刻を保存しました。"
      assert Chidori.Datasets.SurveySetting.get("chidori_dining_1").run_at == "04:20,16:20"

      html = live |> form("#survey-times-form", %{times: "25:00"}) |> render_submit()
      assert html =~ "時刻は 24 時間制で書いてください"
    end

    test "機械で引く巡回には相手を選ばせない", %{conn: conn} do
      # 選んでも何も起きない —— その回は AI を呼ばずに返す
      {_live, html} = shown(conn)

      refute html =~ ~s(name="sweep|機械収集|backend")
      assert html =~ "AI を使いません"
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
      # 情報収集が見終わった数（4 区画のうち 2 つ）
      {_live, html} = shown(conn)

      assert html =~ ~r|区画（<span[^>]*>2 / </span>4）|
      assert html =~ "「情報収集」が見終わった区画の数です"
      assert html =~ "まだ見ていないものが先に表示されます"
      refute html =~ "— まだ見ていないものが先"
    end

    test "既にある収集には、設定を送り直す", %{conn: conn} do
      # 作るときの POST は「もうある」で断られるので、それだけだと
      # Chidori 側で依頼文や区画を直しても永遠に届かない
      {live, _html} = shown(conn)

      live |> element("#collect-form") |> render_submit()
      render_async(live)

      assert_receive {:patched, url, sent}, 2_000
      assert url =~ "/v1/collect/chidori_dining_1"
      assert sent["kind"] == "stock"

      # 辞典は 3 つ。**書いた順がそのまま優先の順**なので、並びごと送る
      assert Enum.map(sent["extract"], & &1["source"]) ==
               ["jawiki", "osm_japan", "overture_japan"]

      assert length(sent["sweeps"]) == 2
    end

    test "区画を回る巡回を「どの巡回として」に出す（機械で引く回は出さない）", %{conn: conn} do
      # 機械で引く回は区画を回らないので、選べるのに効かない欄になる
      {live, _html} = shown(conn)

      html =
        live
        |> element(~s|.partition-table tbody tr:first-child button|)
        |> render_click()

      assert html =~ ~s(<option value="情報収集")
      refute html =~ ~s(<option value="機械収集")
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

    test "選んだ区画に、控えている travel-log からの依頼を出す", %{conn: conn} do
      dataset = Chidori.Datasets.get("dining-1")

      {:ok, _} =
        Chidori.Datasets.Requests.stash(
          dataset,
          "- [修正] 丸の内食堂 (35.65000,139.75000): 閉店している"
        )

      {live, _html} = shown(conn)

      html = render_click(live, "pick_partition", %{"key" => "35.6,139.7/35.7,139.8"})
      assert html =~ "travel-log からの依頼（控えている 1 件）"
      assert html =~ "丸の内食堂"

      # 依頼の無い区画は、無いと言う
      html = render_click(live, "pick_partition", %{"key" => "43.0,141.3/43.1,141.4"})
      assert html =~ "この区画に控えている依頼はありません"
    end

    test "空いている欄のある店を、頼む数だけ名指しして埋めてもらう（区画は渡さない）", %{conn: conn} do
      test_pid = self()

      shops = [
        %{
          "title" => "駅前うどん",
          "tags" => ["食事処", "ジャンル:麺類", "地域:東京都", "ランク:C", "特徴:ランチ営業"],
          "opening" => "所在地: 東京都千代田区\n駅前のうどん屋。",
          "extra" => %{
            "lat" => 35.65,
            "lon" => 139.75,
            "opening_hours" => "Mo-Fr 11:00-15:00",
            "url" => "https://example.com/udon"
          }
        },
        %{
          "title" => "そば屋",
          # 特徴だけ埋まっている（選んだ欄の空きが少ないので後回しになる）
          "tags" => ["食事処", "地域:東京都", "特徴:ランチ営業"],
          "opening" => "所在地: 東京都千代田区",
          "extra" => %{"lat" => 35.66, "lon" => 139.76}
        },
        %{
          "title" => "遠くの店",
          "tags" => ["食事処"],
          "opening" => "",
          "extra" => %{"lat" => 43.05, "lon" => 141.35}
        }
      ]

      Chidori.HttpStub.stub(fn
        %{method: :get, url: "http://chiezo.test:7010/v1/chidori_dining_1/filter?" <> _query} ->
          Chidori.HttpStub.ok(Jason.encode!(%{"total" => 3, "results" => shops}))

        %{url: "http://chiezo.test:7010/v1/ai/backends"} ->
          Chidori.HttpStub.ok(~s({"backends":[{"id":"antigravity","label":"Antigravity"}]}))

        %{method: :get, url: "http://chiezo.test:7010/v1/collect"} ->
          Chidori.HttpStub.ok(Jason.encode!(%{"collections" => [@collection]}))

        %{method: :post, url: url, body: body} ->
          send(test_pid, {:posted, url, Jason.decode!(body)})
          Chidori.HttpStub.ok(~s({}))

        %{method: :get, url: url} ->
          if String.contains?(url, "/v1/collect/chidori_dining_1"),
            do: Chidori.HttpStub.ok(Jason.encode!(@collection)),
            else: Chidori.HttpStub.ok(~s({"backends":[],"sources":[],"changes":[]}))
      end)

      {live, html} = shown(conn)

      assert html =~ "AI が目を通した 3 店のうち、空いている欄のある店は 2 店です"
      assert html =~ "営業時間 2 店"
      # 「空いている欄を埋める」は既定で畳む
      assert html =~
               ~r|<details class="settings-block blank-report"[^>]*>\s*<summary><h3>空いている欄を埋める</h3>|

      # 区画の一覧に、その区画の空いている欄のある店の数（どれか 1 つでも空いている店）
      assert html =~ ~r|<td>35.6,139.7/35.7,139.8</td>\s*<td>\d+</td>\s*<td>\s*1\s*</td>|

      live
      |> form("#fill-blanks-form", %{
        "fields" => ["opening_hours", "feature"],
        "count" => "1",
        "fill|backend" => "antigravity"
      })
      |> render_submit()

      assert render_async(live) =~ "1 店の空欄を埋める 1 回を頼みました"

      assert_receive {:posted, url, sent}, 2_000
      assert url =~ "/v1/collect/chidori_dining_1/focus"

      # 区画に縛らない（範囲のどこの店でもよい）。空いている欄の多いほうが先
      assert sent["titles"] == ["遠くの店"]
      assert sent["sweep"] == "情報収集"
      # 区画を渡すと情報収集の印が付き、見直しが一周先へ回る
      refute Map.has_key?(sent, "partition")
      assert sent["prompt"] =~ "- 遠くの店: 営業時間・特徴\n"
      # 選んだ相手はその回だけ（巡回の設定は送り直さない）
      assert sent["backend"] == "antigravity"
    end

    test "区画は地図にもなる", %{conn: conn} do
      # 「8,185 区画のうち 2 つ見終わり」と数で言われても、どこなのかは読めない
      {_live, html} = shown(conn)

      assert html =~ "partition-map"
      # 見終わった区画は色を変える（進み具合は数では読めない）
      assert html =~ "is-done"
      assert html =~ ~s(phx-value-key="35.6,139.7/35.7,139.8")
    end

    test "色は、情報収集が見たかで決まる", %{conn: conn} do
      # 区画を回る巡回は情報収集の 1 本なので、見た区画は薄い緑
      {_live, html} = shown(conn)

      assert html =~ ~r|<rect[^>]*is-done[^>]*phx-value-key="35.0,135.7/35.1,135.8"|
      assert html =~ ~r|<rect[^>]*is-done[^>]*phx-value-key="34.6,135.4/34.8,135.6"|
      refute html =~ ~r|<rect[^>]*is-done[^>]*phx-value-key="43.0,141.3/43.1,141.4"|
      assert html =~ "薄い緑が「情報収集」まで見終わった区画"
      assert html =~ "情報収集 済み"
    end

    test "まだ焼いていない固定があれば、画面を移ってきても「AI を使わずにいま反映する」が出る", %{
      conn: conn
    } do
      # 範囲の画面で依頼を配ったときなど、固定した直後の画面でなくても押せるように
      collection = Map.put(@collection, "locks_pending", 1)

      Chidori.HttpStub.stub(fn %{url: url} ->
        cond do
          String.ends_with?(url, "/v1/collect") ->
            Chidori.HttpStub.ok(Jason.encode!(%{"collections" => [collection]}))

          String.contains?(url, "/v1/collect/") ->
            Chidori.HttpStub.ok(Jason.encode!(collection))

          true ->
            Chidori.HttpStub.ok(~s({"backends":[],"sources":[],"changes":[]}))
        end
      end)

      {_live, html} = shown(conn)
      assert html =~ "AI を使わずにいま反映する"
      assert html =~ "まだ反映していない固定が 1 件あります"
    end

    test "固定がみな焼けていれば出さない（固定の記録は反映後も残る）", %{conn: conn} do
      collection =
        @collection
        |> Map.put("locks", %{"駅前うどん" => %{"lat" => 35.65, "lon" => 139.75}})
        |> Map.put("locks_pending", 0)

      Chidori.HttpStub.stub(fn %{url: url} ->
        cond do
          String.ends_with?(url, "/v1/collect") ->
            Chidori.HttpStub.ok(Jason.encode!(%{"collections" => [collection]}))

          String.contains?(url, "/v1/collect/") ->
            Chidori.HttpStub.ok(Jason.encode!(collection))

          true ->
            Chidori.HttpStub.ok(~s({"backends":[],"sources":[],"changes":[]}))
        end
      end)

      {_live, html} = shown(conn)
      refute html =~ "AI を使わずにいま反映する"
    end

    test "依頼を頼む相手は、選んだ相手とモデルをその 1 回だけ渡す" do
      backends = [
        %{id: "claude", label: "Claude", kind: "plain", models: ["opus", "sonnet"]},
        %{id: "w-1", label: "整理用ワーカー", kind: "worker", models: []}
      ]

      assigns = &%{request_backend: &1, request_model: &2, backends: backends}

      assert DatasetsLive.request_options(assigns.(nil, nil)) == []

      assert DatasetsLive.request_options(assigns.("claude", "opus")) ==
               [backend: "claude", model: "opus"]

      # ワーカーはモデルを持たない（渡す先はそのときの枠で決まる）
      assert DatasetsLive.request_options(assigns.("w-1", "opus")) == [worker: "w-1"]
    end

    test "地図の上で地名を探すと、その場所へ寄って印を立てる", %{conn: conn} do
      collection = @collection

      Chidori.HttpStub.stub(fn %{url: url} ->
        cond do
          String.contains?(url, "/v1/osm_japan/search?") ->
            Chidori.HttpStub.ok(Jason.encode!(%{"results" => [%{"title" => "札幌駅 (node:1)"}]}))

          String.contains?(url, "/v1/osm_japan/doc?") ->
            Chidori.HttpStub.ok(
              Jason.encode!(%{
                "title" => "札幌駅 (node:1)",
                "extra" => %{"lat" => 43.05, "lon" => 141.35, "area" => "北海道"}
              })
            )

          String.ends_with?(url, "/v1/collect") ->
            Chidori.HttpStub.ok(Jason.encode!(%{"collections" => [collection]}))

          String.contains?(url, "/v1/collect/") ->
            Chidori.HttpStub.ok(Jason.encode!(collection))

          true ->
            Chidori.HttpStub.ok(~s({"backends":[],"sources":[],"changes":[]}))
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
        "sweep" => "情報収集",
        "run|backend" => "antigravity"
      })
      |> render_submit()

      assert_receive {:posted, url, sent}, 2_000
      assert url =~ "/run"
      assert url =~ URI.encode_query(%{"sweep" => "情報収集"})
      assert sent["partitions"] == ["43.0,141.3/43.1,141.4"]
      assert sent["backend"] == "antigravity"
    end

    # 裏の処理から届く知らせで画面が変わるのを待つ（render_async は async の処理しか待たない）
    defp wait_for(live, text, tries \\ 40) do
      html = render_async(live, 2_000)

      cond do
        html =~ text -> html
        tries == 0 -> html
        true -> Process.sleep(50) && wait_for(live, text, tries - 1)
      end
    end

    test "控えている travel-log からの依頼を、区画ごとに頼める", %{conn: conn} do
      # 貼るのは「全体」のタブ（範囲ごとに配る）。ここでは配られた控えを区画ごとに頼む
      text = """
      # 修正・追加の依頼(日本の食事処) 3件

      - [修正] 駅前うどん (35.65000,139.75000): 閉店している
      - [追加] (35.68000,139.76000): そば屋がある
      - [追加] (26.20000,127.68000): 区画の外
      """

      {:ok, _} = Chidori.Datasets.Requests.stash(Chidori.Datasets.get("dining-1"), text)
      {live, html} = shown(conn)

      # **控えただけでは頼まない**（1 件しか無い区画にも回が走ると枠を使い潰す）
      refute_receive {:posted, _url, _sent}, 300
      assert html =~ "控えている依頼（3 件）"

      # 区画ごとに件数の多い順。区画の外は最後に「どの区画にも入らない」として
      assert html =~ "35.6,139.7/35.7,139.8"
      assert html =~ "どの区画にも入らない"

      # **区画を選んで頼む。** ふつうの回として走らせ、その区画の控えだけを補足に載せる
      live
      |> element(~s|button[phx-click="send_pending"][phx-value-key="35.6,139.7/35.7,139.8"]|)
      |> render_click()

      assert_receive {:posted, url, sent}, 2_000
      assert url =~ "/v1/collect/chidori_dining_1/run"
      assert url =~ URI.encode_query(%{"sweep" => "情報収集"})
      assert sent["partitions"] == ["35.6,139.7/35.7,139.8"]
      note = sent["notes"]["35.6,139.7/35.7,139.8"]
      assert note =~ "閉店している"
      assert note =~ "そば屋がある"
      refute note =~ "区画の外"

      # 頼み終えた知らせ（裏の処理から届く）を待ってから読む
      html = wait_for(live, "区画 1 つで情報収集を頼みました")

      # 頼んだ区画の控えは消え、区画の外の 1 件だけが残る
      assert html =~ "控えている依頼（1 件）"

      # **依頼と、その結果を並べる**（頼んだ区画をちょうど見た回を引き当てる）
      assert [log] = Chidori.Datasets.Requests.recent("chidori_dining_1")
      assert log.keys == ["35.6,139.7/35.7,139.8"]
      assert log.status == "sent"
      assert html =~ "依頼の結果"
      assert html =~ "足した 25 ・直した 1 ・消した 1"
      assert html =~ "/admin/collect/chidori_dining_1/doc?title="

      # 控えは頼まずに捨てられる
      html =
        live
        |> element(~s|button[phx-click="drop_pending"][phx-value-key=""]|)
        |> render_click()

      refute html =~ "控えている依頼（"
    end

    # 押した後に区画が割り直された状態にする（範囲を広げて保存した直後の回のあと）。
    # 区画を読む口だけ差し替え、ほかはそのまま
    defp resplit(partitions) do
      previous = Application.get_env(:chidori, :http_stub_responder)

      moved = %{
        @collection
        | "partitions" => partitions,
          "partitions_total" => length(partitions)
      }

      Chidori.HttpStub.stub(fn
        %{method: :get, url: "http://chiezo.test:7010/v1/collect"} ->
          Chidori.HttpStub.ok(Jason.encode!(%{"collections" => [moved]}))

        %{method: :get, url: "http://chiezo.test:7010/v1/collect/chidori_dining_1" <> _rest} ->
          Chidori.HttpStub.ok(Jason.encode!(moved))

        request ->
          previous.(request)
      end)
    end

    defp stash_two do
      text = """
      - [修正] 駅前うどん (35.62000,139.75000): 閉店している
      - [追加] (35.68000,139.76000): そば屋がある
      """

      {:ok, _} = Chidori.Datasets.Requests.stash(Chidori.Datasets.get("dining-1"), text)
    end

    test "押した後に区画が割り直されていたら、新しい区画で頼み直す", %{conn: conn} do
      stash_two()
      {live, _html} = shown(conn)

      # 画面にはまだ前の区画が出ている。押す前に Chiezo で割り直された
      south = "35.6,139.7/35.65,139.8"
      north = "35.65,139.7/35.7,139.8"

      resplit([
        %{"key" => south, "count" => 90, "visits" => %{}},
        %{"key" => north, "count" => 90, "visits" => %{}}
      ])

      live
      |> element(~s|button[phx-click="send_pending"][phx-value-key="35.6,139.7/35.7,139.8"]|)
      |> render_click()

      # **台帳に無くなった鍵では頼まない。** 補足も新しい区画ごとに分ける
      assert_receive {:posted, _url, sent}, 2_000
      assert sent["partitions"] == [south, north]
      assert sent["notes"][south] =~ "閉店している"
      refute sent["notes"][south] =~ "そば屋がある"
      assert sent["notes"][north] =~ "そば屋がある"

      html = wait_for(live, "区画 2 つで情報収集を頼みました")
      assert html =~ "区画 2 つで情報収集を頼みました"
      refute html =~ "控えている依頼（"

      # 依頼の結果は区画の鍵で引き当てるので、記録も頼んだ鍵になっている
      assert [log] = Chidori.Datasets.Requests.recent("chidori_dining_1")
      assert log.keys == [south, north]
      assert log.status == "sent"
    end

    test "割り直した区画のどれにも入らなければ、頼まずに控えを残す", %{conn: conn} do
      stash_two()
      {live, _html} = shown(conn)

      resplit([%{"key" => "43.0,141.3/43.1,141.4", "count" => 90, "visits" => %{}}])

      live
      |> element(~s|button[phx-click="send_pending"][phx-value-key="35.6,139.7/35.7,139.8"]|)
      |> render_click()

      refute_receive {:posted, _url, _sent}, 300
      html = wait_for(live, "控えは残してあります")
      assert html =~ "控えは残してあります"
      assert Chidori.Datasets.Requests.pending_count(%{collection: "chidori_dining_1"}) == 2
      assert [%{status: "failed"}] = Chidori.Datasets.Requests.recent("chidori_dining_1")
    end

    test "最近の回は、自動で回った回も並べ、依頼で走った回には印を付ける", %{conn: conn} do
      # 依頼の結果は依頼ごとに回を引き当てるので、自動の回は出てこなかった
      {:ok, _log} =
        %Chidori.Datasets.RequestLog{}
        |> Chidori.Datasets.RequestLog.changeset(%{
          collection: "chidori_dining_1",
          keys: ["35.6,139.7/35.7,139.8"],
          text: "- [修正] 駅前うどん (35.65,139.75): 閉店している",
          points: 1,
          missed: 0,
          requested_at: ~U[2098-12-31 00:00:00Z],
          status: "sent"
        })
        |> Chidori.Repo.insert()

      {_live, html} = shown(conn)

      assert html =~ ~s(aria-label="最近の回")
      # 依頼で走った回（頼んだ区画をちょうど見た回）
      assert html =~ "足した 25 ・直した 1 ・消した 1"
      assert html =~ ~s(class="run-by-request")
      # 自動の回（Chiezo が選んだ別の区画）も出る
      assert html =~ "足した 9 ・直した 0 ・消した 0"
      assert html =~ "情報収集・区画 1 つ"
    end

    test "範囲ごとの画面には、依頼を貼る欄を出さない（全体のタブで貼る）", %{conn: conn} do
      # travel-log の食事処は範囲で分かれていないので、別の範囲の店が混ざったテキストを
      # ここに貼ると事故る
      {live, html} = shown(conn)

      refute html =~ ~s(phx-submit="travel_log_request")
      assert html =~ "「全体」のタブで貼ってください"

      # 古い画面から送られても受けない
      render_submit(live, "travel_log_request", %{"text" => "- [追加] (35.68000,139.76000): 店"})
      assert Chidori.Datasets.Requests.pending_count(Chidori.Datasets.get("dining-1")) == 0
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
      "name" => "chidori_books",
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

      Chidori.HttpStub.stub(fn
        %{url: "http://chiezo.test:7010/v1/ai/backends"} ->
          Chidori.HttpStub.ok(~s({"backends":[{"id":"antigravity","label":"Antigravity"}]}))

        %{method: :get, url: "http://chiezo.test:7010/v1/collect"} ->
          Chidori.HttpStub.ok(Jason.encode!(%{"collections" => [@shelf]}))

        %{method: :get, url: "http://chiezo.test:7010/v1/collect/chidori_books" <> _rest} ->
          Chidori.HttpStub.ok(Jason.encode!(@shelf))

        %{method: :get, url: "http://chiezo.test:7010/v1/chidori_book_posts/filter?" <> _query} ->
          Chidori.HttpStub.ok(
            Jason.encode!(%{
              "results" => [
                %{
                  "title" => "おすすめの本 10 冊",
                  "extra" => %{"url" => "https://example.com/a", "published_at" => "2026-01-07"}
                }
              ]
            })
          )

        %{method: :get, url: "http://chiezo.test:7010/v1/chidori_books/filter?" <> _query} ->
          Chidori.HttpStub.ok(
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
          Chidori.HttpStub.ok(~s({}))

        %{method: :post, url: url, body: body} ->
          send(test_pid, {:posted, url, Jason.decode!(body)})
          Chidori.HttpStub.ok(~s({}))

        %{method: :get, url: _other} ->
          Chidori.HttpStub.ok(~s({"collections":[],"sources":[],"changes":[]}))
      end)

      :ok
    end

    test "本棚の本を、表紙つきでおすすめ度の高い順に並べる", %{conn: conn} do
      {:ok, live, _html} = open_read(conn, ~p"/datasets?view=books")
      html = render_async(live)

      [_, shelf] = String.split(html, ~s(class="bookshelf"), parts: 2)

      # 表紙はまだ取りに行っていないので空の枠（取りに行く列に並ぶ。「表紙なし」は取れなかった本だけ）。
      # 外の絵を直に指さない
      assert shelf =~ "book-cover is-empty"
      refute shelf =~ "hanmoto.com/bd/img"
      assert shelf =~ "記事 5 本が勧めている"
      refute shelf =~ ~s(class="book-badge">定番<)

      # 順は本棚の一覧で見る
      [_, list] = String.split(shelf, ~s(class="book-list"), parts: 2)
      {first, _} = :binary.match(list, "リーダブルコード")
      {second, _} = :binary.match(list, "入門 監視")
      assert first < second

      # リーダブルコードはオライリーの本。上位の枠にも同じ並びで出て、印で見分ける
      [top, _] = String.split(shelf, ~s(class="book-list"), parts: 2)
      assert top =~ ~r|リーダブルコード\s*</a>.*?book-badge is-oreilly|s
      # 数を持たない本（見出しを書き換えて足されたもの）は並べない
      refute shelf =~ ~s(phx-value-title="リーダブルコード")

      # 読む画面には収集の設定を出さない（収集の画面で直す）
      refute html =~ "収集の設定を更新"
      refute html =~ "Chiezo への依頼文"
    end

    test "興味トピックに近い本を強調し、絞り込める", %{conn: conn} do
      Chidori.News.Interests.toggle("chidori_tech", "設計・アーキテクチャ")
      Chidori.News.Interests.toggle("chidori_tech", "監視")

      {:ok, live, _html} = open_read(conn, ~p"/datasets?view=books")
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
      {:ok, live, _html} = open_read(conn, ~p"/datasets?view=books")
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
      {:ok, live, _html} = open_read(conn, ~p"/datasets?view=books")
      render_async(live)

      live
      |> element(~s(button.book-name[phx-value-title="本:リーダブルコード"]))
      |> render_click()

      live
      |> element("#book-ask")
      |> render_submit(%{"title" => "本:リーダブルコード", "note" => "表紙が違う"})

      assert render_async(live) =~ "Chiezo に頼みました"

      # 本棚を開くと表紙の取り寄せ（`POST /v1/covers`）も同じ口へ届くので、割り込みだけを待つ
      {url, body} = receive_post("/focus")
      assert url =~ "/v1/collect/chidori_books/focus"
      assert body["titles"] == ["本:リーダブルコード"]
      assert body["sweep"] == "整理"
      assert body["note"] =~ "リーダブルコードについて"
      assert body["note"] =~ "補足: 表紙が違う"
      # 調べ終えた本でも並ぶように、名指しした 1 冊を {current} で見せる
      assert body["prompt"] =~ "{current}"
      refute body["prompt"] =~ "{unreviewed}"
    end

    test "読んだ印を付けると、本棚で分かり、未読の上位の枠から外れる", %{conn: conn} do
      {:ok, live, html} = open_read(conn, ~p"/datasets?view=books")
      html = render_async(live) || html

      assert html =~ "未読の上位"
      refute html =~ "オライリー以外の未読の上位"
      assert html =~ ~r|<ol[^>]*class="top-books">.*本:リーダブルコード|s

      live
      |> element(~s(button.book-name[phx-value-title="本:リーダブルコード"]))
      |> render_click()

      html =
        live
        |> element("#book-mark")
        |> render_submit(%{
          "title" => "本:リーダブルコード",
          "read" => "on",
          "read_on" => "2026-10-01",
          "note" => "命名の章が役に立った"
        })

      assert html =~ "保存しました。"
      assert Chidori.Datasets.BookMarks.get("本:リーダブルコード").read

      # 本棚の一覧には残し、読んだことが分かる印を付ける
      assert html =~ ~s(class="book-card is-read")
      assert html =~ "読んだ（2026-10-01）"
      # 未読の上位の枠からは外れる
      for [top] <- Regex.scan(~r|<ol[^>]*class="top-books">.*?</ol>|s, html) do
        refute top =~ "本:リーダブルコード"
      end
    end

    test "印もメモも空にして保存すると、記録ごと消える", %{conn: conn} do
      {:ok, _mark} = Chidori.Datasets.BookMarks.put("本:リーダブルコード", %{"read" => true})
      {:ok, live, _html} = open_read(conn, ~p"/datasets?view=books")
      render_async(live)

      live
      |> element(~s(button.book-name[phx-value-title="本:リーダブルコード"]))
      |> render_click()

      live
      |> element("#book-mark")
      # チェックを外す（外したチェックボックスは値を送らない。ここでは空で上書きする）
      |> render_submit(%{"title" => "本:リーダブルコード", "read" => "", "read_on" => "", "note" => ""})

      refute Chidori.Datasets.BookMarks.get("本:リーダブルコード")
    end

    test "「いま頼む」の欄は出さず、依頼文は収集ごとの節に出す", %{conn: conn} do
      {:ok, live, _html} = open_live(conn, ~p"/collect/datasets?view=books")
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
      {:ok, live, _html} = open_live(conn, ~p"/collect/datasets?view=books")
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
      assert url =~ "/v1/collect/chidori_books"
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
end
