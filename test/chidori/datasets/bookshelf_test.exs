defmodule Chidori.Datasets.BookshelfTest do
  @moduledoc """
  定番の技術書（記事のタグから機械で作る本棚）。

  見ているのは **数を AI に触らせていないこと**と、**整える仕事だけを頼んでいること**です。
  """

  use ExUnit.Case, async: true

  alias Chidori.Chiezo
  alias Chidori.Datasets.Bookshelf
  alias Chidori.Datasets.Books

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

  describe "整理の回" do
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

    test "分野の語彙は Chidori が持つ" do
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

    test "機械収集の回は AI を呼ばない", %{sweeps: sweeps} do
      # 機械がタグを数えるだけ
      assert sweeps["機械収集"].use_extract
      refute Map.has_key?(sweeps["機械収集"], :prompt)
    end

    test "整理の回だけが依頼文を持つ", %{sweeps: sweeps} do
      assert sweeps["整理"].prompt =~ "本棚を整えます"
    end

    test "記事の収集とは別の溜め先", %{attrs: attrs} do
      # 同じ収集に置くと、記事とタグが混ざる
      assert attrs.name != Books.collection()
    end
  end

  describe "本棚に並べる" do
    defp book(title, extra, tags \\ ["技術書"]) do
      Bookshelf.to_book(%{"title" => title, "tags" => tags, "opening" => "説明", "extra" => extra})
    end

    test "おすすめ度（勧めている記事の本数）の高い順に並べる" do
      books =
        Bookshelf.ranked([
          book("本:少ない", %{"docs" => 2}),
          book("本:多い", %{"docs" => 9}),
          book("本:同じ数で直近が多い", %{"docs" => 2, "docs_recent" => 1})
        ])

      assert Enum.map(books, & &1.name) == ["多い", "同じ数で直近が多い", "少ない"]
    end

    test "見出しの「本:」は外し、分野と定番の印を読む" do
      b = book("本:リーダブルコード", %{"docs" => 3}, ["技術書", "分野:設計・アーキテクチャ"])

      assert b.name == "リーダブルコード"
      assert b.fields == ["設計・アーキテクチャ"]
      assert b.classic
      refute book("本:x", %{"docs" => 2}).classic
    end

    test "ISBN を 13 桁に揃えて持つ（表紙は `with_covers/1` が付ける）" do
      b = book("本:リーダブルコード", %{"docs" => 3, "isbn" => "978-4-87311-565-8"})

      assert b.oreilly
      assert b.isbn == "9784873115658"
    end

    test "チェックディジットが合わない ISBN は使わない" do
      # AI が書いた番号なので、1 桁違いで別の本の表紙が出るのを止める
      assert book("本:x", %{"isbn" => "9784873115659"}).isbn == nil
    end

    test "10 桁の ISBN は 13 桁に直す" do
      assert Bookshelf.isbn13("4873115655") == "9784873115658"
      assert Bookshelf.isbn13("4-87311-565-X") == nil
    end

    test "技術書でない本は、説明を書いて残さずに墓標で外させる" do
      prompt = Bookshelf.tidy_prompt()
      assert prompt =~ "技術書でない本も同じく外します"
      assert prompt =~ "小説・漫画"
      assert prompt =~ "まだ調べていなくても外してください"
      assert prompt =~ "下の 1〜4 を書かずに墓標を付けてください"
      assert Bookshelf.focus_prompt() =~ "小説・漫画"
    end

    test "整理の回に ISBN を調べさせる" do
      assert Bookshelf.tidy_prompt() =~ ~s("isbn")
    end

    test "ISBN はタグからも読む（脇書きが先）" do
      # 全冊を見る差し込み口は見出しとタグしか見せないので、番号をタグにも付けさせている
      assert book("本:x", %{}, ["技術書", "ISBN:9784873115658"]).isbn == "9784873115658"
      assert book("本:x", %{}, ["技術書", "ISBN:不明"]).isbn == nil

      assert book("本:x", %{"isbn" => "9784873115658"}, ["技術書", "ISBN:9784297146221"]).isbn ==
               "9784873115658"
    end

    test "整理の 1 回に渡す冊数は Chiezo が決め、渡した本は全部調べさせる" do
      # 一度に全部を渡していた頃は、164 冊を渡した回で AI が先頭の 18 冊だけ返した
      tidy = Enum.find(Bookshelf.sweeps(), &(&1[:prompt] == :tidy))
      assert tidy.unreviewed_per_run == Bookshelf.tidy_per_run()
      # 有効にした直後に、空の本棚を整理させない
      assert tidy.after == "機械収集"

      # 20 冊ずつなので、勧めている記事の多い本（機械が数えた extra.docs）から仕上げる
      assert tidy.unreviewed_by == "docs"

      prompt = Bookshelf.tidy_prompt()
      assert prompt =~ "#{Bookshelf.tidy_per_run()} 冊まで"
      assert prompt =~ "**並んだ本はすべて**"
      # 確かめられなかった本は印を付けて、毎回は調べ直さない
      assert prompt =~ "ISBN:不明"
      # 返すと丸ごと置き換わるので、分野や話題のタグを残させる
      assert prompt =~ "いま付いているタグをすべて残したうえで"
    end

    test "調べるのは、まだ調べていない本だけ（畳むのは書名の一覧で）" do
      # 全部を渡していた頃は、調べ終えた本も見つからなかった本も毎回調べ直していた
      prompt = Bookshelf.tidy_prompt()
      assert prompt =~ "{unreviewed}"
      assert prompt =~ "{names}"
      refute prompt =~ "{current}"
    end

    test "タグは数を決めずに付けさせる（技術ニュースのトピックに縛らない）" do
      prompt = Bookshelf.tidy_prompt()
      assert prompt =~ "付けるべきだと思う語を\nすべて"
      refute prompt =~ "1〜3"
      refute prompt =~ "chidori_tech_topics"
    end

    test "話題のタグを読み、興味トピックに近い本に印を付ける" do
      near = Chidori.Themes.Search.near_map([], ["画像生成"])

      [b, other] =
        Bookshelf.with_interests(
          [
            book("本:x", %{"docs" => 2}, ["技術書", "話題:画像 生成"]),
            book("本:y", %{"docs" => 2}, ["技術書", "話題:Kubernetes"])
          ],
          near
        )

      assert b.topics == ["画像 生成"]
      assert b.near == ["画像生成"], "表記ゆれ（空白）でも当たる"
      assert other.near == []
    end

    test "整理の回には、見出しを変えずに返させる" do
      # 変えると別の本として足され、元の本は直らない（本番で 14 冊そうなった）
      prompt = Bookshelf.tidy_prompt()
      assert prompt =~ "いまの見出しを一字も変えずに"
      assert prompt =~ "「本:」で始まらない見出し"
    end
  end

  describe "買う口" do
    test "オライリー・ジャパンの本は公式の頁、原書は本家の検索、それ以外は Kindle ストアの検索" do
      japan =
        Bookshelf.to_book(%{
          "title" => "本:a",
          "extra" => %{"docs" => 2, "isbn" => "9784873115658"}
        })

      assert japan.store_label == "O'Reilly"
      assert japan.store_url == "https://www.oreilly.co.jp/books/9784873115658/"

      original =
        Bookshelf.to_book(%{
          "title" => "本:b",
          "extra" => %{"docs" => 2, "isbn" => "9781098148621"}
        })

      assert original.store_url == "https://www.oreilly.com/search/?q=9781098148621"

      other = Bookshelf.to_book(%{"title" => "本:テスト駆動開発", "extra" => %{"docs" => 2}})
      assert other.store_label == "Kindle"
      assert other.store_url =~ "https://www.amazon.co.jp/s?"

      assert URI.decode_query(URI.parse(other.store_url).query) ==
               %{"k" => "テスト駆動開発", "i" => "digital-text"}
    end
  end

  describe "oreilly_isbn?/1" do
    test "オライリーの出版者記号（日本と原書）だけを見分ける" do
      assert Bookshelf.oreilly_isbn?("9784873115658")
      assert Bookshelf.oreilly_isbn?("9784814400744")
      assert Bookshelf.oreilly_isbn?("9781098148621")
      refute Bookshelf.oreilly_isbn?("9784297146221")
      refute Bookshelf.oreilly_isbn?(nil)
    end
  end
end
