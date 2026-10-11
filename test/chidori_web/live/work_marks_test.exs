defmodule ChidoriWeb.WorkMarksTest do
  @moduledoc """
  映画・アニメの作品に付ける「見た」記録。見ているのは、**作品の詳細に記録の欄を出すこと**、
  **見た作品には見出しの横に印が付くこと**、**作品ごとに種類を分けて残すこと**です。
  """

  use ChidoriWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Chidori.Relations.Marks
  alias ChidoriWeb.NewsLive

  @entry %{title: "サンプル映画", date: ~D[2026-10-10], summary: "", tags: [], extra: %{}}

  test "詳細に見た記録の欄を出し、付いている印を読む" do
    {:ok, mark} = Marks.put("movies", "サンプル映画", %{"seen" => true, "seen_on" => "2026-10-11"})

    html =
      render_component(&ChidoriWeb.WorkModal.work_body/1,
        entry: @entry,
        works: Chidori.News.Movies,
        marks: %{"サンプル映画" => mark}
      )

    assert html =~ "見た記録"
    assert html =~ "見た（2026-10-11）"
    assert html =~ ~s(phx-submit="save_work_mark")
  end

  test "印を渡さなければ欄を出さない（映画・アニメ以外）" do
    html =
      render_component(&ChidoriWeb.WorkModal.work_body/1,
        entry: @entry,
        works: Chidori.News.Movies
      )

    refute html =~ "見た記録"
  end

  test "映画とアニメで種類を分けて残す（同じ題でも混ざらない）" do
    {:ok, _} = Marks.put(Chidori.News.Movies.mark_view(), "同じ題", %{"seen" => true})

    assert NewsLive.seen_work?(Marks.for_view("movies"), "同じ題")
    refute NewsLive.seen_work?(Marks.for_view("anime"), "同じ題")
    refute NewsLive.seen_work?(nil, "同じ題")
  end
end
