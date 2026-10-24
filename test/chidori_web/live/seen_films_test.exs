defmodule ChidoriWeb.SeenFilmsTest do
  @moduledoc """
  趣味の映画のタブの中の「見た映画」。見た映画の一覧と、見た映画を足す口（関連図の画面から移した）。
  """

  use ChidoriWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Chidori.Relations.Films
  alias Chidori.Relations.Marks

  setup do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
    test_pid = self()

    Chidori.HttpStub.stub(fn
      %{method: :get, url: url} ->
        cond do
          # 映画の図にある作品
          url =~ "/v1/chidori_movie_catalog/doc?" and url =~ URI.encode_www_form("七人の侍") ->
            Chidori.HttpStub.ok(~s({"title":"七人の侍"}))

          url =~ "/v1/chidori_movie_catalog/doc?" ->
            {:ok, %{status: 404, body: ~s({"error":"not found"})}}

          url =~ "/v1/chidori_movies/doc?" ->
            {:ok, %{status: 404, body: ~s({"error":"not found"})}}

          # 引き継いだときの元の見出しで図にある作品
          url =~ "/v1/chidori_movie_catalog/filter?" and url =~ URI.encode_www_form("記録:元の見出し") ->
            Chidori.HttpStub.ok(
              ~s|{"total":1,"results":[{"title":"元の見出し (映画)","tags":["映画","年代:1980","監督:ある監督","主演:主演A","主演:主演B"],"body":"図の作品の説明"}]}|
            )

          true ->
            Chidori.HttpStub.ok(~s({"collections":[],"results":[],"backends":[]}))
        end

      %{method: :post, url: url} ->
        send(test_pid, {:posted, url})
        Chidori.HttpStub.ok("{}")
    end)

    :ok
  end

  test "見た映画を、見た日の新しい順に並べる（見た日の無いものは後ろ）", %{conn: conn} do
    {:ok, _} = Marks.put(Films.mark_view(), "古い映画", %{"seen" => true, "seen_on" => "2026-01-01"})
    {:ok, _} = Marks.put(Films.mark_view(), "新しい映画", %{"seen" => true, "seen_on" => "2026-10-01"})
    {:ok, _} = Marks.put(Films.mark_view(), "日付なし", %{"seen" => true})

    {:ok, _live, html} = live(conn, ~p"/news?view=chidori_movies&section=seen")

    assert html =~ "見た映画（3 本）"
    {new, _} = :binary.match(html, "新しい映画")
    {old, _} = :binary.match(html, "古い映画")
    {undated, _} = :binary.match(html, "日付なし")
    assert new < old and old < undated

    # 切り替えは「見た映画」を選んだ状態。最新の要約は出さない
    [_, tabs] = String.split(html, ~s(id="movie-tabs"), parts: 2)
    [tabs, _] = String.split(tabs, "</nav>", parts: 2)
    assert tabs =~ ~r|section=seen"[^>]*class="selected"|
    refute html =~ ~s(aria-label="要約")

    # 見出しは最新・関連図と同じ（`DiningTabs.movie_intro/1`）
    assert html =~ ~s(class="relations-intro movie-intro")
  end

  test "図にもうある作品は記録だけ、無い作品は図に足すよう頼む", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/news?view=chidori_movies&section=seen")

    html =
      live
      |> form("#seen-films form", %{"title" => "七人の侍", "seen_on" => "2026-10-20"})
      |> render_submit()

    assert html =~ "見た映画（1 本）"
    assert render_async(live) =~ "映画の図にもうあります"
    refute_received {:posted, _}
    assert Marks.get(Films.mark_view(), "七人の侍").seen

    live
    |> form("#seen-films form", %{"title" => "図に無い映画", "hint" => "2026年"})
    |> render_submit()

    render_async(live)
    assert_received {:posted, url}
    assert url =~ "/v1/collect/chidori_movie_catalog/"
  end

  test "最新情報に無い見た映画も、映画の図から詳細を開ける", %{conn: conn} do
    {:ok, _} = Marks.put(Films.mark_view(), "七人の侍", %{"seen" => true, "seen_on" => "2026-10-01"})
    {:ok, _} = Marks.put(Films.mark_view(), "元の見出し", %{"seen" => true})

    {:ok, live, _html} = live(conn, ~p"/news?view=chidori_movies&section=seen")

    # 図の札の見出しで当たる
    live |> element(~s(li[phx-value-title="七人の侍"])) |> render_click()
    html = render_async(live)
    refute html =~ "見当たりませんでした"
    assert html =~ "七人の侍"

    # 引き継いだときの元の見出し（記録:）で当たる。開いた見出しのまま出す
    live |> element(~s(li[phx-value-title="元の見出し"])) |> render_click()
    html = render_async(live)
    refute html =~ "見当たりませんでした"
    assert html =~ "図の作品の説明"
    # 公開日の代わりに、図のタグの公開年・監督・主演
    assert html =~ "1980年 公開"
    assert html =~ "監督: ある監督"
    assert html =~ "主演: 主演A・主演B"
  end
end
