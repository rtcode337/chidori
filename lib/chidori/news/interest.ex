defmodule Chidori.News.Interest do
  @moduledoc """
  興味トピック 1 つ（話題ごと）。**利用者が決めることだけ**を持ちます。
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "news_interests" do
    field(:collection, :string)
    field(:name, :string)
    field(:position, :integer, default: 0)

    timestamps(type: :utc_datetime)
  end

  def changeset(interest, attrs) do
    interest
    |> cast(attrs, [:collection, :name, :position])
    |> validate_required([:collection, :name])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 200)
    |> unique_constraint([:collection, :name])
  end
end
