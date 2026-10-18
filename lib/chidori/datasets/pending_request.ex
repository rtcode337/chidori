defmodule Chidori.Datasets.PendingRequest do
  @moduledoc """
  travel-log から届いた依頼 1 件の控え（**まだ Chiezo に頼んでいないもの**）。
  区画ごとに溜まった件数を見てから頼むために持ちます（`Chidori.Datasets.Requests`）。
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "pending_requests" do
    field(:collection, :string)
    field(:text, :string)
    field(:lat, :float)
    field(:lon, :float)

    # 依頼を頼む区画の鍵。**座標で区画を引けない対象だけが持つ**（ご当地グルメは区画が県で、
    # 依頼の座標は代表店の位置 —— 料理の県とは限らないので、控えるときに料理から引いて残す）。
    # 持たない控えは、見るたびに座標から区画を引く（食事処）
    field(:partition_key, :string)

    timestamps(type: :utc_datetime)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:collection, :text, :lat, :lon, :partition_key])
    |> validate_required([:collection, :text, :lat, :lon])
    |> unique_constraint([:collection, :text])
  end
end
