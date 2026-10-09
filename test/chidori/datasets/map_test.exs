defmodule Chidori.Datasets.MapTest do
  @moduledoc """
  区画の地図。見ているのは、**鍵から座標が読めること**と、
  **南北で横の縮尺が変わらないこと**（メルカトル）です。
  """

  use ExUnit.Case, async: true

  alias Chidori.Datasets.Map, as: PartitionMap

  defp row(key, opts \\ []) do
    %{key: key, count: opts[:count] || 1, stage: opts[:stage] || 0, by: opts[:by]}
  end

  test "鍵から四角を作る" do
    rects = PartitionMap.build([row("35.0,135.0/36.0,136.0")]).rects

    assert [%{key: "35.0,135.0/36.0,136.0", x: +0.0, y: +0.0}] = rects
  end

  test "緯度経度を、区画と同じ投影で図の座標へ直す" do
    # 地名で探した場所へ寄るのに使う。区画と別の置き方をすると、違うところへ寄る
    map = PartitionMap.build([row("35.0,135.0/36.0,136.0"), row("34.0,136.0/35.0,137.0")])
    [north_west, south_east] = map.rects

    assert PartitionMap.xy(map, 36.0, 135.0) == %{x: north_west.x, y: north_west.y}

    # 図の座標は 0.1 単位に丸めてある
    %{x: x, y: y} = PartitionMap.xy(map, 34.0, 137.0)
    assert_in_delta x, south_east.x + south_east.width, 0.1
    assert_in_delta y, south_east.y + south_east.height, 0.1

    assert PartitionMap.xy(PartitionMap.build([]), 35.0, 135.0) == nil
  end

  test "西と北が左上" do
    # 緯度は上が大きい（画面の y は下が大きい）ので、そのまま使うと南北が逆さになる
    map = PartitionMap.build([row("35.0,135.0/36.0,136.0"), row("34.0,136.0/35.0,137.0")])
    [north_west, south_east] = map.rects

    assert north_west.x < south_east.x
    assert north_west.y < south_east.y
  end

  test "南北で横の縮尺が変わらない" do
    # 緯度をそのまま縦に使うと、北へ行くほど横に潰れて見える（日本は南北に長い）。
    # 同じ 1 度四方なら、北の区画のほうが**縦に伸びる**のがメルカトル
    map =
      PartitionMap.build([
        row("25.0,135.0/26.0,136.0"),
        row("44.0,135.0/45.0,136.0")
      ])

    [south, north] = map.rects

    assert south.width == north.width
    assert north.height > south.height
  end

  test "細い区画は細いまま描く" do
    # 見える太さまで太らせると、**寄っても本当の大きさに戻らない** ——
    # 同じ塊が大きくなるだけで、区画の細かさは最後まで読めない
    map =
      PartitionMap.build([
        row("35.0,135.0/45.0,145.0"),
        row("35.0,135.0/35.001,135.001")
      ])

    [wide, thin] = map.rects

    assert thin.width > 0
    assert thin.height > 0
    # 広さの比は 1 万倍。太らせていれば、ここが 100 倍ほどに縮む
    assert thin.width < wide.width / 1_000
  end

  test "隣り合う区画は端がぴったり合う" do
    # 幅を別々に丸めると隣と端が合わず、**白い筋**になって出る。
    # 隣り合う区画は同じ境界の値を持つので、端で丸めれば必ず一致する
    map =
      PartitionMap.build([
        row("35.0,135.0/36.0,135.3333"),
        row("35.0,135.3333/36.0,136.0"),
        # 縦も同じ（南北は投影を挟むので、丸める前の値は割り切れない）
        row("36.0,135.0/36.6667,135.3333")
      ])

    [left, right, upper] = map.rects

    assert left.x + left.width == right.x
    assert upper.y + upper.height == left.y
  end

  test "濃さは詰まり具合の順に散らす" do
    # 値の比で塗ると、桁違いに詰まった 1 区画のせいで**他が全部同じ薄さに潰れる**
    map =
      PartitionMap.build([
        row("35.0,135.0/36.0,136.0", count: 1),
        row("36.0,135.0/37.0,136.0", count: 2),
        row("37.0,135.0/38.0,136.0", count: 1_000_000)
      ])

    [thin, middle, dense] = map.rects

    assert thin.tone < middle.tone
    assert middle.tone < dense.tone
    assert dense.tone == 1.0
  end

  test "見終わった数を数える" do
    map =
      PartitionMap.build([
        row("35.0,135.0/36.0,136.0", stage: 1, by: "ざっと見る"),
        row("36.0,136.0/37.0,137.0")
      ])

    assert map.visited == 1
  end

  test "どこまで見たかを持ち越す" do
    # 区画を回る巡回は順に走るので、**どちらの目で見たか**で色が変わる
    map =
      PartitionMap.build([
        row("35.0,135.0/36.0,136.0", stage: 2, by: "整理"),
        row("36.0,136.0/37.0,137.0")
      ])

    [deep, untouched] = map.rects

    assert deep.stage == 2
    assert deep.by == "整理"
    assert untouched.stage == 0
    assert untouched.by == nil
  end

  test "座標で切っていない区画は地図にしない" do
    # 名前で切った区画を並べても、地図の意味にならない
    assert PartitionMap.build([row("関東"), row("近畿")]).rects == []
  end

  test "区画が無ければ空の図" do
    assert PartitionMap.build([]).rects == []
  end
end
