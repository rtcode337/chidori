defmodule ChidoriWeb.NewsFavoritesTest do
  @moduledoc """
  ニュースのお気に入りの画面。見ているのは、**話題のタブの最後にお気に入りのタブがあること**、
  **記事の詳細から入れ外しできること**、**お気に入りの札に印が付くこと**、**タブで一覧が読めて
  外せること**です。
  """

  use ChidoriWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Chidori.News.Favorites
  alias ChidoriWeb.NewsLive

  test "お気に入りのタブで一覧を読み、外せる", %{conn: conn} do
    {:ok, _} = Favorites.add("https://example.com/a", "残したい記事")

    {:ok, live, html} = live(conn, ~p"/news?view=favorites")

    assert html =~ ~s(href="/news?view=favorites")
    assert html =~ "残したい記事"
    assert html =~ ~s(href="https://example.com/a")
    # 話題ごとの節（記事一覧・収集の設定）は出さない
    refute html =~ "Chiezo の収集"
    refute html =~ ~s(id="news-articles")

    html = render_click(live, "remove_favorite", %{"url" => "https://example.com/a"})
    refute html =~ "残したい記事"
    assert html =~ "まだありません"
  end

  test "記事の詳細から入れ外しする", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/news?view=favorites")
    params = %{"url" => "https://example.com/b", "title" => "記事 B"}

    render_click(live, "toggle_favorite", params)
    assert [%{title: "記事 B"}] = Favorites.list()

    render_click(live, "toggle_favorite", params)
    assert Favorites.list() == []
  end

  test "お気に入りの札には印が付く" do
    article = %{
      title: "記事",
      url: "https://example.com/c",
      image: nil,
      collected_at: "10/16 09:00",
      summary: nil,
      tags: [],
      reason: "",
      importance: 1
    }

    marked = render_component(&NewsLive.article_card/1, article: article, favorite: true)
    plain = render_component(&NewsLive.article_card/1, article: article)

    assert marked =~ "favorite-mark"
    refute plain =~ "favorite-mark"
    assert NewsLive.favorite?(MapSet.new(["https://example.com/c"]), article)
    refute NewsLive.favorite?(MapSet.new(), article)
  end
end
