defmodule Tazuna.Home.Panel do
  @moduledoc "トップページに並べる枠 1 つ（`Tazuna.Home`）。"

  use Ecto.Schema

  import Ecto.Changeset

  schema "home_panels" do
    field(:key, :string)
    field(:position, :integer, default: 0)

    timestamps(type: :utc_datetime)
  end

  def changeset(panel, attrs) do
    panel
    |> cast(attrs, [:key, :position])
    |> validate_required([:key])
    |> unique_constraint(:key)
  end
end
