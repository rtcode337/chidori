defmodule Chidori.Repo.Migrations.CreateHomePanels do
  @moduledoc """
  トップページに並べる枠（設定ページで選ぶ）。1 行 1 枠で、並びは選んだ順。

  **鍵は枠の名前**（`topic:tazuna_news` / `relations:painters` / `books`）。
  枠の中身はコードの側にあるので、ここに持つのは「どれを・どの順で」だけ。
  """

  use Ecto.Migration

  def change do
    create table(:home_panels) do
      add(:key, :string, null: false)
      add(:position, :integer, null: false, default: 0)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:home_panels, [:key]))
  end
end
