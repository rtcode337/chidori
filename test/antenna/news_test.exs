defmodule Antenna.NewsTest do
  use ExUnit.Case, async: false

  alias Antenna.HttpStub
  alias Antenna.News

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
        "description" => "antenna のニュース",
        "enabled" => true,
        "interval_minutes" => 360,
        "next_run_at" => "2026-09-07T09:00:00+00:00",
        "last_run_at" => "2026-09-07T03:00:00+00:00",
        "last_status" => "ok",
        "prompt" => "{cursor} 以降のニュースを10件。next_cursor に続きを。",
        "last_added" => 3,
        "requested_by" => "antenna",
        "url" => "/search/antenna_news/"
      },
      overrides
    )
  end

  defp list_body(collections), do: Jason.encode!(%{"collections" => collections})

  # 話題の定義そのもの。**DB は見ない** —— 巡回も配信元も定義が持っているので、
  # 保存してある設定が無くても組み立てられる
  defp defined_topic(collection),
    do: Enum.find(Antenna.Topics.defined(), &(&1.collection == collection))

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

  describe "to_articles/1" do
    test "見出しと要約と、原文へのリンクを組み立てる" do
      assert [article] = News.to_articles([recent("静かな話題")])
      assert article.title == "静かな話題"
      # 出典は Chiezo の中の入口ではなく、集めた1件の原文
      assert article.url == "https://example.com/1"
      assert article.summary == "静かな話題の要約。"
      assert article.collected_at == "2026-09-07T03:00:00+00:00"
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
      assert c.url == "http://chiezo.test:7010/search/antenna_news/"

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

        %{method: :get, url: url} ->
          assert url =~ "/v1/collect/antenna_news"
          HttpStub.ok(detail_body([recent("地震の続報")]))
      end)

      name = start_news()
      News.subscribe()
      News.refresh(name)

      assert_receive {:news_updated, %{status: :loading}}, 1_000
      assert_receive {:news_updated, %{status: :ready} = news}, 2_000
      assert [%{title: "地震の続報", importance: 2}] = news.articles
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
      assert payload["name"] == "antenna_news"
      assert payload["requested_by"] == "antenna"
      # 実行のたびに進む印を使う（前回以降を集めるため）
      assert payload["prompt"] =~ "{cursor}"
      assert payload["prompt"] =~ "next_cursor"
      # **流れ。** 時とともに増えるものを追っていて、古いものは順に要らなくなる
      # （落とさないと、この収集は永久に増え続ける）
      assert payload["kind"] == "flow"
      # 巡回は仕事ごとに分ける（集める・漏れを探す・読んで印を付ける・まとめる・割り込み）
      assert Enum.map(payload["sweeps"], & &1["name"]) ==
               ["集める", "漏れ探し", "情報更新", "要約", "割り込み"]
      # 割り込みは時計を持たない 1 本（頼まれたときだけ動く）
      assert List.last(payload["sweeps"])["on_demand"] == true
      # 配信元を持たない話題なので、外の道具は付けない（集めるところから AI に頼む）
      refute payload["feed"]

      # 名指ししていないので、相手は Chiezo にまかせる（項目ごと送らない）
      refute Map.has_key?(payload, "backend")

      assert_receive {:news_updated, %{status: :ready, collection: %{enabled: false}}}, 2_000
    end

    test "相手を名指しして依頼できる" do
      System.put_env("ANTENNA_NEWS_BACKEND", "antigravity")
      System.put_env("ANTENNA_NEWS_MODEL", "haiku")

      on_exit(fn ->
        System.delete_env("ANTENNA_NEWS_BACKEND")
        System.delete_env("ANTENNA_NEWS_MODEL")
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

  describe "巡回" do
    test "仕事ごとに別の時計で回す" do
      names = defined_topic("antenna_news") |> News.sweeps() |> Enum.map(& &1.name)

      assert names == ["集める", "漏れ探し", "情報更新", "要約", "割り込み"]
    end

    test "配信元を持つ話題は、集めるところを機械にまかせる" do
      [intake | _rest] = defined_topic("antenna_tech") |> News.sweeps()

      assert intake.name == "見出し"
      assert intake.use_feed == true
      # **足すだけと組にする** —— 組にしないと、情報更新が付けたタグを
      # 配信の薄い内容で上書きする
      assert intake.only_new == true
    end

    test "配信元は束の名前つきで渡す" do
      spec = defined_topic("antenna_tech") |> News.feed_spec()

      assert Enum.any?(spec.urls, &(&1.tags == ["ニュース"]))
      assert Enum.any?(spec.urls, &(&1.tags == ["記事"]))
    end

    test "配信元を持たない話題に外の道具は付けない" do
      assert defined_topic("antenna_news") |> News.feed_spec() == nil
    end

    test "落とす力を持つのは情報更新の回だけ" do
      # 溜めるほうを機械にまかせた以上、選り分ける口がどこかに要る。
      # ただし足すだけの回に消す力を持たせない（足すはずの回が消し始める）
      topic = defined_topic("antenna_tech")
      prompts = for s <- News.sweeps(topic), into: %{}, do: {s.name, Map.get(s, :prompt)}

      assert prompts["情報更新"] =~ "chiezo_tombstone"
      refute prompts["漏れ探し"] =~ "chiezo_tombstone"
      refute prompts["要約"] =~ "chiezo_tombstone"
    end

    test "漏れ探しは、まとめより高い頻度で回る" do
      # まとめの窓に 1 回しか入らないと、直前に起きたことが最大 12 時間ぶん
      # 抜けたまままとめられる —— ニュースは新しさが落ちると意味が薄い
      sweeps = defined_topic("antenna_tech") |> News.sweeps() |> Map.new(&{&1.name, &1})

      assert sweeps["漏れ探し"].interval_minutes < sweeps["要約"].interval_minutes
      # 印を付ける回も、まとめより先に回る（まとめる頃には印が付いている）
      assert sweeps["情報更新"].interval_minutes < sweeps["要約"].interval_minutes
    end

    test "まとめの見出しは回ごとに変わる" do
      # 見出しは重複の鍵。日付だけだと、1 日に 2 回まとめたときの 2 回目が
      # 丸ごと捨てられる（要約は足すだけの回なので、既にある見出しは入らない）
      prompt = News.digest_prompt(defined_topic("antenna_tech"))

      assert prompt =~ "{now}"
      assert prompt =~ "丸ごと捨てられます"
    end

    test "漏れ探しは、ニュース以外も探す" do
      # 配信元から機械的に入るのは決まった媒体のぶんだけ。
      # 記事も論文も、探しに行かなければ永遠に入らない
      prompt = News.find_missing_prompt(defined_topic("antenna_tech"))

      assert prompt =~ "話題になっている"
      assert prompt =~ "論文"
      assert prompt =~ "ニュースだけではありません"
    end

    test "整理の回の依頼文には、今あるものの差し込み口が要る" do
      # Chiezo が作る時点で弾く決まり（無いと、AI は今あるものを知らないまま書く）
      topic = defined_topic("antenna_tech")

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
  end
end
