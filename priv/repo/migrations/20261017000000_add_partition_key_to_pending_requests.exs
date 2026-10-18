defmodule Chidori.Repo.Migrations.AddPartitionKeyToPendingRequests do
  use Ecto.Migration

  # travel-log からの依頼の控えに、頼む区画の鍵を持たせる（座標で区画を引けない対象のため。
  # `Chidori.Datasets.PendingRequest`）
  def change do
    alter table(:pending_requests) do
      add(:partition_key, :string)
    end
  end
end
