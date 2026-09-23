defmodule Tazuna.ThemesTest do
  @moduledoc """
  トピックの溜め方。見ているのは、**語を拾うのは機械だということ**（AI に思いつかせない）
  と、**図の語彙が依頼文と読み取りで揃っていること**です。
  """

  use ExUnit.Case, async: true

  alias Tazuna.Themes

  defp topic, do: Enum.find(Tazuna.Topics.list(), &(&1.collection == "tazuna_tech"))

  describe "収集の形" do
    test "網羅で、期限では落とさない" do
      # 記事と同じ収集に置くと、流れの期限でトピックまで消える
      attrs = Themes.attrs(topic())

      assert attrs.name == "tazuna_tech_topics"
      assert attrs.kind == "stock"
    end

    test "語は、記事のタグをそのまま拾う" do
      # AI に語を思いつかせると、記事に出てこない語が混ざり、同じ話題が回ごとに
      # 違う表記で増える —— 語そのものは手元の索引に入っている
      attrs = Themes.attrs(topic())

      assert attrs.extract.source == "tazuna_tech"
      assert attrs.extract.of == "tags"
      # 図に出す目印は機械が付ける
      assert attrs.extract.tags == [%{const: Themes.theme_tag()}]
    end

    test "話題でない語のうち、tazuna が決めているものは先に外す" do
      # 種別も重要度も話題度も、決めているのは tazuna。配信元の名前は書けない
      # （配信元が名乗るタイトルなので tazuna は知らない）—— あれは AI が外す
      skip = Themes.attrs(topic()).extract.skip

      assert "^_chiezo_" in skip
      assert "^#{Tazuna.News.importance_tag()}:" in skip
      assert Enum.any?(skip, &(&1 =~ "ニュース"))
    end

    test "時間軸は、直近の窓と一緒に出てくる語で持つ" do
      # 件数だけだと、昔よく出てきた語がいつまでも大きいままになる
      extract = Themes.attrs(topic()).extract

      assert extract.recent_days > 0
      assert extract.links > 0
      # 1 件しか付いていない語は、まだ話題かどうかも分からない
      assert extract.min_docs >= 2
    end

    test "巡回は、拾う回と整える回に分ける" do
      assert [pick, tidy] = Themes.sweeps(topic())

      # 拾う回は機械（AI を呼ばない）。足すだけと組にしないと、AI の説明を
      # 機械の 1 行で上書きする
      assert pick.name == "拾う"
      assert pick.use_extract
      assert pick.only_new
      refute Map.has_key?(pick, :prompt)

      assert tidy.name == "整える"
      # 拾うほうが高い頻度（AI を呼ばないので短い間隔で回せる）
      assert pick.interval_minutes < tidy.interval_minutes
    end
  end

  describe "依頼文" do
    test "整える回は、4 つの分け方だけを頼む" do
      # 語はもう機械が拾ってある。ここでやるのは精査だけ
      prompt = Themes.tidy_prompt(topic())

      assert prompt =~ "{current}"
      refute prompt =~ "{material}"
      # 図の語彙をそのまま頼む（読む側と書かせる側が離れるとズレる）
      assert prompt =~ Themes.theme_tag()
      assert prompt =~ Themes.parent_tag()
      assert prompt =~ Themes.field_tag()
      assert prompt =~ Themes.synonym_tag()
      # 畳むにも外すにも消す力が要る（墓標）
      assert prompt =~ Tazuna.Chiezo.tombstone_tag()
    end

    test "粒度が違うだけの語を、言い換えとして畳ませない" do
      # 畳むと片方が消える。粒度の違いは親子で表す
      assert Themes.tidy_prompt(topic()) =~ "粒度が違うだけの語は畳まないでください"
    end

    test "迷ったものは触らせずに、次の回へ送る" do
      # 間違って外した語は二度と入らない（同じ語が記事に付いても拾われない）
      prompt = Themes.tidy_prompt(topic())

      assert prompt =~ "迷ったら触らない"
      assert prompt =~ "外した語は二度と入りません"
    end

    test "新しい語をここで足させない" do
      # 語を拾うのは機械の回の仕事
      assert Themes.tidy_prompt(topic()) =~ "新しい語をここで足さないでください"
    end
  end

  describe "読み取り" do
    test "親と分野はタグから、数は脇書きから読む" do
      one =
        Themes.to_theme(%{
          "title" => "AIエージェント",
          "opening" => "道具を使う AI。",
          "tags" => ["トピック", "分野:AI", "親:AI"],
          "extra" => %{
            "docs" => 31,
            "docs_recent" => 12,
            "last_seen" => "2026-09-22",
            "links" => ["AI:18", "CodeZine:新着一覧:3"]
          }
        })

      assert one.field == "AI"
      assert one.parent == "AI"
      assert {one.docs, one.recent} == {31, 12}
      assert one.last_seen == "2026-09-22"

      # 語そのものに `:` が入りうるので、右端で割る
      assert one.related == [%{to: "AI", n: 18}, %{to: "CodeZine:新着一覧", n: 3}]
    end

    test "数が無いうちは、静かなものとして読む" do
      # 拾う回が 1 度も走っていない間は脇書きが空（読めないだけで、壊れではない）
      one = Themes.to_theme(%{"title" => "AI", "opening" => "", "tags" => ["トピック"]})

      assert {one.docs, one.recent, one.related} == {0, 0, []}
    end
  end
end
