defmodule Chidori.News.FavoritesTest do
  @moduledoc """
  ニュースのお気に入り。見ているのは、**URL と見出しだけを残すこと**、**同じ URL は増えないこと**、
  **外せること**、**付けた日の新しい順に並ぶこと**です。
  """

  use Chidori.DataCase, async: false

  alias Chidori.DataStore.MarkRecords
  alias Chidori.News.Favorites

  test "URL と見出しを残し、一覧と URL の集まりで引ける" do
    assert {:ok, _doc_id} = Favorites.add("https://example.com/a", "記事 A")

    assert [%{url: "https://example.com/a", title: "記事 A", on: on}] = Favorites.list()
    assert on == Chidori.Jst.today()
    assert MapSet.member?(Favorites.urls(), "https://example.com/a")
  end

  test "同じ URL を入れ直しても増えず、見出しだけ新しくなる" do
    {:ok, first} = Favorites.add("https://example.com/a", "古い見出し")
    {:ok, second} = Favorites.add("https://example.com/a", "新しい見出し")

    assert first == second
    assert [%{title: "新しい見出し"}] = Favorites.list()
  end

  test "外せる（入っていないものを外しても何も起きない）" do
    {:ok, _} = Favorites.add("https://example.com/a", "記事 A")

    assert :ok = Favorites.remove("https://example.com/a")
    assert Favorites.list() == []
    assert :ok = Favorites.remove("https://example.com/none")
  end

  test "URL の無い記事は入れられない" do
    assert {:error, :no_url} = Favorites.add(nil, "見出しだけ")
    assert {:error, :no_url} = Favorites.add("javascript:alert(1)", "危ない")
    assert Favorites.list() == []
  end

  test "付けた日の新しい順に並ぶ" do
    put = fn url, title, on ->
      MarkRecords.put(
        Favorites.view(),
        url,
        %{done: true, on: on, note: "", label: title},
        nil
      )
    end

    {:ok, _} = put.("https://example.com/old", "古い", ~D[2026-10-01])
    {:ok, _} = put.("https://example.com/new", "新しい", ~D[2026-10-15])

    assert Enum.map(Favorites.list(), & &1.title) == ["新しい", "古い"]
  end

  test "見た記録とは混ざらない" do
    {:ok, _} = Favorites.add("https://example.com/a", "記事 A")
    assert Chidori.Relations.Marks.for_view("movies") == %{}
  end
end
