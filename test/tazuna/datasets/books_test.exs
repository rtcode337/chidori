defmodule Tazuna.Datasets.BooksTest do
  @moduledoc """
  技術書を勧めている**記事**の収集。見ているのは、**数の母数が動かないか**です。

  AI にその場で探させて数えさせると、同じ本が次の回では見つからず、数が増えたり
  戻ったりします。記事を溜めておけば、同じ材料からは同じ数が出ます。
  """

  use ExUnit.Case, async: true

  alias Tazuna.Datasets.Books

  describe "配信元" do
    setup do
      %{feed: Books.feed_spec()}
    end

    test "人気順と新着順を両方引く", %{feed: feed} do
      # 定番の根拠は何年も前の記事にある —— 新着だけを追っても永遠に届かない
      # （実測で、人気順なら 2022〜2024 年の記事がブクマ 1,000 超えの順に出る）
      urls = Enum.map(feed.urls, & &1.url)

      assert Enum.any?(urls, &(&1 =~ "sort=popular"))
      assert Enum.any?(urls, &(&1 =~ "sort=recent"))
    end

    test "人気順はページを繰る", %{feed: feed} do
      # 1 ページ 40 件。立ち上げの 1 周で過去を拾うため
      pages =
        feed.urls
        |> Enum.filter(&(&1.url =~ "sort=popular"))
        |> Enum.map(&(URI.parse(&1.url).query |> URI.decode_query() |> Map.get("page")))
        |> Enum.uniq()

      assert length(pages) > 1
    end

    test "語ごとに引く", %{feed: feed} do
      # 語を増やすと拾える範囲も増えるが、関係の薄い記事も混ざる
      assert length(Books.queries()) >= 3
      assert length(feed.urls) >= length(Books.queries())
    end

    test "http(s) だけ", %{feed: feed} do
      for one <- feed.urls, do: assert(one.url =~ ~r{\Ahttps://})
    end
  end

  describe "依頼文" do
    test "手元の記事を開いて、本をタグにさせる" do
      # 配信元が配るのは見出しと要約だけ —— どの本を勧めているかは開かないと分からない
      prompt = Books.read_prompt()

      assert prompt =~ "#{Books.book_tag()}:"
      assert prompt =~ "記事を開いて"
    end

    test "書名の表記を揃えさせる" do
      # ここが数える鍵。表記が割れると、同じ本が別々に数えられる
      prompt = Books.read_prompt()

      assert prompt =~ "邦題があれば邦題"
      assert prompt =~ "版や巻の数字は入れない"
    end

    test "勧めていない本は入れさせない" do
      assert Books.read_prompt() =~ "勧めている本だけ"
    end

    test "開けなかった記事は触らせない" do
      # 当て推量で本を並べると、根拠の無い数になる
      assert Books.read_prompt() =~ "開けなかった記事は触らないでください"
    end

    test "手元に無い記事も探させる" do
      # 社内ブログ・海外の記事・発表資料は配信元からは入ってこない
      prompt = Books.read_prompt()

      assert prompt =~ "手元に無い記事を探す"
      assert prompt =~ "社内ブログ"
    end

    test "宣伝は入れさせない" do
      assert Books.read_prompt() =~ "宣伝と本の紹介ページは入れないでください"
    end
  end

  describe "Chiezo へ送る設定" do
    setup do
      attrs = Books.attrs()
      %{attrs: attrs, sweeps: Map.new(attrs.sweeps, &{&1.name, &1})}
    end

    test "網羅として溜める", %{attrs: attrs} do
      # 2022 年の記事も根拠として生きている（期限で落とすと数が減る）
      assert attrs.kind == "stock"
    end

    test "機械収集の回は AI を呼ばない", %{sweeps: sweeps} do
      assert sweeps["機械収集"].use_feed
      refute Map.get(sweeps["機械収集"], :web)
    end

    test "整理の回は web を開ける", %{sweeps: sweeps} do
      # 記事を開かないと、どの本を勧めているかが分からない
      assert sweeps["整理"].web
      assert sweeps["整理"].prompt =~ "記事を開いて"
    end

    test "画面で選んだ相手を載せる" do
      attrs = Books.attrs(%{"整理" => %{backend: "codex", model: "gpt-6-sol-high"}})
      read = Enum.find(attrs.sweeps, &(&1.name == "整理"))

      assert read.backend == "codex"
    end
  end

  describe "画面に出す 1 タブぶん" do
    test "本棚を子として持つ" do
      # 別のタブにすると、何から作られたものかが読めなくなる
      d = Books.definition()

      assert d.key == "books"
      assert d.derived == Tazuna.Datasets.Bookshelf
      assert d.unit == "記事 1 本 1 文書"
    end

    test "数の元がどれかを出す" do
      assert Enum.any?(Books.fields(), &(&1.stored =~ Books.book_tag()))
    end
  end
end
