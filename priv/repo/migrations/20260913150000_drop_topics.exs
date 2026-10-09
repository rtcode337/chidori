defmodule Chidori.Repo.Migrations.DropTopics do
  @moduledoc """
  話題の表を落とす。

  この表が持っていたのは設定だけ(誰に頼むか)で、名前も収集名も関心もコードの側
  (`Chidori.Topics.defined/0`)にある。誰に頼むかは巡回ごとに画面から選んで Chiezo へ
  送る形になったので、持ち主は Chiezo ひとつになった —— こちらに写しを残すと、
  どちらが本物か分からなくなる。
  """

  use Ecto.Migration

  def up do
    drop table(:topics)
  end

  # 戻すときのために、元の形をそのまま作り直す(中身は戻らない)
  def down do
    create table(:topics) do
      add :name, :string, null: false
      add :collection, :string, null: false
      add :interest, :text, null: false, default: ""
      add :collect_backend, :string
      add :collect_model, :string
      add :collect_effort, :string
      add :select_backend, :string
      add :select_model, :string
      add :select_effort, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:topics, [:name])
    create unique_index(:topics, [:collection])
  end
end
