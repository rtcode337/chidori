defmodule Chidori.ChiezoTagCountTest do
  @moduledoc """
  印の付いた文書の数（`Chidori.Chiezo.tag_count/3`）。溜まった数は消したものも数えるので、
  生きている数を出すのに消したものの数を引く。
  """

  use ExUnit.Case, async: false

  alias Chidori.Chiezo
  alias Chidori.HttpStub

  test "消したものも数えるよう頼み、1 件だけ読んで件数を受け取る" do
    test_pid = self()

    HttpStub.stub(fn %{url: url} ->
      send(test_pid, {:asked, URI.decode_query(URI.parse(url).query)})
      HttpStub.ok(Jason.encode!(%{"total" => 20, "results" => [%{"title" => "閉店した店"}]}))
    end)

    assert Chiezo.tag_count("http://chiezo.test", "chidori_dining_1", Chiezo.removed_tag()) == 20

    assert_receive {:asked, query}
    assert query["tag"] == Chiezo.removed_tag()
    assert query["include_removed"] == "true"
    assert query["limit"] == "1"
  end

  test "読めなければ nil（画面は生きている数を出さない）" do
    HttpStub.stub(fn _request -> {:ok, %{status: 500, body: ""}} end)

    assert Chiezo.tag_count("http://chiezo.test", "chidori_dining_1", Chiezo.removed_tag()) == nil
  end
end
