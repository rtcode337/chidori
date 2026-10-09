defmodule Tazuna.Repo.Migrations.DropNationalMealsLeftovers do
  use Ecto.Migration

  # 食事処は範囲ごとの収集（tazuna_dining_<範囲の番号>）だけになったので、
  # 日本全体を 1 つで回していた収集（tazuna_meals）の残りを消す。
  # 起点と時刻（survey_plans）はその収集のためだけの表だったので、表ごと捨てる
  @collection "tazuna_meals"

  def up do
    for table <- ~w(dataset_requests pending_requests tidy_stops notify_settings) do
      execute("DELETE FROM #{table} WHERE collection = '#{@collection}'")
    end

    drop(table(:survey_plans))
  end

  # 消した行は戻せない（使う収集がもう無い）。表だけ作り直す
  def down do
    create table(:survey_plans) do
      add(:collection, :string, null: false)
      add(:place, :string, null: false, default: "")
      add(:lat, :float)
      add(:lon, :float)
      add(:place_set_at, :utc_datetime)
      add(:run_at, :string, null: false, default: "")
      add(:last_run_at, :utc_datetime)
      add(:last_result, :text, null: false, default: "")

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:survey_plans, [:collection]))
  end
end
