defmodule Tazuna.ThemesTest do
  @moduledoc """
  トピックの溜め方。見ているのは、**育てるのは Chiezo の側だということ**
  （材料は tazuna が作らない）と、**図の語彙が依頼文と読み取りで揃っていること**です。
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

    test "材料は、溜まった記事のほう" do
      # 配信元から引くと、整理の回が落とした宣伝や重複、付け直した重要度が
      # 効かないまま材料になる。トピックは「読むに値すると判じたもの」から育てる
      attrs = Themes.attrs(topic())

      assert attrs.material.source == "tazuna_tech"
      # 記事とまとめが混ざるので、種別のタグで絞る
      assert attrs.material.tag == "ニュース,記事"
    end

    test "巡回は、育てる回と整える回に分ける" do
      assert [grow, tidy] = Themes.sweeps(topic())

      assert grow.name == "育てる"
      assert tidy.name == "整える"
      # 育てるほうが高い頻度（整えるのは手元を読むだけの回）
      assert grow.interval_minutes < tidy.interval_minutes
    end
  end

  describe "依頼文" do
    test "育てる回は、記事といま持っているものを両方読む" do
      prompt = Themes.grow_prompt(topic())

      assert prompt =~ "{material}"
      assert prompt =~ "{current}"
      # 図の語彙をそのまま頼む（読む側と書かせる側が離れるとズレる）
      assert prompt =~ Themes.theme_tag()
      assert prompt =~ Themes.parent_tag()
      assert prompt =~ Themes.related_tag()
      assert prompt =~ Themes.field_tag()

      # 素材に無い話題を足させない（記事に出てこないトピックが図に増える）
      assert prompt =~ "素材に出てこない話題を足さないでください"

      # 手元の知識は自分で引ける（読むだけ。書き込みの道具は渡っていない）
      assert prompt =~ "読むだけ"
      # つながりは思いつきではなく、共起を数えて当たれる
      assert prompt =~ "doc_tags"
    end

    test "整える回は、記事を読まない" do
      # 畳むために毎回記事を読ませると、その回ぶんの枠が素材に消える
      prompt = Themes.tidy_prompt(topic())

      assert prompt =~ "{current}"
      refute prompt =~ "{material}"
      # 畳むには消す力が要る（墓標）
      assert prompt =~ Tazuna.Chiezo.tombstone_tag()
      assert prompt =~ "新しい話題をここで足さないでください"
    end
  end

  describe "読み取り" do
    test "上位・つながり・分野をタグから読む" do
      one =
        Themes.to_theme(%{
          "title" => "AIエージェント",
          "opening" => "道具を使う AI。",
          "tags" => [
            "トピック",
            "分野:AI",
            "親:AI",
            "関連:MCP:道具の口を決める規格",
            "関連:LLM"
          ]
        })

      assert one.field == "AI"
      assert one.parent == "AI"

      assert one.related == [
               %{to: "MCP", note: "道具の口を決める規格"},
               %{to: "LLM", note: ""}
             ]
    end
  end
end
