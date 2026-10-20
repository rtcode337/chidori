defmodule Chidori.Repo.Migrations.CreateDiningSurveySettings do
  use Ecto.Migration

  # 食事処の情報収集を起こす時刻と、時計が最後に起こした記録（1 行だけ。
  # `Chidori.Datasets.DiningSurveySetting`）。時刻は空が既定（その Chidori からは起こさない）
  def change do
    create table(:dining_survey_settings) do
      add(:run_at, :text, null: false, default: "")

      # 時計が最後に受け持った予定の時刻と、その予定で起こし終えた収集（収集の名前の並び）
      add(:slot_at, :utc_datetime)
      add(:done, {:array, :text}, null: false, default: [])
      add(:last_at, :utc_datetime)
      add(:last_result, :text)
      timestamps(type: :utc_datetime)
    end
  end
end
