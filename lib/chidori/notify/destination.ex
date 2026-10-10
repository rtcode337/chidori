defmodule Chidori.Notify.Destination do
  @moduledoc """
  ntfy の宛先（トピック名と場所）。**全部の通知で 1 つ**です。設定画面の
  「通知」タブで書きます。

  話題ごとに持たせていた頃は、同じトピックを画面ごとに書き写していて、変えるときに
  全部の画面を回る羽目になっていました。話題ごとに決めるのは**知らせるかどうか**
  だけです（`Chidori.Notify.Setting` の `notify`）。

  **行は 1 つだけ**持ちます。まだ書かれていなければ空の宛先を返します。

  **送るかどうかは `enabled` で切り替えます**（トピック名は残したまま止められる）。
  トピック名が空でも送りません（送る先が無い）。
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Chidori.Repo

  schema "ntfy_settings" do
    field(:topic, :string, default: "")
    field(:base_url, :string, default: "")
    field(:enabled, :boolean, default: true)

    timestamps(type: :utc_datetime)
  end

  def changeset(destination, attrs) do
    destination
    |> cast(attrs, [:topic, :base_url, :enabled])
    |> update_change(:topic, &String.trim/1)
    |> update_change(:base_url, &(&1 |> String.trim() |> String.trim_trailing("/")))
    |> validate_length(:topic, max: 200)
    |> validate_length(:base_url, max: 500)
    # **押せる形だけを受け取る**
    |> validate_format(:base_url, ~r{\A(\z|https?://)}, message: "http:// か https:// で書いてください")
  end

  @doc "いまの宛先。**無ければ空のもの**を返します。"
  def get do
    Repo.one(from(d in __MODULE__, order_by: [asc: d.id], limit: 1)) ||
      %__MODULE__{topic: "", base_url: "", enabled: true}
  end

  @doc "宛先を書き換えます。"
  def put(attrs) do
    get() |> changeset(attrs) |> Repo.insert_or_update()
  end

  @doc "フォームに載せる形。"
  def change(attrs \\ %{}), do: changeset(get(), attrs)
end
