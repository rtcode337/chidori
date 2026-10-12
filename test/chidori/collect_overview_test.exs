defmodule Chidori.CollectOverviewTest do
  @moduledoc "設定ページの「Chiezo 収集」の一覧。"

  use Chidori.DataCase, async: false

  alias Chidori.CollectOverview

  setup do
    base = "http://chiezo.test:7010"

    Chidori.HttpStub.stub(fn
      %{url: ^base <> "/v1/collect"} ->
        Chidori.HttpStub.ok(
          Jason.encode!(%{
            "collections" => [
              %{
                "name" => "chidori_tech",
                "description" => "Chidori の「技術ニュース」。技術に関する…",
                "requested_by" => "chidori",
                "enabled" => true,
                "sweeps" => [
                  %{"name" => "整理", "interval_minutes" => 240, "backend" => "worker:w1"},
                  %{"name" => "要約", "on_demand" => true, "worker" => "w1"},
                  # 待ち行列の口に居ないワーカーは、相手の一覧の名前で出す
                  %{"name" => "情報収集", "interval_minutes" => 1440, "worker" => "w-2"}
                ]
              },
              %{"name" => "other_app", "requested_by" => "sample-app", "sweeps" => []}
            ]
          })
        )

      %{url: ^base <> "/v1/ai/backends"} ->
        Chidori.HttpStub.ok(
          Jason.encode!(%{
            "backends" => [
              %{"id" => "claude", "label" => "Claude"},
              %{"id" => "worker:w-2", "label" => "情報収集用", "kind" => "worker"}
            ]
          })
        )

      %{url: ^base <> "/v1/collect/queue"} ->
        Chidori.HttpStub.ok(
          Jason.encode!(%{
            "workers" => [
              %{
                "id" => "w1",
                "name" => "整理用",
                "interval_minutes" => 30,
                "per_run" => 2,
                "next_at" => "2026-09-28T01:00:00+00:00",
                "flowing" => [],
                "queued" => [%{"collection" => "chidori_tech", "sweep" => "整理"}]
              }
            ],
            "ingest_waiting" => []
          })
        )
    end)

    %{base: base}
  end

  test "chidori が頼んだ収集だけを、巡回の間隔と相手つきで並べる", %{base: base} do
    Chidori.Notify.Settings.put("chidori_tech", %{"digest_at" => "07:00,19:00"})

    {:ok, overview} = CollectOverview.load(base)

    assert [%{label: "技術ニュース", sweeps: [refine, digest, survey]}] = overview.collections
    assert survey.backend == "ワーカー「情報収集用」"
    assert refine.clock == "4 時間ごと"
    # ワーカーは名前で出す
    assert refine.backend == "ワーカー「整理用」"
    # 時計を持たない要約の回は、Chidori が起こす時刻を出す
    assert digest.clock == "Chidori が起こす（07:00・19:00）"
    # ワーカーは `worker` の欄に入っていることもある
    assert digest.backend == "ワーカー「整理用」"

    assert [%{name: "整理用", every: "30 分ごと", per_run: 2, queued: [_]}] = overview.workers
  end

  test "名前は Chidori が置いた説明の頭から取る" do
    label = &CollectOverview.label(%{"name" => "x", "description" => &1})

    assert label.("Chidori の「技術ニュース」。技術に関する…") == "技術ニュース"

    # 話題とその網を見分けられるように
    assert label.("Chidori の「技術ニュース」のトピック（記事のタグから作る話題の網）") == "技術ニュースのトピック"
    assert label.("Chidori の関連図（画家の影響と時代）") == "画家の影響と時代"
    assert label.("Chidori のデータ収集（日本の食事処 / travel-log 向け）") == "日本の食事処"
    assert label.("Chidori のデータ収集（定番の技術書。記事のタグから作る本棚）") == "定番の技術書"
    assert label.("よく分からない") == "x"
  end

  test "間隔は読める単位で" do
    assert CollectOverview.every(60) == "1 時間ごと"
    assert CollectOverview.every(1440) == "1 日ごと"
    assert CollectOverview.every(45) == "45 分ごと"
  end
end
