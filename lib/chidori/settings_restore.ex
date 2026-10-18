defmodule Chidori.SettingsRestore do
  @moduledoc """
  **Chiezo の収集に載っている設定から、Chidori の設定を戻します**（設定ページの
  「Chiezo 収集」）。動かす場所を変えたとき・DB を作り直したときに、画面で選び直さずに
  済むようにするためのものです。

  Chidori の設定のうち、次の 3 つは送ったものがそのまま Chiezo の収集に残っています。

  | 設定 | 表 | Chiezo のどこに残るか |
  |---|---|---|
  | 巡回の間隔 | `collect_paces` | 「整理」「ざっと見る」の巡回の `interval_minutes` |
  | 整理を自動で回さない収集 | `tidy_stops` | 「整理」の巡回の `by_caller` |
  | 関連図の知名度の下限 | `relation_settings` | 芸能人の収集の名簿の指定 `extract.min_extra.pageviews_month` |

  **Chiezo へは何も送りません**（読んで手元に書くだけ）。食事処の範囲は範囲の画面から
  戻します（`Chidori.Datasets.DiningAreas.restore/1`）。
  """

  alias Chidori.Chiezo
  alias Chidori.CollectOverview
  alias Chidori.CollectPace
  alias Chidori.Relations
  alias Chidori.SweepNames

  @doc """
  戻します。`{:ok, %{paces: [{種類, 分}], stopped: [収集], resumed: [収集], min_pageviews: 値 | nil}}`
  か `{:error, 理由}`。並ぶのは**変えたものだけ**です。

  `collections` は Chiezo の収集の一覧を返す関数（テストで差し替える）。
  """
  def run(collections) when is_function(collections, 0) do
    with {:ok, all} <- collections.() do
      ours = Enum.filter(all, &CollectOverview.ours?/1)

      {:ok,
       %{
         paces: restore_paces(ours),
         stopped: restore_stops(ours, true),
         resumed: restore_stops(ours, false),
         min_pageviews: restore_min_pageviews(ours)
       }}
    end
  end

  def run(base) when is_binary(base), do: run(fn -> Chiezo.collections(base) end)

  # **いちばん多い間隔**を戻す。Chidori は全部の収集に同じ間隔を送るので、ふつうは
  # 1 つに揃っている（送れなかった収集が混ざっていても多数決で決まる）。選べない値は戻さない
  defp restore_paces(collections) do
    for kind <- CollectPace.kinds(),
        minutes = most_common(intervals(collections, CollectPace.sweep_name(kind))),
        is_integer(minutes),
        minutes in CollectPace.choices(kind),
        minutes != CollectPace.minutes(kind),
        CollectPace.put(kind, minutes) == :ok,
        do: {kind, minutes}
  end

  # 時計で回っている巡回の間隔だけ（時計を外した巡回の間隔は、止める前の値のまま残っている）
  defp intervals(collections, sweep_name) do
    for collection <- collections,
        sweep <- collection["sweeps"] || [],
        sweep["name"] == sweep_name,
        sweep["on_demand"] != true,
        sweep["by_caller"] != true,
        is_integer(sweep["interval_minutes"]),
        do: sweep["interval_minutes"]
  end

  defp most_common([]), do: nil

  defp most_common(values) do
    values |> Enum.frequencies() |> Enum.max_by(fn {_value, count} -> count end) |> elem(0)
  end

  # Chiezo で整理の時計が外れている収集を「回さない」に、付いている収集を「回す」に揃える。
  # **整理を持たない収集は触らない**（どちらとも言えない）
  defp restore_stops(collections, stop?) do
    for collection <- collections,
        name = collection["name"],
        is_binary(name),
        tidy = Enum.find(collection["sweeps"] || [], &(&1["name"] == SweepNames.tidy())),
        tidy != nil,
        tidy["by_caller"] == true == stop?,
        CollectPace.tidy_stopped?(name) != stop?,
        CollectPace.put_stop(name, stop?) == :ok,
        do: name
  end

  # 名簿の広さを持つ図は芸能人と映画。**返すのは芸能人の値**（画面の知らせはそちらだけ）
  defp restore_min_pageviews(collections) do
    restore_min_pageviews(collections, "films", Relations.Films.collection())
    restore_min_pageviews(collections, "people", Relations.People.collection())
  end

  defp restore_min_pageviews(collections, view, name) do
    with %{} = collection <- Enum.find(collections, &(&1["name"] == name)),
         value when is_integer(value) and value > 0 <- min_pageviews_of(collection["extract"]),
         true <- value != Relations.Settings.min_pageviews(view),
         {:ok, _saved} <- Relations.Settings.put_min_pageviews(view, value) do
      value
    else
      _unchanged -> nil
    end
  end

  # 名簿の指定は 1 つのことも並びのこともある
  defp min_pageviews_of(%{"min_extra" => %{"pageviews_month" => value}}), do: value
  defp min_pageviews_of([_ | _] = specs), do: Enum.find_value(specs, &min_pageviews_of/1)
  defp min_pageviews_of(_spec), do: nil
end
