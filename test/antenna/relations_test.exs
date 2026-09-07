defmodule Antenna.RelationsTest do
  use ExUnit.Case, async: false

  alias Antenna.HttpStub
  alias Antenna.Relations

  @base "http://chiezo.test:7010"

  defp painter_doc(title, tags) do
    %{"title" => title, "body" => "説明", "tags" => ["画家" | tags]}
  end

  # Chiezo の `filter` が返す形（キーは `results`）
  defp docs_body(docs), do: Jason.encode!(%{"results" => docs, "total" => length(docs)})

  # 表示例をそのまま下敷きにする（本番と同じく、失敗したらこれが残る）
  defp fallback, do: Relations.current("painters")

  describe "画家の図を Chiezo から読む" do
    test "読むだけのときは、何も作りに行かない" do
      # 画面を開くたびに呼ぶ経路。開いただけで向こうに何かが作られるのは驚きが大きい
      HttpStub.stub(fn
        %{method: :post} -> flunk("読むだけのはずが依頼を出している")
        %{method: :get} -> HttpStub.ok(docs_body([painter_doc("A", ["年代:1900"])]))
      end)

      assert {:ok, %{nodes: [%{name: "A"}]}} = Relations.fetch_painters(@base, fallback())
    end

    test "依頼してから、溜まっているものを図にする" do
      test_pid = self()

      HttpStub.stub(fn
        %{method: :post, url: @base <> "/v1/collect", body: body} ->
          send(test_pid, {:requested, Jason.decode!(body)})
          HttpStub.ok("{}")

        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => []}))

        %{method: :get, url: url} ->
          send(test_pid, {:read, url})

          HttpStub.ok(
            docs_body([
              painter_doc("クロード・モネ", ["年代:1860-1920", "様式:印象派"]),
              painter_doc("フィンセント・ファン・ゴッホ", ["年代:1880-1890", "影響元:クロード・モネ:光"])
            ])
          )
      end)

      assert {:ok, relation} = Relations.request_painters(@base, fallback())

      assert_received {:requested, payload}
      # 整理する収集として依頼する（実行のたびに育てていく）
      assert payload["mode"] == "refine"
      assert payload["prompt"] =~ "{current}"
      assert payload["requested_by"] == "antenna"

      assert_received {:read, url}
      # 一枚ものなので、新しい順に何件かではなく全部を引く
      assert url =~ "/filter?"
      assert url =~ "tag="

      assert Enum.map(relation.nodes, & &1.name) == ["クロード・モネ", "フィンセント・ファン・ゴッホ"]
      assert [%{label: "光", kind: :influence}] = relation.edges
      # 見出しなど図そのもの以外は表示例のものを引き継ぐ
      assert relation.title == fallback().title
    end

    test "「収集」を押したら、依頼するだけでなく実際に集めさせる" do
      # 依頼するだけだと一瞬で終わり、画面も変わらないので、押せたのかどうかが
      # 分からなかった。押したときは向こうを 1 回走らせる
      test_pid = self()

      HttpStub.stub(fn
        %{method: :post, url: @base <> "/v1/collect"} ->
          HttpStub.ok("{}")

        %{method: :post, url: url} ->
          send(test_pid, {:ran, url})
          HttpStub.ok("{}")

        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => []}))

        %{method: :get, url: _url} ->
          HttpStub.ok(docs_body([painter_doc("クロード・モネ", ["年代:1860-1920"])]))
      end)

      assert {:ok, %{nodes: [%{name: "クロード・モネ"}]}} =
               Relations.collect_painters(@base, fallback())

      assert_received {:ran, url}
      assert url =~ "/v1/collect/antenna_painters/run"
    end

    test "止まっている収集は集めさせられない。溜まっているものは出したまま理由を添える" do
      HttpStub.stub(fn
        %{method: :post, url: @base <> "/v1/collect"} ->
          HttpStub.ok("{}")

        # 有効にできるのは Chiezo の画面だけ。向こうは 403 で断る
        %{method: :post, url: _run} ->
          {:ok, %{status: 403, body: ""}}

        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => []}))

        %{method: :get, url: _url} ->
          HttpStub.ok(docs_body([painter_doc("クロード・モネ", ["年代:1860-1920"])]))
      end)

      assert {:ok, %{nodes: [_]}, :collection_disabled} =
               Relations.collect_painters(@base, fallback())
    end

    test "止まっていて、まだ何も溜まっていなければ、断られた理由のほうを出す" do
      # 「まだ何も溜まっていません」だけでは、次に何をすればよいか分からない
      HttpStub.stub(fn
        %{method: :post, url: @base <> "/v1/collect"} ->
          HttpStub.ok("{}")

        %{method: :post, url: _run} ->
          {:ok, %{status: 403, body: ""}}

        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(
            Jason.encode!(%{"collections" => [%{"name" => "antenna_painters", "enabled" => false}]})
          )

        %{method: :get, url: _url} ->
          HttpStub.ok(docs_body([]))
      end)

      assert {:error, {:collection_disabled, collection}} =
               Relations.collect_painters(@base, fallback())

      refute collection.enabled
    end

    test "すでにある収集は 409 が返るだけで、そのまま読みに行く" do
      HttpStub.stub(fn
        %{method: :post} -> {:ok, %{status: 409, body: ""}}
        %{method: :get} -> HttpStub.ok(docs_body([painter_doc("A", ["年代:1900"])]))
      end)

      assert {:ok, %{nodes: [%{name: "A"}]}} = Relations.request_painters(@base, fallback())
    end

    test "まだ何も溜まっていなければ、そう分かる理由を返す" do
      HttpStub.stub(fn
        %{method: :post} -> HttpStub.ok("{}")
        %{method: :get} -> HttpStub.ok(docs_body([]))
      end)

      # 収集の状態も一緒に返す（有効にしていないのか、まだ走っていないのかで
      # 次にすることが違う）
      assert {:error, {:nothing_collected, _c}} = Relations.fetch_painters(@base, fallback())
    end

    test "焼かれる前はソースごと無い。繋がらないのとは区別する" do
      HttpStub.stub(fn
        %{method: :post} -> HttpStub.ok("{}")
        %{method: :get} -> {:ok, %{status: 404, body: ""}}
      end)

      # 収集の状態も一緒に返す（有効にしていないのか、まだ走っていないのかで
      # 次にすることが違う）
      assert {:error, {:nothing_collected, _c}} = Relations.fetch_painters(@base, fallback())
    end

    test "断られた理由をそのまま出す" do
      # 数字だけ出しても、押した人には次に何をすればよいか分からない
      # （実際に「400」とだけ出て、Chiezo の版が古いという理由に辿り着けなかった）
      HttpStub.stub(fn %{method: :post} ->
        {:ok, %{status: 400, body: ~s({"error":"mode は append / refine のどれかにしてください"})}}
      end)

      assert {:error, {:chiezo_refused, 400, message}} =
               Relations.request_painters(@base, fallback())

      assert message =~ "mode"
    end

    test "理由が読めなければ、状態だけ返す" do
      HttpStub.stub(fn %{method: :post} -> {:ok, %{status: 400, body: "<html>"}} end)
      assert {:error, {:chiezo_refused, 400, nil}} = Relations.request_painters(@base, fallback())
    end

    test "集める層が無い Chiezo はそれと分かる" do
      HttpStub.stub(fn %{method: :post} -> {:ok, %{status: 404, body: ""}} end)
      assert {:error, :collect_unsupported} = Relations.request_painters(@base, fallback())
    end

    test "繋がらなければ、そう返す（前の図を消すのは呼ぶ側の判断）" do
      HttpStub.stub(fn _request -> {:error, :boom} end)
      assert {:error, :chiezo_unavailable} = Relations.fetch_painters(@base, fallback())
    end
  end

  test "指示文はタグの書き方まで指定する" do
    prompt = Relations.painters_prompt()

    # 図の構造は Chiezo に持ち込まない。属性と関係はタグに載せる
    assert prompt =~ "画家"
    assert prompt =~ "様式:"
    assert prompt =~ "年代:"
    assert prompt =~ "影響元:"

    assert prompt =~ "代表作:"
    # 初回は一気に、以降は少しずつ。進み具合で振り分ける
    assert prompt =~ "{cursor}"
    assert prompt =~ "一気に"
    assert prompt =~ "3人から5人だけ"

    # 毎回全部を返させない（返し忘れで消えない作りなので、その必要が無い）
    assert prompt =~ "変えない人を返す必要はありません"
  end
end
