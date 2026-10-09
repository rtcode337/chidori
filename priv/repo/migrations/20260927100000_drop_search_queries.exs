defmodule Chidori.Repo.Migrations.DropSearchQueries do
  @moduledoc """
  検索文の控えを落とす。**考えるのも控えるのも Chiezo に移した**
  （機械収集の巡回の依頼文に `{queries}` を書くと、その巡回の相手が考える）。

  Chidori に持っていた頃は、Chiezo で収集を作り直しても前の収集の検索文が残り、
  新しい収集ではまだ走っていない検索文が「0 件だった」と数えられて、
  最初の組が一度も走らないまま置き換わった。
  """

  use Ecto.Migration

  def up do
    drop_if_exists(table(:search_queries))
  end

  def down do
    create table(:search_queries) do
      add(:collection, :string, null: false)
      add(:query, :string, null: false)
      add(:used_at, :utc_datetime, null: false)
      add(:found, :integer)

      timestamps()
    end

    create(unique_index(:search_queries, [:collection, :query]))
    create(index(:search_queries, [:collection, :used_at]))
  end
end
