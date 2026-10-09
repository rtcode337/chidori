defmodule Chidori.Repo.Migrations.CreateClosedTwinChecks do
  @moduledoc """
  閉店の片割れを確かめてもらった控え（`Chidori.Datasets.ClosedTwins`）。

  **同じ組を二度頼まないため**に持ちます。確かめた AI が「別の店なので残す」と
  判断した 1 件は、そのまま生きて残る —— 控えが無いと、毎日同じ店を頼み直すことになる。
  1 行 1 組（残った店と、その近くで閉店として消した店）。
  """

  use Ecto.Migration

  def change do
    create table(:closed_twin_checks) do
      add(:collection, :string, null: false)
      add(:twin, :string, null: false)
      add(:closed, :string, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:closed_twin_checks, [:collection, :twin, :closed]))
  end
end
