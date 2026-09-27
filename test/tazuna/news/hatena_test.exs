defmodule Tazuna.News.HatenaTest do
  use ExUnit.Case, async: false

  alias Tazuna.HttpStub
  alias Tazuna.News.Hatena

  setup do
    Hatena.clear()
    :ok
  end

  test "50 本ずつまとめて引き、覚えたものは引き直さない" do
    test_pid = self()

    HttpStub.stub(fn %{url: "https://bookmark.hatenaapis.com/count/entries?" <> query} ->
      send(test_pid, {:asked, query})

      urls =
        query
        |> String.split("&")
        |> Enum.map(&URI.decode_www_form(String.replace_prefix(&1, "url=", "")))

      HttpStub.ok(Jason.encode!(Map.new(urls, &{&1, String.length(&1)})))
    end)

    Application.put_env(:tazuna, :hatena_pause_ms, 0)
    on_exit(fn -> Application.delete_env(:tazuna, :hatena_pause_ms) end)

    urls = for i <- 1..60, do: "https://example.com/#{i}"
    counts = Hatena.counts(urls)

    assert map_size(counts) == 60
    assert_received {:asked, _first}
    assert_received {:asked, _second}

    # 2 回目は覚えているぶんで返す（外へ出ない）
    assert Hatena.counts(Enum.take(urls, 3)) == Map.take(counts, Enum.take(urls, 3))
    refute_received {:asked, _}
  end

  test "引けなければ数を持たないだけ（記事の一覧は止めない）" do
    HttpStub.stub(fn _request -> {:error, :timeout} end)

    assert [%{bookmarks: nil}] = Hatena.with_counts([%{url: "https://example.com/x"}])
    assert [%{bookmarks: nil}] = Hatena.with_counts([%{url: nil}])
  end
end
