defmodule Chidori.Repo.Migrations.CreateFilmCarrySettings do
  use Ecto.Migration

  # 最新情報の映画を映画の図へ引き継ぐ時刻と 1 回の数、前回頼んだ記録（1 行だけ。
  # `Chidori.Relations.CarrySetting`）。時刻は空が既定（その Chidori からは頼まない）
  def change do
    create table(:film_carry_settings) do
      add(:run_at, :text, null: false, default: "")
      add(:batch, :integer, null: false, default: 20)
      add(:last_at, :utc_datetime)
      add(:last_result, :text)
      add(:last_titles, {:array, :text}, null: false, default: [])
      add(:last_by, :string)

      # 時計が最後に頼みに行った時刻と、済んだか（画面から足した 1 回とは分けて持つ ——
      # 混ぜると、画面で 1 本足しただけでその日の時計の回が飛ぶ）
      add(:clock_at, :utc_datetime)
      add(:clock_ok, :boolean, null: false, default: false)
      timestamps(type: :utc_datetime)
    end
  end
end
