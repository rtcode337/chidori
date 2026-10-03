defmodule Tazuna.Datasets.RequestsHoldTest do
  @moduledoc """
  travel-log の「位置は正しい」（`- [位置確認] 名前 (緯度,経度)`）。見ているのは、
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
                  "tags" => ["食事処"],
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
          send(parent, {:posted, url, Jason.decode!(body)})
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
  end
end
