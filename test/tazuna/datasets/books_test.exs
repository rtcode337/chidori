defmodule Tazuna.Datasets.BooksTest do
  @moduledoc """
  定番の技術書。見ているのは **「良い本」ではなく「勧められている数」で決めているか**です。

  AI に良し悪しを聞くと、学習に多く出てくる名前が並ぶだけで、**なぜその本なのかを
  後から確かめられません**（出どころが無いので、間違っていても気づけない）。
  """

  use ExUnit.Case, async: true

  alias Tazuna.Chiezo
  alias Tazuna.Datasets.Books

  describe "依頼文" do
    test "本ではなく、勧めている記事を探させる" do
      prompt = Books.hunt_prompt()

      assert prompt =~ "勧めている記事を探す"
      assert prompt =~ "本を思い出すのではなく"
      assert prompt =~ "URL"
    end

    test "根拠の無い 1 冊は入れさせない" do
      # 出どころを示せない本が混ざると、数で並べる意味がそこで壊れる
      assert Books.hunt_prompt() =~ "出どころの URL を示せない本は"
      assert Books.hunt_prompt() =~ "心当たりが無ければ、足さなくて構いません"
    end

    test "分野の語彙は tazuna が持つ" do
      # AI に決めさせると回ごとに表記が割れ、区画（＝分野）が毎回作り直される
      prompt = Books.hunt_prompt()

      assert prompt =~ "新しい語は作らない"

      for field <- Books.fields_of_study() do
        assert prompt =~ field
      end
    end

    test "定番と候補は数で分ける" do
      for prompt <- [Books.hunt_prompt(), Books.tidy_prompt()] do
        assert prompt =~ Books.classic_tag()
        assert prompt =~ Books.candidate_tag()
        assert prompt =~ "#{Books.classic_sources()}"
      end

      # **あなたの評価では決めないでください** —— ここが崩れると収集の意味が無くなる
      assert Books.tidy_prompt() =~ "あなたの評価では決めないで"
    end

    test "整える回は数を数え直す" do
      # AI が書いた数と、並んでいる URL の数が食い違うと、並びが嘘になる
      assert Books.tidy_prompt() =~ "extra.sources"
      assert Books.tidy_prompt() =~ "同じ"
    end

    test "出どころは消させない" do
      # ここが数の根拠。消すと「なぜ定番なのか」を誰も確かめられない
      assert Books.tidy_prompt() =~ "出どころの URL は消さないでください"
    end

    test "消すのは墓標で" do
      assert Books.tidy_prompt() =~ Chiezo.tombstone_tag()
    end
  end

  describe "Chiezo へ送る設定" do
    setup do
      attrs = Books.attrs()
      %{attrs: attrs, sweeps: Map.new(attrs.sweeps, &{&1.name, &1})}
    end

    test "網羅として溜める", %{attrs: attrs} do
      # 定番はむしろ古い。期限で落とすと、この収集は成り立たない
      assert attrs.kind == "stock"
    end

    test "区画は分野で切る", %{attrs: attrs} do
      # 全部を一度に見ると、毎回同じ有名どころを挙げて終わる
      assert attrs.partition.by == "tag"
      assert attrs.partition.prefix == "#{Books.field_tag()}:"
    end

    test "探す回だけ外を当たる", %{sweeps: sweeps} do
      # 整える回は手元のものを畳むだけ（外を当たる理由が無い）
      assert sweeps["探す"].web
      refute Map.get(sweeps["整える"], :web)
    end

    test "巡回ごとに依頼文を持つ", %{sweeps: sweeps} do
      # 1 つの文で全部を頼むと、どの回も同じ薄さの仕事になる
      assert sweeps["探す"].prompt =~ "勧めている記事を探す"
      assert sweeps["整える"].prompt =~ "同じ本を 1 つにまとめる"
    end

    test "画面で選んだ相手を載せる", %{attrs: _attrs} do
      attrs = Books.attrs(%{"探す" => %{backend: "codex", model: "gpt-6-sol-high"}})
      hunt = Enum.find(attrs.sweeps, &(&1.name == "探す"))

      assert hunt.backend == "codex"
      assert hunt.model == "gpt-6-sol-high"
    end
  end

  describe "画面に出す 1 タブぶん" do
    test "読む相手と単位を持つ" do
      # 文面を画面に決め打つと、対象を足すたびに食い違う
      d = Books.definition()

      assert d.key == "books"
      assert d.reader != ""
      assert d.unit == "1 冊 1 文書"
      assert d.partition_sweeps == ["探す", "整える"]
    end

    test "どの項目が誰から来るかを出す" do
      fields = Books.fields()

      assert Enum.any?(fields, &(&1.stored =~ "extra.sources"))
      # **数は AI が数えたものではなく、並べた URL の数**
      assert Enum.any?(fields, &(&1.who =~ "URL の数"))
    end
  end
end
