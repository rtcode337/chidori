defmodule Tazuna.RelationsTest do
  use ExUnit.Case, async: false

  alias Tazuna.HttpStub
  alias Tazuna.Relations

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
      assert payload["prompt"] =~ "{current}"
      assert payload["requested_by"] == "tazuna"

      # **回る先は Chiezo に割らせる。** 全員が必ずどこかの区画に入る見出し順で、
      # 1 区画 25 人 —— **1 回の答えが長くなりすぎない大きさ**にしてある
      # （50 人ずつで聞いていた頃、AI の答えが出力上限に当たって途中で切れた）
      # **区画は地域 × 生年。** 辞書順の塊には意味が無く、同じ区画に入った 2 人に
      # 何の関係も無かった（影響関係も漏れも見つけようがない）
      assert payload["partition"] ==
               %{"by" => "band", "prefix" => "地域", "value" => "年代", "target" => 25}

      # **実在しない見出しを指すタグは Chiezo が焼く前に落とす。** AI は代表作を
      # 挙げられても、それが記事として存在するかは知らない —— 図は「タグがある =
      # 押せば何か出る」として印を付けるので、混ざっていると押しても何も出ない印が並ぶ
      # **網羅。** ある括りの全部が対象で、古いものが要らなくなることはない
      assert payload["kind"] == "stock"

      assert payload["verify_tags"] == [
               %{"prefix" => "代表作", "source" => "jawiki"},
               %{"prefix" => "関連", "source" => "jawiki"}
             ]

      # **巡回は 5 本で、頼むことが違う。** 名簿は機械で引き直すだけ（AI を呼ばない）、
      # ざっとは区画の材料を埋め（数日で一周）、調査は区画ごとに仕上げ、
      # 漏れ探しは足すだけ、割り込みは時計を持たない
      # **仕事は 3 つ。** 名簿を作る → 区画の材料を埋める → 区画ごとに仕上げる
      assert [roster, rough, survey] = payload["sweeps"]

      # 名簿の回は、AI が肉付けしたぶんを薄い内容で上書きしないよう足すだけにする
      assert roster["use_extract"] == true
      assert roster["only_new"] == true
      # **一度きり。** 元の Wikipedia が変わらない限り何度やっても同じ
      assert roster["once"] == true

      assert rough["name"] == "ざっと"

      # 一周を数日で終える（区画の材料が埋まるまで、後の回は走れない）
      assert rough["cover_days"] == 3
      assert rough["after"] == "名簿"

      # **一周したら止まる。** 行き渡れば用が済む回で、止めないと 2 周目 3 周目が
      # 回り続け、同じことを何度も聞くために枠を使う
      assert rough["one_lap"] == true
      # 埋める回は収集の依頼文のまま（巡回ごとには持たない）
      refute Map.has_key?(rough, "prompt")

      assert survey["name"] == "調査"

      # **一周の日数で決める。** 1 日 1 区画にしていた頃は、400 区画を一周するのに
      # 400 日かかっていた —— 手入れの回が一周しないなら、区画で割っている意味が無い
      assert survey["cover_days"] == 21
      assert survey["effort"] == "high"

      # **ざっとが一周するまで走らない。** 年代の分からない人が 3 割いる状態で
      # 漏れを探させても、その人たちは別の区画にいるだけ
      assert survey["after"] == "ざっと"
      assert survey["prompt"] =~ "この区画ぶんだけ仕上げて"

      assert_received {:read, url}
      # 一枚ものなので、新しい順に何件かではなく全部を引く
      assert url =~ "/filter?"
      assert url =~ "tag="

      assert Enum.map(relation.nodes, & &1.name) == ["クロード・モネ", "フィンセント・ファン・ゴッホ"]
      assert [%{label: "光", kind: :influence}] = relation.edges
      # 見出しなど図そのもの以外は表示例のものを引き継ぐ
      assert relation.title == fallback().title
    end

    test "押しても走らせない。tazuna の設定を送り直すだけ" do
      # **走らせると定時の巡回がその回ぶん先送りになる**（押した人にはそれが見えない）。
      # 集めるのは Chiezo が決まった間隔で回すもの。
      # 送り直すのは、作るときの POST が「もうある」で断られるため —— それだけだと
      # tazuna 側で指示文や区画を直しても永遠に届かない
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
          HttpStub.ok(Jason.encode!(%{"collections" => [%{"name" => "tazuna_painters"}]}))

        %{method: :get, url: url} ->
          if String.contains?(url, "/filter?") do
            HttpStub.ok(docs_body([painter_doc("クロード・モネ", ["年代:1860-1920"])]))
          else
            HttpStub.ok(
              Jason.encode!(%{
                "name" => "tazuna_painters",
                "extract" => %{"source" => "jawiki", "tag" => "画家"}
              })
            )
          end
      end)

      assert {:ok, %{nodes: [%{name: "クロード・モネ"}]}} =
               Relations.push_painters(@base, fallback())

      # 指示文・区画・巡回がそのまま向こうへ行く
      assert_received {:patched, url, patch}
      assert url =~ "/v1/collect/tazuna_painters"
      assert patch["prompt"] =~ "{partition}"

      assert patch["partition"] ==
               %{"by" => "band", "prefix" => "地域", "value" => "年代", "target" => 25}

      assert [
               %{"use_extract" => true, "once" => true},
               %{"name" => "ざっと", "after" => "名簿"},
               %{"name" => "調査", "after" => "ざっと"}
             ] = patch["sweeps"]

      # **走らせない**
      refute_received {:ran, _url}
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
              "collections" => [%{"name" => "tazuna_painters", "enabled" => false}]
            })
          )

        %{method: :get, url: url} ->
          if String.contains?(url, "/filter?") do
            HttpStub.ok(docs_body([painter_doc("クロード・モネ", ["年代:1860-1920"])]))
          else
            HttpStub.ok(
              Jason.encode!(%{
                "name" => "tazuna_painters",
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
          HttpStub.ok(Jason.encode!(%{"collections" => [%{"name" => "tazuna_painters"}]}))

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
          HttpStub.ok(Jason.encode!(%{"collections" => [%{"name" => "tazuna_painters"}]}))

        %{method: :get} ->
          {:ok, %{status: 404, body: ""}}
      end)

      # 収集の状態も一緒に返す（有効にしていないのか、まだ走っていないのかで
      # 次にすることが違う）
      assert {:error, {:nothing_collected, _c}} = Relations.fetch_painters(@base, fallback())
    end

    test "収集そのものが無ければ、溜まっていないのとは分けて言う" do
      # どちらも図は出ないが、次にすることが違う —— 溜まっていないなら Chiezo の
      # 画面で有効にする、作られていないなら tazuna で「関連図を収集」を押す
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
        {:ok, %{status: 400, body: ~s({"error":"kind は flow / stock のどれかにしてください"})}}
      end)

      assert {:error, {:chiezo_refused, 400, message}} =
               Relations.request_painters(@base, fallback())

      assert message =~ "kind"
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

  test "区画ごとの回は、漏れ探し・磨き・削除をまとめて頼む" do
    # 3 本に分けていた頃は、同じ区画を 3 回渡して 3 回とも同じ人たちを読ませていた。
    # 読む材料が同じなら、仕事も一度に頼むほうが安く、判断も揃う
    prompt = Relations.painters_survey_prompt()

    assert prompt =~ "上に並んでいるのが、この範囲の全員です"
    assert prompt =~ "漏れを足す"
    assert prompt =~ "内容を磨く"
    assert prompt =~ "要らないものを消す"

    # 挙げるものが無ければ挙げなくてよい（既にいる人を挙げ直させない）
    assert prompt =~ "足さなくて構いません"
  end

  test "指示文が頼むのは、Wikipedia に書いていないことだけ" do
    prompt = Relations.painters_prompt()

    # 図の構造は Chiezo に持ち込まない。属性と関係はタグに載せる
    assert prompt =~ "影響元:"
    assert prompt =~ "代表作:"

    # **区画の材料がいちばん急ぎ。** 年代と地域が空だと「年代不明」の置き場に入り、
    # 同じ時代・同じ地域の画家と一緒に見てもらえない（実測で 3 割が年代を持たない）
    assert prompt =~ "まず「年代」と「地域」を埋めてください"
    assert prompt =~ "この 2 つで区画が決まる"

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

  test "名簿の引き方は tazuna が持つ" do
    spec = Relations.painters_extract()

    # **カテゴリは書き並べない。** 名前の付き方が揃っておらず（「イギリス」と
    # 「イングランド」は別のカテゴリで、中身は圧倒的に後者に寄っている）、書き並べると
    # 必ず取りこぼす —— 実際に「アメリカ合衆国」が丸ごと落ち、ホッパーもポロックも
    # ホイッスラーも名簿に居なかった
    assert spec.tag_suffix =~ "の画家"

    # **呼び方は 1 つではない。** 「の画家」だけだと「〜の女性画家」が丸ごと落ちる
    # （44 カテゴリ・1,877 記事。草間彌生もそこにいた）
    assert spec.tag_suffix =~ "の女性画家"

    # 絵も描く別の職業の人は外す（カテゴリは持ち主の職業を選ばない）
    assert spec.not_tag =~ "俳優"
  end

  test "広げた末尾でも、地域と様式のタグが付く" do
    # **末尾だけ広げても足りない。** 地域を作る規則が「〜の画家」しか見ていないと、
    # 入ってきた画家に地域も様式も付かず、横軸の「その他」に落ちる
    formats =
      Relations.painters_extract().tags
      |> Enum.filter(&Map.has_key?(&1, :pattern))
      |> Map.new(&{&1.pattern, &1.format})

    region =
      Enum.find(formats, fn {pattern, _format} -> pattern =~ "世紀" end)
      |> elem(0)
      |> Regex.compile!()

    assert Regex.run(region, "20世紀日本の女性画家") == ["20世紀日本の女性画家", "日本"]
    assert Regex.run(region, "19世紀フランスの画家") == ["19世紀フランスの画家", "フランス"]
  end

  test "知らない理由でも、何が起きたかは画面に出す" do
    # 「収集に失敗しました」だけだと、押した人にも直す人にも分からない
    assert TazunaWeb.RelationsLive.status_message(%{status: :unavailable, reason: :なにか}) =~
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

  describe "図の置き方" do
    alias Tazuna.Relations

    test "いちばん上と下のノードが、重なっている UI の下に入らない" do
      # 探す欄と道具は図の上に、操作の案内は下に重ねてある。余白が無いと、
      # **引きずっても拡大しても出てこない**（重なっているものは一緒に動かない）
      margin = Relations.canvas_margin()

      for {key, count} <- [{"painters", 8}, {"people", 10}] do
        nodes = for n <- 1..count, do: %{id: "n#{n}", name: "n#{n}"}
        laid_out = Relations.layout_nodes(nodes, key)
        height = Relations.canvas_height(count, key)

        for node <- laid_out do
          assert node.y >= margin, "#{key}: 上の余白に食い込んでいます"
          assert node.y <= height - margin, "#{key}: 下の余白に食い込んでいます"
        end
      end
    end

    test "余白のぶんだけ面を広げる" do
      # 中身を縮めて余白を作ると、ノードどうしが近づいて札が重なる
      margin = Relations.canvas_margin()

      assert Relations.canvas_height(8, "painters") == 560 + 2 * margin
      assert Relations.canvas_height(1, "people") == 560 + 2 * margin
    end
  end
end
