defmodule TazunaWeb.HomeLiveTest do
  @moduledoc """
  トップページと、そこに並べる枠の設定。見ているのは、**選んだ枠が選んだ順にタブで
  並び、最初の枠が開くこと**です。
  """

  use TazunaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tazuna.Home

  test "選んだ枠が選んだ順にタブで並び、最初の枠が開く", %{conn: conn} do
    Home.put(["books", "topic:tazuna_tech", "relations:painters"])

    {:ok, _live, html} = live(conn, ~p"/")

    [_before, nav | _rest] = String.split(html, ~s(aria-label="トップページの枠"))
    [nav | _rest] = String.split(nav, "</nav>")

    [books, tech, painters] =
      Enum.map(["技術書", "技術ニュース", "関連図（"], fn label ->
        nav |> :binary.match(label) |> elem(0)
      end)

    assert books < tech and tech < painters
    # 最初の枠（技術書）が開いている
    assert html =~ ~s(aria-label="技術書")
  end

  test "関連図は画面ごと埋め込む（頭のメニューは出さない）", %{conn: conn} do
    Home.put(["relations:painters"])

    {:ok, _live, html} = live(conn, ~p"/")
    assert html =~ ~s(src="/relations?view=painters&amp;embed=1")

    {:ok, _live, embedded} = live(conn, ~p"/relations?view=painters&embed=1")
    refute embedded =~ "主要メニュー"
  end

  test "注目イベントは、これから 2 か月を近い順に" do
    today = ~D[2026-10-01]
    event = fn title, date, attention -> %{title: title, date: date, attention: attention} end

    list =
      TazunaWeb.HomeLive.upcoming(
        [
          event.("終わった", ~D[2026-09-30], :high),
          event.("先すぎる", ~D[2026-12-15], :high),
          event.("来週・中", ~D[2026-10-08], :mid),
          event.("来週・高", ~D[2026-10-08], :high),
          event.("今日", ~D[2026-10-01], :mid)
        ],
        today
      )

    assert Enum.map(list, & &1.title) == ["今日", "来週・高", "来週・中"]
  end

  test "技術書は、押すとその本を勧めている記事をたどれる", %{conn: conn} do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

    Tazuna.HttpStub.stub(fn
      %{url: "http://chiezo.test:7010/v1/tazuna_books/filter?" <> _} ->
        Tazuna.HttpStub.ok(
          Jason.encode!(%{
            "results" => [
              %{
                "title" => "本:リーダブルコード",
                "tags" => ["技術書"],
                "opening" => "読みやすいコードの本。",
                "extra" => %{"docs" => 5}
              }
            ]
          })
        )

      %{url: "http://chiezo.test:7010/v1/tazuna_book_posts/filter?" <> _} ->
        Tazuna.HttpStub.ok(
          Jason.encode!(%{
            "results" => [
              %{
                "title" => "新人に勧めたい本",
                "extra" => %{"url" => "https://example.com/post", "published_at" => "2026-09-01"}
              }
            ]
          })
        )

      %{url: _other} ->
        Tazuna.HttpStub.ok(~s({"results":[]}))
    end)

    Home.put(["books"])
    {:ok, live, _html} = live(conn, ~p"/")
    html = render_async(live, 2_000)

    # 見出しは出さない（札そのものが入口）
    refute html =~ "いま勧められている技術書"
    assert html =~ "記事を見る"

    live |> element(~s(li[phx-value-title="本:リーダブルコード"])) |> render_click()
    html = render_async(live, 2_000)

    assert html =~ "「リーダブルコード」を勧めている記事"
    assert html =~ ~s(href="https://example.com/post")
  end

  test "埋め込んだ関連図は、取得の行と図だけ", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/relations?view=painters&embed=1")

    assert html =~ "最新の情報を取得"
    refute html =~ "<h1"
    refute html =~ "relation-guide"
  end

  test "知らない枠は保存しない", %{conn: _conn} do
    Home.put(["nosuch", "topic:tazuna_news"])
    assert Home.selected_keys() == ["topic:tazuna_news"]
  end

  test "並べられる枠は、要約を作る話題と関連図と技術書" do
    keys = Enum.map(Home.catalog(), & &1.key)

    assert "topic:tazuna_news" in keys
    assert "topic:tazuna_movies" in keys

    # 要約を作らずカレンダーを持つ話題（技術イベント）は注目イベントとして並べる
    refute "topic:tazuna_events" in keys
    assert "events:tazuna_events" in keys
    # どちらも持たない話題（銘柄調査）は並べない
    refute "topic:tazuna_stocks" in keys
    refute "events:tazuna_stocks" in keys
    assert "relations:painters" in keys
    assert "books" in keys
  end

  test "設定ページで、並べ替えた順に保存する", %{conn: conn} do
    # 順番は画面の中で並べ替え、各行の hidden の欄に書き込まれて届く（`SortableList`）
    {:ok, live, _html} = live(conn, ~p"/settings?tab=home")

    render_submit(live, "save_home", %{
      "panels" => %{
        "topic:tazuna_news" => %{"on" => "true", "order" => "2"},
        "books" => %{"on" => "true", "order" => "1"},
        "topic:tazuna_tech" => %{"on" => "false", "order" => "3"}
      }
    })

    assert Home.selected_keys() == ["books", "topic:tazuna_news"]
  end

  test "並べ替えの一覧は、並べている枠を並べている順に先に出す", %{conn: conn} do
    # つまんで動かす一覧なので、いまの順番がそのまま上から並んでいないと動かしようがない
    Home.put(["books", "topic:tazuna_news"])

    {:ok, _live, html} = live(conn, ~p"/settings?tab=home")

    [_before, list | _rest] = String.split(html, ~s(id="home-panels"))

    [books, news, tech] =
      Enum.map(["技術書", "一般ニュース", "技術ニュース"], &(list |> :binary.match(&1) |> elem(0)))

    assert books < news and news < tech
    assert html =~ "data-drag-handle"
  end
end
