defmodule Chidori.News.ReportTest do
  @moduledoc """
  まとめの本文の読み分け。見ているのは 3 つ ——
  要旨を本文と分けて取り出せること、決めた記法だけを読むこと、
  そして以前の形で溜まったまとめも読めることです。
  """

  use ExUnit.Case, async: true

  alias Chidori.News.Report

  @body """
  ## 要旨
  この期間は基盤の入れ替えが続きました。
  移行の判断が要るのは 1 つだけです。

  ## 新しい版
  新しい版が出ました。**急ぐのは 1 件**だけです。
  - 影響は限定的
  - 既定は変わらない

  | 版 | 対応 |
  | --- | --- |
  | 19.3 | 済み |

  > 期限はまだ決まっていません。
  出典: [React 19.3 が出た](https://example.com/1)

  ## 次に見るもの
  続報を待ちます。詳細は[告知](https://example.com/2)にあります。
  """

  describe "読み分け" do
    test "要旨は、章に混ぜない" do
      # 画面では導入として別に描き、通知にはここだけを流す
      document = Report.document(@body)

      assert Report.to_text(document.summary) ==
               "この期間は基盤の入れ替えが続きました。移行の判断が要るのは 1 つだけです。"

      assert Enum.map(document.sections, & &1.title) == ["新しい版", "次に見るもの"]
    end

    test "段落・箇条書き・表・注記・出典に割る" do
      [section | _] = Report.document(@body).sections

      assert [
               {:paragraph, _},
               {:list, [_, _]},
               {:table, [_, _], [[_, _]]},
               {:note, _},
               {:source, "https://example.com/1", "React 19.3 が出た"}
             ] = section.blocks
    end

    test "強調と文字つきリンクは、描ける一片に割る" do
      # 素の HTML を渡せる道は作らない（本文を書くのは AI なので）
      assert Report.inline("新しい版が出ました。**急ぐのは 1 件**だけです。") == [
               {:text, "新しい版が出ました。"},
               {:strong, "急ぐのは 1 件"},
               {:text, "だけです。"}
             ]

      assert Report.inline("詳細は[告知](https://example.com/2)にあります。") == [
               {:text, "詳細は"},
               {:link, "https://example.com/2", "告知"},
               {:text, "にあります。"}
             ]
    end

    test "本文の途中の URL は、出典にしない" do
      # 出典は行を立てて書かせている。文中の URL まで出典に数えると、
      # 出典一覧が本文の引用で埋まる
      [%{blocks: blocks}] = Report.document("## 章\n詳細は https://example.com/3 にあります。").sections

      assert [{:paragraph, parts}] = blocks
      assert {:link, "https://example.com/3", _} = Enum.at(parts, 1)
    end

    test "URL を書けなかった出典も、本文の段落にしない" do
      # 元の記事に URL が無いと「出典: 記載なし」の形で返ってくる。落とさずに、
      # 出典として出す（読み物の途中に断り書きが紛れ込まないように）
      [%{blocks: blocks}] = Report.document("## 章\nそうなりました。\n出典: 記事URLの記載なし").sections

      assert [{:paragraph, _}, {:source_note, "出典: 記事URLの記載なし"}] = blocks
    end

    test "出典は、本文に出てきた順で重複を落とす" do
      document = Report.document(@body <> "\n## もう1つ\n同じ話です。\n出典: https://example.com/1\n")

      assert Report.sources(document) == [
               %{url: "https://example.com/1", label: "React 19.3 が出た"}
             ]
    end

    test "見出しの無い出典も、URL だけで読む" do
      # 見出しを書かせる前に溜まったまとめは、裸の URL のまま入っている
      [%{blocks: blocks}] = Report.document("## 章\nそうなりました。\n出典: https://example.com/9").sections

      assert [{:paragraph, _}, {:source, "https://example.com/9", nil}] = blocks
    end
  end

  describe "以前の形" do
    # 溜まったまとめは書き換わらない。読めなくすると、既にあるまとめが
    # 1 つの塊になって出る
    @old """
    この期間は基盤の入れ替えが続きました。

    React の新版
    新しい版が出ました。
    出典: https://example.com/1
    """

    test "空行で区切った塊の 1 行目を、小見出しにする" do
      document = Report.document(@old)

      assert Report.to_text(document.summary) == "この期間は基盤の入れ替えが続きました。"
      assert [%{title: "React の新版", blocks: blocks}] = document.sections
      assert [{:paragraph, _}, {:source, "https://example.com/1", nil}] = blocks
    end

    test "1 行だけの塊は、小見出しにしない" do
      # 導入は 1 行だけの塊。見出しにすると、書き出しが見出しとして出る
      assert Report.document("この期間の動きです。").sections == []
    end
  end

  describe "通知へ流す文" do
    test "飾りを落として、URL はそのまま残す" do
      # ntfy は Markdown として描かないので、記号はそのまま出る。
      # URL は ntfy が自分でリンクにするので、文字に差し替えない
      text =
        @body
        |> Report.document()
        |> Map.fetch!(:sections)
        |> hd()
        |> Map.fetch!(:blocks)
        |> Report.to_text()

      refute text =~ "**"
      assert text =~ "急ぐのは 1 件"
      assert text =~ "・影響は限定的"
      assert text =~ "https://example.com/1"
    end
  end
end
