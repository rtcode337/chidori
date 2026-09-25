defmodule Tazuna.Datasets.RequestsTest do
  @moduledoc """
  travel-log から届いた依頼のテキストから、座標と区画を引くところ。
  """

  use ExUnit.Case, async: true

  alias Tazuna.Datasets.Requests

  @tokyo "35.6,139.7/35.7,139.8"
  @osaka "34.6,135.4/34.8,135.6"

  defp partitions(keys), do: Enum.map(keys, &%{key: &1})

  test "travel-log のテキストから座標を読む（書かれた順・重複なし）" do
    text = """
    # 修正・追加の依頼(日本の食事処) 3件

    - [修正] 店 (35.65000,139.75000): 閉店
    - [追加] ( 34.70000 , 135.50000 )
    - [追加] (35.65000,139.75000): 同じ場所
    """

    assert Requests.points(text) == [{35.65, 139.75}, {34.7, 135.5}]
  end

  test "区画は矩形のものだけを見て、同じ区画は 1 つにまとめる" do
    points = [{35.65, 139.75}, {35.66, 139.71}, {34.7, 135.5}, {26.2, 127.68}]
    ledger = partitions(["日本|-", @osaka, @tokyo])

    assert Requests.partitions_for(points, ledger) == {[@tokyo, @osaka], [{26.2, 127.68}]}
  end

  test "区画が多すぎたら切らずに断る" do
    keys = for i <- 0..20, do: "#{i}.0,100.0/#{i}.5,100.5"
    text = Enum.map_join(0..20, "\n", &"- [追加] (#{&1}.25,100.25)")

    assert Requests.plan(text, partitions(keys)) == {:error, {:too_many_partitions, 21}}
  end

  test "どの区画にも入らなければ断る" do
    assert Requests.plan("- [追加] (26.2,127.68)", partitions([@tokyo])) ==
             {:error, :no_partition}
  end
end
