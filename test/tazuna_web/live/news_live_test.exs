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

    # 読み直しの口も置かない。**文ではなく押す口で見る** —— 説明文には
    # 「読み直す」が出てくる（同じ語で書くのが自然な場面がある）
    refute html =~ ~s(phx-click="refresh")
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

    assert html =~ "整理"
    assert html =~ "要約"
  end

  test "止まっているときは、次の定時の回も止まると言い切る" do
    # 動かせるのは Chiezo 側だけなので、待っていても直らない
    topic = List.first(Tazuna.Topics.list())

    assert TazunaWeb.NewsLive.digest_state_text(%{collection: %{enabled: false}}, topic) =~
             "次の定時の回もここで止まります"
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
        %{"name" => "機械収集", "interval_minutes" => 60, "use_feed" => true, "enabled" => true},
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
                "opening" =>
                  "この期間は基盤の入れ替えが続きました。\n\nReact の新版\n" <>
                    "新しい版が出ました。\n出典: https://example.com/1",
                "tags" => ["まとめ"]
              },
              %{
                "title" => "React 19.3 が出た",
                "opening" => "要約",
                "tags" => ["ニュース", "話題度:高"],
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
      # 落とす力と印を付け直す力を持つのは整理の回だけなので、
      # そこへ乗ることが分からないと「落として」を頼めるのかが読めない
      assert html =~ "いま頼む（割り込み）"
      assert html =~ "走るのは「整理」の設定です"
    end

    test "機械で引く巡回には相手を選ばせない", %{conn: conn} do
      # 選んでも何も起きない —— その回は AI を呼ばずに返すので、相手もモデルも
      # 読まれない。**選べるのに効かない欄は「設定したつもり」を作る**
      html = shown(conn)

      refute html =~ ~s(name="sweep|機械収集|backend")
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

    test "まとめは記事の一覧に混ぜない", %{conn: conn} do
      html = shown(conn)

      assert html =~ "news-digest"
      assert html =~ "まとめ: 今日の動き（2026-09-13）"
    end

    test "通知先が決まっていなければ、書く欄と理由を出す", %{conn: conn} do
      # **まとめの枠には置かない** —— あれはまとめができるまで出ないので、
      # 設定を確かめたいときにいちばん見たい状態で消えている
      System.delete_env("NTFY_BASE_URL")
      html = shown(conn)

      assert html =~ "この話題の通知先が決まっていません"
      assert html =~ ~s(name="setting[ntfy_topic]")
      # 場所を書かなければどこへ送るのかも読める
      assert html =~ Tazuna.Ntfy.public_base_url()

      # 送れない口は出さない（押せるのに何も起きないボタンを置かない）
      refute html =~ "いまのまとめを知らせる"
    end

    test "通知先が決まっていれば、どこへ知らせるかを出す", %{conn: conn} do
      System.put_env("NTFY_BASE_URL", "http://ntfy.test")
      on_exit(fn -> System.delete_env("NTFY_BASE_URL") end)
      Tazuna.Notify.Settings.put("tazuna_news", %{"ntfy_topic" => "tazuna-news"})

      html = shown(conn)

      assert html =~ "tazuna-news"

      # **押したときだけ飛ぶ。** 自動では送らないことが、押す前に読めること
      assert html =~ "いまのまとめを知らせる"
    end

    test "設定は、ページの名前を冠した枠にまとめる", %{conn: conn} do
      # 「設定」とだけ書くと、何の設定なのかがタブを切り替えた後に読めない。
      # 集める設定と知らせる設定は別のものなので、節に分けて見出しを立てる
      html = shown(conn)

      assert html =~ "ニュースの設定"
      assert html =~ "settings-panel"
      assert html =~ "Chiezo の収集"
      assert html =~ "通知の設定"

      # 通知の設定は畳まない（時刻も宛先も、開かずに読めるほうが大事）
      refute html =~ "まとめを知らせる（ntfy）"
    end

    test "知らせる時刻を書けて、その場で作らせる口もある", %{conn: conn} do
      # 時計を持つのは tazuna の側。Chiezo には「いま回してください」としか言わない
      System.put_env("NTFY_BASE_URL", "http://ntfy.test")
      on_exit(fn -> System.delete_env("NTFY_BASE_URL") end)
      Tazuna.Notify.Settings.put("tazuna_news", %{"ntfy_topic" => "tazuna-news"})

      html = shown(conn)

      assert html =~ ~s(name="setting[digest_at]")
      assert html =~ "いま作って知らせる"
      # 作り直さずに送るだけの口も残す
      assert html =~ "いまのまとめを知らせる"
    end

    test "どれだけ反応されているかを、重要度とは別に出す", %{conn: conn} do
      # 重要度の印に混ぜると、沸いていないが効く 1 件と、効かないが沸いている
      # 1 件が同じ印になる。印の無いものには何も書かない（判断に見えるため）
      html = shown(conn)

      assert html =~ "よく読まれています"
      refute html =~ "まだ広がっていません"
    end

    test "いまの状態と、前に走った回の記録を分けて出す", %{conn: conn} do
      # 止まった回の理由は現在形で残る（「Chiezo 側で止まっています」）。
      # 記録だと断らないと、ずっと前の回の理由がいまの状態として読まれる
      # —— 実際に読まれた（そのときは収集も要約も動いていた）
      Tazuna.Notify.Settings.put("tazuna_news", %{"digest_at" => "07:00"})

      Tazuna.Notify.Settings.mark_digest("tazuna_news", ~U[2026-09-16 22:00:00Z])

      Tazuna.Notify.Settings.mark_digest_result(
        "tazuna_news",
        "2026-09-17 07:00 JST — 止まりました。そのときの理由: この収集は Chiezo 側で止まっています。"
      )

      html = shown(conn)

      assert html =~ "前回の定時の回:"

      # 収集は動いているので、いまの状態はそう出る（次にいつ回るかまで）
      assert html =~ "いまは動いています"
      refute html =~ "いまは Chiezo 側で止まっています"
    end

    test "時刻の書き方を間違えても、書いたものは消さない", %{conn: conn} do
      # 時刻だけ直せばよいのに通知先まで書き直させられると、直すたびに全部を
      # 入れ直すことになる（実際、通知先ごと消えた）
      System.put_env("NTFY_BASE_URL", "http://ntfy.test")
      on_exit(fn -> System.delete_env("NTFY_BASE_URL") end)

      Tazuna.News.subscribe("tazuna_news")
      {:ok, live, _html} = live(conn, ~p"/news?view=tazuna_news")
      assert_receive {:news_updated, %{status: :ready}}, 2_000

      html =
        live
        |> form("#notify-form", setting: %{ntfy_topic: "tazuna-news", digest_at: "25 時"})
        |> render_submit()

      assert html =~ "24 時間制で書いてください"
      # 書いた通知先はそのまま残っている
      assert html =~ ~s(value="tazuna-news")
    end

    test "書きかけは、収集の状態が届いても消えない", %{conn: conn} do
      # 覚えないと、届いた拍子にフォームが描き直されて書きかけが消える
      Tazuna.News.subscribe("tazuna_news")
      {:ok, live, _html} = live(conn, ~p"/news?view=tazuna_news")
      assert_receive {:news_updated, %{status: :ready}}, 2_000

      live
      |> form("#notify-form", setting: %{ntfy_topic: "書きかけ", digest_at: "0800"})
      |> render_change()

      # 収集を読み直す（本物の画面では巡回のたびに届く）
      Tazuna.News.refresh(Tazuna.News.server("tazuna_news"))
      assert_receive {:news_updated, %{status: :ready}}, 2_000

      assert render(live) =~ ~s(value="書きかけ")
    end

    test "まとめが、画面ではリンク入りで出る", %{conn: conn} do
      # 裸の URL のままだと、押す前にどこへ行くのか読めない。
      # **通知のほうは逆**（URL のまま出す。ntfy が自分でリンクにする）
      html = shown(conn)

      assert html =~ "digest-source"
      assert html =~ ~s|href="https://example.com/1"|
      assert html =~ "React 19.3 が出た"
      # 小見出しは見出しとして出る（本文と同じ段落にしない）
      assert html =~ "<h3>"
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
      # 重要度を付けるのは整理の巡回で、読んだうえでの判断。新しい順のまま
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

  describe "トピックの網" do
    @news_collection %{
      "name" => "tazuna_tech",
      "enabled" => true,
      "kind" => "flow",
      "recent" => []
    }
    @topic_collection %{"name" => "tazuna_tech_topics", "enabled" => true, "kind" => "stock"}

    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      :ok
    end

    defp stub_themes(collections, themes) do
      Tazuna.HttpStub.stub(fn
        %{url: "http://chiezo.test:7010/v1/ai/backends"} ->
          Tazuna.HttpStub.ok(~s({"backends":[]}))

        %{url: "http://chiezo.test:7010/v1/sources"} ->
          Tazuna.HttpStub.ok(~s({"sources":[]}))

        %{url: "http://chiezo.test:7010/v1/collect"} ->
          Tazuna.HttpStub.ok(Jason.encode!(%{"collections" => collections}))

        %{url: "http://chiezo.test:7010/v1/tazuna_tech_topics/filter?" <> _query} ->
          Tazuna.HttpStub.ok(Jason.encode!(%{"results" => themes}))

        %{url: "http://chiezo.test:7010/v1/collect/tazuna_tech_topics" <> _rest} ->
          Tazuna.HttpStub.ok(Jason.encode!(@topic_collection))

        %{url: "http://chiezo.test:7010/v1/collect/tazuna_tech" <> _rest} ->
          Tazuna.HttpStub.ok(Jason.encode!(@news_collection))

        %{url: _other} ->
          Tazuna.HttpStub.ok(~s({"results":[]}))
      end)
    end

    defp theme(title, tags, extra \\ %{}) do
      %{
        "title" => title,
        "tags" => ["トピック" | tags],
        "opening" => "説明。",
        # 数も一緒に出てくる語も機械が入れる（AI は書かない）
        "extra" => Map.merge(%{"docs" => 3, "docs_recent" => 2}, extra)
      }
    end

    defp opened(conn) do
      {:ok, live, _html} = live(conn, ~p"/news?view=tazuna_tech")
      render_async(live, 2_000)
    end

    test "網の図は、まとめのすぐ下に出す", %{conn: conn} do
      # まとめが「この期間に何があったか」を文で言うのに対して、図は同じことを
      # 語のつながりで見せる。1 件ずつの一覧より先に置く
      stub_themes(
        [@news_collection, @topic_collection],
        [
          theme("AI", ["分野:AI"], %{"docs_recent" => 9}),
          theme("AIエージェント", ["分野:AI", "親:AI"], %{"links" => ["MCP:4"]}),
          theme("MCP", ["分野:AI"])
        ]
      )

      html = opened(conn)

      assert html =~ "topic-map"
      assert html =~ "topic-nodes"
      # 上下のつながりは、横のつながりと見え方を分ける
      assert html =~ "is-parent"

      # 図に出ないものも読める（記事より前に居座らないよう畳んである）
      assert html =~ "トピックの一覧"
      # 丸の大きさの根拠は、一覧では数で読める
      assert html =~ "直近 9 件"
      # 図は一覧より前（まとめの直後）
      assert :binary.match(html, "topic-map") < :binary.match(html, "news-list")
    end

    test "先の無いつながりは、線にしない", %{conn: conn} do
      # 一緒に出てきた相手が、外された語や図の外のこともある
      stub_themes(
        [@news_collection, @topic_collection],
        [theme("AI", ["分野:AI"], %{"links" => ["まだ無い語:3"]})]
      )

      html = opened(conn)

      assert html =~ "topic-map"
      # 図には線を引かない（整える回が直すまで、図は黙って耐える）
      refute html =~ "<line"
      # 一覧には数えたまま出す（黙って消さない）
      assert html =~ "まだ無い語"
    end

    test "収集がまだ無ければ、依頼する口を出す", %{conn: conn} do
      stub_themes([@news_collection], [])

      html = opened(conn)

      assert html =~ "トピックの収集"
      assert html =~ "まだ Chiezo に収集がありません"
      assert html =~ "収集を依頼する"
    end

    test "トピックを持たない話題には、枠ごと出さない", %{conn: conn} do
      # 押せる口だけあって中身が育たないのは、設定し忘れに見える
      stub_themes([@news_collection], [])

      {:ok, live, _html} = live(conn, ~p"/news?view=tazuna_news")
      html = render_async(live, 2_000)

      refute html =~ "トピックの収集"
    end
  end
end
