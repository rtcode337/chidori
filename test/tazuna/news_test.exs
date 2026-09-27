defmodule Tazuna.NewsTest do
  use ExUnit.Case, async: false

  alias Tazuna.HttpStub
  alias Tazuna.News

  setup do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
    :ok
  end

  defp start_news do
    name = :"news_#{System.unique_integer([:positive])}"
    start_supervised!({News, name: name})
    name
  end

  defp collection(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => News.collection_name(),
        "description" => "tazuna のニュース",
        "enabled" => true,
        "interval_minutes" => 360,
        "next_run_at" => "2026-09-07T09:00:00+00:00",
        "last_run_at" => "2026-09-07T03:00:00+00:00",
        "last_status" => "ok",
        "prompt" => "{cursor} 以降のニュースを10件。next_cursor に続きを。",
        "last_added" => 3,
        "requested_by" => "tazuna",
        "url" => "/search/tazuna_news/"
      },
      overrides
    )
  end

  defp list_body(collections), do: Jason.encode!(%{"collections" => collections})

  # 話題の定義そのもの。**DB は見ない** —— 巡回も配信元も定義が持っているので、
  # 保存してある設定が無くても組み立てられる
  defp defined_topic(collection),
    do: Enum.find(Tazuna.Topics.defined(), &(&1.collection == collection))

  defp detail_body(recent, overrides \\ %{}) do
    collection(overrides) |> Map.put("recent", recent) |> Jason.encode!()
  end

  defp recent(title, url \\ "https://example.com/1") do
    %{
      "title" => title,
      "opening" => "#{title}の要約。",
      "updated_at" => "2026-09-07T03:00:00+00:00",
      "extra" => %{"url" => url, "collected_at" => "2026-09-07T03:00:00+00:00", "web" => true}
    }
  end

  defp sources_body(docs) do
    Jason.encode!(%{
      "sources" => [%{"name" => News.collection_name(), "kind" => "collect", "docs" => docs}]
    })
  end

  describe "記事一覧の窓" do
    defp dated(title, at), do: %{title: title, at: at}

    test "公開の新しい順に並べ、直近 72 時間を残す（薄ければ新しい順に 20 件まで埋める）" do
      now = ~U[2026-09-27 12:00:00Z]

      fresh =
        for i <- 1..25,
            do: dated("新しい#{i}", DateTime.add(now, -i * 3600, :second) |> DateTime.to_iso8601())

      old = [dated("古い", "2026-09-01"), dated("日付なし", nil)]

      window = News.in_window(Enum.shuffle(old ++ fresh), now)
      assert length(window) == 25
      assert hd(window).title == "新しい1"
      refute Enum.any?(window, &(&1.title in ["古い", "日付なし"]))

      # 窓が薄いときは、古いものでも新しい順に 20 件までは出す
      thin = News.in_window(old ++ Enum.take(fresh, 3), now)
      assert Enum.map(thin, & &1.title) == ["新しい1", "新しい2", "新しい3", "古い", "日付なし"]
    end
  end

  describe "to_articles/1" do
    test "見出しと要約と、原文へのリンクを組み立てる" do
      assert [article] = News.to_articles([recent("静かな話題")])
      assert article.title == "静かな話題"
      # 出典は Chiezo の中の入口ではなく、集めた1件の原文
      assert article.url == "https://example.com/1"
      assert article.summary == "静かな話題の要約。"
      # 人に見せる日時は JST（届くのは UTC の文字列）
      assert article.collected_at == "2026-09-07 12:00 JST"
    end

    test "出典が http でなければリンクにしない" do
      assert [article] = News.to_articles([recent("あぶない", "javascript:alert(1)")])
      assert article.url == nil
      assert article.title == "あぶない"
    end

    test "出典も要約も無くても、見出しだけで出す" do
      assert [article] = News.to_articles([%{"title" => "見出しだけ"}])
      assert article.url == nil
      assert article.summary == nil
    end

    test "見出しの無いものは落とす" do
      assert [] = News.to_articles([%{"doc_id" => 1}, %{"title" => "   "}])
    end

    test "Chiezo の順（新しい順）をそのまま保つ" do
      titles =
        [recent("あ"), recent("い"), recent("う")]
        |> News.to_articles()
        |> Enum.map(& &1.title)

      assert titles == ["あ", "い", "う"]
    end
  end

  describe "to_collection/1" do
    test "画面が要る項目を取り出し、Chiezo への入口を絶対URLにする" do
      c = News.to_collection(collection())

      assert c.enabled
      # Chiezo が実際に持っている本文（向こうの画面から直せる）
      assert c.prompt =~ "{cursor}"
      # 誰に頼んでいるかも Chiezo 側が正
      assert c.backend == nil
      assert c.url == "http://chiezo.test:7010/search/tazuna_news/"

      # 件数は定義に入っていないので、ここでは 0（読み直しがソース表から埋める）
      assert c.docs == 0
    end
  end

  describe "読み直す" do
    test "溜まっているものを読む" do
      HttpStub.stub(fn
        %{method: :get, url: "http://chiezo.test:7010/v1/collect"} ->
          HttpStub.ok(list_body([collection()]))

        %{method: :get, url: "http://chiezo.test:7010/v1/sources"} ->
          HttpStub.ok(sources_body(42))

        # まとめはタグで引き直す（直近の窓から押し出されても出るように）
        %{method: :get, url: "http://chiezo.test:7010/v1/tazuna_news/filter?" <> _query} ->
          HttpStub.ok(Jason.encode!(%{"results" => []}))

        # 記事一覧の窓は新着の口から（公開の新しい順に並べ直す）
        %{method: :get, url: "http://chiezo.test:7010/v1/tazuna_news/recent?" <> _query} ->
          HttpStub.ok(Jason.encode!(%{"docs" => [recent("地震の続報")]}))

        # 反応の実数（はてブ数）
        %{method: :get, url: "https://bookmark.hatenaapis.com/count/entries?" <> query} ->
          assert query =~ "url=https%3A%2F%2Fexample.com%2F1"
          HttpStub.ok(~s({"https://example.com/1": 12}))

        %{method: :get, url: url} ->
          assert url =~ "/v1/collect/tazuna_news"
          HttpStub.ok(detail_body([recent("見本の 1 件")]))
      end)

      Tazuna.News.Hatena.clear()
      name = start_news()
      News.subscribe()
      News.refresh(name)

      assert_receive {:news_updated, %{status: :loading}}, 1_000
      assert_receive {:news_updated, %{status: :ready} = news}, 2_000
      assert [%{title: "地震の続報", importance: 2, bookmarks: 12}] = news.articles
      assert news.collection.enabled
      # 溜まった件数はソース表から埋める（定義には入っていない）
      assert news.collection.docs == 42
    end

    test "まだ焼いていなければ件数は 0 のまま" do
      HttpStub.stub(fn
        %{url: "http://chiezo.test:7010/v1/collect"} ->
          HttpStub.ok(list_body([collection()]))

        # 焼く前はソースそのものが無い
        %{url: "http://chiezo.test:7010/v1/sources"} ->
          HttpStub.ok(~s({"sources":[]}))

        %{url: _detail} ->
          HttpStub.ok(detail_body([]))
      end)

      name = start_news()
      News.subscribe()
      News.refresh(name)

      assert_receive {:news_updated, %{status: :ready, collection: %{docs: 0}}}, 2_000
    end

    test "まだ依頼していなければ、収集は無いものとして返す" do
      HttpStub.stub(fn %{url: "http://chiezo.test:7010/v1/collect"} ->
        HttpStub.ok(list_body([%{"name" => "tech_news"}]))
      end)

      name = start_news()
      News.subscribe()
      News.refresh(name)

      assert_receive {:news_updated, %{status: :loading}}, 1_000
      assert_receive {:news_updated, %{status: :ready, collection: nil, articles: []}}, 2_000
    end

    test "集める層が無い Chiezo と、繋がらない Chiezo を区別する" do
      HttpStub.stub(fn _request -> {:ok, %{status: 404, body: ""}} end)

      name = start_news()
      News.subscribe()
      News.refresh(name)

      assert_receive {:news_updated, %{status: :loading}}, 1_000
      assert_receive {:news_updated, %{status: :unavailable, reason: :collect_unsupported}}, 2_000
    end

    test "溜め先が未設定の Chiezo はそれと分かる" do
      HttpStub.stub(fn _request -> {:ok, %{status: 503, body: ""}} end)

      name = start_news()
      News.subscribe()
      News.refresh(name)

      assert_receive {:news_updated, %{reason: :collect_disabled}}, 2_000
    end
  end

  describe "依頼する" do
    test "止めた状態で作られる収集を Chiezo へ頼み、そのまま読み直す" do
      test_pid = self()

      HttpStub.stub(fn
        %{method: :post, url: "http://chiezo.test:7010/v1/collect", body: body} ->
          send(test_pid, {:created, Jason.decode!(body)})
          HttpStub.ok(Jason.encode!(collection(%{"enabled" => false})))

        %{method: :get, url: "http://chiezo.test:7010/v1/collect"} ->
          HttpStub.ok(list_body([collection(%{"enabled" => false})]))

        %{method: :get, url: "http://chiezo.test:7010/v1/sources"} ->
          HttpStub.ok(sources_body(0))

        %{method: :get, url: _detail} ->
          HttpStub.ok(detail_body([], %{"enabled" => false}))
      end)

      name = start_news()
      News.subscribe()
      News.request_collection(name)

      assert_receive {:created, payload}, 2_000
      assert payload["name"] == "tazuna_news"
      assert payload["requested_by"] == "tazuna"
      # 実行のたびに進む印を使う（前回以降を集めるため）
      assert payload["prompt"] =~ "{cursor}"
      assert payload["prompt"] =~ "next_cursor"

      # **流れ。** 時とともに増えるものを追っていて、古いものは順に要らなくなる
      # （落とさないと、この収集は永久に増え続ける）
      assert payload["kind"] == "flow"

      # 期限は Chiezo の既定のまま（送らない）
      refute Map.has_key?(payload, "keep_days")

      # **技術イベントも流れ**（これから開かれるものを次々と集めていく）。
      # ただし期限は外す —— Chiezo の期限は配信日で数えるので、半年先のイベントを
      # 募集が出た日から 30 日で落とすことになる。終わったものは整理が落とす
      events = News.attrs("tazuna_events", Tazuna.Topics.get("tazuna_events"))
      assert events[:kind] == "flow"
      assert events[:keep_days] == 0

      # 巡回は仕事ごとに分ける（集める・漏れを探す・読んで印を付ける・まとめる）
      assert Enum.map(payload["sweeps"], & &1["name"]) ==
               ["集める", "整理", "要約"]

      # **時計を持たないのは要約だけ。** 起こすのは tazuna で、何時に知らせるかは
      # 利用者の都合 —— Chiezo に持たせると、あちらが都合を知る場所になる。
      # 割り込みのための空の巡回は置かない（頼みごとは整理の回で走る）
      assert Enum.filter(payload["sweeps"], & &1["on_demand"]) |> Enum.map(& &1["name"]) ==
               ["要約"]

      # 配信元を持たない話題なので、外の道具は付けない（集めるところから AI に頼む）
      refute payload["feed"]

      # 名指ししていないので、相手は Chiezo にまかせる（項目ごと送らない）
      refute Map.has_key?(payload, "backend")

      assert_receive {:news_updated, %{status: :ready, collection: %{enabled: false}}}, 2_000
    end

    test "相手を名指しして依頼できる" do
      System.put_env("TAZUNA_NEWS_BACKEND", "antigravity")
      System.put_env("TAZUNA_NEWS_MODEL", "haiku")

      on_exit(fn ->
        System.delete_env("TAZUNA_NEWS_BACKEND")
        System.delete_env("TAZUNA_NEWS_MODEL")
      end)

      test_pid = self()

      HttpStub.stub(fn
        %{method: :post, body: body} ->
          send(test_pid, {:created, Jason.decode!(body)})
          HttpStub.ok(Jason.encode!(collection()))

        %{method: :get, url: "http://chiezo.test:7010/v1/collect"} ->
          HttpStub.ok(list_body([collection()]))

        %{method: :get, url: "http://chiezo.test:7010/v1/sources"} ->
          HttpStub.ok(sources_body(0))

        %{method: :get} ->
          HttpStub.ok(detail_body([]))
      end)

      name = start_news()
      News.subscribe()
      News.request_collection(name)

      assert_receive {:created, payload}, 2_000
      assert payload["backend"] == "antigravity"
      assert payload["model"] == "haiku"
      # 指定していない項目は送らない
      refute Map.has_key?(payload, "effort")
    end

    test "すでにある収集を頼み直しても失敗にしない" do
      HttpStub.stub(fn
        %{method: :post} ->
          {:ok, %{status: 409, body: ""}}

        %{method: :get, url: "http://chiezo.test:7010/v1/collect"} ->
          HttpStub.ok(list_body([collection()]))

        %{method: :get, url: "http://chiezo.test:7010/v1/sources"} ->
          HttpStub.ok(sources_body(1))

        %{method: :get} ->
          HttpStub.ok(detail_body([]))
      end)

      name = start_news()
      News.subscribe()
      News.request_collection(name)

      assert_receive {:news_updated, %{status: :ready}}, 2_000
    end
  end

  describe "いま集めさせる" do
    test "止まっている収集は Chiezo が断る。その理由をそのまま出す" do
      HttpStub.stub(fn
        %{method: :post} -> {:ok, %{status: 403, body: ""}}
        %{method: :get} -> HttpStub.ok(list_body([collection()]))
      end)

      name = start_news()
      News.subscribe()
      News.run_now(name)

      assert_receive {:news_updated, %{reason: :collection_disabled}}, 2_000
    end

    test "続けて押しても投げ直さない" do
      test_pid = self()

      HttpStub.stub(fn
        %{method: :post} ->
          send(test_pid, :ran)
          HttpStub.ok("{}")

        %{method: :get, url: "http://chiezo.test:7010/v1/collect"} ->
          HttpStub.ok(list_body([collection()]))

        %{method: :get, url: "http://chiezo.test:7010/v1/sources"} ->
          HttpStub.ok(sources_body(1))

        %{method: :get} ->
          HttpStub.ok(detail_body([recent("記事")]))
      end)

      name = start_news()
      News.subscribe()
      News.run_now(name)

      assert_receive :ran, 2_000
      assert_receive {:news_updated, %{status: :ready}}, 2_000

      News.run_now(name)
      assert_receive {:news_updated, %{reason: :too_soon}}, 1_000
      refute_receive :ran, 300
    end

    @tag :capture_log
    test "問い合わせが落ちても :loading のままにしない" do
      HttpStub.stub(fn _request -> raise "壊れた" end)

      name = start_news()
      News.subscribe()
      News.refresh(name)

      assert_receive {:news_updated, %{status: status, reason: :collection_crashed}}, 2_000
      refute status == :loading
      assert News.current(name).status != :loading
    end
  end

  describe "割り込み" do
    test "整理の回として走らせる" do
      # **名指ししないと Chiezo は時計を持たない巡回へ倒す。** 専用の 1 本を
      # 置かなくなった以上、名指ししなければ収集ぜんたいの文（集める回の文）で
      # 走り、頼んだ「落として」が効かない
      test_pid = self()

      HttpStub.stub(fn
        %{method: :post, url: url, body: body} ->
          send(test_pid, {:asked, url, Jason.decode!(body)})
          HttpStub.ok("{}")

        %{method: :get} ->
          HttpStub.ok(list_body([collection()]))
      end)

      assert News.ask_focus("tazuna_tech", "この記事は宣伝なので落として") == :ok
      assert_receive {:asked, url, sent}, 2_000
      assert url =~ "/v1/collect/tazuna_tech/focus"
      assert sent["sweep"] == "整理"
      assert sent["note"] =~ "宣伝"
    end

    test "Chiezo が未設定なら、頼む前に断る" do
      System.delete_env("CHIEZO_BASE_URL")

      assert News.ask_focus("tazuna_tech", "なにか") == {:error, :chiezo_not_configured}
    end
  end

  describe "Chiezo が未設定のとき" do
    test "頼む前に断る" do
      System.delete_env("CHIEZO_BASE_URL")

      name = start_news()
      News.subscribe()
      News.refresh(name)

      assert_receive {:news_updated,
                      %{status: :unavailable, reason: :chiezo_not_configured, configured: false}},
                     1_000
    end
  end

  describe "importance/2" do
    test "暮らしに関わる語を含む見出しを上に置く" do
      assert {2, _reason} = News.importance("大雨の警報が出ました")
      assert {1, _reason} = News.importance("新しい展覧会が始まりました")
    end

    test "AI が読んで付けた印のほうが先" do
      # 語の一致で決めると、同じ語を含むだけの1件が上に出る（読んだ判断には勝てない）
      assert {0, _reason} = News.importance("大雨の警報が出ました", ["重要度:低"])
      assert {2, _reason} = News.importance("新しい展覧会が始まりました", ["重要度:高"])
    end
  end

  describe "興味トピック" do
    defp with_interests(names),
      do: Map.put(defined_topic("tazuna_tech"), :interests, names)

    test "選んでいれば、整理の回に興味度を付けさせる（付け終えた点は付け直させない）" do
      prompt = News.refine_prompt(with_interests(["LLM", "Rust"]))

      assert prompt =~ ~s("興味度:<0〜100 の整数>")
      assert prompt =~ "「LLM」、「Rust」"
      assert prompt =~ "付け直さないでください"
    end

    test "選んでいなければ、興味度を付けさせない" do
      refute News.refine_prompt(with_interests([])) =~ "興味度"
    end

    test "選んでいるときだけ、興味トピックの要約の巡回を置く" do
      names = &Enum.map(News.sweeps(&1), fn sweep -> sweep.name end)

      assert "興味の要約" in names.(with_interests(["LLM"]))
      refute "興味の要約" in names.(with_interests([]))

      sweep = Enum.find(News.sweeps(with_interests(["LLM"])), &(&1.name == "興味の要約"))
      assert sweep.on_demand
      assert sweep.prompt =~ ~s(tags: "興味のまとめ" を**必ず**付けてください)
      assert sweep.prompt =~ "「LLM」"
      # ふつうのまとめの印は付けさせない（2 本が 1 つの並びに混ざる）
      assert sweep.prompt =~ ~s("まとめ" は**付けないでください**)
    end

    test "興味度を読む（無ければ nil、範囲の外は端へ）" do
      assert News.interest_score(["興味度:73"]) == 73
      assert News.interest_score(["興味度:120"]) == 100
      assert News.interest_score(["重要度:高"]) == nil
    end

    test "興味トピックの要約は、記事にもふつうのまとめにも混ぜない" do
      recent = [
        %{"title" => "興味のまとめ: A（1）", "tags" => ["興味のまとめ"]},
        %{"title" => "まとめ: B（1）", "tags" => ["まとめ"]},
        %{"title" => "記事", "tags" => ["ニュース", "興味度:40"]}
      ]

      assert Enum.map(News.to_articles(recent), & &1.title) == ["記事"]
      assert Enum.map(News.to_digests(recent), & &1.title) == ["まとめ: B（1）"]
      assert Enum.map(News.to_interest_digests(recent), & &1.title) == ["興味のまとめ: A（1）"]
      assert [%{interest: 40}] = News.to_articles(recent)
    end
  end

  describe "巡回" do
    test "仕事ごとに別の時計で回す" do
      names = defined_topic("tazuna_news") |> News.sweeps() |> Enum.map(& &1.name)

      # 一般ニュースも技術ニュースと同じく、配信元を機械で引く
      assert names == ["機械収集", "整理", "要約"]
    end

    test "配信元を持たない話題は、AI に集めさせる" do
      names = %{name: "何か", interest: "何か", feeds: []} |> News.sweeps() |> Enum.map(& &1.name)
      assert names == ["集める", "整理", "要約"]
    end

    test "整理は、溜める回が 1 回走るまで待つ" do
      # 有効にした直後は両方が「いますぐ」になり、ワーカーを経由する整理が
      # 機械収集より先に届くと、空の収集を相手に整理が走る
      refine = &Enum.find(News.sweeps(&1), fn sweep -> sweep.name == "整理" end)

      assert refine.(defined_topic("tazuna_tech")).after == "機械収集"
      assert refine.(%{name: "何か", interest: "何か", feeds: []}).after == "集める"
    end

    test "要約を作らない話題には、要約の回を置かない" do
      # 技術イベントは開催日のカレンダーで選ぶもので、要約は読まれない
      names = defined_topic("tazuna_events") |> News.sweeps() |> Enum.map(& &1.name)
      assert names == ["機械収集", "整理", "情報収集"]
    end

    test "技術イベントは 1 日に 1 回、先の月を 1 か月ずつ探して足す" do
      # connpass の新着は募集が出たものしか流れてこないので、カレンダーが来月で止まる
      sweep = defined_topic("tazuna_events") |> News.sweeps() |> Enum.find(&(&1.name == "情報収集"))

      assert sweep.interval_minutes == 24 * 60
      assert sweep.only_new

      # 今日の日付と、いま入っている見出しを見せる（同じものを足し直させない）
      assert sweep.prompt =~ "{now}"
      assert sweep.prompt =~ "{names}"
      assert sweep.prompt =~ "6 か月先まで"

      # 6 か月ぶんを 1 回で頼むと途中で打ち切られる。今回の月はカーソルで渡し、次を返させる
      assert sweep.prompt =~ "今回探すのは「{cursor}」に開かれるものだけです"
      assert sweep.prompt =~ "next_cursor には、今回の次の月の名前"
      assert Tazuna.News.Events.segments() == ~w(今月 来月 2か月先 3か月先 4か月先 5か月先 6か月先)

      # connpass は配信に絵を載せないので、ページの og:image を Chiezo に拾わせる
      assert News.attrs("tazuna_events", defined_topic("tazuna_events")).thumbs ==
               %{pages_from: ["connpass.com"]}

      refute Map.has_key?(News.attrs("tazuna_tech", defined_topic("tazuna_tech")), :thumbs)
      # 整理の回はカーソルを動かさない（動かすと次に探す月が飛ぶ）
      assert Tazuna.News.Events.refine_note() =~ "next_cursor は返さないでください"
      # タグの決まりは整理と同じ文
      assert sweep.prompt =~ Tazuna.News.Events.tag_rules()
      assert Tazuna.News.Events.refine_note() =~ Tazuna.News.Events.tag_rules()

      # ほかの話題には置かない
      refute "情報収集" in (defined_topic("tazuna_tech") |> News.sweeps() |> Enum.map(& &1.name))
    end

    test "技術イベントの整理は、論文ではなく connpass の外のイベントを探させる" do
      events = News.refine_prompt(defined_topic("tazuna_events"))
      tech = News.refine_prompt(defined_topic("tazuna_tech"))

      assert events =~ "上に無いイベントを探して足す"
      assert events =~ "Doorkeeper"
      refute events =~ "話題になっている論文"
      assert tech =~ "話題になっている論文"
    end

    test "一般ニュースはトピックの網を育てない" do
      refute Tazuna.Topics.themes?(defined_topic("tazuna_news"))
      assert Tazuna.Topics.themes?(defined_topic("tazuna_tech"))
    end

    test "割り込みは整理の回に乗せる" do
      # 頼まれるのはたいてい「これは宣伝だから落として」「この印が違う」で、
      # **その力を持つのは整理の回だけ**
      names = defined_topic("tazuna_tech") |> News.sweeps() |> Enum.map(& &1.name)

      assert News.focus_sweep() in names
      assert News.focus_sweep() == "整理"
    end

    test "割り込みのための空の巡回は置かない" do
      # 置いていた頃は時計を持たないだけの空の巡回で、依頼文を持たないので
      # 収集ぜんたいの文（集める回の文）で走っていた —— 落とす力を持たない回。
      # 時計を持たないのは要約だけ（起こすのは tazuna で、依頼文は自分で持っている）
      sweeps = defined_topic("tazuna_tech") |> News.sweeps()

      assert Enum.filter(sweeps, &Map.get(&1, :on_demand)) |> Enum.map(& &1.name) == ["要約"]
    end

    test "配信元を持つ話題は、集めるところを機械にまかせる" do
      [intake | _rest] = defined_topic("tazuna_tech") |> News.sweeps()

      assert intake.name == "機械収集"
      assert intake.use_feed == true

      # **足すだけと組にする** —— 組にしないと、整理が付けたタグを
      # 配信の薄い内容で上書きする
      assert intake.only_new == true
    end

    test "配信元は束の名前つきで渡す" do
      spec = defined_topic("tazuna_tech") |> News.feed_spec()

      assert Enum.any?(spec.urls, &(&1.tags == ["ニュース"]))
      assert Enum.any?(spec.urls, &(&1.tags == ["記事"]))
    end

    test "配信元を持たない話題に外の道具は付けない" do
      assert %{name: "何か", feeds: []} |> News.feed_spec() == nil
    end

    test "落とす力を持つのは整理の回だけ" do
      # 溜めるほうを機械にまかせた以上、選り分ける口がどこかに要る。
      # ただし足すだけの回に消す力を持たせない（足すはずの回が消し始める）
      topic = defined_topic("tazuna_tech")
      prompts = for s <- News.sweeps(topic), into: %{}, do: {s.name, Map.get(s, :prompt)}

      # **名前は Chiezo が決めている**ので、ここでも書き写さずに引く
      tombstone = Tazuna.Chiezo.tombstone_tag()
      assert prompts["整理"] =~ tombstone
      refute prompts["要約"] =~ tombstone
    end

    test "整理は、読み直すのと外を当たるのを 1 本で頼む" do
      # 分けていた頃は、重なった時間ぶんを 2 度読ませていた（画家の収集が
      # 同じ理由で 1 本にまとめてある）
      prompt = News.refine_prompt(defined_topic("tazuna_tech"))

      assert prompt =~ "印を付け直し"
      assert prompt =~ "上に並んでいない出どころ"
    end

    test "記事の主役の名前もタグにさせる" do
      # 分野だけだと「AI」「セキュリティ」のような広い語ばかりになり、そこから作る
      # 話題のつながりで、どの記事も同じ場所に集まってしまう
      # （実測で、上位のタグに製品名がほとんど無かった）
      for prompt <- [
            News.prompt(defined_topic("tazuna_tech")),
            News.refine_prompt(defined_topic("tazuna_tech"))
          ] do
        assert prompt =~ "固有名"
        assert prompt =~ "製品・サービス・技術・組織"
      end
    end

    test "論文は名指しで念を押す" do
      # 外を当たる先の 1 つとして箇条書きに並べていただけの頃は、実測で 269 件の
      # うち論文が 2 件しか入らなかった —— 4 つ並んだうちの最後の 1 行では埋もれる。
      # 配信元は論文を配らないので、この回が見に行かなければ永遠に入らない
      prompt = News.refine_prompt(defined_topic("tazuna_tech"))

      assert prompt =~ "この回が見に行かなければ 1 件も入りません"
      assert prompt =~ "毎回かならず当たってください"
    end

    test "論文の件数は求めない" do
      # 「必ず N 件」と書くと数合わせで薄いものが入り、重要度の印が意味を失う
      # （読む人は印で絞って読むので、そこに当たりが混ざるほうが害が大きい）
      prompt = News.refine_prompt(defined_topic("tazuna_tech"))

      assert prompt =~ "0 件で構いません"
      assert prompt =~ "探さずに 0 件にしないでください"
    end

    test "足す前に、同じ記事が無いかを URL で確かめさせる" do
      # 見出しでは確かめられない —— 同じ記事が配信元ごとに違う見出しで流れてくるし
      # （「記事名 - サイト名」と「記事名」）、差し込まれるのは前回から後のぶんだけ。
      # 実測で、生きている記事の 6% が同じ URL の複製だった
      prompt = News.refine_prompt(defined_topic("tazuna_tech"))

      assert prompt =~ "URL で確かめてください"
      # 引く相手は、その話題の収集（道具に渡す名前）
      assert prompt =~ ~s(query(source: "tazuna_tech")
      assert prompt =~ "見出しの付け替えはできません"
    end

    test "話題度を、重要度とは別の軸として付けさせる" do
      # 同じ配信元から同じ材料を読んでいても、軸が「判断が変わるか」だけだと、
      # 界隈が丸一日その話をしていてもまとめに出てこない（実際にそうなった）。
      # かといって重要度に混ぜると、**沸いていないが効く 1 件**が沈む
      prompt = News.refine_prompt(defined_topic("tazuna_tech"))

      assert prompt =~ "話題度:高"
      assert prompt =~ "重要度 とは別の軸です"

      # 広がっていないことを「悪いこと」と読ませない（一次情報は早いだけ）
      assert prompt =~ "広がっていないことは悪いことではありません"
    end

    test "関心には、話題になっていること自体も入れる" do
      # 判断が変わるかどうかだけで選ぶと、界隈の話題がまるごと落ちる
      assert News.refine_prompt(defined_topic("tazuna_tech")) =~ "界隈で話題になっているもの"
    end

    test "外から見つけたものに、既にあるものを上書きさせない" do
      # 見出しが同じものを薄い要約で返すと、付いている印ごと置き換わる
      prompt = News.refine_prompt(defined_topic("tazuna_tech"))

      assert prompt =~ "書き換えないでください"
      assert prompt =~ "新しい見出しで"
    end

    test "要約は時計を持たず、整理は定時でも回る" do
      # 要約を起こすのは tazuna（知らせる時刻はこちらが持つ）。整理はその直前にも
      # 起こすが、定時の時計も残す —— 落とす仕事も外を当たる仕事も、
      # まとめの回数ぶんしか走らないと間が空きすぎる
      sweeps = defined_topic("tazuna_tech") |> News.sweeps() |> Map.new(&{&1.name, &1})

      assert Map.get(sweeps["要約"], :on_demand)
      refute Map.get(sweeps["要約"], :interval_minutes)
      assert sweeps["整理"].interval_minutes == 240
    end

    test "動きの遅い話題は、間隔を長くできる" do
      # 1 日で情勢がひっくり返らない話題を短い間隔で回しても、同じものを読み直す
      # だけで枠を食う。**話題が書いていればそちらを使う**
      events = defined_topic("tazuna_events") |> News.sweeps() |> Map.new(&{&1.name, &1})
      tech = defined_topic("tazuna_tech") |> News.sweeps() |> Map.new(&{&1.name, &1})

      assert events["整理"].interval_minutes > tech["整理"].interval_minutes
    end

    test "その話題ならではの頼みごとは、整理の回に足す" do
      prompt = News.refine_prompt(defined_topic("tazuna_events"))

      assert prompt =~ Tazuna.News.Events.refine_note() |> String.split("\n") |> hd()

      # 持たない話題には足さない
      refute News.refine_prompt(defined_topic("tazuna_tech")) =~ "開催日"
    end

    test "作品を育てる話題は、先を探す回と整理の回だけで回す" do
      # 記事を集める回を置くと、単位が記事に戻る
      sweeps = defined_topic("tazuna_movies") |> News.sweeps()
      by_name = Map.new(sweeps, &{&1.name, &1})

      assert Enum.map(sweeps, & &1.name) == ["情報収集", "整理"]
      assert by_name["情報収集"].only_new
      # 空の収集を相手に整理が走らないように
      assert by_name["整理"].after == "情報収集"
      assert by_name["整理"].prompt =~ "{current}"
      assert by_name["情報収集"].prompt =~ "{names}"

      attrs = News.attrs("tazuna_movies", defined_topic("tazuna_movies"))
      assert attrs.feed == nil
      assert attrs.keep_days == 0
      # ポスターは Chiezo に縮めて持たせる
      assert attrs.thumbs == true

      # 名指ししない回が記事を集め始めないように、収集ぜんたいの文も作品を探す文
      assert attrs.prompt == by_name["情報収集"].prompt
    end

    test "要旨は、1 行目と箇条書きに分けて書かせる" do
      # 全部を 1 つの段落に詰めると、通知でも画面でも読めない。
      # 通知は畳まれて先頭しか見えないことがあるので、1 行目だけで意味が通るように
      prompt = News.digest_prompt(defined_topic("tazuna_tech"))

      assert prompt =~ "1 行目だけで意味が通るように"
      assert prompt =~ "・"
      assert prompt =~ "1 行に 1 つのこと"
    end

    test "まとめは、記事の URL を名乗らない" do
      # 同じ URL の 1 件は Chiezo が弾く。まとめが引いた記事の URL を名乗ると、
      # その記事は既に入っているので、**まとめ自体が落ちる**（出典は本文に書く）
      prompt = News.digest_prompt(defined_topic("tazuna_tech"))

      assert prompt =~ "url: **空のままにしてください。**"
      assert prompt =~ "出典は本文の「出典:」行に書きます"
    end

    test "まとめの見出しは回ごとに変わる" do
      # 見出しは重複の鍵。日付だけだと、1 日に 2 回まとめたときの 2 回目が
      # 丸ごと捨てられる（要約は足すだけの回なので、既にある見出しは入らない）
      prompt = News.digest_prompt(defined_topic("tazuna_tech"))

      assert prompt =~ "{now}"
      assert prompt =~ "丸ごと捨てられます"
    end

    test "整理は、まとめに触らない" do
      # 同じ出来事に触れているので重複に見えるが、落とすと画面と通知から
      # まとめが消える（実際に消えた）
      prompt = News.refine_prompt(defined_topic("tazuna_tech"))

      assert prompt =~ "「まとめ」「興味のまとめ」のタグが付いたものには触らないでください"
    end

    test "整理は、ニュース以外も探す" do
      # 配信元から機械的に入るのは決まった媒体のぶんだけ。
      # 記事も論文も、探しに行かなければ永遠に入らない
      prompt = News.refine_prompt(defined_topic("tazuna_tech"))

      assert prompt =~ "話題になっている"
      assert prompt =~ "論文"
      assert prompt =~ "ニュースだけではありません"
    end

    test "整理の回の依頼文には、今あるものの差し込み口が要る" do
      # Chiezo が作る時点で弾く決まり（無いと、AI は今あるものを知らないまま書く）
      topic = defined_topic("tazuna_tech")

      for sweep <- News.sweeps(topic), text = Map.get(sweep, :prompt), is_binary(text) do
        assert text =~ "{recent}" or text =~ "{current}",
               "#{sweep.name} の依頼文に差し込み口がありません"
      end
    end
  end

  describe "まとめ" do
    test "記事の一覧には混ぜない" do
      # 一覧に混ぜると、まとめが記事のふりをして並ぶ
      recent = [
        recent("ふつうの記事"),
        Map.put(recent("まとめ: 今日の動き（2026-09-13）"), "tags", ["まとめ"])
      ]

      assert Enum.map(News.to_articles(recent), & &1.title) == ["ふつうの記事"]
      assert Enum.map(News.to_digests(recent), & &1.title) == ["まとめ: 今日の動き（2026-09-13）"]
    end

    test "読者に出さないものの選り分けは Chiezo に任せる" do
      # 消えたものも、まだ整理が読んでいないものも、Chiezo が既定で落として返す。
      # こちらが落とす形にすると、**あちらの印が増えるたびにここも直して回る**
      # ことになり、しかも漏れるのは読者の画面だけなので気づくのが遅い
      recent = [
        recent("ふつうの記事"),
        Map.put(recent("まとめ: 生きている"), "tags", ["まとめ"])
      ]

      assert Enum.map(News.to_articles(recent), & &1.title) == ["ふつうの記事"]
      assert Enum.map(News.to_digests(recent), & &1.title) == ["まとめ: 生きている"]
    end

    test "話題度の印を、記事ごとに持って出す" do
      # 印が無いものに「低」を当てない —— まだ整理が読んでいないだけの 1 件が、
      # 「話題になっていない」として並ぶ
      recent = [
        Map.put(recent("沸いている記事"), "tags", ["ニュース", "話題度:高"]),
        recent("まだ読まれていない記事")
      ]

      assert [%{buzz: "高"}, %{buzz: nil}] = News.to_articles(recent)
    end

    test "まとめは、直近の窓に無くてもタグで引き直す" do
      # 見出しの回が 60 件足すと、まとめは直近の一覧から押し出される
      # （まとめが出ない時間帯ができた）
      stub_digest_by_tag()

      assert %{title: title} = read_digest()
      assert title == "まとめ: 新しい回（2026-09-18 07:00）"
    end

    test "本文は、一覧の要約ではなく取り直したものを出す" do
      # 一覧に付いてくる要約は冒頭だけ（実測で 240 文字）。1 件ずつの索引には
      # それで足りるが、通しで読ませるまとめは途中で切れる
      stub_digest(fn _title ->
        HttpStub.ok(Jason.encode!(%{"title" => "まとめ", "body" => "## 要旨\n最後まで読める本文。"}))
      end)

      assert %{summary: summary} = read_digest()
      assert summary =~ "最後まで読める本文。"
    end

    test "本文を取り直せなければ、冒頭のまま出す" do
      # 切れた文が出るほうが、まとめの枠ごと消えるよりまし
      stub_digest(fn _title -> {:ok, %{status: 404, body: ""}} end)

      assert %{summary: summary} = read_digest()
      assert summary == "まとめ: 今日の動き（2026-09-13）の要約。"
    end

    test "引いた記事は、見出しで引き直す" do
      # 画面に並んでいる直近のぶんと突き合わせる形にはしない —— まとめは前回から
      # 今回までに入った全部から引くので、そこに収まる保証がない。
      # 見出しは Chiezo の中で 1 件を指す鍵なので、引き直せば窓の大きさに関係なく当たる
      body = "## 章\n動きました。\n出典: [遠い記事](https://example.com/9)"

      stub_digest(fn
        "まとめ: 今日の動き（2026-09-13）" ->
          HttpStub.ok(Jason.encode!(%{"title" => "まとめ", "body" => body}))

        "遠い記事" ->
          HttpStub.ok(
            Jason.encode!(%{
              "title" => "遠い記事",
              "extra" => %{
                "url" => "https://example.com/9",
                "image" => "https://example.com/9.png"
              }
            })
          )
      end)

      assert %{cited: cited} = read_digest()

      assert cited == %{
               "https://example.com/9" => %{
                 title: "遠い記事",
                 image: "https://example.com/9.png",
                 url: "https://example.com/9"
               }
             }
    end

    test "引き直せなかった記事は、黙って落とす" do
      # 消えた記事を引いていることはある（整理の回が落とした後など）。
      # そこで画面ごと止めない
      body = "## 章\n動きました。\n出典: [もう無い記事](https://example.com/9)"

      stub_digest(fn
        "まとめ: 今日の動き（2026-09-13）" ->
          HttpStub.ok(Jason.encode!(%{"title" => "まとめ", "body" => body}))

        _title ->
          {:ok, %{status: 404, body: ""}}
      end)

      assert %{cited: cited, summary: summary} = read_digest()
      assert cited == %{}
      assert summary =~ "動きました。"
    end
  end

  defp stub_digest(doc) do
    digest = Map.put(recent("まとめ: 今日の動き（2026-09-13）"), "tags", ["まとめ"])

    HttpStub.stub(fn
      %{url: "http://chiezo.test:7010/v1/collect"} ->
        HttpStub.ok(list_body([collection()]))

      %{url: "http://chiezo.test:7010/v1/sources"} ->
        HttpStub.ok(sources_body(42))

      %{url: "http://chiezo.test:7010/v1/tazuna_news/doc?" <> query} ->
        doc.(query |> URI.decode_query() |> Map.get("title"))

      %{url: _detail} ->
        HttpStub.ok(detail_body([digest]))
    end)
  end

  # まとめが直近の一覧に入っていない面（見出しの回が足した直後）
  defp stub_digest_by_tag do
    digest = Map.put(recent("まとめ: 新しい回（2026-09-18 07:00）"), "tags", ["まとめ"])
    old = Map.put(recent("まとめ: 古い回（2026-09-17 07:00）"), "tags", ["まとめ"])

    HttpStub.stub(fn
      %{url: "http://chiezo.test:7010/v1/collect"} ->
        HttpStub.ok(list_body([collection()]))

      %{url: "http://chiezo.test:7010/v1/sources"} ->
        HttpStub.ok(sources_body(42))

      %{url: "http://chiezo.test:7010/v1/tazuna_news/filter?" <> _query} ->
        # 点数の順で返る（新しい順ではない）ので、古いほうを先に置く
        HttpStub.ok(
          Jason.encode!(%{
            "results" => [
              Map.put(old, "updated_at", "2026-09-17T22:00:00+00:00"),
              Map.put(digest, "updated_at", "2026-09-18T22:00:00+00:00")
            ]
          })
        )

      %{url: "http://chiezo.test:7010/v1/tazuna_news/doc?" <> _query} ->
        HttpStub.ok(Jason.encode!(%{"title" => "まとめ", "body" => "## 要旨\n本文。"}))

      %{url: _detail} ->
        # 一覧には記事しか残っていない
        HttpStub.ok(detail_body([recent("新しい記事")]))
    end)
  end

  defp read_digest do
    name = start_news()
    News.subscribe()
    News.refresh(name)

    # **先頭が画面に出るまとめ**（新しい順に並べてある）。本文を取り直すのもここだけ
    assert_receive {:news_updated, %{status: :ready, digests: [digest | _rest]}}, 2_000
    digest
  end
end
