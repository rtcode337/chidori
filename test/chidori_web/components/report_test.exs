defmodule ChidoriWeb.ReportTest do
  @moduledoc """
  まとめの描き方。見ているのは、読み物として組めていること ——
  要旨が先に出ること、章に番号が付くこと、出典が記事の見出しでリンクになることです。
  """

  use ChidoriWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @body """
  ## 要旨
  この期間は基盤の入れ替えが続きました。

  ## 新しい版
  新しい版が出ました。**急ぐのは 1 件**だけです。
  - 影響は限定的

  | 版 | 対応 |
  | --- | --- |
  | 19.3 | 済み |

  > 期限はまだ決まっていません。
  出典: [React 19.3 が出た（まとめが書いた見出し）](https://example.com/1)

  ## 次に見るもの
  続報を待ちます。
  """

  defp rendered(assigns \\ []) do
    assigns =
      Keyword.merge(
        [
          title: "まとめ: 基盤の入れ替えが続いた（2026-09-15 01:00）",
          at: "2026-09-15 01:00",
          body: @body,
          label: "技術ニュース",
          articles: [
            %{
              url: "https://example.com/1",
              title: "React 19.3 が出た",
              image: "https://example.com/1.png"
            }
          ]
        ],
        assigns
      )

    render_component(&ChidoriWeb.Report.report/1, assigns)
  end

  test "要旨・章・表・注記を、それぞれの見た目で出す" do
    html = rendered()

    assert html =~ "report-summary"
    assert html =~ "この期間は基盤の入れ替えが続きました。"
    assert html =~ "report-number"
    assert html =~ "新しい版"
    # 開発では phx-r などの印が属性に付くので、閉じ側で見る
    assert html =~ "急ぐのは 1 件</strong>"
    assert html =~ "report-list"
    assert html =~ "report-table"
    assert html =~ "report-note"
  end

  test "章が 2 つ以上あるときだけ、目次を出す" do
    # 1 つしかない目次は、見出しの重複でしかない
    assert rendered() =~ "report-toc"
    refute rendered(body: "## 要旨\n動きがありました。") =~ "report-toc"
  end

  test "出典は、見出しでリンクになる" do
    # 裸の URL のままだと、押す前にどこへ行くのか読めない
    html = rendered()

    assert html =~ "digest-source"
    assert html =~ ~s|href="https://example.com/1"|

    # まとめが書いた見出しを使う（溜まっている記事の見出しより、その文脈で選ばれたもの）
    assert html =~ "まとめが書いた見出し"
    assert html =~ "report-refs"
  end

  test "見出しが書かれていなければ、溜まっている記事の見出しを使う" do
    html = rendered(body: "## 章\nそうなりました。\n出典: https://example.com/1")

    assert html =~ "React 19.3 が出た"
  end

  test "章には、引いた記事の絵を 1 枚だけ添える" do
    # 絵を持っているのは配信元が配っているものだけ。まとめの側は絵を持たない
    html = rendered()

    assert html =~ "report-figure"
    assert html =~ ~s|src="https://example.com/1.png"|
    assert length(String.split(html, "report-figure")) - 1 == 1
  end

  test "絵の無い記事しか引いていなければ、絵は出さない" do
    html =
      rendered(articles: [%{url: "https://example.com/1", title: "React 19.3 が出た", image: nil}])

    refute html =~ "report-figure"
  end

  test "溜まっている記事に無い出典も、消さずに出す" do
    # AI が上に無いものを書いたときに、黙って消さない
    html = rendered(articles: [])

    assert html =~ "https://example.com/1"
  end

  test "本文の記号は、そのまま出さない" do
    # 画面は Markdown として描く場所なので、記号が残っていたら読み分けに失敗している
    html = rendered()

    refute html =~ "## "
    refute html =~ "**急ぐ"
    refute html =~ "| --- |"
  end

  describe "映画の要約の、近くの上映館のリンク" do
    test "章で紹介した作品ごとに、上映館を聞くリンクを添える" do
      html = rendered(ask_theaters: true)

      assert html =~ "近くの上映館を Gemini に聞く"
      assert html =~ ~s(phx-hook="AskNearby")
      assert html =~ "udm=50"
    end

    test "映画の要約でなければ添えない" do
      refute rendered() =~ "近くの上映館"
    end

    test "見出しの無い出典（作品として引けなかったもの）は数えない" do
      known = %{"https://example.com/1" => %{title: "作品A"}, "https://example.com/2" => %{}}

      blocks = [
        {:source, "https://example.com/1", "A"},
        {:source, "https://example.com/2", "B"},
        {:source, "https://example.com/1", "A"},
        {:paragraph, [{:text, "本文"}]}
      ]

      assert ChidoriWeb.Report.work_titles(blocks, known) == ["作品A"]
    end
  end
end
