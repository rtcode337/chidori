defmodule Chidori.Repo.Migrations.CreateRelationMarks do
  @moduledoc """
  関連図のノードに付ける「見た」印とメモ。

  図に出ているのは Chiezo から読んだものだけで、**利用者が自分で書いたことは
  どこにも残せなかった**。画家の展覧会へ行った、この人の絵を実物で見た、といった
  記録は Chiezo には置けない —— あちらは題材も好みも持たない側なので、
  利用者ごとの事情は Chidori が持つ(README「Chiezo との関係」)。

  **暫定の形**。いまは 1 ノードに 1 件で、見たかどうか・いつ・ひとこと、だけを持つ。
  同じ画家を何度も見に行く記録(展覧会ごとに 1 件)が要るようになったら、
  この表を親にして子を足す形へ広げられるようにしてある。
  """

  use Ecto.Migration

  def change do
    create table(:relation_marks) do
      # どの図のノードか。人物と画家で同じ名前が出ることがあるので、図ごとに分ける
      add :view, :string, null: false
      # ノードの名前。**id ではなく名前で持つ** —— id は Chiezo から読み直すたびに
      # 振り直されるので、印が別人に移る
      add :node_name, :string, null: false

      add :seen, :boolean, null: false, default: false
      # いつ見たか(JST の日付)。見たとだけ分かっても、後から並べられない
      add :seen_on, :date
      add :note, :text, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    # 1 ノードに 1 件。押すたびに増えると、どれがいまの印なのか決まらない
    create unique_index(:relation_marks, [:view, :node_name])
    # 図を描くときに、その図のぶんをまとめて引く
    create index(:relation_marks, [:view])
  end
end
