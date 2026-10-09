defmodule Chidori.Repo.Migrations.CreateTopics do
  @moduledoc """
  話題(関心テーマ)ごとの設定。

  いまは「ニュース」1 つだが、他の話題を順次足していく前提なので最初から表にする
  —— 1 つぶんを設定ファイルや環境変数で持つと、2 つ目を足すときに置き場ごと作り直す
  ことになる。
  """

  use Ecto.Migration

  def change do
    create table(:topics) do
      # 画面に出す名前と、Chiezo に置く収集の名前。後者はソース名になるので狭く取る
      add :name, :string, null: false
      add :collection, :string, null: false

      # 何を集めてほしいか。Chiezo へ渡す指示文の素になる
      add :interest, :text, null: false, default: ""

      # 誰に頼むか。**集める相手と選ぶ相手を別に持つ** —— 役割が違うので、
      # 速さと質の釣り合いも別に決めたい(集めるのは web を歩く仕事、
      # 選ぶのは溜まったものを読む仕事)
      add :collect_backend, :string
      add :collect_model, :string
      add :collect_effort, :string
      add :select_backend, :string
      add :select_model, :string
      add :select_effort, :string

      timestamps(type: :utc_datetime)
    end

    # 話題の名前も収集の名前も、1 つずつしか持てない
    create unique_index(:topics, [:name])
    create unique_index(:topics, [:collection])
  end
end
