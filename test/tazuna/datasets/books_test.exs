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

    test "人気順は 3 ページまで引く", %{feed: feed} do
      # 定番の推薦記事は 2〜3 ページ目に集まっている
      pages = for one <- feed.urls, one.url =~ "sort=popular", do: one.url
      assert Enum.any?(pages, &(&1 =~ "page=3"))
    end

    test "人気順と新着順を両方引く", %{feed: feed} do
      # 定番の根拠は何年も前の記事にある —— 新着だけを追っても永遠に届かない
      # （実測で、人気順なら 2022〜2024 年の記事がブクマ 1,000 超えの順に出る）
      urls = Enum.map(feed.urls, & &1.url)

      assert Enum.any?(urls, &(&1 =~ "sort=popular"))
      assert Enum.any?(urls, &(&1 =~ "sort=recent"))
    end

    test "検索文は差し込み口にして、Chiezo が回ごとに入れる", %{feed: feed} do
      # 同じ検索文で引き直しても同じ記事が返るだけ。展開と控えは Chiezo の仕事
      for one <- feed.urls, do: assert(one.url =~ "{query}")
      assert feed.queries == Books.queries()
      assert feed.query_tag == Books.query_tag()
      # 1 つにつき 4 本なので、Chiezo の上限（40 本）に収まる数
      assert feed.per_run * length(feed.urls) <= 40
      # 受け取る数を Chiezo の天井の手前で切らない（1 本 40 件まで入る）
      assert feed.limit >= feed.per_run * length(feed.urls) * 40
    end

    test "本文ではなく見出しを探す", %{feed: feed} do
      # 本文検索は語をどこかに含む記事をゆるく拾い、163 件のうち本を勧めていたのは 5 件だった
      for one <- feed.urls, do: assert(one.url =~ "target=title")
    end

    test "使った検索文も、日が経てばまた使える", %{feed: feed} do
      # 二度と使えない形にすると、記事が増えたあとに同じ切り口で拾い直せない
      assert feed.reuse_days > 0
      assert Books.queries_prompt() =~ "#{feed.reuse_days} 日より前に使った検索文は、また使えます"
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
      assert Books.read_prompt() =~ "勧めている本・参考にした本だけ"
    end

    test "開けなかった記事は触らせない" do
      # 当て推量で本を並べると、根拠の無い数になる
      assert Books.read_prompt() =~ "開けなかった記事は触らないでください"
    end

    test "自分で探しに行かせない（記事を広げるのは検索文のほう）" do
      # 同じ有名な記事を毎回見つけ直しては URL で弾かれ、枠を食うだけだった
      refute Books.read_prompt() =~ "手元に無い記事を探す"
    end

    test "検索の印は消させない" do
      assert Books.read_prompt() =~ "「検索:」で始まるタグは消さずに残してください"
    end

    test "読ませるのは、まだ読んでいない記事だけ" do
      prompt = Books.read_prompt()

      assert prompt =~ "{unreviewed}"
      refute prompt =~ "{names}"
      refute prompt =~ "{current}"
    end

    test "宣伝と本を挙げていない記事は外させる" do
      assert Books.read_prompt() =~ "宣伝と本の紹介ページ"
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

    test "機械収集の回は、検索文を AI に考えさせてから機械で引く", %{sweeps: sweeps} do
      # 依頼文に `{queries}` があると、Chiezo がその巡回の相手に考えさせる
      assert sweeps["機械収集"].use_feed
      assert sweeps["機械収集"].prompt =~ "{queries}"
      refute Map.get(sweeps["機械収集"], :web)
      # Chiezo の時計で回す（tazuna は起こさない）
      assert Map.get(sweeps["機械収集"], :enabled, true)
      refute Map.has_key?(Books.definition(), :survey_plan_sweep)
    end

    test "検索文を考える相手も、画面で選んだものを載せる" do
      attrs = Books.attrs(%{"機械収集" => %{backend: "antigravity", model: nil}})
      pick = Enum.find(attrs.sweeps, &(&1.name == "機械収集"))

      assert pick.backend == "antigravity"
      assert pick.prompt =~ "{queries}"
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
