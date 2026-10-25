defmodule Chidori.Datasets.Blanks do
  @moduledoc """
  空いている欄を埋める 1 回の、対象に依らない部分（食事処の範囲・ご当地グルメ）。
  どの欄を空とみなすか・依頼文は対象が持ち（`blank_fields/0`・`blank_report/1`・
  `fill_request/3`）、ここには数え方と選び方だけを置く。説明は
  `docs/datasets.md「食事処（travel-log 向け）」`。
  """

  @doc """
  欄ごとの空いている数（`fields` の並び。`[{鍵, 名前, 数}]`）。
  **空いているものの無い欄は出しません**（0 件の欄を選べても頼むものが無い）。
  """
  def counts(items, fields) do
    for {field, label} <- fields,
        (count = Enum.count(items, &(field in &1.missing))) > 0,
        do: {field, label, count}
  end

  @doc """
  名指しするものを選びます。`wanted` は埋めてほしい欄の鍵、`count` は数（1〜`max` に丸める）。
  **`first` の欄が空いているものを先に**、そのあと空いている欄の多いものから。
  **同じ並びの中は毎回混ぜます** —— 確かめられなかった欄は空いたまま残るので、決まった順だと
  続けて押したときに同じものばかり頼むことになる。返すものの `missing` は `wanted` に絞ってある。
  """
  def pick(items, wanted, count, max, first) do
    items
    |> Enum.map(&%{&1 | missing: Enum.filter(&1.missing, fn field -> field in wanted end)})
    |> Enum.reject(&(&1.missing == []))
    |> Enum.shuffle()
    |> Enum.sort_by(&{if(first in &1.missing, do: 0, else: 1), -length(&1.missing)})
    |> Enum.take(count |> max(1) |> min(max))
  end
end
