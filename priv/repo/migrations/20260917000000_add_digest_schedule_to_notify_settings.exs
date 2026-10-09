defmodule Chidori.Repo.Migrations.AddDigestScheduleToNotifySettings do
  use Ecto.Migration

  def change do
    alter table(:notify_settings) do
      # 知らせる時刻（JST の "07:00,21:00"）。空なら回さない。
      # 時刻を持つのは Chidori の側 —— 何時に読みたいかは利用者の都合で、
      # 集める側（Chiezo）に持たせると、あちらが都合を知る場所になる
      add(:digest_at, :string, null: false, default: "")
      # 最後にまとめを作らせた時刻。予定を二度走らせないために持つ
      # （立ち上げ直しをまたいでも同じ回を数えられるよう、メモリではなく DB）
      add(:last_digest_at, :utc_datetime)
    end
  end
end
