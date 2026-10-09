defmodule Tazuna.Datasets.RequestsTest do
  @moduledoc """
  travel-log から届いた依頼のテキストから、座標と区画を引くところ。
  """

  use ExUnit.Case, async: true

  alias Tazuna.Datasets.Requests

  @tokyo "35.6,139.7/35.7,139.8"
  @osaka "34.6,135.4/34.8,135.6"

  defp partitions(keys), do: Enum.map(keys, &%{key: &1})

  describe "範囲ごとに振り分ける" do
    # 東京駅のあたりの広い範囲と、その中の狭い範囲、離れた大阪の範囲
    @wide %{id: 1, name: "広い", south: 35.60, west: 139.70, north: 35.75, east: 139.85}
    @narrow %{id: 2, name: "狭い", south: 35.67, west: 139.75, north: 35.69, east: 139.78}
    @osaka_area %{id: 3, name: "大阪", south: 34.60, west: 135.40, north: 34.80, east: 135.60}

    test "1 件ずつ、座標の入る範囲へ回す（重なっていれば狭いほう）" do
      text = """
      - [修正] 東京駅の店 (35.6812,139.7671): 閉店している
      - [追加] (35.7200,139.8000): 広い範囲だけに入る
      - [修正] 大阪の店 (34.7000,135.5000): 営業時間が違う
      """

      %{areas: routed, outside: outside} = Requests.route(text, [@wide, @narrow, @osaka_area])
      by = Map.new(routed, &{&1.area.name, Enum.map(&1.items, fn item -> item.text end)})

      assert by["狭い"] == ["- [修正] 東京駅の店 (35.6812,139.7671): 閉店している"]
      assert by["広い"] == ["- [追加] (35.7200,139.8000): 広い範囲だけに入る"]
      assert by["大阪"] == ["- [修正] 大阪の店 (34.7000,135.5000): 営業時間が違う"]
      assert outside == %{confirms: [], items: []}
    end

    test "位置修正は、店が今いる座標で振り分ける（直す先が範囲の外でも）" do
      text = "- [位置修正] 東京駅の店 (35.6812,139.7671) → (35.7000,139.9000)"

      %{areas: [%{area: area, confirms: [confirm]}]} = Requests.route(text, [@wide, @narrow])
      assert area.name == "狭い"
      assert confirm.to == {35.7, 139.9}
    end

    test "どの範囲にも入らない依頼は、落とさずに返す" do
      text = "- [追加] (43.0600,141.3500): 札幌の店\n- [位置確認] 札幌の店 (43.0600,141.3500)"

      %{areas: [], outside: %{confirms: [confirm], items: [item]}} =
        Requests.route(text, [@wide, @osaka_area])

      assert confirm.name == "札幌の店"
      assert item.text =~ "札幌の店"
    end
  end

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

    test "途中で止まった回は、見ていない区画を返す" do
      # 2 区画目で相手に繋がらなくなり、残りを見送って ok で終わった回
      log = %RequestLog{keys: [@tokyo, @osaka], requested_at: ~U[2026-09-26 00:00:00Z]}
      stopped = Map.put(change(~U[2026-09-26 01:00:00Z], [@tokyo, @osaka]), :visited, [@tokyo])

      assert [%{result: %{at: ~U[2026-09-26 01:00:00Z]}, unfinished: [@osaka]}] =
               Requests.with_results([log], [stopped])
    end

    test "全部を見終えた回は、見ていない区画が無い" do
      log = %RequestLog{keys: [@tokyo, @osaka], requested_at: ~U[2026-09-26 00:00:00Z]}

      done =
        Map.put(change(~U[2026-09-26 01:00:00Z], [@tokyo, @osaka]), :visited, [@osaka, @tokyo])

      assert [%{unfinished: []}] = Requests.with_results([log], [done])
    end

    test "見終えた区画を持たない古い行は、分からないとして扱う" do
      log = %RequestLog{keys: [@tokyo], requested_at: ~U[2026-09-26 00:00:00Z]}
      old = Map.put(change(~U[2026-09-26 01:00:00Z], [@tokyo]), :visited, nil)

      assert [%{unfinished: []}] = Requests.with_results([log], [old])
    end

    test "焼くところで落ちて戻された回は、失敗として返す" do
      # Chiezo は ok の行を残したまま、見ていた区画を名指しした失敗の行をあとから足す
      log = %RequestLog{keys: [@tokyo, @osaka], requested_at: ~U[2026-09-26 00:00:00Z]}
      ok = Map.put(change(~U[2026-09-26 01:00:00Z], [@tokyo, @osaka]), :visited, [@tokyo, @osaka])

      failed = %{
        at: ~U[2026-09-26 01:20:00Z],
        scope: [@osaka, @tokyo],
        status: "error",
        error: "焼くところで落ちました"
      }

      assert [%{result: %{status: "error"}, unfinished: []}] =
               Requests.with_results([log], [failed, ok])
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

  test "依頼の前置きは、閉店の報告を先に、確かめられなくても消させる" do
    # 巡回の依頼文はいつもの仕事を頼んでいて、依頼は後ろに足されるだけだった。
    # web で閉店を確かめられない小さな店が「確かめられなかった」として残っていた
    preface = Requests.preface()

    assert preface =~ "足りない店を探すより先に"
    # 答えたあともいつもの仕事を続けさせる（報告だけで終えていた）
    assert preface =~ "報告に答えただけで終えないで"
    assert preface =~ "営業していると\n  確かめられない限り、墓標で消して"
    assert preface =~ "残す理由になりません"
    assert preface =~ "閉店の報告があった店は、いま消えていても戻さないでください"

    # 閉店していないと報告された店は、消えていたら戻させる（戻す印を付けないと戻らない）
    assert preface =~ "「閉店していない」「営業している」と書かれた店が、いま消えていたら戻してください"
    assert preface =~ Tazuna.Chiezo.restore_tag()
    # 書き出すときに落としている見分けの番号
    assert preface =~ "「 (数字)」が落ちている"
  end

  test "依頼の前置きは、変わった先の店と、web に無い店も足させる" do
    # 「変わった」の報告で前の店だけ消え、新しい店は web で見つからずに足されなかった。
    # 「ある」の報告も、同じ場所で web に出ている別の店に置き換えられた
    preface = Requests.preface()

    assert preface =~ "前の店を墓標で消し、新しい店を\n  足す"
    assert preface =~ "web で見つからなくても足して"
    assert preface =~ "現地からの報告（web では確かめられず）"
    # 打ち間違いは web の名前に寄せ、別の店では置き換えない
    assert preface =~ "一字違いの店"
    assert preface =~ "その店で\n  置き換えずに報告の名前で足して"
  end
end
