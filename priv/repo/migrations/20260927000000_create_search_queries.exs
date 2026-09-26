defmodule Tazuna.Repo.Migrations.CreateSearchQueries do
  @moduledoc """
  機械収集が引く**検索文の控え**（`Tazuna.Datasets.BookQueries`）。

  **同じ検索文で引き直しても、同じ記事が返るだけ**なので、決めた時刻ごとに AI に
  新しい検索文を考えさせて差し替える。考えさせるときに「これまでに使った検索文と、
  それぞれが連れてきた新しい記事の数」を見せるために持つ。
  """

  use Ecto.Migration

  def change do
    create table(:search_queries) do
      add(:collection, :string, null: false)
      add(:query, :string, null: false)
      # 配信元に載せた時刻。**同じ時刻のものが 1 回ぶんの組**
      add(:used_at, :utc_datetime, null: false)

      # その検索文で入った記事の数（次の回の頭で数える。数えるまでは nil）
      add(:found, :integer)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:search_queries, [:collection, :query]))
    create(index(:search_queries, [:collection, :used_at]))
  end
end
