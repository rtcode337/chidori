defmodule Chidori.Repo.Migrations.CreateTidyStops do
  @moduledoc """
  整理を自動で回さない収集（設定ページの「Chiezo 収集」で選ぶ。`Chidori.CollectPace`）。

  1 行 1 収集。**行が無いことは「自動で回す」**（既定）を意味します。
  """

  use Ecto.Migration

  def change do
    create table(:tidy_stops) do
      add(:collection, :string, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:tidy_stops, [:collection]))
  end
end
