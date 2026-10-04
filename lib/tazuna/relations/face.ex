defmodule Tazuna.Relations.Face do
  @moduledoc "顔写真の写し 1 枚（`Tazuna.Relations.Faces`）。"

  use Ecto.Schema

  import Ecto.Changeset

  schema "face_thumbs" do
    field(:source_url, :string)
    field(:content_type, :string, default: "")
    field(:image, :binary)
    field(:status, :string)

    timestamps(type: :utc_datetime)
  end

  def changeset(face, attrs) do
    face
    |> cast(attrs, [:source_url, :content_type, :image, :status])
    |> validate_required([:source_url, :status])
    |> validate_inclusion(:status, ["ok", "missing"])
  end
end
