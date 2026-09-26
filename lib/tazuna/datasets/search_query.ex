defmodule Tazuna.Datasets.SearchQuery do
  @moduledoc "機械収集が引いた検索文 1 つの控え（`Tazuna.Datasets.BookQueries`）。"

  use Ecto.Schema

  import Ecto.Changeset

  schema "search_queries" do
    field(:collection, :string)
    field(:query, :string)
    field(:used_at, :utc_datetime)
    field(:found, :integer)

    timestamps(type: :utc_datetime)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, ~w(collection query used_at found)a)
    |> validate_required([:collection, :query, :used_at])
    |> unique_constraint([:collection, :query])
  end
end
