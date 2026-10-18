defmodule Chidori.Repo.Migrations.AddAttemptsToFilmCarrySettings do
  use Ecto.Migration

  # 作品ごとに、図へ足すよう頼んだ回数（`Chidori.Relations.CarrySetting`）。
  # 何度頼んでも載らない作品が、毎回の枠の頭を占め続けないようにするため
  def change do
    alter table(:film_carry_settings) do
      add(:attempts, :map, null: false, default: %{})
    end
  end
end
