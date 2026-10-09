defmodule Chidori.Repo.Migrations.CreateBookMarks do
  @moduledoc """
  技術書に付けた「読んだ」印とメモ（`Chidori.Datasets.BookMarks`）。

  1 行 1 冊。鍵は本棚の 1 冊の見出し（Chiezo の文書の見出し）。
  **行が無いことは「読んでいない」**を意味します。
  """

  use Ecto.Migration

  def change do
    create table(:book_marks) do
      add(:title, :string, null: false)
      add(:read, :boolean, null: false, default: false)
      add(:read_on, :date)
      add(:note, :text, null: false, default: "")

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:book_marks, [:title]))
  end
end
