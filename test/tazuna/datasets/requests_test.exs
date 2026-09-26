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

  test "1 行ずつ、座標の入る区画の補足に振り分ける" do
    # **区画ごとに分ける。** Chiezo は区画ごとに AI を呼ぶので、全部に同じ依頼を渡すと、
    # その店を見ていない AI まで答えようとする
    text = """
    # 修正・追加の依頼(日本の食事処) 4件

    - [修正] 東京の店 (35.65000,139.75000): 閉店
      続きの説明
    - [追加] (34.70000,135.50000): 大阪に足りない店
    - [追加] (26.20000,127.68000): 区画の外
      外の続き
    - [修正] 東京の別の店 (35.66000,139.71000)
    """

    ledger = partitions(["日本|-", @osaka, @tokyo])

    assert {:ok, plan} = Requests.plan(text, ledger)
    # 区画は矩形のものだけを見る。並びは書かれた順
    assert plan.keys == [@tokyo, @osaka]
    assert plan.missed == [{26.2, 127.68}]
    assert length(plan.points) == 4

    tokyo = plan.notes[@tokyo]

    # 見出しはどの区画にも付け、座標の無い行は直前の依頼と同じ区画へ
    assert tokyo =~ "# 修正・追加の依頼"
    assert tokyo =~ "東京の店" and tokyo =~ "続きの説明" and tokyo =~ "東京の別の店"
    refute tokyo =~ "大阪" or tokyo =~ "区画の外" or tokyo =~ "外の続き"

    osaka = plan.notes[@osaka]
    assert osaka =~ "# 修正・追加の依頼" and osaka =~ "大阪に足りない店"
    refute osaka =~ "東京" or osaka =~ "外の続き"
  end

  describe "結果の引き当て" do
    alias Tazuna.Datasets.RequestLog

    defp change(at, scope), do: %{at: at, scope: scope, status: "ok"}

    test "頼んだ後に、頼んだ区画をちょうど見た回のうち、いちばん早いものを結果にする" do
      log = %RequestLog{keys: [@tokyo, @osaka], requested_at: ~U[2026-09-26 00:00:00Z]}

      changes = [
        change(~U[2026-09-26 02:00:00Z], [@osaka, @tokyo]),
        change(~U[2026-09-26 01:00:00Z], [@tokyo, @osaka]),
        # 頼む前の回・区画の組が違う回は結果にしない
        change(~U[2026-09-25 23:00:00Z], [@tokyo, @osaka]),
        change(~U[2026-09-26 00:30:00Z], [@tokyo])
      ]

      assert [%{result: %{at: ~U[2026-09-26 01:00:00Z]}}] = Requests.with_results([log], changes)
    end

    test "まだ回が終わっていなければ、結果は無い" do
      log = %RequestLog{keys: [@tokyo], requested_at: ~U[2026-09-26 00:00:00Z]}

      assert [%{result: nil}] = Requests.with_results([log], [])
    end
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
