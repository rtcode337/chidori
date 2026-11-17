defmodule Chidori.Repo.Migrations.SurveySettingsPerSweep do
  use Ecto.Migration

  # Chidori の時計が起こす巡回の時刻を、収集と巡回の組ごとに持つ（1 組 1 行）。
  # 情報収集だけを起こしていた頃は収集ごとに 1 行で足りたが、同じ収集の別の巡回
  # （ご当地グルメの漏れ探し）も時刻で起こすようになり、時刻と記録を巡回ごとに分ける。
  # 今ある行はどれも情報収集のもの
  def change do
    alter table(:dining_survey_settings) do
      add(:sweep, :text, null: false, default: "情報収集")
    end

    drop(unique_index(:dining_survey_settings, [:collection]))
    create(unique_index(:dining_survey_settings, [:collection, :sweep]))
  end
end
