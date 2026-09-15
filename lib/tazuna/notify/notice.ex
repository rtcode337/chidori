defmodule Tazuna.Notify.Notice do
  @moduledoc """
  知らせたものの記録 1 件。**同じものを二度知らせない**ためだけに残します。
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "sent_notices" do
    field(:collection, :string)
    field(:key, :string)
    field(:topic, :string, default: "")

    timestamps(type: :utc_datetime)
  end

  @fields ~w(collection key topic)a

  def changeset(notice, attrs) do
    notice
    |> cast(attrs, @fields)
    |> validate_required([:collection, :key])
    |> unique_constraint([:collection, :key, :topic])
  end
end
