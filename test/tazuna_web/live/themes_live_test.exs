defmodule TazunaWeb.ThemesLiveTest do
  @moduledoc """
  トピックの画面。見ているのは、**押す前に何を渡すのかが読めること**です。
  """

  use TazunaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tazuna.HttpStub

  setup do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
    :ok
  end

  defp stub(collections, themes) do
    HttpStub.stub(fn
      %{url: "http://chiezo.test:7010/v1/ai/backends"} ->
        HttpStub.ok(~s({"backends":[]}))

      %{url: "http://chiezo.test:7010/v1/collect"} ->
        HttpStub.ok(Jason.encode!(%{"collections" => collections}))

      %{url: "http://chiezo.test:7010/v1/sources"} ->
        HttpStub.ok(Jason.encode!(%{"sources" => []}))

      %{url: "http://chiezo.test:7010/v1/tazuna_tech_topics/filter?" <> _query} ->
        HttpStub.ok(Jason.encode!(%{"results" => themes}))

      %{url: _detail} ->
        HttpStub.ok(Jason.encode!(List.first(collections) || %{}))
    end)
  end

  defp theme(title, tags, note \\ "説明。") do
    %{"title" => title, "tags" => ["トピック" | tags], "opening" => note}
  end

  defp shown(conn) do
    {:ok, live, _html} = live(conn, ~p"/topics?view=tazuna_tech")
    render_async(live, 2_000)
  end

  test "収集がまだ無ければ、依頼する口を出す", %{conn: conn} do
    stub([], [])

    html = shown(conn)

    assert html =~ "収集を依頼する"
    assert html =~ "まだ Chiezo に収集がありません"
    # 育てるのは Chiezo の側だと、押す前に読める
    assert html =~ "育てるのは Chiezo"
  end

  test "トピックの網を図にする", %{conn: conn} do
    collections = [%{"name" => "tazuna_tech_topics", "enabled" => true, "kind" => "stock"}]

    themes = [
      theme("AI", ["分野:AI"], "機械学習ぜんたい。"),
      theme("AIエージェント", ["分野:AI", "親:AI", "関連:MCP:道具の口を決める規格"]),
      theme("MCP", ["分野:AI"])
    ]

    stub(collections, themes)

    html = shown(conn)

    assert html =~ "topic-map"
    assert html =~ "topic-nodes"
    # つながりの説明は線の上に出る
    assert html =~ "道具の口を決める規格"
    # 上下のつながりは、横のつながりと見え方を分ける
    assert html =~ "is-parent"
    # 図に出ないものも一覧では読める
    assert html =~ "theme-list"
    assert html =~ "機械学習ぜんたい。"
    assert html =~ "いま育てる"
  end

  test "先の無いつながりは、線にしない", %{conn: conn} do
    collections = [%{"name" => "tazuna_tech_topics", "enabled" => true, "kind" => "stock"}]
    stub(collections, [theme("AI", ["関連:まだ無い語:説明"])])

    html = shown(conn)

    assert html =~ "topic-map"
    # 図には線を引かない（整える回が直すまで、図は黙って耐える）
    refute html =~ "<line"
    # 一覧には AI が書いたまま出す（黙って消さない）
    assert html =~ "まだ無い語"
  end
end
