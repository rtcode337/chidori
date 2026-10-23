defmodule Chidori.Datasets.GourmetChiezoTest do
  @moduledoc """
  ご当地グルメのうち、Chiezo を読むところ（県ごとの進み具合・travel-log 用の ZIP・
  travel-log からの依頼の振り分け）。Chiezo の応答は `Chidori.HttpStub` で差し込む。
  """

  use Chidori.DataCase, async: false

  alias Chidori.Datasets.Gourmet
  alias Chidori.Datasets.Requests
  alias Chidori.Datasets.TravelLog
  alias Chidori.HttpStub

  @base "http://chiezo.test"

  setup do
    System.put_env("CHIEZO_BASE_URL", @base)
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
    :ok
  end

  defp dataset, do: Gourmet.definition()

  # 収集の 1 件（座標を持つ = 代表店が引き当たったもの）
  defp dish(id, title, prefecture, extra, tags \\ []) do
    %{
      "doc_id" => id,
      "title" => title,
      "tags" => ["ご当地グルメ", "地域:#{prefecture}", "種類:麺類"] ++ tags,
      "extra" => extra
    }
  end

  defp placed, do: %{"lat" => 35.68, "lon" => 139.76, "shop" => %{"name" => "サンプル亭"}}

  defp page(docs), do: HttpStub.ok(Jason.encode!(%{"total" => length(docs), "results" => docs}))

  describe "県ごとの進み具合" do
    test "料理・店（うち店）・代表店あり・代表店まだ（うち引き当てできず）・代表店なしを県ごとに数え、消えたものは数えない" do
      docs = [
        # 店の 1 件も同じ数に入り、内訳（shops）にも数える
        dish(1, "東京の名店", "東京都", placed(), [Gourmet.shop_tag()]),
        dish(2, "東京のそば", "東京都", %{}, [Chidori.Chiezo.unreviewed_tag()]),
        dish(3, "東京の菓子", "東京都", %{"shop" => %{"unresolved" => "辞典に無い"}}),
        dish(4, "消えた店", "東京都", placed(), [
          Chidori.Chiezo.removed_tag(),
          Gourmet.shop_tag()
        ]),
        dish(5, "北の麺", "北海道", placed()),
        dish(7, "店の無い菓子", "東京都", %{"no_shop" => "家庭で作るお菓子で、売っている店が無い"}, [
          Gourmet.no_shop_tag()
        ]),
        %{"doc_id" => 6, "title" => "県の無い料理", "tags" => ["ご当地グルメ", "地域:東京"]}
      ]

      HttpStub.stub(fn
        %{method: :get, url: "http://chiezo.test/v1/chidori_gourmet/filter?" <> query} ->
          # 数えるために、未確認と消えたものも受け取る
          assert URI.decode_query(query)["include_removed"] == "true"
          page(docs)

        %{method: :get, url: "http://chiezo.test/v1/collect/chidori_gourmet/unresolved" <> _} ->
          HttpStub.ok(
            Jason.encode!(%{
              "total" => 1,
              "unresolved" => [%{"title" => "東京の菓子", "reason" => "辞典に無い"}]
            })
          )
      end)

      assert {:ok, progress} = Gourmet.progress()

      assert [tokyo | _] = progress.rows

      assert tokyo == %{
               prefecture: "東京都",
               key: "地域:東京都",
               dishes: 4,
               shops: 1,
               placed: 1,
               # 手がかりなし（東京のそば。AI が見ていなくても数える）と引き当てできず
               pending: 2,
               unresolved: 1,
               no_shop: 1,
               # 県を選んだときに並べる料理（理由つき）
               pending_items: [
                 %{title: "東京のそば", reason: "代表店の手がかりがまだ無い（情報収集の回で探す）"},
                 %{title: "東京の菓子", reason: "辞典に無い"}
               ],
               no_shop_items: [%{title: "店の無い菓子", reason: "家庭で作るお菓子で、売っている店が無い"}]
             }

      assert %{dishes: 1, placed: 1} = Enum.find(progress.rows, &(&1.prefecture == "北海道"))
      assert length(progress.rows) == 47
      assert progress.unplaced_region == 1
      assert progress.unresolved_total == 1
    end

    test "引き当ての口を持たない Chiezo でも、ほかの数は出す" do
      HttpStub.stub(fn
        %{url: "http://chiezo.test/v1/chidori_gourmet/filter?" <> _} ->
          page([dish(1, "東京のうどん", "東京都", placed())])

        %{url: "http://chiezo.test/v1/collect/chidori_gourmet/unresolved" <> _} ->
          {:ok, %{status: 404, body: ~s({"detail":"Not Found"})}}
      end)

      assert {:ok, %{unresolved_total: nil, rows: [%{dishes: 1, placed: 1} | _]}} =
               Gourmet.progress()
    end
  end

  describe "travel-log 用の ZIP" do
    test "代表店のある料理だけを書き、地図に置けなくなった料理と消えた料理は exclude.txt へ" do
      living = [
        dish(1, "東京のうどん", "東京都", placed(), ["裏付け:県"]),
        # 代表店が外れた（前に書き出していれば、travel-log から消す）
        dish(2, "店の閉じたそば", "東京都", %{"shop" => %{"unresolved" => "閉店"}})
      ]

      removed = [
        %{
          "doc_id" => 9,
          "title" => "終わった焼きそば",
          "tags" => ["ご当地グルメ", "地域:東京都", Chidori.Chiezo.removed_tag()],
          "extra" => %{"removed_after_review" => true}
        }
      ]

      HttpStub.stub(fn
        %{url: "http://chiezo.test/v1/chidori_gourmet/filter?" <> query} ->
          if URI.decode_query(query)["include_removed"] == "true",
            do: page(removed),
            else: page(living)

        %{url: "http://chiezo.test/v1/collect/chidori_gourmet/links"} ->
          HttpStub.ok(~s({"links": {}}))
      end)

      assert {:ok, "gourmet.zip", binary, counts} = TravelLog.bundle(dataset())
      assert counts.rows == 1
      assert counts.excluded == 2

      {:ok, files} = :zip.unzip(binary, [:memory])
      files = Map.new(files, fn {name, body} -> {to_string(name), body} end)

      settings = Jason.decode!(files["gourmet/settings.json"])
      assert settings["key"] == "gourmet"
      assert settings["label"] == "ご当地グルメ"
      assert settings["settings"]["rank_enabled"] == true

      # シリーズの並びは種類の語彙の順で固定（読み込むたびに色が入れ替わらない）
      assert Enum.map(settings["series"], & &1["series"]) == Gourmet.kinds()
      assert settings["categories"] == Gourmet.category_order()

      [header, line | _] = String.split(files["gourmet/spots.csv"], "\r\n")
      assert header =~ ",available_months,opening_hours,key"
      assert line =~ "東京のうどん,35.68,139.76,東京都,B,麺類,県の紹介,"

      exclude = files["gourmet/excluded_candidates/exclude.txt"]
      assert exclude =~ "\r\n2\r\n"
      assert exclude =~ "\r\n9\r\n"
      refute exclude =~ "\r\n1\r\n"
    end

    test "料理の代表店と店の 1 件が辞典の同じ記録なら、片方だけを書いて落としたほうは exclude.txt へ" do
      shop = %{
        "name" => "サンプル家",
        "resolved_at" => "2026-10-01T00:00:00Z",
        "identity" => ["osm_japan:osm_type=node;osm_id=1"]
      }

      living = [
        dish(1, "サンプル系ラーメン", "神奈川県", Map.put(placed(), "shop", shop), ["提供店:多数"]),
        dish(2, "サンプル家", "神奈川県", Map.put(placed(), "shop", shop), ["区分:店"])
      ]

      HttpStub.stub(fn
        %{url: "http://chiezo.test/v1/chidori_gourmet/filter?" <> query} ->
          if URI.decode_query(query)["include_removed"] == "true",
            do: page([]),
            else: page(living)

        %{url: "http://chiezo.test/v1/collect/chidori_gourmet/links"} ->
          HttpStub.ok(~s({"links": {}}))
      end)

      assert {:ok, "gourmet.zip", binary, counts} = TravelLog.bundle(dataset())
      assert counts.rows == 1

      {:ok, files} = :zip.unzip(binary, [:memory])
      files = Map.new(files, fn {name, body} -> {to_string(name), body} end)

      assert files["gourmet/spots.csv"] =~ "サンプル系ラーメン,"
      refute files["gourmet/spots.csv"] =~ "\r\nサンプル家,"
      exclude = files["gourmet/excluded_candidates/exclude.txt"]
      assert exclude =~ "\r\n2\r\n"
      refute exclude =~ "\r\n1\r\n"
    end
  end

  describe "travel-log からの依頼を県へ振り分ける" do
    test "名前の出てくる依頼は、近くの同じ名前の料理の県（代表店が県の外にあっても）" do
      HttpStub.stub(fn
        %{url: "http://chiezo.test/v1/chidori_gourmet/filter?" <> _} ->
          # 本店は東京にあるが、料理は福井県の 1 件
          page([dish(1, "ソースカツ丼（福井県）", "福井県", placed())])
      end)

      assert Gourmet.request_partition(%{
               text: "- [修正] ソースカツ丼 (35.68000,139.76000): 代表店が閉店している",
               lat: 35.68,
               lon: 139.76
             }) == "地域:福井県"
    end

    test "名前の無い依頼（追加）は、座標のある県（地図辞典の点の所属）" do
      HttpStub.stub(fn
        %{url: "http://chiezo.test/v1/chidori_gourmet/filter?" <> _} ->
          page([])

        %{url: "http://chiezo.test/v1/osm_japan/filter?" <> _} ->
          page([
            %{"title" => "駅", "extra" => %{"area" => "東京都"}},
            %{"title" => "店", "extra" => %{"area" => "東京都"}},
            %{"title" => "橋", "extra" => %{"area" => "神奈川県"}}
          ])
      end)

      assert Gourmet.request_partition(%{
               text: "- [追加] (35.68000,139.76000): 名物の店がある",
               lat: 35.68,
               lon: 139.76
             }) == "地域:東京都"
    end

    test "控えに県を残し、県ごとにまとめて、その県の区画で頼む" do
      HttpStub.stub(fn
        %{url: "http://chiezo.test/v1/chidori_gourmet/filter?" <> _} ->
          page([dish(1, "ソースカツ丼（福井県）", "福井県", placed())])

        %{url: "http://chiezo.test/v1/osm_japan/filter?" <> _} ->
          page([%{"title" => "駅", "extra" => %{"area" => "東京都"}}])
      end)

      text = """
      - [修正] ソースカツ丼 (35.68000,139.76000): 代表店が閉店している
      - [追加] (35.69000,139.70000): 名物の菓子の店がある
      """

      assert {:ok, %{added: 2}} = Requests.stash(dataset(), text)

      partitions = [%{key: "地域:東京都"}, %{key: "地域:福井県"}]

      assert [%{key: "地域:東京都", items: [_]}, %{key: "地域:福井県", items: [_]}] =
               Requests.pending(dataset(), partitions) |> Enum.sort_by(& &1.key)

      items = Enum.flat_map(Requests.pending(dataset(), partitions), & &1.items)
      plan = Requests.regroup(items, partitions)

      assert plan.keys == ["地域:東京都", "地域:福井県"]
      assert plan.notes["地域:福井県"] =~ "ソースカツ丼"
      refute plan.notes["地域:福井県"] =~ "名物の菓子"
      assert plan.missed == []

      # 台帳から県の区画が消えていたら、迷子として残す（黙って別の区画に入れない）
      assert [%{key: nil, items: [_, _]}] = Requests.pending(dataset(), [])
    end

    test "前置きは料理と代表店の言い方（食事処の前置きとは別）" do
      preface = Requests.preface(dataset())

      assert preface == Gourmet.request_preface()
      assert preface =~ "代表店を選び直して"
      refute preface == Requests.preface()
      # 食事処は今までどおり
      assert Requests.preface(%{collection: "chidori_dining_1"}) == Requests.preface()
    end
  end
end
