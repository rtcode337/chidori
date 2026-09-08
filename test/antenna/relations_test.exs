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

    @tag :capture_log
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
          if String.ends_with?(url, "/run"), do: send(test_pid, {:ran, url})
          HttpStub.ok(Jason.encode!(%{"extract" => %{"source" => "jawiki", "tag" => "画家"}}))

        %{method: :patch} ->
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

    test "収集を作るときは、依頼する前に指定を書かせて一緒に渡す" do
      # 作った収集は次の予定が「いま」なので、作ってから指定を持たせに行くと、
      # 書かせている数分のあいだに Chiezo 側が AI の回を始めてしまう（実際にそうなった）
      test_pid = self()

      HttpStub.stub(fn
        %{method: :post, url: @base <> "/v1/collect/draft-extract", body: body} ->
          send(test_pid, {:drafted, Jason.decode!(body)})

          HttpStub.ok(
            Jason.encode!(%{
              "extract" => %{"source" => "jawiki", "tag" => "印象派の画家"},
              "total" => 39
            })
          )

        %{method: :post, url: @base <> "/v1/collect", body: body} ->
          send(test_pid, {:created, Jason.decode!(body)})
          HttpStub.ok("{}")

        %{method: :post, url: _run} ->
          HttpStub.ok("{}")

        %{method: :get, url: @base <> "/v1/collect"} ->
          # まだ無い
          HttpStub.ok(Jason.encode!(%{"collections" => []}))

        %{method: :get, url: _url} ->
          HttpStub.ok(docs_body([painter_doc("クロード・モネ", ["年代:1860-1920"])]))
      end)

      assert {:ok, %{nodes: [_]}} = Relations.collect_painters(@base, fallback())

      # 名前はまだ無いので渡さない（相手も今の指定も無い）
      assert_received {:drafted, %{"name" => nil} = asked}
      # 本番と同じ相手に書かせる（違う相手の指定は、本番で通るか分からない）
      assert asked["backend"] == "claude"
      assert_received {:created, created}
      assert created["extract"]["tag"] == "印象派の画家"
      assert created["mode"] == "refine"
    end

    @tag :capture_log
    test "作った直後は、指定を書かせに行き直さない" do
      # 作るときに書かせたばかり。同じ押下で 2 度目を投げると、時間切れの
      # 待ち時間をもう一度食う（実際にそうなった）
      test_pid = self()

      HttpStub.stub(fn
        %{method: :post, url: @base <> "/v1/collect/draft-extract"} ->
          send(test_pid, :drafted)
          {:ok, %{status: 504, body: ""}}

        %{method: :post} ->
          HttpStub.ok("{}")

        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => []}))

        %{method: :get, url: _url} ->
          HttpStub.ok(docs_body([painter_doc("クロード・モネ", ["年代:1860-1920"])]))
      end)

      assert {:ok, %{nodes: [_]}} = Relations.collect_painters(@base, fallback())

      assert_received :drafted
      refute_received :drafted
    end

    test "指定を持っていなければ、依頼文から書かせて持たせる" do
      # 名簿と年代は Wikipedia から引けば済む。AI に書かせると存在しない画家が混ざる
      test_pid = self()

      HttpStub.stub(fn
        %{method: :post, url: @base <> "/v1/collect/draft-extract", body: body} ->
          send(test_pid, {:drafted, Jason.decode!(body)})

          HttpStub.ok(
            Jason.encode!(%{
              "extract" => %{"source" => "jawiki", "tag" => "印象派の画家"},
              "total" => 39,
              "sample" => []
            })
          )

        %{method: :patch, url: url, body: body} ->
          send(test_pid, {:patched, url, Jason.decode!(body)})
          HttpStub.ok("{}")

        %{method: :post, url: @base <> "/v1/collect"} ->
          HttpStub.ok("{}")

        %{method: :post, url: _run} ->
          HttpStub.ok("{}")

        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => [%{"name" => "antenna_painters"}]}))

        %{method: :get, url: url} ->
          if String.contains?(url, "/filter?") do
            HttpStub.ok(docs_body([painter_doc("クロード・モネ", ["年代:1860-1920"])]))
          else
            HttpStub.ok(Jason.encode!(%{"name" => "antenna_painters"}))
          end
      end)

      assert {:ok, %{nodes: [_]}} = Relations.collect_painters(@base, fallback())

      assert_received {:drafted, payload}
      assert payload["name"] == "antenna_painters"
      # 条件は言葉で渡す（Chiezo は何を集めているかを知らない）
      assert payload["want"] =~ "年代"
      assert payload["want"] =~ "Wikipedia"

      assert_received {:patched, url, patch}
      assert url =~ "/v1/collect/antenna_painters"
      assert patch["extract"]["tag"] == "印象派の画家"
      # まだ何も溜まっていないので、進み具合も空にして機械の側から始めさせる
      assert patch["cursor"] == ""
    end

    test "すでに溜まっているときは、進み具合を空に戻さない" do
      # 戻すと機械の側から作り直しになり、AI が足した影響関係と代表作を
      # 名簿と年代で上書きしてしまう
      test_pid = self()

      HttpStub.stub(fn
        %{method: :post, url: @base <> "/v1/collect/draft-extract"} ->
          HttpStub.ok(Jason.encode!(%{"extract" => %{"source" => "jawiki", "tag" => "画家"}}))

        %{method: :post} ->
          HttpStub.ok("{}")

        %{method: :patch, body: body} ->
          send(test_pid, {:patched, Jason.decode!(body)})
          HttpStub.ok("{}")

        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => [%{"name" => "antenna_painters"}]}))

        %{method: :get, url: @base <> "/v1/sources"} ->
          HttpStub.ok(
            Jason.encode!(%{
              "sources" => [%{"name" => "antenna_painters", "kind" => "collect", "docs" => 33}]
            })
          )

        %{method: :get, url: url} ->
          if String.contains?(url, "/filter?") do
            HttpStub.ok(docs_body([painter_doc("クロード・モネ", ["年代:1860-1920"])]))
          else
            HttpStub.ok(Jason.encode!(%{"name" => "antenna_painters"}))
          end
      end)

      assert {:ok, %{nodes: [_]}} = Relations.collect_painters(@base, fallback())

      assert_received {:patched, patch}
      refute Map.has_key?(patch, "cursor")
    end

    test "すでに指定を持っていれば書かせ直さない" do
      # 決まった結果が出るのは指定のおかげ。毎回書かせると毎回違うものになる
      HttpStub.stub(fn
        %{method: :post, url: @base <> "/v1/collect/draft-extract"} ->
          flunk("指定を持っているのに書かせ直している")

        %{method: :post} ->
          HttpStub.ok("{}")

        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => [%{"name" => "antenna_painters"}]}))

        %{method: :get, url: url} ->
          if String.contains?(url, "/filter?") do
            HttpStub.ok(docs_body([painter_doc("クロード・モネ", ["年代:1860-1920"])]))
          else
            HttpStub.ok(
              Jason.encode!(%{
                "name" => "antenna_painters",
                "extract" => %{"source" => "jawiki", "tag" => "印象派の画家"}
              })
            )
          end
      end)

      assert {:ok, %{nodes: [_]}} = Relations.collect_painters(@base, fallback())
    end

    @tag :capture_log
    test "指定を書かせられなくても、集めるのは続ける" do
      # 指定が無ければ AI が全部集める形に戻るだけで、図が出ないわけではない
      HttpStub.stub(fn
        %{method: :post, url: @base <> "/v1/collect/draft-extract"} ->
          {:ok, %{status: 502, body: ~s({"error":"AI が抽出の指定を返しませんでした"})}}

        %{method: :post} ->
          HttpStub.ok("{}")

        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => [%{"name" => "antenna_painters"}]}))

        %{method: :get, url: url} ->
          if String.contains?(url, "/filter?") do
            HttpStub.ok(docs_body([painter_doc("クロード・モネ", ["年代:1860-1920"])]))
          else
            HttpStub.ok(Jason.encode!(%{"name" => "antenna_painters"}))
          end
      end)

      assert {:ok, %{nodes: [_]}} = Relations.collect_painters(@base, fallback())
    end

    @tag :capture_log
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

    @tag :capture_log
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

    @tag :capture_log
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

    @tag :capture_log
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

    @tag :capture_log
    test "理由が読めなければ、状態だけ返す" do
      HttpStub.stub(fn %{method: :post} -> {:ok, %{status: 400, body: "<html>"}} end)
      assert {:error, {:chiezo_refused, 400, nil}} = Relations.request_painters(@base, fallback())
    end

    @tag :capture_log
    test "集める層が無い Chiezo はそれと分かる" do
      HttpStub.stub(fn %{method: :post} -> {:ok, %{status: 404, body: ""}} end)
      assert {:error, :collect_unsupported} = Relations.request_painters(@base, fallback())
    end

    test "繋がらなければ、そう返す（前の図を消すのは呼ぶ側の判断）" do
      HttpStub.stub(fn _request -> {:error, :boom} end)
      assert {:error, :chiezo_unavailable} = Relations.fetch_painters(@base, fallback())
    end
  end

  test "指示文が頼むのは、Wikipedia に書いていないことだけ" do
    prompt = Relations.painters_prompt()

    # 図の構造は Chiezo に持ち込まない。属性と関係はタグに載せる
    assert prompt =~ "影響元:"
    assert prompt =~ "代表作:"
    # 名簿・年代・様式は抽出で入るので、書かせない（書かせると存在しない画家が混ざる）
    assert prompt =~ "すでに Wikipedia から機械的に入っています"
    # 様式のカテゴリは疎（ゴッホもピカソも持っていない）。空の人には足させる
    assert prompt =~ "空の人には様式のタグを足してください"
    # 名簿は機械で作るので、絵で知られていない人が混ざる。その見分けは AI にしかできない
    assert prompt =~ "絵で知られていない人"
    assert prompt =~ "いまの内容に付いているタグをすべて残したうえで"

    # 少しずつ育てる。進み具合で次にどこから続けるかを決める
    assert prompt =~ "{cursor}"
    assert prompt =~ "10人ほど"
    # 線が引かれていない人から埋めさせる（名簿と年代は最初から入っている）
    assert prompt =~ "まだ影響元のタグが付いていない人を先に"

    # 毎回全部を返させない（返し忘れで消えない作りなので、その必要が無い）
    assert prompt =~ "変えない人を返す必要はありません"
  end

  test "溜まっていないと分かったら、前回の図は出し続けない" do
    # 繋がらない類の失敗と違って、これは「向こうに無い」という確かな答え。
    # 消したのに図が出たままになる（実際にそうなった）
    HttpStub.stub(fn
      %{method: :get, url: @base <> "/v1/collect"} ->
        HttpStub.ok(Jason.encode!(%{"collections" => [%{"name" => "antenna_painters"}]}))

      %{method: :get, url: url} ->
        if String.contains?(url, "/filter?") do
          HttpStub.ok(docs_body([]))
        else
          HttpStub.ok(Jason.encode!(%{"name" => "antenna_painters"}))
        end
    end)

    collected = %{fallback() | nodes: [%{id: "n0", name: "前に集めた画家", kind: :artist}]}

    assert {:error, {:nothing_collected, _c}} = Relations.fetch_painters(@base, collected)
  end

  test "抽出の依頼文は、引ける事実だけを頼む" do
    want = Relations.painters_extract_request()

    # どのカテゴリから何を作るかまで言葉で渡す（Chiezo は中身を知らない）
    assert want =~ "Wikipedia"
    assert want =~ "年代:"
    assert want =~ "様式:"
    assert want =~ "件数は絞らなくて構いません"
    # 書いてあることは全部頼む（頼まなければ、その読み替えは使われない）
    assert want =~ "代表作:"
    assert want =~ "関連:"
    assert want =~ "相互にリンクしている相手"
    # カテゴリは持ち主の職業を選ばない。外す指定まで頼む
    assert want =~ "not_tag"
    # 年代は絞らない（どの時代を見たいかは、頼む側が決めること）
    assert want =~ "年代は絞りません"
    # 書いていないことは頼まない
    refute want =~ "影響"
  end

  test "知らない理由でも、何が起きたかは画面に出す" do
    # 「収集に失敗しました」だけだと、押した人にも直す人にも分からない
    assert AntennaWeb.RelationsLive.status_message(%{status: :unavailable, reason: :なにか}) =~
             ":なにか"
  end
end