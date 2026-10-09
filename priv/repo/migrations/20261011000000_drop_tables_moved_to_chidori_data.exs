defmodule Chidori.Repo.Migrations.DropTablesMovedToChidoriData do
  @moduledoc """
  興味トピックと、読んだ・見た記録の表を消す。中身は Chiezo の置き場 `chidori_data` に
  移した（`Chidori.DataStore`。前の版が起動時に、置き場にまだ無いものを写した）。
  """

  use Ecto.Migration

  def up do
    drop(table(:news_interests))
    drop(table(:book_marks))
    drop(table(:relation_marks))
  end

  # 中身は戻らない（置き場にある）。表の形だけ作り直す
  def down do
    create table(:news_interests) do
      add(:collection, :string, null: false)
      add(:name, :string, null: false)
      add(:position, :integer, null: false, default: 0)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:news_interests, [:collection, :name]))

    create table(:book_marks) do
      add(:title, :string, null: false)
      add(:read, :boolean, null: false, default: false)
      add(:read_on, :date)
      add(:note, :text, null: false, default: "")
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:book_marks, [:title]))

    create table(:relation_marks) do
      add(:view, :string, null: false)
      add(:node_name, :string, null: false)
      add(:seen, :boolean, null: false, default: false)
      add(:seen_on, :date)
      add(:note, :text, null: false, default: "")
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:relation_marks, [:view, :node_name]))
  end
end
