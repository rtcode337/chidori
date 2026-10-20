defmodule Chidori.Repo.Migrations.AddSurveyPerRunToDiningAreas do
  use Ecto.Migration

  # 範囲ごとの情報収集が 1 回に回る区画の数（`Chidori.Datasets.DiningAreas`）。重い相手で
  # 回すので、区画の数から自動で決めさせず、範囲ごとに決める
  def change do
    alter table(:dining_areas) do
      add(:survey_per_run, :integer, null: false, default: 1)
    end
  end
end
