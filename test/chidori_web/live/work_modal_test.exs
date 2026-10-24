defmodule ChidoriWeb.WorkModalTest do
  @moduledoc """
  映画・アニメの作品の詳細（モーダル）。見ているのは、**札を押すと開き、説明・出典・
  上映館・見た記録が出ること**、**一覧に無い作品（要約から開いたもの）は Chiezo から
  1 件引くこと**、**閉じられること**です。
  """

  use ChidoriWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ChidoriWeb.WorkModal

  @today Chidori.Jst.today() |> Date.to_iso8601()

  defp doc(title, url) do
    %{
      "title" => title,
      "tags" => ["公開日:#{@today}", "注目度:高"],
      "extra" => %{"url" => url},
      "opening" => "どんな作品か: 説明",
      "body" => "どんな作品か: 説明\n口コミ: よかった https://example.com/review"
    }
  end

  setup do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Chidori.News.Supervisor) do
      DynamicSupervisor.terminate_child(Chidori.News.Supervisor, pid)
    end

    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
    listed = doc("一覧の作品", "https://example.com/listed")
    other = doc("要約だけの作品", "https://example.com/other")

    Chidori.HttpStub.stub(fn
      %{url: "http://chiezo.test:7010/v1/chidori_movies/filter?" <> _query} ->
        Chidori.HttpStub.ok(Jason.encode!(%{"total" => 1, "results" => [listed]}))

      %{url: "http://chiezo.test:7010/v1/chidori_movies/doc?" <> query} ->
        case URI.decode_query(query) do
          %{"title" => "要約だけの作品"} -> Chidori.HttpStub.ok(Jason.encode!(other))
          _other -> {:ok, %{status: 404, body: ~s({"error":"not found"})}}
        end

      _request ->
        {:ok, %{status: 404, body: ~s({"error":"not found"})}}
    end)

    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
    :ok
  end

  test "注目作の札を押すと、説明・出典・上映館・見た記録の詳細が開き、閉じられる", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/news?view=chidori_movies")
    html = render_async(live)

    # 「注目作」の見出しは付けず、公開中の作品はカレンダーの上
    refute html =~ ~s(>注目作<)
    {started, _} = :binary.match(html, ~s(aria-label="公開中の作品"))
    {calendar, _} = :binary.match(html, "のカレンダー")
    {upcoming, _} = :binary.match(html, ~s(aria-label="これからの作品"))
    assert started < calendar and calendar < upcoming

    # 札は見出しと事実だけ。本文と記録の欄は詳細の中
    assert html =~ ~s(phx-click="open_work")
    refute html =~ "口コミ: よかった"

    html = render_click(live, "open_work", %{"title" => "一覧の作品"})
    assert html =~ ~s(id="work-modal")
    assert html =~ "口コミ: よかった"
    assert html =~ "出典"
    assert html =~ "https://example.com/listed"
    assert html =~ "https://example.com/review"
    assert html =~ "近くの上映館を Gemini に聞く"
    assert html =~ "見た記録"

    refute render_click(live, "close_work", %{}) =~ ~s(id="work-modal")
  end

  test "一覧に無い作品（要約から開いたもの）は Chiezo から引く", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/news?view=chidori_movies")
    render_async(live)

    assert render_click(live, "open_work", %{"title" => "要約だけの作品"}) =~ "読み込んでいます…"

    html = render_async(live)
    assert html =~ "https://example.com/other"
    assert html =~ "口コミ: よかった"
  end

  test "見つからない作品は、そう言う", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/news?view=chidori_movies")
    render_async(live)

    render_click(live, "open_work", %{"title" => "どこにも無い作品"})
    assert render_async(live) =~ "Chiezo に見当たりませんでした"
  end

  test "出典は作品のページを先に、本文の URL を重ねずに" do
    entry = %{
      url: "https://example.com/a",
      summary: "公式 https://example.com/a\n評判 https://example.com/b https://example.com/b"
    }

    assert WorkModal.sources(entry) == ["https://example.com/a", "https://example.com/b"]
    assert WorkModal.sources(%{url: nil, summary: nil}) == []
  end
end
