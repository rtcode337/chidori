defmodule ChidoriWeb.SettingsLiveTest do
  @moduledoc """
  設定ページの「Chiezo 収集」。ここでは**巡回の間隔を画面から変えられること**を見ます。
  """

  use ChidoriWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Chidori.CollectPace
  alias Chidori.HttpStub

  setup do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test")

    on_exit(fn ->
      System.delete_env("CHIEZO_BASE_URL")
      for kind <- CollectPace.kinds(), do: :persistent_term.erase({CollectPace, kind})
      :persistent_term.erase({CollectPace, :tidy_stops})
    end)

    parent = self()

    HttpStub.stub(fn
      %{method: :get, url: url} ->
        if String.ends_with?(url, "/v1/collect"),
          do:
            HttpStub.ok(
              Jason.encode!(%{
                "collections" => [
                  %{
                    "name" => "chidori_tech",
                    "sweeps" => [%{"name" => "整理", "interval_minutes" => 720}]
                  },
                  # Chidori の画面に無い収集（Chiezo にだけ残っている）
                  %{
                    "name" => "chidori_old",
                    "requested_by" => "chidori",
                    "sweeps" => [%{"name" => "整理", "interval_minutes" => 720}]
                  }
                ]
              })
            ),
          else:
            HttpStub.ok(
              ~s({"workers":[],"backends":[{"id":"codex","label":"Codex","models":["gpt-5"]}]})
            )

      %{method: :post, url: url, body: body} ->
        send(parent, {:posted, URI.decode(url), Jason.decode!(body)})
        HttpStub.ok("{}")

      %{method: :patch, url: url, body: body} ->
        send(parent, {:patched, URI.decode(url), Jason.decode!(body)})
        HttpStub.ok("{}")
    end)

    :ok
  end

  test "Chiezo の設定が Chidori の定義と違う収集に、違う項目を出す", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/collect")
    html = render_async(live)

    # Chiezo の技術ニュースには整理の回しか無い（Chidori の定義には見出しの回もある）
    [_, tech] = String.split(html, "chidori_tech</span>", parts: 2)
    [tech, _] = String.split(tech, "</tbody>", parts: 2)
    assert tech =~ "Chidori の定義と違います"
    assert tech =~ "が Chiezo にありません"
  end

  test "いまの間隔が選ばれて出る", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/collect")

    assert html =~ "巡回の間隔"
    assert html =~ ~r/<option[^>]*value="720"[^>]*selected/
  end

  test "保存すると、その間隔を Chiezo に送る", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/collect")

    live
    |> form("#collect-pace", pace: %{tidy: "1440", scan: "120"})
    |> render_submit()

    assert CollectPace.minutes(:tidy) == 1440
    assert_receive {:patched, "http://chiezo.test/v1/collect/chidori_tech/sweeps/整理", body}
    assert body["interval_minutes"] == 1440
    assert render_async(live) =~ "本の巡回に送りました"
  end

  test "開くと写真と表紙のタブが先頭で選ばれている（トップページは廃止した）", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/settings")

    [_before, tabs | _rest] = String.split(html, ~s(aria-label="設定"))
    [tabs | _rest] = String.split(tabs, "</nav>")
    assert :binary.match(tabs, "写真と表紙") < :binary.match(tabs, "通知")

    # Chiezo 収集の表は収集の画面（/collect）へ、トップページ（閲覧）は廃止。設定のタブには置かない
    refute tabs =~ "Chiezo 収集"
    refute tabs =~ "トップページ"
    assert html =~ ~r/class="selected"[^>]*>\s*写真と表紙/
  end

  test "前の「Chiezo 収集」のタブを開くと、収集の画面へ送る", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/collect"}}} = live(conn, ~p"/settings?tab=chiezo")
  end

  test "収集の画面は収集の表だけを出し、設定のタブは出さない", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/collect")

    assert html =~ "巡回の間隔"
    refute html =~ ~s(aria-label="設定")
    assert html =~ ~r|class="active" href="/collect"|
  end

  test "収集は Chidori の画面の並びで、Chiezo にまだ無いものも並ぶ", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/collect")
    html = render_async(live)

    [tech, tech_topics, painters, old] =
      Enum.map(
        [
          "send-chidori_tech\"",
          "send-chidori_tech_topics\"",
          "send-chidori_painters\"",
          "send-chidori_old\""
        ],
        fn id ->
          html |> :binary.match(id) |> elem(0)
        end
      )

    # 同じ画面の収集（技術ニュースとそのトピック）のあいだに、別の画面のものが挟まらない
    assert tech < tech_topics and tech_topics < painters
    # 画面に無い収集は後ろ
    assert painters < old
    assert html =~ "Chiezo にまだありません"
    assert html =~ "Chidori の画面に無い収集です"
  end

  test "画面の収集は、その画面と同じ設定を丸ごと送る（選んだ相手と整理の止め方を載せる）", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/collect")
    html = render_async(live)

    # 整理は押しボタンではなくチェックボックス
    assert html =~ ~r/<input[^>]*type="checkbox"[^>]*name="tidy"/
    assert html =~ ~s(<option value="codex")

    live
    |> element("#send-chidori_tech")
    |> render_submit(%{
      "collection" => "chidori_tech",
      "sweep|整理|backend" => "codex",
      "sweep|整理|model" => "gpt-5",
      "tidy" => "true"
    })

    html = render_async(live)

    assert_received {:patched, "http://chiezo.test/v1/collect/chidori_tech", body}
    # 依頼文を含む Chidori の今の定義が届く
    assert is_binary(body["prompt"])
    tidy = Enum.find(body["sweeps"], &(&1["name"] == "整理"))
    assert {tidy["backend"], tidy["model"], tidy["by_caller"]} == {"codex", "gpt-5", true}
    assert CollectPace.tidy_stopped?("chidori_tech")
    assert html =~ "送りました（"
  end

  test "画面に無い収集は、選び直した相手だけを送る", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/collect")
    render_async(live)

    live
    |> element("#send-chidori_old")
    |> render_submit(%{
      "collection" => "chidori_old",
      "sweep|整理|backend" => "codex",
      "tidy" => "false"
    })

    assert render_async(live) =~ "送りました（整理の相手）"

    assert_received {:patched, "http://chiezo.test/v1/collect/chidori_old/sweeps/整理",
                     %{"backend" => "codex"}}
  end

  test "最後に取得した時刻を出し、「最新の情報を取得」で読み直す", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/collect")
    html = render_async(live)

    assert html =~ "最後に取得:"
    assert html =~ "（たった今）"

    live |> element("button", "最新の情報を取得") |> render_click()
    assert render_async(live) =~ "最新の情報を取得"
  end

  test "通知タブで、全部の通知に共通の宛先を書く", %{conn: conn} do
    # 話題ごとに書いていた頃は、同じトピックを画面ごとに書き写していた
    Chidori.Notify.Settings.put("chidori_tech", %{"notify" => "true"})
    {:ok, live, html} = live(conn, ~p"/settings?tab=notify")

    assert html =~ ~s(name="ntfy[topic]")
    assert html =~ ~s(name="ntfy[base_url]")

    # 知らせるかどうかは話題ごと。いまどうなっているかはチェックで並べる
    assert html =~ ~r|<input type="checkbox" checked[^>]*phx-value-collection="chidori_tech"|

    live
    |> form("#ntfy-form",
      ntfy: %{enabled: "true", topic: " shared-topic ", base_url: "http://ntfy.test/"}
    )
    |> render_submit()

    assert Chidori.Ntfy.topic() == "shared-topic"
    assert Chidori.Ntfy.base_url() == "http://ntfy.test"
    assert Chidori.Ntfy.ready("chidori_tech") == {:ok, {"http://ntfy.test", "shared-topic"}}

    # 「ntfy に送る」を外すと、トピック名を残して止まる
    live |> form("#ntfy-form", ntfy: %{enabled: "false"}) |> render_submit()
    assert Chidori.Ntfy.topic() == "shared-topic"
    refute Chidori.Ntfy.enabled?()

    html =
      live
      |> form("#ntfy-form", ntfy: %{base_url: "ntfy.test"})
      |> render_submit()

    assert html =~ "http:// か https:// で書いてください"
    # 書いたものは消さない
    assert html =~ ~s(value="ntfy.test")
  end

  test "通知タブで、話題ごとに知らせるかをその場で切り替える", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/settings?tab=notify")
    refute Chidori.Notify.Settings.get("chidori_tech").notify

    html =
      live
      |> element(~s(#notify-topics input[phx-value-collection="chidori_tech"]))
      |> render_click()

    assert Chidori.Notify.Settings.get("chidori_tech").notify
    assert html =~ "知らせるようにしました"

    live
    |> element(~s(#notify-topics input[phx-value-collection="chidori_tech"]))
    |> render_click()

    refute Chidori.Notify.Settings.get("chidori_tech").notify
  end

  describe "この端末に通知を送る（Web Push）" do
    defp device_subscription(endpoint) do
      {ua_public, _ua_private} = :crypto.generate_key(:ecdh, :prime256v1)

      %{
        "endpoint" => endpoint,
        "keys" => %{
          "p256dh" => Chidori.WebPush.b64(ua_public),
          "auth" => Chidori.WebPush.b64(:crypto.strong_rand_bytes(16))
        }
      }
    end

    test "送り手の公開鍵を端末へ渡し、端末を登録・確認・解除できる", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/settings?tab=notify")

      assert html =~ "この端末に通知を送る"
      assert html =~ ~s(phx-hook="WebPush")
      assert html =~ ~s(data-key="#{Chidori.WebPush.public_key()}")
      assert html =~ "登録してある端末はありません"

      html =
        live
        |> element("#web-push")
        |> render_hook("push_subscribe", %{
          "subscription" => device_subscription("https://fcm.googleapis.com/send/a"),
          "user_agent" =>
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        })

      assert html =~ "この端末（iPhone）を登録しました"
      # 登録した日時は日本時間で出す
      assert html =~ ~s(id="push-devices")
      assert html =~ "JST に登録"
      assert html =~ "テスト通知を送る"

      live
      |> element("#web-push")
      |> render_hook("push_unsubscribe", %{"endpoint" => "https://fcm.googleapis.com/send/a"})

      assert Chidori.WebPush.Subscriptions.list() == []
    end

    test "鍵の形が違う登録は断って、理由を出す", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/settings?tab=notify")

      html =
        live
        |> element("#web-push")
        |> render_hook("push_subscribe", %{
          "subscription" => %{"endpoint" => "https://fcm.googleapis.com/x", "keys" => %{}},
          "user_agent" => ""
        })

      assert html =~ "この端末を登録できませんでした"
      assert Chidori.WebPush.Subscriptions.list() == []
    end

    test "一覧から外せて、テスト通知の結果を出す", %{conn: conn} do
      {:ok, alive} =
        Chidori.WebPush.Subscriptions.subscribe(
          device_subscription("https://fcm.googleapis.com/send/alive"),
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/140.0 Safari/537.36"
        )

      {:ok, _gone} =
        Chidori.WebPush.Subscriptions.subscribe(
          device_subscription("https://fcm.googleapis.com/send/gone"),
          ""
        )

      {:ok, removed} =
        Chidori.WebPush.Subscriptions.subscribe(
          device_subscription("https://fcm.googleapis.com/send/removed"),
          ""
        )

      HttpStub.stub(fn %{url: url} ->
        if url =~ "gone",
          do: {:ok, %{status: 410, body: ""}},
          else: {:ok, %{status: 201, body: ""}}
      end)

      {:ok, live, html} = live(conn, ~p"/settings?tab=notify")
      assert html =~ "Mac Chrome"

      live |> element(~s(#push-devices button[phx-value-id="#{removed.id}"])) |> render_click()
      refute Enum.any?(Chidori.WebPush.Subscriptions.list(), &(&1.id == removed.id))

      live |> element("#test-push") |> render_click()
      html = render_async(live)

      assert html =~ "1 台に送りました"
      assert html =~ "受け取れなくなっていた 1 台の登録を外しました"
      assert [%{id: id}] = Chidori.WebPush.Subscriptions.list()
      assert id == alive.id
    end
  end

  test "chidori が起こす回は、表の中で時刻を直せる", %{conn: conn} do
    # 要約の回は Chiezo 側に時計が無く、時刻を持つのは Chidori（各話題の画面と同じ値）
    Chidori.Notify.Settings.put("chidori_news", %{"digest_at" => "07:00"})

    HttpStub.stub(fn
      %{method: :get, url: url} ->
        if String.ends_with?(url, "/v1/collect"),
          do:
            HttpStub.ok(
              Jason.encode!(%{
                "collections" => [
                  %{
                    "name" => "chidori_news",
                    "sweeps" => [%{"name" => "要約", "on_demand" => true}]
                  }
                ]
              })
            ),
          else: HttpStub.ok(~s({"workers":[],"backends":[]}))
    end)

    {:ok, live, _html} = live(conn, ~p"/collect")
    html = render_async(live)

    assert html =~ "Chidori が起こす（07:00）"
    assert html =~ ~s(value="07:00")

    live
    |> form(~s|.wake-form:has(input[value="digest"])|, times: "6, 19")
    |> render_submit()

    assert Chidori.Notify.Settings.get("chidori_news").digest_at == "06:00,19:00"
    assert render_async(live) =~ "起こす時刻を保存しました。"

    # 映画の図の行では、最新情報からの引き継ぎの時刻と 1 回の数を決める
    live
    |> form(~s|.wake-form:has(input[value="carry"])|, times: "4", batch: "30")
    |> render_submit()

    setting = Chidori.Relations.CarrySetting.get()
    assert {setting.run_at, setting.batch} == {"04:00", 30}
  end

  test "巡回の間隔はざっと見るが先で、それぞれ何本あって何本動いているかを出す", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/collect")
    html = render_async(live)

    pace = html |> String.split(~s(id="collect-pace")) |> List.last()
    {scan, tidy} = {:binary.match(pace, "ざっと見る"), :binary.match(pace, "整理")}
    assert elem(scan, 0) < elem(tidy, 0)

    # ざっと見るは関連図の 3 本（画家・芸能人・映画）とレシピ集の書く回、ご当地グルメ
    assert pace =~ "Chidori に 5 本・動いている"
  end

  test "Chiezo から戻した結果は、変えたものだけを並べる" do
    alias ChidoriWeb.SettingsLive

    assert SettingsLive.restore_text(
             {:ok,
              %{
                paces: [{:tidy, 1440}],
                stopped: ["chidori_books"],
                resumed: [],
                min_pageviews: nil
              }}
           ) == "Chiezo の設定から戻しました（整理を1 日ごとに、整理を自動で回さない: chidori_books）。"

    assert SettingsLive.restore_text(
             {:ok, %{paces: [], stopped: [], resumed: [], min_pageviews: nil}}
           ) =~
             "変えたものはありません"
  end

  test "写真と表紙のタブに、Chiezo の具合と直近の依頼を並べる", %{conn: conn} do
    HttpStub.stub(fn %{method: :get, url: url} ->
      if String.ends_with?(url, "/v1/thumbs/health"),
        do:
          HttpStub.ok(
            Jason.encode!(%{
              "last_ok_at" => "2026-10-21T15:40:09+00:00",
              "failing" => 1,
              "last_reason" => "HTTP 429",
              "resting" => %{
                "upload.wikimedia.org" => "2099-01-01T00:00:00+00:00",
                # 期限の過ぎた休みは出さない
                "img.hanmoto.com" => "2000-01-01T00:00:00+00:00"
              },
              "recent" => [
                %{
                  "at" => "2026-10-21T15:41:00+00:00",
                  "caller" => "表紙の依頼",
                  "target" => "https://www.hanmoto.com/bd/img/9784873115658.jpg",
                  "result" => "取った",
                  "ok" => true
                }
              ]
            })
          ),
        else: HttpStub.ok("{}")
    end)

    {:ok, live, _html} = live(conn, ~p"/settings?tab=photos")
    html = render_async(live)

    assert html =~ "Chidori の頼みの列"
    assert html =~ "upload.wikimedia.org に断られたので"
    refute html =~ "img.hanmoto.com に断られたので"
    assert html =~ "表紙の依頼"
    assert html =~ "www.hanmoto.com …/9784873115658.jpg"
  end
end

defmodule ChidoriWeb.SettingsLiveSwitchTest do
  @moduledoc """
  設定ページの「Chiezo 収集」で、Chidori が依頼した収集を止める・動かす。
  動かすのは Chiezo の管理画面で外部からの有効化を許可したときだけ通る（`Chidori.Chiezo.switch/3`）。
  """

  use ChidoriWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Chidori.HttpStub

  setup do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
    :ok
  end

  defp stub(enabled, answer) do
    parent = self()

    HttpStub.stub(fn
      %{method: :get, url: url} ->
        if String.ends_with?(url, "/v1/collect"),
          do:
            HttpStub.ok(
              Jason.encode!(%{
                "collections" => [
                  %{
                    "name" => "chidori_tech",
                    "enabled" => enabled,
                    "sweeps" => [%{"name" => "整理", "interval_minutes" => 720}]
                  }
                ]
              })
            ),
          else: HttpStub.ok(~s({"workers":[],"backends":[]}))

      %{method: :post, url: url, body: body} ->
        send(parent, {:posted, url, Jason.decode!(body)})
        answer
    end)
  end

  test "止まっている収集は塊に色を付け、「動かす」で Chidori の名乗りで動かす", %{conn: conn} do
    stub(false, HttpStub.ok("{}"))
    {:ok, live, _html} = live(conn, ~p"/collect")
    html = render_async(live)

    assert html =~ ~s(class="is-stopped")
    assert html =~ "止まっています"

    live
    |> element(~s(button.collection-switch[phx-value-collection="chidori_tech"]))
    |> render_click()

    assert_receive {:posted, "http://chiezo.test/v1/collect/chidori_tech/enabled",
                    %{"enabled" => true, "requested_by" => "chidori"}}

    assert render_async(live) =~ "動かしました"
  end

  test "許可されていなければ、Chiezo でどうすればよいかを出す", %{conn: conn} do
    stub(false, {:ok, %{status: 403, body: ~s({"error":"外部からの有効化を許可していません"})}})
    {:ok, live, _html} = live(conn, ~p"/collect")
    render_async(live)

    live
    |> element(~s(button.collection-switch[phx-value-collection="chidori_tech"]))
    |> render_click()

    assert render_async(live) =~ "「外部からの有効化を許可する」を押してください"
  end

  test "動いている収集には「止める」を出す", %{conn: conn} do
    stub(true, HttpStub.ok("{}"))
    {:ok, live, _html} = live(conn, ~p"/collect")
    html = render_async(live)

    refute html =~ ~s(class="is-stopped")

    live
    |> element(~s(button.collection-switch[phx-value-collection="chidori_tech"]), "止める")
    |> render_click()

    assert_receive {:posted, _url, %{"enabled" => false}}
  end
end

defmodule ChidoriWeb.CollectOpsTest do
  @moduledoc """
  Chiezo の管理画面のボタンと同じ操作を、収集の画面（`/collect`）から頼む。
  Chiezo の管理画面を開かずに済むようにするための口。
  """

  use ChidoriWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Chidori.HttpStub

  setup do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

    parent = self()

    HttpStub.stub(fn
      %{method: :get, url: url} ->
        cond do
          String.ends_with?(url, "/v1/collect") ->
            HttpStub.ok(
              Jason.encode!(%{
                "collections" => [
                  %{
                    "name" => "chidori_tech",
                    "enabled" => true,
                    "partitions_total" => 12,
                    "last_undo" => %{"sweep" => "整理"},
                    "sweeps" => [
                      %{"name" => "整理", "interval_minutes" => 720},
                      %{"name" => "機械収集", "use_feed" => true, "prompt" => "{queries}"}
                    ]
                  }
                ]
              })
            )

          String.ends_with?(url, "/v1/collect/queue") ->
            HttpStub.ok(
              Jason.encode!(%{
                "workers" => [
                  %{
                    "id" => "w-1",
                    "name" => "精査",
                    "interval_minutes" => 60,
                    "per_run" => 2,
                    "paused" => false,
                    "queued" => [%{"collection" => "chidori_tech", "sweep" => "整理"}]
                  }
                ]
              })
            )

          String.contains?(url, "/queries") ->
            HttpStub.ok(
              Jason.encode!(%{
                "queries" => [%{"query" => "SRE 本", "used_at" => nil, "found" => 3, "kept" => 2}]
              })
            )

          true ->
            HttpStub.ok(~s({"backends":[]}))
        end

      %{method: method, url: url} = request ->
        send(parent, {method, url, request[:body]})
        HttpStub.ok("{}")
    end)

    :ok
  end

  defp opened(conn) do
    {:ok, live, _html} = live(conn, ~p"/collect")
    {live, render_async(live)}
  end

  test "やり直す・一周をやり直す・割り直す・未確認に戻す・止めるを Chiezo へ頼む", %{conn: conn} do
    {live, html} = opened(conn)
    assert html =~ "ほかの操作"

    for {op, path} <- [
          {"redo", "/redo?manual=true"},
          {"repartition", "/repartition"},
          {"requeue", "/requeue"},
          {"stop", "/stop"}
        ] do
      live
      |> element(~s(button[phx-click="operate"][phx-value-op="#{op}"]))
      |> render_click()

      url = "http://chiezo.test/v1/collect/chidori_tech" <> path
      assert_receive {:post, ^url, _body}
    end

    live
    |> element(~s(button[phx-value-op="restart"][phx-value-sweep="整理"]))
    |> render_click()

    assert_receive {:post, "http://chiezo.test/v1/collect/chidori_tech/restart?sweep=" <> sweep,
                    _}

    assert URI.decode_www_form(sweep) == "整理"
    assert render_async(live) =~ "「整理」の一周をやり直します"
  end

  test "Chiezo が断ったら、その言い分を出す", %{conn: conn} do
    HttpStub.stub(fn
      %{method: :get, url: url} ->
        if String.ends_with?(url, "/v1/collect"),
          do:
            HttpStub.ok(
              ~s({"collections":[{"name":"chidori_tech","enabled":true,"sweeps":[{"name":"整理"}]}]})
            ),
          else: HttpStub.ok(~s({"workers":[],"backends":[]}))

      %{method: :post} ->
        {:ok, %{status: 409, body: ~s({"error":"いま割り直しています"})}}
    end)

    {live, _html} = opened(conn)

    live
    |> element(~s(button[phx-click="operate"][phx-value-op="stop"]))
    |> render_click()

    assert render_async(live) =~ "Chiezo が断りました: いま割り直しています"
  end

  test "ワーカーを止める・起こす", %{conn: conn} do
    {live, _html} = opened(conn)

    live |> element(~s(button[phx-value-id="w-1"][phx-value-op="pause"])) |> render_click()
    assert_receive {:post, "http://chiezo.test/v1/ai/workers/w-1/paused", ~s({"paused":true})}

    live |> element(~s(button[phx-value-id="w-1"][phx-value-op="wake"])) |> render_click()
    assert_receive {:post, "http://chiezo.test/v1/ai/workers/w-1/wake", _}
  end

  test "検索文の控えは開いたときだけ読み、1 つずつ消せる", %{conn: conn} do
    {live, html} = opened(conn)
    refute html =~ "SRE 本"

    live |> element(~s(button[phx-click="load_queries"])) |> render_click()
    assert render_async(live) =~ "SRE 本"

    live
    |> element(~s(button[phx-click="forget_query"][phx-value-query="SRE 本"]))
    |> render_click()

    assert_receive {:delete,
                    "http://chiezo.test/v1/collect/chidori_tech/queries?query=SRE+%E6%9C%AC", _}
  end
end

defmodule ChidoriWeb.CollectTabsTest do
  @moduledoc "収集の画面の頭の段（一覧・ニュース・趣味・他アプリ用）。頭のメニューの「収集」から直接たどれる。"

  use ChidoriWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "どの段へも行け、開いている段に印が付く" do
    html = render_component(&ChidoriWeb.CollectTabs.collect_tabs/1, current: :apps)

    for path <- [
          "/collect",
          "/collect/news",
          "/collect/news?view=chidori_movies",
          "/collect/apps"
        ] do
      assert html =~ ~s(href="#{path}")
    end

    # 関連図はどれも趣味に並べたので、関連図の段は無い
    refute html =~ ~s(href="/collect/relations")

    [picked] = Regex.run(~r|<a[^>]*href="/collect/apps"[^>]*>|, html)
    assert picked =~ ~s(class="selected") and picked =~ ~s(aria-current="page")
    [other] = Regex.run(~r|<a[^>]*href="/collect/news"[^>]*>|, html)
    refute other =~ "selected"
  end
end
