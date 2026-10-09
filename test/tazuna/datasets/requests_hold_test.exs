defmodule Tazuna.Datasets.RequestsHoldTest do
  @moduledoc """
  travel-log の「位置OK」（`- [位置確認] 名前 (緯度,経度)`）と「この位置へ直して」
  （`- [位置修正] 名前 (緯度,経度) → (緯度,経度)`）。見ているのは、
  **AI に渡すテキストから外すこと**と、**近くの同じ名前の店を探して Chiezo に座標を
  固定させること**（見つからなかった店も黙って落とさない）です。
  """

  use ExUnit.Case, async: false

  alias Tazuna.Datasets.Requests
  alias Tazuna.HttpStub

  @text """
  # 修正・追加の依頼(食事処) 3件

  - [修正] 駅前うどん (35.68100,139.76700): 閉店している
  - [位置確認] 丸の内食堂 (35.68120,139.76650)
  - [位置確認] 見つからない店 (35.68200,139.76800)
  """

  test "位置確認の行を読み、AI に渡すテキストからは外す" do
    assert Requests.confirms(@text) == [
             %{name: "丸の内食堂", lat: 35.6812, lon: 139.7665},
             %{name: "見つからない店", lat: 35.682, lon: 139.768}
           ]

    rest = Requests.without_confirms(@text)
    assert rest =~ "駅前うどん"
    refute rest =~ "位置確認"
  end

  describe "固定させる" do
    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      parent = self()

      HttpStub.stub(fn
        %{method: :get, url: "http://chiezo.test/v1/tazuna_dining_1/filter?" <> _query} ->
          HttpStub.ok(
            Jason.encode!(%{
              "results" => [
                # 見分けの番号が付いていても同じ店（travel-log は番号を落として出す）
                %{
                  "title" => "丸の内食堂 (1470001)",
                  "tags" => ["食事処", Tazuna.Chiezo.locked_tag()],
                  "extra" => %{"lat" => 35.6813, "lon" => 139.7664}
                },
                # 消えた同名の店は選ばない
                %{
                  "title" => "丸の内食堂 (1470002)",
                  "tags" => ["食事処", "_chiezo_removed"],
                  "extra" => %{"lat" => 35.6812, "lon" => 139.7665}
                }
              ]
            })
          )

        %{method: :post, url: url, body: body} ->
          send(parent, {:posted, url, if(body in ["", nil], do: %{}, else: Jason.decode!(body))})
          HttpStub.ok("{}")
      end)

      :ok
    end

    test "近くの同じ名前の店を探して、その座標を固定させる" do
      dataset = %{collection: "tazuna_dining_1"}

      assert {:ok, result} = Requests.hold(dataset, Requests.confirms(@text))

      assert result.held == ["丸の内食堂"]
      # 見つからなかった店も黙って落とさない
      assert result.missed == ["見つからない店"]

      assert_received {:posted, "http://chiezo.test/v1/collect/tazuna_dining_1/locks", body}
      assert body == %{"title" => "丸の内食堂 (1470001)", "lat" => 35.6812, "lon" => 139.7665}
      refute_received {:posted, _url, _body}
    end

    test "位置修正は、いまの座標で店を探して、動かした先の座標で固定させる" do
      # ピンを動かして指した位置。AI に調べさせずにそのまま固定する
      text = "- [位置修正] 丸の内食堂 (35.68120,139.76650) → (35.68150,139.76600)\n"
      dataset = %{collection: "tazuna_dining_1"}

      assert [%{name: "丸の内食堂", lat: 35.6812, lon: 139.7665, to: {35.6815, 139.766}}] =
               Requests.confirms(text)

      # AI に渡すテキストからは外す
      refute Requests.without_confirms(text) =~ "位置修正"

      assert {:ok, %{held: ["丸の内食堂（位置を直した）"]}} =
               Requests.hold(dataset, Requests.confirms(text))

      assert_received {:posted, "http://chiezo.test/v1/collect/tazuna_dining_1/locks", body}
      assert body == %{"title" => "丸の内食堂 (1470001)", "lat" => 35.6815, "lon" => 139.766}
    end

    test "人が閉店を報告した店は、固定していれば頼む前に固定を外す" do
      # 固定した店は AI の墓標では消えず「閉店の可能性あり」が付くだけなので、
      # 人が現地で見た報告まで残ってしまう
      text = """
      - [修正] 丸の内食堂 (35.68120,139.76650): 閉店している
      - [修正] 駅前うどん (35.68100,139.76700): 営業時間が違う
      """

      assert Requests.closures(text) == [%{name: "丸の内食堂", lat: 35.6812, lon: 139.7665}]

      assert Requests.release_closed(%{collection: "tazuna_dining_1"}, Requests.closures(text)) ==
               ["丸の内食堂"]

      assert_received {:posted, "http://chiezo.test/v1/collect/tazuna_dining_1/locks", body}
      # 緯度・経度を書かないと外れる
      assert body == %{"title" => "丸の内食堂 (1470001)"}
    end

    test "固定していない店は触らない" do
      HttpStub.stub(fn
        %{method: :get} ->
          HttpStub.ok(
            Jason.encode!(%{
              "results" => [
                %{
                  "title" => "丸の内食堂 (1470001)",
                  "tags" => ["食事処"],
                  "extra" => %{"lat" => 35.6812, "lon" => 139.7665}
                }
              ]
            })
          )

        %{method: :post} ->
          flunk("固定していない店の固定を外しに行った")
      end)

      closures = [%{name: "丸の内食堂", lat: 35.6812, lon: 139.7665}]
      assert Requests.release_closed(%{collection: "tazuna_dining_1"}, closures) == []
    end

    test "近くの店が 1 ページに収まらなくても、後ろのページまで探す" do
      # 駅前のように店が密集した場所では、近くの店が 1 ページの上限を超える。
      # 1 ページ目で打ち切ると、名前順で後ろにある店を「近くに無い」と取り違えていた
      parent = self()

      filler =
        for i <- 1..200,
            do: %{
              "title" => "店#{i}",
              "tags" => ["食事処"],
              "extra" => %{"lat" => 35.6812, "lon" => 139.7665}
            }

      HttpStub.stub(fn
        %{method: :get, url: url} ->
          page =
            if url =~ "offset=200",
              do: [
                %{
                  "title" => "福々酒場 駅前店",
                  "tags" => ["食事処"],
                  "extra" => %{"lat" => 35.6812, "lon" => 139.7665}
                }
              ],
              else: filler

          HttpStub.ok(Jason.encode!(%{"results" => page, "total" => 201}))

        %{method: :post, url: url, body: body} ->
          send(parent, {:posted, url, Jason.decode!(body)})
          HttpStub.ok("{}")
      end)

      confirms = [%{name: "福々酒場 駅前店", lat: 35.6812, lon: 139.7665}]

      assert {:ok, %{held: ["福々酒場 駅前店"], missed: []}} =
               Requests.hold(%{collection: "tazuna_dining_1"}, confirms)

      assert_received {:posted, "http://chiezo.test/v1/collect/tazuna_dining_1/locks", body}
      assert body["title"] == "福々酒場 駅前店"
    end

    test "AI を使わずにいま反映するのは、名簿を引く回（機械収集）" do
      dataset = %{collection: "tazuna_dining_1", module: Tazuna.Datasets.Meals}

      assert Requests.apply_now(dataset) == :ok
      assert_received {:posted, url, _body}
      assert url =~ "/v1/collect/tazuna_dining_1/run?sweep="
      assert URI.decode(url) =~ Tazuna.SweepNames.machine()
      # 押したのは人なので、止めている収集でも走らせる印を付ける
      assert url =~ "manual=true"
    end

    test "人が押した操作の印は、by_hand の中だけに付く（定時の頼みには付けない）" do
      :ok = Tazuna.Chiezo.run("http://chiezo.test", "tazuna_dining_1", sweep: "整理")
      assert_received {:posted, url, _body}
      refute url =~ "manual"

      :ok =
        Tazuna.Chiezo.by_hand(fn ->
          Tazuna.Chiezo.focus("http://chiezo.test", "tazuna_dining_1", "直して", [])
        end)

      assert_received {:posted, url, _body}
      assert url =~ "/focus?manual=true"
      refute Tazuna.Chiezo.by_hand?()
    end
  end
end
