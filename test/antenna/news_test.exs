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
        "mode" => "append",
        "prompt" => "{cursor} 以降のニュースを10件。next_cursor に続きを。",
        "last_added" => 3,
        "requested_by" => "antenna",
        "url" => "/search/antenna_news/"
      },
      overrides
    )
  end

  defp list_body(collections), do: Jason.encode!(%{"collections" => collections})

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
      assert c.mode == "append"
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
      # 足していく収集だと明示する（集め方が 2 つある層なので）
      assert payload["mode"] == "append"

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

  describe "importance/1" do
    test "暮らしに関わる語を含む見出しを上に置く" do
      assert {2, _reason} = News.importance("大雨の警報が出ました")
      assert {1, _reason} = News.importance("新しい展覧会が始まりました")
    end
  end
end
