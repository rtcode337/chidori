defmodule TazunaWeb.TopBooksTest do
  @moduledoc """
  本棚の上位の枠（技術書の画面とトップページ）。見ているのは、**10 冊まで並ぶこと**、
  **順位を書名の左に文字で出すこと**、**表紙を押しても書名と同じく本の頁へ行くこと**、
  **オライリーの本を別の枠に分けること**です。
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias TazunaWeb.TopBooks

  defp book(n, overrides \\ %{}) do
    Map.merge(
      %{
        title: "本#{n}",
        name: "本#{n}",
        near: [],
        cover_url: "https://example.com/cover/#{n}.jpg",
        page_url: "https://example.com/book/#{n}",
        classic: false,
        docs: 20 - n,
        recent: 0,
        fields: [],
        note: ""
      },
      overrides
    )
  end

  test "10 冊まで並べ、順位は書名の左に文字で出す" do
    html = render_component(&TopBooks.top_books/1, books: Enum.map(1..12, &book/1))

    assert TopBooks.count() == 10
    assert html =~ "10位"
    refute html =~ "11位"
    # 丸い印ではなく、書名の行の中の文字
    assert html =~ ~r|<p class="top-book-title">\s*<span class="top-book-rank">1位</span>|
  end

  test "読んだ本は並べず、そのぶん次の本が繰り上がる" do
    books = Enum.map(1..12, &book/1)
    html = render_component(&TopBooks.top_books/1, books: books, read: MapSet.new(["本1"]))

    refute html =~ ">\n      本1\n"
    refute html =~ ~s(href="https://example.com/book/1")
    # 10 冊は保つ（11 冊目が繰り上がる）
    assert html =~ "本11"
    assert html =~ "10位"
  end

  test "表紙を押しても、書名と同じく本の頁へ行く（札を開かない）" do
    html = render_component(&TopBooks.top_books/1, books: [book(1)], open_event: "open_book")

    assert html =~
             ~r|<a href="https://example.com/book/1" target="_blank" rel="noreferrer" class="top-book-cover\s*"|

    # 札の開閉に伝えない
    assert html =~ ~r|class="top-book-cover\s*"[^>]*onclick="event.stopPropagation\(\)"|
  end

  test "頁の無い本の表紙は、リンクにしない" do
    html = render_component(&TopBooks.top_books/1, books: [book(1, %{page_url: nil})])

    refute html =~ ~s(<a href="https://example.com/book/1")
    assert html =~ ~r|<div class="top-book-cover\s*">|
  end

  test "オライリーの本は既定の枠から外し、oreilly の枠にだけ並べる（順位はそれぞれで数える）" do
    books = [book(1, %{oreilly: true}), book(2), book(3, %{oreilly: true})]

    general = render_component(&TopBooks.top_books/1, books: books)
    refute general =~ "本1"
    assert general =~ ~r|1位</span>\s*<a[^>]*>\s*本2|

    oreilly = render_component(&TopBooks.top_books/1, books: books, oreilly: true)
    refute oreilly =~ "本2"
    assert oreilly =~ ~r|1位</span>\s*<a[^>]*>\s*本1|
    assert oreilly =~ ~r|2位</span>\s*<a[^>]*>\s*本3|
  end

  test "買う口のリンクを出し、押しても札を開かない" do
    html =
      render_component(&TopBooks.top_books/1,
        books: [book(1, %{store_label: "Kindle", store_url: "https://example.com/kindle"})],
        open_event: "open_book"
      )

    assert html =~
             ~r|<a href="https://example.com/kindle"[^>]*onclick="event.stopPropagation\(\)"[^>]*>\s*Kindle で探す|
  end
end
