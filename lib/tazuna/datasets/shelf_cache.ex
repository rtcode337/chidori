defmodule Tazuna.Datasets.ShelfCache do
  @moduledoc """
  読んだ本棚の覚え書き（データ収集の対象ごとに 1 つ）。

  **開くたびには Chiezo へ取りに行かない**（関連図の図と同じ）。本棚は整理の回が
  12 時間おきに動かすだけなのに、画面を開くたびに全冊を読んでいた —— 開いた回数だけ
  待たされ、Chiezo にも同じ問い合わせが積まれる。**まだ 1 度も読んでいないときだけ**
  取りに行き、あとは「最新の情報を取得」で取り直す。

  覚えるのはプロセスの中だけ（立て直せば空から始まり、最初に開いたときに読む）。
  """

  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "覚えている本棚（`%{shelf: 結果, checked_at: DateTime}`）。無ければ nil。"
  def get(key), do: Agent.get(__MODULE__, &Map.get(&1, key))

  @doc "読んだ本棚を覚える。**読めなかった結果も覚える**（画面に理由を出すため）。"
  def put(key, shelf, at \\ DateTime.utc_now()) do
    Agent.update(__MODULE__, &Map.put(&1, key, %{shelf: shelf, checked_at: at}))
  end

  @doc "忘れる（テスト用）。"
  def clear, do: Agent.update(__MODULE__, fn _ -> %{} end)
end
