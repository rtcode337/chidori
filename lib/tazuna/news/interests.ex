defmodule Tazuna.News.Interests do
  @moduledoc """
  興味トピックの読み書き（話題ごと）。選ぶのはトピックの網の札から。

  選んだ語は、**整理の回が 1 件ごとに付ける「興味度」**（0〜100）と、
  **興味トピックの要約**（ふつうの要約とは別の 1 本）の依頼文に書き込みます
  （`Tazuna.News.attrs/3`）。依頼文は Chiezo に置いてあるので、選び直したら
  送り直す必要があります（画面がそうします）。
  """

  import Ecto.Query

  alias Tazuna.News.Interest
  alias Tazuna.Repo

  @doc "選んだ語（選んだ順）。"
  def list(collection) when is_binary(collection) do
    Interest
    |> where([i], i.collection == ^collection)
    |> order_by([i], asc: i.position, asc: i.id)
    |> select([i], i.name)
    |> Repo.all()
  end

  def list(_collection), do: []

  @doc """
  選ぶ・外す。**選んでいれば外し、選んでいなければ末尾に足します**。
  返すのは選び直したあとの語の並び。
  """
  def toggle(collection, name) when is_binary(collection) and is_binary(name) do
    name = String.trim(name)

    case Repo.get_by(Interest, collection: collection, name: name) do
      nil ->
        position =
          (Repo.aggregate(where(Interest, collection: ^collection), :max, :position) || 0) + 1

        %Interest{}
        |> Interest.changeset(%{collection: collection, name: name, position: position})
        |> Repo.insert()

      interest ->
        Repo.delete(interest)
    end

    list(collection)
  end

  @doc """
  話題に興味トピックを載せます（`:interests`）。**依頼文を組む直前に呼びます** ——
  依頼文を組む関数そのものは DB を読みません（そのほうが、何を送るかを確かめやすい）。
  """
  def attach(%{interests_from: from} = topic) when is_binary(from),
    do: Map.put(topic, :interests, list(from))

  def attach(%{collection: collection} = topic) when is_binary(collection),
    do: Map.put(topic, :interests, list(collection))

  def attach(topic), do: topic
end
