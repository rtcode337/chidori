defmodule Chidori.DataStore.Memory do
  @moduledoc """
  `Chidori.DataStore` の手元だけの実装（テスト用）。Chiezo の代わりに ETS の表に持ちます
  （読み直したときに、書いたものが返ってくるように）。表は置き場のプロセスが持つ。
  """

  @table :chidori_data_store_memory

  def load, do: {:ok, Enum.map(:ets.tab2list(table()), &elem(&1, 1))}

  def add(attrs) do
    doc = %{
      doc_id: System.unique_integer([:positive, :monotonic]),
      title: attrs[:title] || "",
      tags: attrs[:tags] || [],
      extra: attrs[:extra] || %{}
    }

    put(doc)
  end

  # 差し替えは渡した項目だけ（いまの中身は DataStore が渡す）
  def update(current, attrs),
    do: current |> Map.merge(Map.take(attrs, [:title, :tags, :extra])) |> put()

  def delete(doc_id) do
    :ets.delete(table(), doc_id)
    :ok
  end

  def reset do
    :ets.delete_all_objects(table())
    :ok
  end

  defp put(doc) do
    :ets.insert(table(), {doc.doc_id, doc})
    {:ok, doc}
  end

  defp table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _tid -> @table
    end
  end
end
