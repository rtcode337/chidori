defmodule Chidori.News.HatenaTest do
  use ExUnit.Case, async: false

  alias Chidori.HttpStub
  alias Chidori.News.Hatena

  @base "http://chiezo.test:7010"

  setup do
    Hatena.clear()
    System.put_env("CHIEZO_BASE_URL", @base)
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
    :ok
  end

  test "はてなへは出ず Chiezo に 50 本ずつ聞き、覚えたものは聞き直さない" do
    test_pid = self()

    HttpStub.stub(fn %{url: @base <> "/v1/bookmarks?" <> query} ->
      send(test_pid, {:asked, query})

      urls =
        query
        |> String.split("&")
        |> Enum.map(&URI.decode_www_form(String.replace_prefix(&1, "url=", "")))

      HttpStub.ok(Jason.encode!(%{"counts" => Map.new(urls, &{&1, String.length(&1)})}))
    end)

    urls = for i <- 1..60, do: "https://example.com/#{i}"
    counts = Hatena.counts(urls)

    assert map_size(counts) == 60
    assert_received {:asked, _first}
    assert_received {:asked, _second}

    # 2 回目は覚えているぶんで返す（Chiezo にも聞かない）
    assert Hatena.counts(Enum.take(urls, 3)) == Map.take(counts, Enum.take(urls, 3))
    refute_received {:asked, _}
  end

  test "引けなければ数を持たないだけ（記事の一覧は止めない）" do
    HttpStub.stub(fn _request -> {:error, :timeout} end)

    assert [%{bookmarks: nil}] = Hatena.with_counts([%{url: "https://example.com/x"}])
    assert [%{bookmarks: nil}] = Hatena.with_counts([%{url: nil}])
  end
end
