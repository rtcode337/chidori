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
    # 最初に開くのは定義の先頭の話題（一般ニュース）
    {:ok, _live, html} = live(conn, ~p"/news")

    assert html =~ ~r|<h1[^>]*>\s*一般ニュース\s*</h1>|
    # 集めるのは Chiezo だと画面から読めること
    assert html =~ "集めるのは Chiezo です"
  end

  test "技術イベントは開催日のカレンダーを出し、要約と通知の設定は出さない", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/news?view=tazuna_events")

    assert html =~ "開催日のカレンダー"
    refute html =~ "<h3>通知</h3>"
    refute html =~ "<h3>要約</h3>"

    {:ok, _live, html} = live(conn, ~p"/news?view=tazuna_tech")
    refute html =~ "開催日のカレンダー"
    assert html =~ "<h3>通知</h3>"
    assert html =~ "<h3>要約</h3>"
  end

  test "トップページは、何も選んでいなければ一般ニュースの要約", %{conn: conn} do
    # トップは設定ページで選んだ枠。何も選んでいなければいちばん読まれるものを出す
    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ ~s(aria-label="一般ニュース")
    assert html =~ ~s(href="/news?view=tazuna_news")
  end

  test "最新情報のタブは見出しの上にある", %{conn: conn} do
    # タブは見出しの上（関連図・データ収集と同じ）
    {:ok, _live, html} = live(conn, ~p"/news")

    assert html =~ ~r|<h1[^>]*>\s*一般ニュース\s*</h1>|
    [before_heading | _rest] = String.split(html, "<h1")
    assert before_heading =~ "relation-tabs"
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

  test "開いたときの読み直しでは「送っています」と出さない" do
    # どちらも読み込み中だが、読むだけのときは何も送っていない
    assert TazunaWeb.NewsLive.collect_label(%{status: :loading, pushing: false}) ==
             "読み込んでいます…"

    assert TazunaWeb.NewsLive.collect_label(%{status: :loading, pushing: true}) ==
             "送っています…"
  end

  describe "注目作の一覧" do
    alias TazunaWeb.NewsLive

    defp work(title, date, attention), do: %{title: title, date: date, attention: attention}

    test "公開中とこれからに分け、公開から時間が経ったものは並べない" do
      today = ~D[2026-10-01]

      groups =
        NewsLive.works_groups(
          [
            work("古い", ~D[2026-07-01], :high),
            work("公開中・中", ~D[2026-09-20], :mid),
            work("公開中・高", ~D[2026-09-01], :high),
            work("今日", ~D[2026-10-01], :mid),
            work("来月", ~D[2026-11-05], :mid),
            work("来週", ~D[2026-10-08], :high)
          ],
          today
        )

      assert [{"公開中", showing}, {"これから公開", coming}] = groups
      # 公開中は注目度の高い順、同じなら新しい順
      assert Enum.map(showing, & &1.title) == ["公開中・高", "今日", "公開中・中"]
      # これからは公開の近い順
      assert Enum.map(coming, & &1.title) == ["来週", "来月"]
    end

    test "絵は Chiezo が縮めたものを先に使う" do
      # 見る人のブラウザが知らない外のサイトへつながないため
      assert NewsLive.entry_thumb(%{thumb: nil, image: "https://example.com/a.png"}) ==
               "https://example.com/a.png"

      assert NewsLive.entry_thumb(%{thumb: nil, image: nil}) == nil
    end

    test "要約の頭に、出典の順で絵のある作品を並べる" do
      sources = [
        %{url: "https://a.example", label: "作品A"},
        %{url: "https://b.example", label: "作品B"},
        %{url: "https://c.example", label: "作品C"}
      ]

      known = %{
        "https://a.example" => %{image: "/a.webp"},
        "https://c.example" => %{image: "/c.webp"}
      }

      assert [%{label: "作品A"}, %{label: "作品C"}] = TazunaWeb.Report.hero_figures(sources, known)
      assert NewsLive.hero?(Tazuna.Topics.get("tazuna_movies"))

      # 記事の絵を持たせている話題（ニュース）も並べ、持たせない話題（市況）は並べない
      assert NewsLive.hero?(Tazuna.Topics.get("tazuna_tech"))
      refute NewsLive.hero?(Tazuna.Topics.get("tazuna_market"))
    end

    test "本文の URL はリンクにする" do
      assert NewsLive.link_parts("出どころ: https://example.com/a、https://example.com/b") == [
               {:text, "出どころ: "},
               {:url, "https://example.com/a"},
               {:text, "、"},
               {:url, "https://example.com/b"}
             ]
    end
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
                "title" => "まとめ: 昨日の動き（2026-09-12）",
                "opening" => "前の日は静かでした。",
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

      # 割り込みは記事の詳細から頼む（設定の欄には置かない）
      refute html =~ "いま頼む（割り込み）"
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
      assert html =~ "流れ（時とともに増えるものを追う"
      refute html =~ "整理する（磨いていく）"
    end

    test "要約は押すと全画面で開き、右に払うと古いほう、左に払うと新しいほうへ動く", %{conn: conn} do
      Tazuna.News.subscribe("tazuna_news")
      {:ok, live, _html} = live(conn, ~p"/news?view=tazuna_news")
      assert_receive {:news_updated, %{status: :ready}}, 2_000

      html = render(live)
      assert html =~ ~s(<h2 class="news-section-title">要約</h2>)
      refute html =~ "digest-viewer"

      # **ページの上では頭だけ**（見出し・要旨・目次）。章と出典は全画面で読む
      refute html =~ "report-section"

      html = live |> element(".digest-preview") |> render_click()
      assert html =~ "digest-viewer"
      assert html =~ "1 / 2"
      assert html =~ "report-section"

      # **古いほうは左に置く**（右へ払う = 戻る）。フックは右へ払うと 1 を送る。
      # 端より先へは進まない
      html = live |> element("#digest-viewer") |> render_hook("digest_step", %{"by" => 1})
      assert html =~ "2 / 2"
      assert html =~ "昨日の動き"

      html = live |> element("#digest-viewer") |> render_hook("digest_step", %{"by" => 1})
      assert html =~ "2 / 2"

      # 帯のボタンも同じ並び（古いほうが左）。← のキーは古いほう、→ は新しいほう
      assert html =~ ~r/← 古い.*新しい →/s
      html = render_keydown(live, "digest_key", %{"key" => "ArrowRight"})
      assert html =~ "1 / 2"

      html = live |> element(".digest-viewer-close") |> render_click()
      refute html =~ "digest-viewer"
    end

    test "記事一覧は見出しを付けて、ふだんは畳んでおく", %{conn: conn} do
      html = shown(conn)

      # 畳んだまま出す（open を付けない）。並び替えで閉じないよう、開閉はブラウザに任せる
      [tag] = Regex.run(~r/<details[^>]*id="news-articles"[^>]*>/, html)
      assert tag =~ "news-articles"
      refute tag =~ ~r/\sopen(\s|>|=)/
      assert tag =~ "ignore_attrs"
      assert html =~ "記事一覧（直近 3 日・2 件）"
    end

    test "まとめは記事の一覧に混ぜない", %{conn: conn} do
      html = shown(conn)

      assert html =~ "news-digest"
      assert html =~ "まとめ: 今日の動き（2026-09-13）"
    end

    test "話題の画面では知らせるかどうかだけを決め、宛先は設定の通知タブにある", %{conn: conn} do
      # **まとめの枠には置かない** —— あれはまとめができるまで出ないので、
      # 設定を確かめたいときにいちばん見たい状態で消えている
      html = shown(conn)

      assert html =~ ~s(name="setting[notify]")
      # 宛先は全部の通知で 1 つ（画面ごとに書き写さない）
      refute html =~ "ntfy_topic"
      assert html =~ "この話題は知らせません"
      assert html =~ ~s(href="/settings?tab=notify")

      # 送れない口は出さない（押せるのに何も起きないボタンを置かない）
      refute html =~ "いまのまとめを知らせる"
    end

    test "知らせる設定で宛先もあれば、どこへ知らせるかを出す", %{conn: conn} do
      System.put_env("NTFY_BASE_URL", "http://ntfy.test")
      on_exit(fn -> System.delete_env("NTFY_BASE_URL") end)
      notify_to("tazuna-news")

      html = shown(conn)

      assert html =~ "http://ntfy.test の「tazuna-news」へ送ります"

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
      # 要約を作る時刻と通知先は別の枠（時刻は通知の時刻ではない）
      assert html =~ "<h3>要約</h3>"
      assert html =~ "<h3>通知</h3>"

      # 通知の設定は畳まない（時刻も宛先も、開かずに読めるほうが大事）
      refute html =~ "まとめを知らせる（ntfy）"
    end

    test "要約を作る時刻を書けて、その場で作らせる口もある", %{conn: conn} do
      # 時計を持つのは tazuna の側。Chiezo には「いま回してください」としか言わない
      System.put_env("NTFY_BASE_URL", "http://ntfy.test")
      on_exit(fn -> System.delete_env("NTFY_BASE_URL") end)
      notify_to("tazuna-news")

      html = shown(conn)

      assert html =~ ~s(name="setting[digest_at]")
      assert html =~ "いま作って知らせる"
      # 作り直さずに送るだけの口も残す
      assert html =~ "いまのまとめを知らせる"
    end

    test "知らせない設定なら、要約を作るだけの口になる", %{conn: conn} do
      # 時刻は「要約を作る時刻」。知らせないのは失敗ではない
      Tazuna.Notify.Destination.put(%{"topic" => "tazuna-news"})
      Tazuna.Notify.Settings.put("tazuna_news", %{"notify" => "false"})

      html = shown(conn)

      assert html =~ "要約を作る時刻"
      assert html =~ "いま要約を作る"
      refute html =~ "いまのまとめを知らせる"
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
      # 時刻だけ直せばよいのに通知の設定まで書き直させられると、直すたびに全部を
      # 入れ直すことになる（通知先を同じ画面で書いていた頃、実際に消えた）
      System.put_env("NTFY_BASE_URL", "http://ntfy.test")
      on_exit(fn -> System.delete_env("NTFY_BASE_URL") end)

      Tazuna.News.subscribe("tazuna_news")
      {:ok, live, _html} = live(conn, ~p"/news?view=tazuna_news")
      assert_receive {:news_updated, %{status: :ready}}, 2_000

      live
      |> form("#notify-form", setting: %{notify: "true"})
      |> render_change()

      html =
        live
        |> form("#digest-form", setting: %{digest_at: "25 時"})
        |> render_submit()

      assert html =~ "24 時間制で書いてください"
      # 付けたチェックはそのまま残っている
      assert html =~ ~s(value="true" checked)
    end

    test "書きかけは、収集の状態が届いても消えない", %{conn: conn} do
      # 覚えないと、届いた拍子にフォームが描き直されて書きかけが消える
      Tazuna.News.subscribe("tazuna_news")
      {:ok, live, _html} = live(conn, ~p"/news?view=tazuna_news")
      assert_receive {:news_updated, %{status: :ready}}, 2_000

      live
      |> form("#notify-form", setting: %{notify: "true"})
      |> render_change()

      live
      |> form("#digest-form", setting: %{digest_at: "0800"})
      |> render_change()

      # 収集を読み直す（本物の画面では巡回のたびに届く）
      Tazuna.News.refresh(Tazuna.News.server("tazuna_news"))
      assert_receive {:news_updated, %{status: :ready}}, 2_000

      assert render(live) =~ ~s(value="true" checked)
    end

    test "まとめが、画面ではリンク入りで出る", %{conn: conn} do
      # 裸の URL のままだと、押す前にどこへ行くのか読めない。
      # **通知のほうは逆**（URL のまま出す。ntfy が自分でリンクにする）。
      # 章と出典は全画面で読む（ページの上には見出し・要旨・目次だけ）
      Tazuna.News.subscribe("tazuna_news")
      {:ok, live, _html} = live(conn, ~p"/news?view=tazuna_news")
      assert_receive {:news_updated, %{status: :ready}}, 2_000
      html = live |> element(".digest-preview") |> render_click()

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

  test "設定ページでは、誰に頼むかを選ばせない", %{conn: conn} do
    # 誰に頼むかは巡回ごとに収集の枠で選ぶ。**別の置き場を残すと、どちらが効くのか
    # 押す前に読めない**（しかも片方は何にも効かない欄になる）。
    # 設定ページの「Chiezo 収集」は一覧を見るだけ
    {:ok, _live, html} = live(conn, ~p"/settings?tab=chiezo")

    assert html =~ "Chiezo 収集"
    refute html =~ ~s(name="backend")
    refute html =~ "pick_sweep"
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

      assert html =~ ~r|<h1[^>]*>\s*技術ニュース\s*</h1>|
      # 依頼の本文も話題の関心から作る（話題ごとに文面を持たせない）
      assert html =~ "技術に関する新しい動き"
    end

    test "知らない話題は先頭に丸める", %{conn: conn} do
      # 消した話題のリンクを踏んだだけで、空白の画面を出す理由が無い
      {:ok, _live, html} = live(conn, ~p"/news?view=nosuch")

      assert html =~ ~r|<h1[^>]*>\s*一般ニュース\s*</h1>|
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
      # 親子は線ではなく囲み（クラスタ）で表す。操作は関連図と同じ器
      assert html =~ "topic-clusters"
      assert html =~ "AI の仲間"
      # 何のクラスタかを枠に書く
      assert html =~ ~r/<g class="topic-cluster">.*?<text[^>]*>\s*AI\s*<\/text>/s
      assert html =~ ~s(phx-hook="TopicMap")

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

      # （一般ニュースも網を持つようになったので、持たない技術イベントで見る）
      {:ok, live, _html} = live(conn, ~p"/news?view=tazuna_events")
      html = render_async(live, 2_000)

      refute html =~ "トピックの収集"
    end

    test "タブを切り替えても、前の話題の網は持ち込まない", %{conn: conn} do
      # 前のタブで頼んだ読み込みが、切り替えた後に届くことがある。受け取ると、
      # 網を持たない話題のページに別の話題の図が出る
      stub_themes([@news_collection], [theme("React", ["分野:Web"])])

      {:ok, live, _html} = live(conn, ~p"/news?view=tazuna_tech")
      assert render_async(live, 2_000) =~ ~s(aria-label="トピックの網")

      html = live |> render_patch(~p"/news?view=tazuna_events")
      refute html =~ ~s(aria-label="トピックの網")
      refute render_async(live, 2_000) =~ ~s(aria-label="トピックの網")
    end

    # 札を押したときの記事と、興味トピックの PATCH を見る
    defp stub_picking(test_pid) do
      news =
        Map.put(@news_collection, "sweeps", [
          %{"name" => "機械収集", "use_feed" => true},
          %{"name" => "整理", "backend" => "antigravity", "model" => "gemini-3.8-flash"}
        ])

      Tazuna.HttpStub.stub(fn
        %{url: "http://chiezo.test:7010/v1/ai/backends"} ->
          Tazuna.HttpStub.ok(~s({"backends":[]}))

        %{url: "http://chiezo.test:7010/v1/sources"} ->
          Tazuna.HttpStub.ok(~s({"sources":[]}))

        %{method: :patch, url: url, body: body} ->
          send(test_pid, {:patched, url, Jason.decode!(body)})
          Tazuna.HttpStub.ok(~s({}))

        %{url: "http://chiezo.test:7010/v1/collect"} ->
          Tazuna.HttpStub.ok(Jason.encode!(%{"collections" => [news, @topic_collection]}))

        %{url: "http://chiezo.test:7010/v1/tazuna_tech_topics/filter?" <> _query} ->
          Tazuna.HttpStub.ok(
            Jason.encode!(%{
              "results" => [
                theme("LLM", ["同義:大規模言語モデル"], %{"docs_recent" => 9}),
                theme("Rust", [])
              ]
            })
          )

        # 記事をタグで引く口。**言い換えのタグでも引く**
        %{url: "http://chiezo.test:7010/v1/tazuna_tech/filter?" <> query} ->
          send(test_pid, {:tagged, URI.decode_query(query)["tag"]})

          docs =
            case URI.decode_query(query)["tag"] do
              "LLM" -> [%{"title" => "LLM の新版", "tags" => ["LLM", "興味度:80"]}]
              "大規模言語モデル" -> [%{"title" => "言い換えの記事", "tags" => ["大規模言語モデル"]}]
              _other -> []
            end

          Tazuna.HttpStub.ok(Jason.encode!(%{"results" => docs, "total" => length(docs)}))

        %{url: "http://chiezo.test:7010/v1/collect/tazuna_tech_topics" <> _rest} ->
          Tazuna.HttpStub.ok(Jason.encode!(@topic_collection))

        %{url: "http://chiezo.test:7010/v1/collect/tazuna_tech" <> _rest} ->
          Tazuna.HttpStub.ok(Jason.encode!(news))

        %{url: _other} ->
          Tazuna.HttpStub.ok(~s({"results":[]}))
      end)
    end

    test "札を押すと、その語と言い換えで記事を引いて図の下に並べる", %{conn: conn} do
      stub_picking(self())
      {:ok, live, _html} = live(conn, ~p"/news?view=tazuna_tech")
      render_async(live, 2_000)

      live |> element("#topic-canvas") |> render_hook("pick_theme", %{"name" => "LLM"})

      assert_receive {:tagged, "LLM"}, 2_000
      assert_receive {:tagged, "大規模言語モデル"}, 2_000
      html = render_async(live, 2_000)

      assert html =~ "「LLM」の記事"
      assert html =~ "LLM の新版"
      assert html =~ "言い換えの記事"
      assert html =~ "興味 80"

      # 押した札と、その線は描き直しても濃いまま（サーバーでも印を付ける）
      assert html =~ ~r/class="topic-node[^"]*is-picked[^"]*" data-name="LLM"/

      html = live |> element(".theme-pick-close") |> render_click()
      refute html =~ "「LLM」の記事"
    end

    test "記事を押すと詳細が開き、その記事について頼める。タグは興味トピックで強調する", %{
      conn: conn
    } do
      stub_picking(self())
      Tazuna.News.Interests.toggle("tazuna_tech", "LLM")
      {:ok, live, _html} = live(conn, ~p"/news?view=tazuna_tech")
      render_async(live, 2_000)

      live |> element("#topic-canvas") |> render_hook("pick_theme", %{"name" => "LLM"})
      html = render_async(live, 2_000)

      # 興味トピックそのものは濃く、言い換えは淡く
      assert html =~ ~r/class="article-tag is-interest"[^>]*>\s*LLM/
      assert html =~ ~r/class="article-tag[^"]*is-near"[^>]*>\s*大規模言語モデル/
      # 画面の外の印（興味度など）はタグとして出さない
      refute html =~ ~r/class="article-tag[^"]*"[^>]*>\s*興味度:80/

      html =
        live
        |> element(~s(article[phx-value-title="LLM の新版"]))
        |> render_click()

      assert html =~ ~s(id="article-detail-title")
      assert html =~ "この記事について Chiezo に頼む"

      live |> form("#article-ask", %{"note" => "続報を追って"}) |> render_submit()
      assert render_async(live, 2_000) =~ "Chiezo へ頼みました"
    end

    test "図の左上でトピックを名前で探せる（表記ゆれと言い換えでも）", %{conn: conn} do
      stub_picking(self())
      {:ok, live, _html} = live(conn, ~p"/news?view=tazuna_tech")
      render_async(live, 2_000)

      # 全角で打っても、言い換え（大規模言語モデル）で当たる
      html = live |> element("#topic-search") |> render_change(%{"q" => "大規模　言語"})
      [_, rest] = String.split(html, ~s(class="relation-matches"), parts: 2)
      [hits, _] = String.split(rest, "</ul>", parts: 2)
      assert hits =~ "LLM"
      assert hits =~ "（大規模言語モデル）"
      refute hits =~ "Rust"

      # 候補を選ぶと、その札へ寄り（図へ知らせる）、札を押したのと同じく記事が開く
      live |> element(~s(button[phx-click="focus_theme"][phx-value-name="LLM"])) |> render_click()
      assert_push_event(live, "focus", %{name: "LLM"})
      assert_receive {:tagged, "LLM"}, 2_000
      assert render_async(live, 2_000) =~ "「LLM」の記事"
    end

    test "興味トピックに入れると、依頼文を Chiezo へ送り直す（選んだ相手はそのまま）", %{conn: conn} do
      stub_picking(self())
      Tazuna.News.subscribe("tazuna_tech")
      {:ok, live, _html} = live(conn, ~p"/news?view=tazuna_tech")
      assert_receive {:news_updated, %{status: :ready}}, 2_000
      render_async(live, 2_000)

      live |> element("#topic-canvas") |> render_hook("pick_theme", %{"name" => "LLM"})
      html = live |> element(".interest-toggle") |> render_click()

      assert html =~ "★ 興味トピックから外す"
      assert html =~ ~s(class="interest-list")
      assert Tazuna.News.Interests.list("tazuna_tech") == ["LLM"]

      assert_receive {:patched, url, sent}, 2_000
      assert url =~ "/v1/collect/tazuna_tech"
      refine = Enum.find(sent["sweeps"], &(&1["name"] == "整理"))
      assert refine["prompt"] =~ "興味度"
      assert refine["prompt"] =~ "「LLM」"
      # 送り直した拍子に、画面で選んだ相手が既定へ戻らない
      assert refine["backend"] == "antigravity"
      assert Enum.any?(sent["sweeps"], &(&1["name"] == "興味の要約"))

      # 興味の近い順に並べ替えられる
      assert html =~ "興味の近い順"
    end
  end

  describe "トピックの収集の依頼文" do
    test "Chiezo が持っているものを先に出し、まだ無ければ送る予定の内容を出す" do
      topic = List.first(Tazuna.Topics.list())

      assert TazunaWeb.NewsLive.theme_prompt_text(%{collection: %{prompt: "持っている"}}, topic) ==
               "持っている"

      assert TazunaWeb.NewsLive.theme_prompt_text(%{collection: nil}, topic) ==
               Tazuna.Themes.tidy_prompt(topic)

      assert TazunaWeb.NewsLive.theme_prompt_note(%{collection: nil}) =~ "収集を依頼する"
    end
  end

  # 全部の通知で共通の宛先を決め、ニュースの話題を知らせる設定にする
  defp notify_to(topic) do
    Tazuna.Notify.Destination.put(%{"topic" => topic})
    Tazuna.Notify.Settings.put("tazuna_news", %{"notify" => "true"})
  end
end
