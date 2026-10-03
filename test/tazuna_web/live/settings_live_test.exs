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
    assert html =~ "tazuna の画面に無い収集です"
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
end
