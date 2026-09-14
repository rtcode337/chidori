defmodule Antenna.Repo.Migrations.DropArticleFame do
  @moduledoc """
  知名度の控えを落とす。

  この表が持っていたのは jawiki の月次ページビューの写しで、図を出すたびに
  画家 1 人ずつ Chiezo へ引きに行くのを避けるための控えだった。
  その値は収集の側が文書に載せるようになった(`extra.pageviews_month`)ので、
  antenna は収集を読むだけで図を描ける —— 控える対象そのものが無くなった。
  """

  use Ecto.Migration

  def up do
    drop table(:article_fame)
  end

  # 戻すときのために、元の形をそのまま作り直す(中身は戻らない)
  def down do
    create table(:article_fame, primary_key: false) do
      add :article, :string, primary_key: true, null: false
      add :views, :integer, null: false, default: 0
      add :fetched_at, :utc_datetime, null: false
    end

    create index(:article_fame, [:fetched_at])
  end
end
