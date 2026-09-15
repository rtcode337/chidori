defmodule Tazuna.Notify.Settings do
  @moduledoc """
  話題ごとの通知先の読み書き。

  **持っていない話題には、空の設定を返します**（nil ではなく）。画面はこれを
  そのままフォームに載せるので、まだ書かれていないことと、書いて空にしたことを
  分ける必要がありません —— どちらも「知らせない」で同じです。
  """

  alias Tazuna.Notify.Setting
  alias Tazuna.Repo

  @doc """
  その収集の通知先。**無ければ空のもの**を返します。
  """
  def get(collection) when is_binary(collection) do
    Repo.get_by(Setting, collection: collection) ||
      %Setting{collection: collection, ntfy_topic: "", ntfy_base_url: ""}
  end

  def get(_collection), do: %Setting{collection: "", ntfy_topic: "", ntfy_base_url: ""}

  @doc """
  通知先を書き換えます。**空にすれば、その話題は知らせなくなります**。
  """
  def put(collection, attrs) do
    collection
    |> get()
    |> Setting.changeset(Map.put(attrs, "collection", collection))
    |> Repo.insert_or_update()
  end

  @doc "フォームに載せる形。"
  def changeset(collection, attrs \\ %{}) do
    collection |> get() |> Setting.changeset(Map.put(attrs, "collection", collection))
  end
end
