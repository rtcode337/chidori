defmodule Chidori.Repo.Migrations.CreatePendingRequests do
  @moduledoc """
  travel-log から届いた依頼のうち、**まだ Chiezo に頼んでいないもの**（1 件ずつ）。

  貼ったその場で頼むと、1 件しか依頼の無い区画にも AI の回が 1 回走り、枠を
  使い潰す。控えておいて、区画ごとに溜まった件数を見てから頼めるようにする。

  **区画の鍵は持たない**（座標で持つ）。区画は割り直されることがあるので、鍵で
  持つと割り直した拍子に控えが迷子になる。どの区画に入るかは見るたびに引く。
  """

  use Ecto.Migration

  def change do
    create table(:pending_requests) do
      add(:collection, :string, null: false)
      # 依頼 1 件ぶんの行（座標の行と、その続きの行）
      add(:text, :text, null: false)
      add(:lat, :float, null: false)
      add(:lon, :float, null: false)

      timestamps(type: :utc_datetime)
    end

    # 同じ依頼を貼り直しても 1 件のまま
    create(unique_index(:pending_requests, [:collection, :text]))
  end
end
