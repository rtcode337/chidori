defmodule TazunaWeb.SettingsLiveTest do
  @moduledoc """
  設定ページの「Chiezo 収集」。ここでは**巡回の間隔を画面から変えられること**を見ます。
  """

  use TazunaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tazuna.CollectPace
  alias Tazuna.HttpStub

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
                    "name" => "tazuna_tech",
                    "sweeps" => [%{"name" => "整理", "interval_minutes" => 720}]
                  },
                  # tazuna の画面に無い収集（Chiezo にだけ残っている）
                  %{
                    "name" => "tazuna_old",
                    "requested_by" => "tazuna",
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
    {:ok, live, _html} = live(conn, ~p"/settings?tab=chiezo")
    html = render_async(live)

    # Chiezo の技術ニュースには整理の回しか無い（Chidori の定義には見出しの回もある）
    [_, tech] = String.split(html, "tazuna_tech</span>", parts: 2)
    [tech, _] = String.split(tech, "</tbody>", parts: 2)
    assert tech =~ "Chidori の定義と違います"
    assert tech =~ "が Chiezo にありません"
  end

  test "いまの間隔が選ばれて出る", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/settings?tab=chiezo")

    assert html =~ "巡回の間隔"
    assert html =~ ~r/<option[^>]*value="720"[^>]*selected/
  end

  test "保存すると、その間隔を Chiezo に送る", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/settings?tab=chiezo")

    live
    |> form("#collect-pace", pace: %{tidy: "1440", scan: "120"})
    |> render_submit()

    assert CollectPace.minutes(:tidy) == 1440
    assert_receive {:patched, "http://chiezo.test/v1/collect/tazuna_tech/sweeps/整理", body}
    assert body["interval_minutes"] == 1440
    assert render_async(live) =~ "本の巡回に送りました"
  end

  test "開くとトップページのタブが先頭で選ばれている", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/settings")

    [_before, tabs | _rest] = String.split(html, ~s(aria-label="設定"))
    [tabs | _rest] = String.split(tabs, "</nav>")
    assert :binary.match(tabs, "トップページ") < :binary.match(tabs, "Chiezo 収集")
    assert html =~ ~r/class="selected"[^>]*>\s*トップページ/
  end

  test "収集は tazuna の画面の並びで、Chiezo にまだ無いものも並ぶ", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/settings?tab=chiezo")
    html = render_async(live)

    [tech, tech_topics, painters, old] =
      Enum.map(
        [
          "send-tazuna_tech\"",
          "send-tazuna_tech_topics\"",
          "send-tazuna_painters\"",
          "send-tazuna_old\""
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
    {:ok, live, _html} = live(conn, ~p"/settings?tab=chiezo")
    html = render_async(live)

    # 整理は押しボタンではなくチェックボックス
    assert html =~ ~r/<input[^>]*type="checkbox"[^>]*name="tidy"/
    assert html =~ ~s(<option value="codex")

    live
    |> element("#send-tazuna_tech")
    |> render_submit(%{
      "collection" => "tazuna_tech",
      "sweep|整理|backend" => "codex",
      "sweep|整理|model" => "gpt-5",
      "tidy" => "true"
    })

    html = render_async(live)

    assert_received {:patched, "http://chiezo.test/v1/collect/tazuna_tech", body}
    # 依頼文を含む tazuna の今の定義が届く
    assert is_binary(body["prompt"])
    tidy = Enum.find(body["sweeps"], &(&1["name"] == "整理"))
    assert {tidy["backend"], tidy["model"], tidy["by_caller"]} == {"codex", "gpt-5", true}
    assert CollectPace.tidy_stopped?("tazuna_tech")
    assert html =~ "送りました（"
  end

  test "画面に無い収集は、選び直した相手だけを送る", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/settings?tab=chiezo")
    render_async(live)

    live
    |> element("#send-tazuna_old")
    |> render_submit(%{
      "collection" => "tazuna_old",
      "sweep|整理|backend" => "codex",
      "tidy" => "false"
    })

    assert render_async(live) =~ "送りました（整理の相手）"

    assert_received {:patched, "http://chiezo.test/v1/collect/tazuna_old/sweeps/整理",
                     %{"backend" => "codex"}}
  end

  test "最後に取得した時刻を出し、「最新の情報を取得」で読み直す", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/settings?tab=chiezo")
    html = render_async(live)

    assert html =~ "最後に取得:"
    assert html =~ "（たった今）"

    live |> element("button", "最新の情報を取得") |> render_click()
    assert render_async(live) =~ "最新の情報を取得"
  end

  test "通知タブで、全部の通知に共通の宛先を書く", %{conn: conn} do
    # 話題ごとに書いていた頃は、同じトピックを画面ごとに書き写していた
    Tazuna.Notify.Settings.put("tazuna_tech", %{"notify" => "true"})
    {:ok, live, html} = live(conn, ~p"/settings?tab=notify")

    assert html =~ ~s(name="ntfy[topic]")
    assert html =~ ~s(name="ntfy[base_url]")

    # 知らせるかどうかは話題ごと（直すのは各画面）。いまどうなっているかは並べる
    assert html =~ "知らせる"

    live
    |> form("#ntfy-form", ntfy: %{topic: " shared-topic ", base_url: "http://ntfy.test/"})
    |> render_submit()

    assert Tazuna.Ntfy.topic() == "shared-topic"
    assert Tazuna.Ntfy.base_url() == "http://ntfy.test"
    assert Tazuna.Ntfy.ready("tazuna_tech") == {:ok, {"http://ntfy.test", "shared-topic"}}

    html =
      live
      |> form("#ntfy-form", ntfy: %{base_url: "ntfy.test"})
      |> render_submit()

    assert html =~ "http:// か https:// で書いてください"
    # 書いたものは消さない
    assert html =~ ~s(value="ntfy.test")
  end

  test "tazuna が起こす回は、表の中で時刻を直せる", %{conn: conn} do
    # 要約の回は Chiezo 側に時計が無く、時刻を持つのは tazuna（各話題の画面と同じ値）
    Tazuna.Notify.Settings.put("tazuna_news", %{"digest_at" => "07:00"})

    HttpStub.stub(fn
      %{method: :get, url: url} ->
        if String.ends_with?(url, "/v1/collect"),
          do:
            HttpStub.ok(
              Jason.encode!(%{
                "collections" => [
                  %{
                    "name" => "tazuna_news",
                    "sweeps" => [%{"name" => "要約", "on_demand" => true}]
                  }
                ]
              })
            ),
          else: HttpStub.ok(~s({"workers":[],"backends":[]}))
    end)

    {:ok, live, _html} = live(conn, ~p"/settings?tab=chiezo")
    html = render_async(live)

    assert html =~ "Chidori が起こす（07:00）"
    assert html =~ ~s(value="07:00")

    live
    |> form(".wake-form", times: "6, 19")
    |> render_submit()

    assert Tazuna.Notify.Settings.get("tazuna_news").digest_at == "06:00,19:00"
    assert render_async(live) =~ "起こす時刻を保存しました。"
  end

  test "巡回の間隔はざっと見るが先で、それぞれ何本あって何本動いているかを出す", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/settings?tab=chiezo")
    html = render_async(live)

    pace = html |> String.split(~s(id="collect-pace")) |> List.last()
    {scan, tidy} = {:binary.match(pace, "ざっと見る"), :binary.match(pace, "整理")}
    assert elem(scan, 0) < elem(tidy, 0)
    # 整理は tazuna_tech と tazuna_old の 2 本（どちらも時計で回る）
    assert pace =~ "Chidori に 2 本・動いている"
  end
end
