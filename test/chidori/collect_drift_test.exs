defmodule Chidori.CollectDriftTest do
  @moduledoc """
  Chiezo の今の設定と、Chidori が送るはずの設定の違い（設定ページの「Chiezo 収集」）。
  見ているのは、**違う項目を名前で出すこと**と、**Chiezo の返し方の違いを違いとして
  出さないこと**（既定の鍵を足して返す・知らない鍵を捨てる・相手は表で選ぶ）です。
  """

  use ExUnit.Case, async: true

  alias Chidori.CollectDrift

  defp chiezo(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "tazuna_x",
        "prompt" => "集めてください",
        "kind" => "flow",
        "thumbs" => %{"pages_from" => []},
        "backend" => "codex",
        "enabled" => false,
        "feed" => %{"limit" => 60, "urls" => [%{"url" => "https://example.com/feed"}]},
        "sweeps" => [
          %{"name" => "整理", "prompt" => "整えてください", "only_new" => false, "worker" => "w1"}
        ]
      },
      overrides
    )
  end

  defp wanted(overrides \\ %{}) do
    Map.merge(
      %{
        name: "tazuna_x",
        prompt: "集めてください\n",
        kind: "flow",
        thumbs: true,
        feed: %{urls: [%{url: "https://example.com/feed"}], since: "always"},
        sweeps: [%{name: "整理", prompt: "整えてください", web: true, backend: "antigravity"}]
      },
      overrides
    )
  end

  test "同じなら何も出さない（相手・動かすか・Chiezo が足した鍵・知らない鍵は比べない）" do
    assert CollectDrift.differences(wanted(), chiezo()) == []
  end

  test "違う項目を、収集ぜんたいと巡回に分けて名前で出す" do
    want =
      wanted(%{
        prompt: "新しい依頼文",
        thumbs: %{pages_from: ["*"]},
        sweeps: [%{name: "整理", prompt: "新しい整え方"}, %{name: "要約", prompt: "まとめて"}]
      })

    assert CollectDrift.differences(want, chiezo()) == [
             "依頼文",
             "絵の拾い方",
             "巡回「整理」の依頼文",
             "巡回「要約」が Chiezo にありません"
           ]
  end

  test "Chiezo にだけある巡回も出す（外したつもりの仕事が回り続ける）" do
    have =
      chiezo(%{"sweeps" => [%{"name" => "整理", "prompt" => "整えてください"}, %{"name" => "古い回"}]})

    assert CollectDrift.differences(wanted(), have) == ["Chiezo にだけある巡回「古い回」"]
  end

  test "ホストの並びは順に依らない" do
    want = wanted(%{thumbs: %{pages_from: ["b.example", "a.example"]}})
    have = chiezo(%{"thumbs" => %{"pages_from" => ["a.example", "b.example"]}})

    assert CollectDrift.differences(want, have) == []
  end

  test "Chiezo に絵の拾い方が無ければ違いとして出す" do
    assert CollectDrift.differences(wanted(), chiezo(%{"thumbs" => nil})) == ["絵の拾い方"]
  end
end
