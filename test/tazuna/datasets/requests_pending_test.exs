defmodule Tazuna.Datasets.RequestsPendingTest do
  @moduledoc """
  travel-log から届いた依頼の控え。**すぐには頼まず、区画ごとに溜めてから頼む**ため、
  1 件ずつ座標で控え、見るたびにいまの区画で振り分ける。
  """

  use Tazuna.DataCase, async: true

  alias Tazuna.Datasets.Requests

  @dataset %{collection: "tazuna_dining_test"}
  @tokyo "35.6,139.7/35.7,139.8"
  @osaka "34.6,135.4/34.8,135.6"

  defp partitions(keys), do: Enum.map(keys, &%{key: &1})

  test "1 件は座標の行とその続きの行で、見出しは捨てる" do
    text = """
    # 修正・追加の依頼 2件

    - [修正] 店 (35.65000,139.75000): 閉店
      隣のビルに移った
    - [追加] (34.70000,135.50000): そば屋
    """

    assert [
             %{text: "- [修正] 店 (35.65000,139.75000): 閉店\n  隣のビルに移った", lat: 35.65},
             %{text: "- [追加] (34.70000,135.50000): そば屋", lon: 135.5}
           ] = Requests.items(text)
  end

  test "控えは区画ごとに、件数の多い順にまとまり、区画の外は最後に残る" do
    text = """
    - [修正] A (35.65,139.75): 閉店
    - [追加] (35.68,139.76): そば屋
    - [追加] (34.70,135.50): うどん屋
    - [追加] (26.20,127.68): 範囲の外
    """

    assert {:ok, %{added: 4, skipped: 0}} = Requests.stash(@dataset, text)

    assert [
             %{key: @tokyo, items: [_, _]},
             %{key: @osaka, items: [_]},
             %{key: nil, items: [%{lat: 26.2}]}
           ] = Requests.pending(@dataset, partitions([@osaka, @tokyo]))

    # 貼り直しても増えない
    assert {:ok, %{added: 0, skipped: 4}} = Requests.stash(@dataset, text)
    assert Requests.pending_count(@dataset) == 4
  end

  test "区画を割り直しても、控えは新しい区画に入り直す" do
    Requests.stash(@dataset, "- [追加] (35.65,139.75): そば屋")

    assert [%{key: "35.6,139.7/35.65,139.8"}] =
             Requests.pending(
               @dataset,
               partitions(["35.6,139.7/35.65,139.8", "35.65,139.7/35.7,139.8"])
             )
  end

  test "捨てた控えは消える" do
    Requests.stash(@dataset, "- [追加] (35.65,139.75): そば屋")
    [%{items: items}] = Requests.pending(@dataset, partitions([@tokyo]))

    assert Requests.drop(@dataset, Enum.map(items, & &1.id)) == 1
    assert Requests.pending(@dataset, partitions([@tokyo])) == []
  end

  describe "報告に名前の出てくる店が近くで消えていたら、その店の区画で頼む" do
    defp shop(title, lat, lon, removed?) do
      %{
        "title" => title,
        "tags" => if(removed?, do: ["食事処", "_chiezo_removed"], else: ["食事処"]),
        "extra" => %{"lat" => lat, "lon" => lon}
      }
    end

    test "消えた店の座標で振り分け、依頼の文は報告のまま" do
      # 報告の座標（南の区画）と、消えた店の座標（北の区画）が数百 m ずれている
      text = "- [追加] (35.62,139.75): 駅前の焼肉店 がある（営業している）"
      gone = shop("駅前の焼肉店", 35.68, 139.75, true)

      assert {:ok, %{added: 1}} = Requests.stash(@dataset, text, fn _item -> [gone] end)

      north = "35.65,139.7/35.7,139.8"
      south = "35.6,139.7/35.65,139.8"

      assert [%{key: ^north, items: [%{text: ^text}]}] =
               Requests.pending(@dataset, partitions([south, north]))
    end

    test "同じ名前の生きている店が近くにあれば、報告の座標のまま" do
      item = %{text: "- [追加] (35.62,139.75): 駅前の焼肉店", lat: 35.62, lon: 139.75}
      docs = [shop("駅前の焼肉店", 35.68, 139.75, true), shop("駅前の焼肉店 (123)", 35.621, 139.75, false)]

      assert Requests.revive_point(item, docs) == item
    end

    test "短い名前は見ない（理由の文に紛れて別の店を指しかねない）" do
      item = %{text: "- [追加] (35.62,139.75): 和食の店がある", lat: 35.62, lon: 139.75}

      assert Requests.revive_point(item, [shop("和", 35.68, 139.75, true)]) == item
    end

    test "名前の出てこない消えた店では動かさない" do
      item = %{text: "- [追加] (35.62,139.75): そば屋", lat: 35.62, lon: 139.75}

      assert Requests.revive_point(item, [shop("駅前の焼肉店", 35.68, 139.75, true)]) == item
    end
  end
end
