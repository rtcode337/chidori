defmodule Tazuna.Datasets.RequestLog do
  @moduledoc """
  travel-log から届いた依頼 1 件の控え（`Tazuna.Datasets.Requests`）。

  **結果を依頼と並べて見せるために持ちます。** Chiezo の変更履歴には、その回が
  どの依頼から走ったのかが残らないので、頼んだ時刻と区画をこちらで控えます。
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "dataset_requests" do
    field(:collection, :string)
    field(:keys, {:array, :string}, default: [])
    field(:text, :string, default: "")
    field(:points, :integer, default: 0)
    field(:missed, :integer, default: 0)
    field(:status, :string, default: "waiting")
    field(:error, :string, default: "")
    field(:requested_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  @fields ~w(collection keys text points missed status error requested_at)a

  def changeset(log, attrs) do
    log
    |> cast(attrs, @fields)
    |> validate_required([:collection, :requested_at])
    |> validate_inclusion(:status, ~w(waiting sent failed))
  end
end
