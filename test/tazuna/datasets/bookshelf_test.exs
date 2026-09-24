defmodule Tazuna.Datasets.BookshelfTest do
  @moduledoc """
  定番の技術書（記事のタグから機械で作る本棚）。

  見ているのは **数を AI に触らせていないこと**と、**整える仕事だけを頼んでいること**です。
  """

  use ExUnit.Case, async: true

  alias Tazuna.Chiezo
  alias Tazuna.Datasets.Bookshelf
  alias Tazuna.Datasets.Books

  describe "語の拾い方" do
    setup do
      %{spec: Bookshelf.extract_spec()}
    end

    test "記事の収集から、本のタグだけを拾う", %{spec: spec} do
      # 記事の種別も配信元の名前も本ではない
      assert spec.source == Books.collection()
      assert spec.of == "tags"
      assert spec.skip == ["^(?!#{Books.book_tag()}:)"]
    end

    test "1 本の記事にしか出てこない本は、まだ置かない", %{spec: spec} do
      # 記事が増えれば上がってくる（たまたま 1 人が挙げた本で棚が埋まらないように）
      assert spec.min_docs >= 2
    end

    test "一緒に挙げられている本も持つ", %{spec: spec} do
      assert spec.links > 0
    end
  end

  describe "整える回" do
    test "数には触らせない" do
      # 数えるのは機械。AI に数えさせると、その回の検索運で数が動く
      prompt = Bookshelf.tidy_prompt()

      assert prompt =~ "数は機械が数えています"
      assert prompt =~ "数を書き換えないでください"
    end

    test "言い換えを畳ませる" do
      prompt = Bookshelf.tidy_prompt()

      assert prompt =~ "言い換えを 1 つに畳む"
      assert prompt =~ Chiezo.tombstone_tag()
    end

    test "分野の語彙は tazuna が持つ" do
      prompt = Bookshelf.tidy_prompt()

      assert prompt =~ "新しい語は作らない"
      for field <- Bookshelf.fields_of_study(), do: assert(prompt =~ field)
    end

    test "迷ったものは触らせない" do
      # 間違って畳んだ本は、記事の側から上がってくるまで戻らない
      assert Bookshelf.tidy_prompt() =~ "迷ったものは触らないでください"
    end

    test "読むかどうかを決められる説明を書かせる" do
      assert Bookshelf.tidy_prompt() =~ "読むかどうかを決められること"
    end
  end

  describe "Chiezo へ送る設定" do
    setup do
      attrs = Bookshelf.attrs()
      %{attrs: attrs, sweeps: Map.new(attrs.sweeps, &{&1.name, &1})}
    end

    test "網羅として溜める", %{attrs: attrs} do
      assert attrs.kind == "stock"
    end

    test "拾う回は AI を呼ばない", %{sweeps: sweeps} do
      # 機械がタグを数えるだけ
      assert sweeps["拾う"].use_extract
      refute Map.has_key?(sweeps["拾う"], :prompt)
    end

    test "整える回だけが依頼文を持つ", %{sweeps: sweeps} do
      assert sweeps["整える"].prompt =~ "本棚を整えます"
    end

    test "記事の収集とは別の溜め先", %{attrs: attrs} do
      # 同じ収集に置くと、記事とタグが混ざる
      assert attrs.name != Books.collection()
    end
  end
end
