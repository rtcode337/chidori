defmodule Chidori.News.Interests do
  @moduledoc """
  興味トピックの読み書き（話題ごと）。選ぶのはトピックの網の札から。

  選んだ語は、**整理の回が 1 件ごとに付ける「興味度」**（0〜100）と、
  **興味トピックの要約**（ふつうの要約とは別の 1 本）の依頼文に書き込みます
  （`Chidori.News.attrs/3`）。依頼文は Chiezo に置いてあるので、選び直したら
  送り直す必要があります（画面がそうします）。

  **置き場は Chiezo の `chidori_data`**（`Chidori.DataStore`）。1 語 1 文書で、
  タグは `興味トピック` と `話題:<収集>`、脇書きに収集・語・並び順を持ちます。
  """

  alias Chidori.DataStore

  @doc "選んだ語（選んだ順）。"
  def list(collection) when is_binary(collection) do
    collection
    |> docs()
    |> Enum.map(& &1.extra["name"])
  end

  def list(_collection), do: []

  defp docs(collection) do
    DataStore.interest_tag()
    |> DataStore.docs()
    |> Enum.filter(&(&1.extra["collection"] == collection and is_binary(&1.extra["name"])))
    |> Enum.sort_by(&{&1.extra["position"] || 0, &1.doc_id})
  end

  @doc """
  選ぶ・外す。**選んでいれば外し、選んでいなければ末尾に足します**。
  返すのは選び直したあとの語の並び（書けなかったときは選び直す前のまま）。
  """
  def toggle(collection, name) when is_binary(collection) and is_binary(name) do
    name = String.trim(name)
    current = docs(collection)

    case Enum.find(current, &(&1.extra["name"] == name)) do
      _any when name == "" ->
        :ok

      nil ->
        position = Enum.max(Enum.map(current, &(&1.extra["position"] || 0)), fn -> 0 end) + 1
        DataStore.add(record(collection, name, position))

      doc ->
        DataStore.delete(doc.doc_id)
    end

    list(collection)
  end

  @doc "1 語の文書の形。"
  def record(collection, name, position) do
    title = "興味トピック: #{collection} / #{name}"

    %{
      title: title,
      text: title,
      tags: [DataStore.interest_tag(), "話題:" <> collection],
      extra: %{"collection" => collection, "name" => name, "position" => position}
    }
  end

  @doc """
  話題に興味トピックを載せます（`:interests`）。**依頼文を組む直前に呼びます** ——
  依頼文を組む関数そのものは置き場を読みません（そのほうが、何を送るかを確かめやすい）。
  """
  def attach(%{interests_from: from} = topic) when is_binary(from),
    do: Map.put(topic, :interests, list(from))

  def attach(%{collection: collection} = topic) when is_binary(collection),
    do: Map.put(topic, :interests, list(collection))

  def attach(topic), do: topic
end
