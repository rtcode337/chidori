defmodule Tazuna.Datasets.BookQueriesTest do
  @moduledoc """
  技術書の記事を探す検索文を、回ごとに AI に考えさせる（`Tazuna.Datasets.BookQueries`）。

  **同じ検索文で引き直しても、同じ記事が返るだけ**（実測で 1 回目 158 件、2 回目は
  158 件すべて既にあるもの）。見ているのは、**新しい検索文に差し替わること**と、
  **使った検索文を二度と使わないこと**、**何件入ったかを数えて AI に見せること**。
  """

  use Tazuna.DataCase, async: false

  alias Tazuna.Datasets.BookQueries

  @base "http://chiezo.test:7010"
  @name "tazuna_book_posts"

  defp stub(proposed, tags \\ []) do
    test_pid = self()

    Tazuna.HttpStub.stub(fn
      %{url: @base <> "/v1/ai/complete", body: body} ->
        send(test_pid, {:asked, Jason.decode!(body)})
        Tazuna.HttpStub.ok(Jason.encode!(%{"content" => "案です:\n" <> Jason.encode!(proposed)}))

      %{url: @base <> "/v1/" <> @name <> "/tags?" <> _query} ->
        Tazuna.HttpStub.ok(Jason.encode!(%{"tags" => tags}))
    end)
  end

  test "1 回目は最初の組を控える（AI には頼まない）" do
    stub([])

    assert {:ok, ["技術書", "SRE 本"]} = BookQueries.refresh(@base, @name, ["技術書", "SRE 本"])
    refute_received {:asked, _}
    assert BookQueries.current(@name) == ["技術書", "SRE 本"]
  end

  test "2 回目からは、数えてから AI に考えさせ、使った検索文は落とす" do
    stub(["技術書", "輪読会 技術書", "SRE 本 おすすめ"], [
      %{"tag" => "検索:技術書", "docs" => 12}
    ])

    BookQueries.refresh(@base, @name, ["技術書"])
    # 同じ秒に控えると同じ組に見えるので、1 回目の時刻をずらす
    Tazuna.Repo.update_all(Tazuna.Datasets.SearchQuery,
      set: [used_at: ~U[2026-09-01 00:00:00Z]]
    )

    assert {:ok, fresh} = BookQueries.refresh(@base, @name, ["技術書"])

    assert fresh == ["輪読会 技術書", "SRE 本 おすすめ"], "使った検索文は二度と使わない"
    assert BookQueries.current(@name) == fresh

    # 前の検索文で何件入ったかを数え、AI に見せている
    assert_received {:asked,
                     %{"messages" => [%{"content" => prompt}], "requested_by" => "tazuna"}}

    assert prompt =~ "- 技術書（12 件）"
  end

  test "新しい検索文が 1 つも無ければ、その回は走らせない" do
    stub(["技術書"])
    BookQueries.refresh(@base, @name, ["技術書"])

    Tazuna.Repo.update_all(Tazuna.Datasets.SearchQuery,
      set: [used_at: ~U[2026-09-01 00:00:00Z]]
    )

    assert BookQueries.refresh(@base, @name, ["技術書"]) == {:error, :no_new_queries}
  end

  test "答えの前置きや囲みがあっても、配列を拾う" do
    assert BookQueries.parse("```json\n[\"a b\", \" c \"]\n```") == ["a b", "c"]
    assert BookQueries.parse("読めない") == []
  end
end
