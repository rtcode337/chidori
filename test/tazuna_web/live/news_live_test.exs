defmodule TazunaWeb.NewsLiveTest do
  use TazunaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # 収集の入れ物は話題ごとに 1 つで、テストをまたいで生き残る。
  # **前のテストで読めた状態が次のテストに漏れる**ので、毎回まっさらから始める
  setup do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Tazuna.News.Supervisor) do
      DynamicSupervisor.terminate_child(Tazuna.News.Supervisor, pid)
    end

    :ok
  end

  test "最新情報のページを表示する", %{conn: conn} do
    # 最初に開くのは定義の先頭の話題（いまは技術ニュース）
    {:ok, _live, html} = live(conn, ~p"/news")

    assert html =~ "今日、押さえておきたい技術ニュース"
    # 集めるのは Chiezo だと画面から読めること
    assert html =~ "集めるのは Chiezo です"
  end

  test "Chiezo が未設定なら、その旨を出して依頼を押させない", %{conn: conn} do
    System.delete_env("CHIEZO_BASE_URL")

    {:ok, _live, html} = live(conn, ~p"/news")

    assert html =~ "CHIEZO_BASE_URL"
    # 押す口は枠の中の 1 つだけ（関連図と同じ形）
    assert html =~ "収集を依頼する"
    assert html =~ "disabled"
  end

  test "押す口は 1 つだけ", %{conn: conn} do
    # ボタンを役割ごとに並べていた頃は、どれを押せば何が起きるのかが押す前に
    # 読めなかった（しかも走らせる口が混ざっていた）
    {:ok, _live, html} = live(conn, ~p"/news")

    refute html =~ "いま集めさせる"
    refute html =~ "AI に選ばせる"
    refute html =~ "読み直す"
  end

  test "頼んでいる内容が画面から読める", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/news")

    assert html =~ "Chiezo への依頼文"
    # まだ依頼していないので、これから送る雛形が出る
    assert html =~ "next_cursor"
    assert html =~ "この内容で Chiezo に頼みます"
  end

  test "巡回ごとの依頼文が読める", %{conn: conn} do
    # 回ごとに頼むことが違うので、1 つの文だけを出すと実際と食い違う
    {:ok, _live, html} = live(conn, ~p"/news")

    assert html =~ "漏れ探し"
    assert html =~ "要約"
  end

  describe "Chiezo の収集の枠" do
    @collection %{
      "name" => "tazuna_news",
      "description" => "tazuna のニュース",
      "enabled" => true,
      "interval_minutes" => 360,
      "kind" => "flow",
      "keep_days" => 30,
      "prompt" => "{cursor} 以降のニュース。{recent}",
      "sweeps" => [
        %{"name" => "見出し", "interval_minutes" => 60, "use_feed" => true, "enabled" => true},
        %{"name" => "集める", "interval_minutes" => 360, "enabled" => true},
        %{"name" => "要約", "interval_minutes" => 720, "enabled" => true}
      ]
    }

    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")

      Tazuna.HttpStub.stub(fn
        %{url: "http://chiezo.test:7010/v1/ai/backends"} ->
          Tazuna.HttpStub.ok(~s({"backends":[]}))

        %{url: "http://chiezo.test:7010/v1/sources"} ->
          Tazuna.HttpStub.ok(Jason.encode!(%{"sources" => []}))

        %{url: "http://chiezo.test:7010/v1/collect"} ->
          Tazuna.HttpStub.ok(Jason.encode!(%{"collections" => [@collection]}))

        %{url: _detail} ->
          Tazuna.HttpStub.ok(
            @collection
            |> Map.put("recent", [
              %{
                "title" => "まとめ: 今日の動き（2026-09-13）",
                "opening" => "この期間は基盤の入れ替えが続きました。\n出典: https://example.com/1",
                "tags" => ["まとめ"]
              },
              %{
                "title" => "React 19.3 が出た",
                "opening" => "要約",
                "tags" => ["ニュース"],
                "extra" => %{"url" => "https://example.com/1"}
              },
              %{"title" => "ふつうの記事", "opening" => "要約", "tags" => ["ニュース"]}
            ])
            |> Jason.encode!()
          )
      end)

      :ok
    end

    # 収集の状態は非同期に届く。**届いたことを待ってから見る** ——
    # 待たずに見ると、まだ読めていない画面を見ていることになる
    defp shown(conn) do
      Tazuna.News.subscribe("tazuna_news")

      # **話題は名指しで開く。** 既定の話題に寄りかかると、タブの並びを変えただけで
      # 落ちる —— ここで見たいのは収集の枠であって、どれが先頭かではない
      {:ok, live, _html} = live(conn, ~p"/news?view=tazuna_news")
      assert_receive {:news_updated, %{status: :ready}}, 2_000
      render(live)
    end

    test "巡回ごとに 1 行出て、相手を選んで送れる", %{conn: conn} do
      html = shown(conn)

      # **相手も進み具合も巡回ごとに違う**ので、収集に 1 つだけ出すと読めない
      assert html =~ "sweep-table"
      assert html =~ "収集の設定を更新"
      assert html =~ ~s(name="sweep|要約|backend")

      # 定時の巡回とは別に頼める口。**どの回として走るかを押す前に読める** ——
      # 落とす力と印を付け直す力を持つのは情報更新の回だけなので、
      # そこへ乗ることが分からないと「落として」を頼めるのかが読めない
      assert html =~ "いま頼む（割り込み）"
      assert html =~ "走るのは「情報更新」の設定です"
    end

    test "機械で引く巡回には相手を選ばせない", %{conn: conn} do
      # 選んでも何も起きない —— その回は AI を呼ばずに返すので、相手もモデルも
      # 読まれない。**選べるのに効かない欄は「設定したつもり」を作る**
      html = shown(conn)

      refute html =~ ~s(name="sweep|見出し|backend")
      assert html =~ "AI を使いません"
    end

    test "収集の状態は、関連図と同じ並びで出す", %{conn: conn} do
      # 画面ごとに書いていた頃は、見出しも並びも食い違っていた
      html = shown(conn)

      assert html =~ "状態"
      assert html =~ "集め方"
      assert html =~ "溜まった数"

      # **言い方は収集の種類から出す。** 流れ（ニュース）と網羅（画家の名簿）は
      # そもそも別のことをしているので、同じ言い方になるほうがおかしい
      assert html =~ "流れを追う"
      refute html =~ "整理する（磨いていく）"
    end

    test "まとめの出典は、記事の見出しでリンクになる" do
      # 裸の URL のままだと、押す前にどこへ行くのか読めない
      articles = [%{url: "https://example.com/1", title: "React 19.3 が出た"}]

      body = """
      この期間は基盤の入れ替えが続きました。

      React の新版
      新しい版が出ました。移行の要点はここです。
      出典: https://example.com/1
      """

      assert TazunaWeb.NewsLive.digest_blocks(body, articles) == [
               {:text, "この期間は基盤の入れ替えが続きました。"},
               {:text, "React の新版"},
               {:text, "新しい版が出ました。移行の要点はここです。"},
               {:link, "https://example.com/1", "React 19.3 が出た"}
             ]
    end

    test "溜まっている記事に無い出典も、消さずに出す" do
      # AI が上に無いものを書いたときに、黙って消さない
      blocks = TazunaWeb.NewsLive.digest_blocks("出典: https://example.org/x", [])

      assert blocks == [{:link, "https://example.org/x", "https://example.org/x"}]
    end

    test "まとめは記事の一覧に混ぜない", %{conn: conn} do
      html = shown(conn)

      assert html =~ "news-digest"
      assert html =~ "まとめ: 今日の動き（2026-09-13）"
    end

    test "通知先が決まっていなければ、どこへ書けばよいかを出す", %{conn: conn} do
      # **まとめの枠には置かない** —— あれはまとめができるまで出ないので、
      # 設定を確かめたいときにいちばん見たい状態で消えている
      System.delete_env("NTFY_BASE_URL")
      html = shown(conn)

      assert html =~ "NTFY_BASE_URL"
    end

    test "通知先が決まっていれば、どこへ知らせるかを出す", %{conn: conn} do
      System.put_env("NTFY_BASE_URL", "http://ntfy.test")
      System.put_env("TAZUNA_NEWS_NTFY_TOPIC", "tazuna-news")

      on_exit(fn ->
        System.delete_env("NTFY_BASE_URL")
        System.delete_env("TAZUNA_NEWS_NTFY_TOPIC")
      end)

      html = shown(conn)

      assert html =~ "tazuna-news"
      assert html =~ "二度送りません"
    end

    test "まとめが、画面ではリンク入りで出る", %{conn: conn} do
      # 裸の URL のままだと、押す前にどこへ行くのか読めない。
      # **通知のほうは逆**（URL のまま出す。ntfy が自分でリンクにする）
      html = shown(conn)

      assert html =~ "digest-source"
      assert html =~ ~s|href="https://example.com/1"|
      assert html =~ "React 19.3 が出た"
      # 本文の段落はそのまま出る（整形済みの塊で投げ出さない）
      assert html =~ "この期間は基盤の入れ替えが続きました。"
      refute html =~ "<pre>この期間は"
    end
  end

  test "関連図への行き来ができる", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/news")

    assert html =~ ~p"/relations"
  end

  test "設定の画面へは行かせない", %{conn: conn} do
    # 誰に頼むかは巡回ごとに収集の枠で選ぶ。**別の置き場を残すと、どちらが効くのか
    # 押す前に読めない**（しかも片方は何にも効かない欄になる）
    {:ok, _live, html} = live(conn, ~p"/news")

    refute html =~ "/settings"
  end

  describe "一覧の並び" do
    defp article(title, importance),
      do: %{
        title: title,
        importance: importance,
        url: nil,
        image: nil,
        summary: nil,
        tags: [],
        collected_at: nil,
        reason: ""
      }

    test "重要度の高い順に並べる" do
      # 重要度を付けるのは情報更新の巡回で、読んだうえでの判断。新しい順のまま
      # 出すと、その判断が一覧に現れない
      news = %{
        articles: [article("急がない", 0), article("注目", 1), article("優先", 2)]
      }

      assert Enum.map(TazunaWeb.NewsLive.sorted_articles(news), & &1.title) ==
               ["優先", "注目", "急がない"]
    end

    test "同じ重さのものは、届いた並び（新しい順）のまま" do
      news = %{articles: [article("新しい", 1), article("古い", 1)]}

      assert Enum.map(TazunaWeb.NewsLive.sorted_articles(news), & &1.title) ==
               ["新しい", "古い"]
    end

    test "重要度の低いものも消さない" do
      # 重要度は並びであって、ふるい分けではない
      news = %{articles: [article("急がない", 0)]}

      assert length(TazunaWeb.NewsLive.sorted_articles(news)) == 1
    end
  end

  describe "話題のタブ" do
    test "既定の話題がタブに並ぶ", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/news")

      assert html =~ "ニュース"
      assert html =~ "技術ニュース"
      assert html =~ ~s(href="/news?view=tazuna_tech")
    end

    test "タブを切り替えると、その話題の画面になる", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/news")

      html = live |> element(~s|a[href="/news?view=tazuna_tech"]|) |> render_click()

      assert html =~ "今日、押さえておきたい技術"
      # 依頼の本文も話題の関心から作る（話題ごとに文面を持たせない）
      assert html =~ "ソフトウェア開発"
    end

    test "知らない話題は先頭に丸める", %{conn: conn} do
      # 消した話題のリンクを踏んだだけで、空白の画面を出す理由が無い
      {:ok, _live, html} = live(conn, ~p"/news?view=nosuch")

      assert html =~ "今日、押さえておきたい技術ニュース"
    end
  end
end
