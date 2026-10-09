defmodule Chidori.Repo.Migrations.CreateSentNotices do
  @moduledoc """
  知らせたものの記録。

  **同じものを二度知らせない**ために要る。まとめは Chiezo 側に溜まっていて、
  Chidori は時々読みに行くだけなので、**読み直すたびに同じまとめが返ってくる** ——
  何を知らせたかを覚えていないと、読むたびに通知が飛ぶ。

  **メモリでは足りない。** 知らせた記録が再起動で消えると、立ち上げ直した拍子に
  前のまとめをもう一度知らせることになる(`Chidori.Repo` の説明にある「通知の記録」が
  これ)。
  """

  use Ecto.Migration

  def change do
    create table(:sent_notices) do
      # どの収集のものか。話題ごとに通知先が違うので、鍵だけでは足りない
      add :collection, :string, null: false
      # 知らせたものの見分け。まとめの見出しを使う —— **あれは重複の鍵**で、
      # 回ごとに変わることを Chiezo 側の依頼文で保証している
      add :key, :string, null: false
      # どこへ知らせたか。宛先を変えたときに、変えた先へは改めて届いてほしい
      add :topic, :string, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    # 1 つのまとめにつき 1 回。**宛先も鍵に入れる** —— 宛先を変えたのに
    # 「もう知らせた」と黙られると、新しい宛先には何も来ないまま気づけない
    create unique_index(:sent_notices, [:collection, :key, :topic])
  end
end
