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

  @doc """
  まとめを作らせたことを控えます。**走らせる前に控えます** —— 走ってから控えると、
  数分かかる段取りの最中にもう一度その回の時刻が来て、二重に起こします。

  控えるのは「予定の時刻」で、走らせた時刻ではありません —— 遅れて走ったときに、
  次の回まで進めてしまわないためです。
  """
  def mark_digest(collection, %DateTime{} = at) do
    collection
    |> get()
    |> Setting.changeset(%{
      "collection" => collection,
      "last_digest_at" => DateTime.truncate(at, :second)
    })
    |> Repo.insert_or_update()
  end

  @doc """
  定時の回がどう終わったかを控えます。**画面に出すために残します** ——
  残さないと、知らせが来なかった理由はログにしか無く、誰も見ていない時刻に走る回
  なので、気づくのは「来ていない」と思ったときになります。
  """
  def mark_digest_result(collection, text) when is_binary(text) do
    collection
    |> get()
    |> Setting.changeset(%{"collection" => collection, "last_digest_result" => text})
    |> Repo.insert_or_update()
  end

  @doc "フォームに載せる形。"
  def changeset(collection, attrs \\ %{}) do
    collection |> get() |> Setting.changeset(Map.put(attrs, "collection", collection))
  end
end
