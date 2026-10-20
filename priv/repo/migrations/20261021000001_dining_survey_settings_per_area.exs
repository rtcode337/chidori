defmodule Chidori.Repo.Migrations.DiningSurveySettingsPerArea do
  use Ecto.Migration

  # 食事処の情報収集を起こす時刻を、範囲ごとに持つ（1 範囲 1 行。`collection` は Chiezo の
  # 収集の名前）。全部の範囲を同じ時刻に起こすと、1 回十分ほどの回が範囲の数だけ並び、
  # 取り込みをその間ずっと占める。範囲ごとの記録は「受け持った予定」と「起こせたか」で足りる
  def change do
    execute("DELETE FROM dining_survey_settings", "")

    alter table(:dining_survey_settings) do
      add(:collection, :text, null: false, default: "")
      add(:slot_ok, :boolean, null: false, default: false)
      remove(:done, {:array, :text}, null: false, default: [])
    end

    create(unique_index(:dining_survey_settings, [:collection]))
  end
end
