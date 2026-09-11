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

  # 抽出の指定が書けた、という Chiezo の応答。**指定が書けないと収集は作られない**
  # ので、書けたかどうかを見ないテストではこれを返しておく
  defp drafted_body do
    Jason.encode!(%{"extract" => %{"source" => "jawiki", "tag" => "画家"}, "total" => 10})
  end

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
        %{method: :post, url: @base <> "/v1/collect/draft-extract"} ->
          HttpStub.ok(drafted_body())

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

      # **回る先は Chiezo に割らせる。** 全員が必ずどこかの区画に入る見出し順で、
      # 1 区画 25 人 —— **1 回の答えが長くなりすぎない大きさ**にしてある
      # （50 人ずつで聞いていた頃、AI の答えが出力上限に当たって途中で切れた）
      assert payload["partition"] == %{"by" => "title", "target" => 25}

      # **巡回は 2 本。** ざっとは 14 日で一周（1 回に見る区画数は Chiezo が
      # 区画の数から計算するので、画家が増えても一周の日数は変わらない）、
      # じっくりは 1 日 1 区画を考える量を上げて見直す
      assert [rough, deep] = payload["sweeps"]
      assert rough["name"] == "ざっと"
      assert rough["cover_days"] == 14
      assert deep["partitions_per_run"] == 1
      assert deep["effort"] == "high"

      assert_received {:read, url}
      # 一枚ものなので、新しい順に何件かではなく全部を引く
      assert url =~ "/filter?"
      assert url =~ "tag="

      assert Enum.map(relation.nodes, & &1.name) == ["クロード・モネ", "フィンセント・ファン・ゴッホ"]
      assert [%{label: "光", kind: :influence}] = relation.edges
      # 見出しなど図そのもの以外は表示例のものを引き継ぐ
      assert relation.title == fallback().title
    end

    test "押しても走らせない。antenna の設定を送り直すだけ" do
      # **走らせると定時の巡回がその回ぶん先送りになる**（押した人にはそれが見えない）。
      # 集めるのは Chiezo が決まった間隔で回すもの。
      # 送り直すのは、作るときの POST が「もうある」で断られるため —— それだけだと
      # antenna 側で指示文や区画を直しても永遠に届かない
      test_pid = self()

      HttpStub.stub(fn
        %{method: :post, url: @base <> "/v1/collect"} ->
          HttpStub.ok("{}")

        %{method: :post, url: url} ->
          if String.ends_with?(url, "/run"), do: send(test_pid, {:ran, url})
          HttpStub.ok(Jason.encode!(%{"extract" => %{"source" => "jawiki", "tag" => "画家"}}))

        %{method: :patch, url: url, body: body} ->
          send(test_pid, {:patched, url, Jason.decode!(body)})
          HttpStub.ok("{}")

        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(
            Jason.encode!(%{"collections" => [%{"name" => "antenna_painters"}]})
          )

        %{method: :get, url: url} ->
          if String.contains?(url, "/filter?") do
            HttpStub.ok(docs_body([painter_doc("クロード・モネ", ["年代:1860-1920"])]))
          else
            HttpStub.ok(
              Jason.encode!(%{
                "name" => "antenna_painters",
                "extract" => %{"source" => "jawiki", "tag" => "画家"}
              })
            )
          end
      end)

      assert {:ok, %{nodes: [%{name: "クロード・モネ"}]}} =
               Relations.push_painters(@base, fallback())

      # 指示文・区画・巡回がそのまま向こうへ行く
      assert_received {:patched, url, patch}
      assert url =~ "/v1/collect/antenna_painters"
      assert patch["prompt"] =~ "{partition}"
      assert patch["partition"] == %{"by" => "title", "target" => 25}
      assert [%{"name" => "ざっと"}, %{"name" => "じっくり"}] = patch["sweeps"]

      # **走らせない**
      refute_received {:ran, _url}
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

      assert {:ok, %{nodes: [_]}} = Relations.push_painters(@base, fallback())

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
          HttpStub.ok(drafted_body())

        %{method: :post} ->
          HttpStub.ok("{}")

        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => []}))

        %{method: :get, url: _url} ->
          HttpStub.ok(docs_body([painter_doc("クロード・モネ", ["年代:1860-1920"])]))
      end)

      assert {:ok, %{nodes: [_]}} = Relations.push_painters(@base, fallback())

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

      assert {:ok, %{nodes: [_]}} = Relations.push_painters(@base, fallback())

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

      assert {:ok, %{nodes: [_]}} = Relations.push_painters(@base, fallback())

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

        %{method: :patch} ->
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

      assert {:ok, %{nodes: [_]}} = Relations.push_painters(@base, fallback())
    end

    @tag :capture_log
    test "指定を書かせられなくても、集めるのは続ける" do
      # 指定が無ければ AI が全部集める形に戻るだけで、図が出ないわけではない
      HttpStub.stub(fn
        %{method: :post, url: @base <> "/v1/collect/draft-extract"} ->
          {:ok, %{status: 502, body: ~s({"error":"AI が抽出の指定を返しませんでした"})}}

        %{method: :post} ->
          HttpStub.ok("{}")

        %{method: :patch} ->
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

      assert {:ok, %{nodes: [_]}} = Relations.push_painters(@base, fallback())
    end

    @tag :capture_log
    test "止まっている収集にも設定は送る（有効にするのは Chiezo 側の判断）" do
      # 押して設定が届かないと、有効にした瞬間に古い指示文で走り出す
      test_pid = self()

      HttpStub.stub(fn
        %{method: :post, url: @base <> "/v1/collect/draft-extract"} ->
          HttpStub.ok(drafted_body())

        %{method: :post} ->
          HttpStub.ok("{}")

        %{method: :patch} ->
          send(test_pid, :patched)
          HttpStub.ok("{}")

        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(
            Jason.encode!(%{
              "collections" => [%{"name" => "antenna_painters", "enabled" => false}]
            })
          )

        %{method: :get, url: url} ->
          if String.contains?(url, "/filter?") do
            HttpStub.ok(docs_body([painter_doc("クロード・モネ", ["年代:1860-1920"])]))
          else
            HttpStub.ok(
              Jason.encode!(%{
                "name" => "antenna_painters",
                "enabled" => false,
                "extract" => %{"source" => "jawiki", "tag" => "画家"}
              })
            )
          end
      end)

      assert {:ok, %{nodes: [_]}} = Relations.push_painters(@base, fallback())
      assert_received :patched
    end

    @tag :capture_log
    test "すでにある収集は 409 が返るだけで、そのまま読みに行く" do
      HttpStub.stub(fn
        %{method: :post, url: @base <> "/v1/collect/draft-extract"} -> HttpStub.ok(drafted_body())
        %{method: :post} -> {:ok, %{status: 409, body: ""}}
        %{method: :get} -> HttpStub.ok(docs_body([painter_doc("A", ["年代:1900"])]))
      end)

      assert {:ok, %{nodes: [%{name: "A"}]}} = Relations.request_painters(@base, fallback())
    end

    test "まだ何も溜まっていなければ、そう分かる理由を返す" do
      HttpStub.stub(fn
        %{method: :post} ->
          HttpStub.ok("{}")

        # 収集はある（作られてはいる）。溜まっていないだけ
        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => [%{"name" => "antenna_painters"}]}))

        %{method: :get} ->
          HttpStub.ok(docs_body([]))
      end)

      # 収集の状態も一緒に返す（有効にしていないのか、まだ走っていないのかで
      # 次にすることが違う）
      assert {:error, {:nothing_collected, _c}} = Relations.fetch_painters(@base, fallback())
    end

    test "焼かれる前はソースごと無い。繋がらないのとは区別する" do
      HttpStub.stub(fn
        %{method: :post} ->
          HttpStub.ok("{}")

        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => [%{"name" => "antenna_painters"}]}))

        %{method: :get} ->
          {:ok, %{status: 404, body: ""}}
      end)

      # 収集の状態も一緒に返す（有効にしていないのか、まだ走っていないのかで
      # 次にすることが違う）
      assert {:error, {:nothing_collected, _c}} = Relations.fetch_painters(@base, fallback())
    end

    test "収集そのものが無ければ、溜まっていないのとは分けて言う" do
      # どちらも図は出ないが、次にすることが違う —— 溜まっていないなら Chiezo の
      # 画面で有効にする、作られていないなら antenna で「関連図を収集」を押す
      HttpStub.stub(fn
        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => []}))

        %{method: :get} ->
          {:ok, %{status: 404, body: ""}}
      end)

      assert {:error, {:collection_missing, nil}} = Relations.fetch_painters(@base, fallback())
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
    assert prompt =~ "名簿と年代は Wikipedia から機械的に入れてあります"

    # 様式のカテゴリは疎（ゴッホもピカソも持っていない）。空の人には足させる
    assert prompt =~ "空の人には様式のタグを足してください"

    # 名簿は機械で作るので、絵で知られていない人が混ざる。その見分けは AI にしかできない
    assert prompt =~ "絵で知られていない人"
    assert prompt =~ "その人にいま付いているタグをすべて残したうえで"

    # 毎回全部を返させない（返し忘れで消えない作りなので、その必要が無い）
    assert prompt =~ "変えない人を返す必要はありません"
  end

  test "誰を見るかは Chiezo が区画で渡す（AI に選ばせない）" do
    prompt = Relations.painters_prompt()

    # 今回見る範囲が差し込まれ、その範囲の画家が {current} に丸ごと入る。
    # **選ばせない**のが要 —— 選ばせていた頃は同じ人を何度も選ぶのを止められず、
    # 1 日 10 人では 2,999 人の一周に 300 日かかった
    assert prompt =~ "{partition}"
    assert prompt =~ "{current}"
    assert prompt =~ "誰を見るか選ぶ必要はありません"
    assert prompt =~ "範囲の外の画家は返さないでください"

    # 進み具合は Chiezo の台帳が持つので、AI に名乗らせない
    refute prompt =~ "{cursor}"
    refute prompt =~ "next_cursor"
  end

  test "影響元の相手は、関連タグから選ばせる" do
    # 区画で切ると {current} はその 50 人だけになる。「いまの内容にいる画家だけ」
    # と頼むと、線が区画の中でしか引かれず図が分断される。関連タグには名簿にいる
    # 相手が載っているので、そこから選ばせれば区画をまたいだ線が引ける
    assert Relations.painters_prompt() =~ "タグに\n    挙がっている画家から選んでください"
  end

  test "名簿はカテゴリを書き並べず、末尾で指させる" do
    request = Relations.painters_extract_request()

    # **書き並べると必ず取りこぼす。** 名前の付き方が揃っておらず（「イギリス」と
    # 「イングランド」は別のカテゴリで、中身は圧倒的に後者に寄っている）、書く側は
    # 思い出しで補うしかない —— 実際に「アメリカ合衆国」が丸ごと落ち、ホッパーも
    # ポロックもホイッスラーも名簿に居なかった
    assert request =~ "tag_suffix"
    assert request =~ "書き並べると必ず取りこぼします"

    # **地域も年代も絞らない。** 限定は頼まれていない
    assert request =~ "地域も年代も絞りません"
    refute request =~ "西洋"
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
    # 地域も年代も絞らない（どこまで見たいかは、頼む側が決めること）
    assert want =~ "地域も年代も絞りません"
    # 書いていないことは頼まない
    refute want =~ "影響"
  end

  test "知らない理由でも、何が起きたかは画面に出す" do
    # 「収集に失敗しました」だけだと、押した人にも直す人にも分からない
    assert AntennaWeb.RelationsLive.status_message(%{status: :unavailable, reason: :なにか}) =~
             ":なにか"
  end

  describe "溜まっているぶんを全部読む" do
    # 図を読む経路は収集の情報も引く。頁の話だけを見たいので、そちらは黙って返す
    defp stub_pages(pages) do
      test_pid = self()

      HttpStub.stub(fn
        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => []}))

        %{method: :get, url: url} ->
          send(test_pid, {:page, url})
          pages.(url)
      end)
    end

    test "1 頁に収まらなければ、続きを継いで読む" do
      # Chiezo の filter は 1 回 500 件までしか返さない。継がないと先頭だけの図になる
      stub_pages(fn url ->
        cond do
          String.contains?(url, "offset=0") ->
            HttpStub.ok(docs_body(for i <- 1..500, do: painter_doc("A#{i}", ["年代:1900"])))

          String.contains?(url, "offset=500") ->
            HttpStub.ok(docs_body(for i <- 1..3, do: painter_doc("B#{i}", ["年代:1910"])))

          true ->
            flunk("読みすぎている: #{url}")
        end
      end)

      assert {:ok, relation} = Relations.fetch_painters(@base, fallback())
      assert length(relation.nodes) == 503
    end

    test "満たない頁で止める" do
      # total を信じて回数を決めると、途中で件数が変わったときに空振りする
      stub_pages(fn _url -> HttpStub.ok(docs_body([painter_doc("A", ["年代:1900"])])) end)

      assert {:ok, _relation} = Relations.fetch_painters(@base, fallback())

      assert_received {:page, _first}
      refute_received {:page, _second}
    end

    test "2 頁目が無くなっても、読めたぶんは図にする" do
      # 読んでいる最中に焼き直されると、途中の頁が 404 になりうる
      stub_pages(fn url ->
        if String.contains?(url, "offset=0") do
          HttpStub.ok(docs_body(for i <- 1..500, do: painter_doc("A#{i}", ["年代:1900"])))
        else
          {:ok, %{status: 404, body: ""}}
        end
      end)

      assert {:ok, relation} = Relations.fetch_painters(@base, fallback())
      assert length(relation.nodes) == 500
    end

    test "1 頁目から無ければ、まだ何も溜まっていない" do
      # stub_pages は収集を空で返すので、ここは「収集が作られていない」ほうになる
      stub_pages(fn _url -> {:ok, %{status: 404, body: ""}} end)
      assert {:error, {:collection_missing, nil}} = Relations.fetch_painters(@base, fallback())
    end
  end

  describe "指定を書けなかったとき" do
    test "収集を作らない" do
      # 指定なしで作ると、名簿が空のまま AI に「いまの内容から 10 人ほど選べ」と
      # 頼むことになり、10 件の図ができて終わる（実測。4,250 人になるはずだった）
      test_pid = self()

      HttpStub.stub(fn
        %{method: :post, url: @base <> "/v1/collect/draft-extract"} ->
          # 「機械では引けない」も Chiezo の答えのうち（200 で返る）
          HttpStub.ok(Jason.encode!(%{"extract" => nil, "reason" => "タグで引けない題材です"}))

        %{method: :post, url: @base <> "/v1/collect"} ->
          send(test_pid, :created)
          HttpStub.ok("{}")

        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => []}))

        %{method: :get, url: _url} ->
          HttpStub.ok(docs_body([]))
      end)

      assert {:error, {:extract_refused, "タグで引けない題材です"}} =
               Relations.request_painters(@base, fallback())

      refute_received :created
    end

    test "Chiezo が添えた理由を捨てない" do
      # 理由が消えると、押した人には何も起きなかったように見える
      HttpStub.stub(fn
        %{method: :post, url: @base <> "/v1/collect/draft-extract"} ->
          HttpStub.ok(Jason.encode!(%{"extract" => nil, "reason" => "  "}))

        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => []}))

        %{method: :get, url: _url} ->
          HttpStub.ok(docs_body([]))
      end)

      # 空白だけの理由は「理由なし」として扱う（画面に空文字を出さない）
      assert {:error, {:extract_refused, nil}} = Relations.request_painters(@base, fallback())
    end

    @tag :capture_log
    test "Chiezo 側の理由はそのまま通す" do
      # 包み直すと「集める層が無い」も「断られた」も同じ 1 つの理由に潰れ、
      # 画面から次の手が読めなくなる
      HttpStub.stub(fn
        %{method: :post, url: @base <> "/v1/collect/draft-extract"} ->
          {:ok, %{status: 404, body: ""}}

        %{method: :get, url: @base <> "/v1/collect"} ->
          HttpStub.ok(Jason.encode!(%{"collections" => []}))

        %{method: :get, url: _url} ->
          HttpStub.ok(docs_body([]))
      end)

      assert {:error, :collect_unsupported} = Relations.request_painters(@base, fallback())
    end
  end
end
