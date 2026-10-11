defmodule ChidoriWeb.AskNearbyTest do
  @moduledoc """
  映画の詳細の「近くの上映館を Gemini に聞く」。見ているのは、**公開中かもうすぐの映画だけに出ること**、
  **Google 検索の AI モード（`udm=50`）に質問文を渡すこと**、**地域を書けばその近く、
  空なら現在地を添えること**です。
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ChidoriWeb.NewsLive

  @entry %{title: "サンプル映画", date: Chidori.Jst.today(), summary: "", tags: [], extra: %{}}

  test "映画の詳細に、地域の欄と AI モードで開くリンクを出す" do
    html =
      render_component(&ChidoriWeb.WorkModal.work_body/1,
        entry: @entry,
        works: Chidori.News.Movies
      )

    assert html =~ "近くの上映館を Gemini に聞く"
    assert html =~ ~s(phx-hook="AskNearby")
    assert html =~ "https://www.google.com/search?"
    assert html =~ "udm=50"
    # 地域を書けばその近くを聞く（置き換えるのはブラウザの側）
    assert html =~ "地域（空なら現在地）"
    assert html =~ "data-region-question="
    assert html =~ "{region}の近くにあるところ"
  end

  test "公開が 1 週間より先の作品には出さない（まだどこも上映していない）" do
    today = ~D[2026-10-10]

    assert NewsLive.showing_soon?(%{date: ~D[2026-09-01]}, today)
    assert NewsLive.showing_soon?(%{date: ~D[2026-10-17]}, today)
    refute NewsLive.showing_soon?(%{date: ~D[2026-10-18]}, today)
    refute NewsLive.showing_soon?(%{date: nil}, today)
  end

  test "アニメの詳細には出さない" do
    html =
      render_component(&ChidoriWeb.WorkModal.work_body/1,
        entry: @entry,
        works: Chidori.News.Anime
      )

    refute html =~ "近くの上映館"
  end

  test "質問文に作品名と今日の日付を入れ、地域か現在地が分かれば添える" do
    question = NewsLive.theaters_question("サンプル映画")

    assert question =~ "映画「サンプル映画」"
    assert question =~ "いまいる場所から近い"
    assert question =~ Date.to_iso8601(Chidori.Jst.today())

    assert NewsLive.theaters_question("サンプル映画", "35.6812,139.7671") =~
             "現在地（35.6812,139.7671）から近い"

    assert NewsLive.theaters_question("サンプル映画", {:region, "新宿"}) =~
             "新宿の近くにあるところを教えてください"

    assert %{"udm" => "50", "q" => q} =
             NewsLive.theaters_url("サンプル映画")
             |> URI.parse()
             |> Map.get(:query)
             |> URI.decode_query()

    assert q == question
  end
end
