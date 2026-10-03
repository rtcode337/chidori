defmodule Tazuna.Datasets.PendingRequest do
  @moduledoc """
  travel-log から届いた依頼 1 件の控え（**まだ Chiezo に頼んでいないもの**）。
  区画ごとに溜まった件数を見てから頼むために持ちます（`Tazuna.Datasets.Requests`）。
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "pending_requests" do
    field(:collection, :string)
    field(:text, :string)
    field(:lat, :float)
    field(:lon, :float)

    timestamps(type: :utc_datetime)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:collection, :text, :lat, :lon])
    |> validate_required([:collection, :text, :lat, :lon])
    |> unique_constraint([:collection, :text])
  end
end
