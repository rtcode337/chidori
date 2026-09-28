defmodule Tazuna.Datasets.ClosedTwinCheck do
  @moduledoc """
  閉店の片割れを確かめてもらった 1 組（`Tazuna.Datasets.ClosedTwins`）。
  """

  use Ecto.Schema

  schema "closed_twin_checks" do
    field(:collection, :string)
    field(:twin, :string)
    field(:closed, :string)

    timestamps(type: :utc_datetime)
  end
end
