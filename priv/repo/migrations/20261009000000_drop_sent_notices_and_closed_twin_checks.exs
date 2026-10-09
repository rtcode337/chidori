defmodule Chidori.Repo.Migrations.DropSentNoticesAndClosedTwinChecks do
  use Ecto.Migration

  # 知らせ済みの記録（sent_notices）は、新しいまとめと押されたときにしか知らせない
  # 作りでは使い道が「最後に知らせた時刻」だけだったので、話題の設定の 1 列に畳む。
  # 閉店の片割れの控え（closed_twin_checks）は、機能ごと外したので要らない
  def up do
    alter table(:notify_settings) do
      add(:last_sent_at, :utc_datetime)
    end

    flush()

    # いまの記録から、話題ごとの最後に知らせた時刻を写してから捨てる
    execute("""
    UPDATE notify_settings s
       SET last_sent_at = n.sent_at
      FROM (SELECT collection, MAX(updated_at) AS sent_at FROM sent_notices GROUP BY collection) n
     WHERE s.collection = n.collection
    """)

    drop(table(:sent_notices))
    drop(table(:closed_twin_checks))
  end

  def down do
    create table(:closed_twin_checks) do
      add(:collection, :string, null: false)
      add(:twin, :string, null: false)
      add(:closed, :string, null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:closed_twin_checks, [:collection, :twin, :closed]))

    create table(:sent_notices) do
      add(:collection, :string, null: false)
      add(:key, :string, null: false)
      add(:topic, :string, null: false, default: "")
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:sent_notices, [:collection, :key, :topic]))

    alter table(:notify_settings) do
      remove(:last_sent_at)
    end
  end
end
