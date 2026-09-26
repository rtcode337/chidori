defmodule Tazuna.Repo.Migrations.CreateDatasetRequests do
  @moduledoc """
  travel-log から届いた依頼（「区画を引いて頼む」）の控え。

  **結果を依頼と並べて見せるために持つ。** Chiezo の変更履歴には 1 回ごとに
  「どの区画を見て、何を足し・直し・消したか」が残るが、その回が**どの依頼から
  走ったのか**は残らない（定時の回と同じ行に並ぶ）。頼んだ時刻と区画をこちらで
  控えておけば、その後に同じ区画を見た回を依頼の結果として引き当てられる。
  """

  use Ecto.Migration

  def change do
    create table(:dataset_requests) do
      add(:collection, :string, null: false)
      # 頼んだ区画の鍵（Chiezo の区画の鍵そのもの）
      add(:keys, {:array, :string}, null: false, default: [])
      # 依頼のテキスト（貼られたもの）。区画に振り分ける前の全体
      add(:text, :text, null: false, default: "")
      # 座標の数と、どの区画にも入らなかった座標の数
      add(:points, :integer, null: false, default: 0)
      add(:missed, :integer, null: false, default: 0)

      # waiting（取り込みが空くのを待っている）/ sent（Chiezo が受けた）/ failed
      add(:status, :string, null: false, default: "waiting")
      add(:error, :text, null: false, default: "")
      add(:requested_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:dataset_requests, [:collection, :requested_at]))
  end
end
