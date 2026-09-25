defmodule Tazuna.Repo.Migrations.CreateNewsInterests do
  @moduledoc """
  話題ごとの「興味トピック」。トピックの網から利用者が選んだ語を 1 行ずつ持つ。

  **Chiezo には持たせない。** 何に興味があるかは利用者の都合で、Chiezo は題材も
  都合も持たない側。tazuna が持ち、整理と要約の依頼文に書き込んで送る。

  **語そのもので持つ**（トピックの id ではなく）。トピックは Chiezo の収集の 1 件で、
  焼き直しで id が変わりうる —— 語なら、整理の回が付けるタグとそのまま突き合う。
  """

  use Ecto.Migration

  def change do
    create table(:news_interests) do
      add(:collection, :string, null: false)
      add(:name, :string, null: false)
      # 選んだ順。依頼文にもこの順で並ぶ
      add(:position, :integer, null: false, default: 0)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:news_interests, [:collection, :name]))
  end
end
