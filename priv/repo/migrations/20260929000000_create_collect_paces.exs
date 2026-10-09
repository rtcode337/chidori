defmodule Chidori.Repo.Migrations.CreateCollectPaces do
  @moduledoc """
  巡回の間隔（設定ページの「Chiezo 収集」で変える。`Chidori.CollectPace`）。

  1 行 1 種類（`tidy` = 整理、`scan` = ざっと見る）。**書いていない種類は既定の間隔**
  で回るので、行が無いことは「既定のまま」を意味します。
  """

  use Ecto.Migration

  def change do
    create table(:collect_paces) do
      add(:kind, :string, null: false)
      add(:minutes, :integer, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:collect_paces, [:kind]))
  end
end
