defmodule Tazuna.Repo.Migrations.CreateRelationSettingsAndFaces do
  @moduledoc """
  関連図の 2 つの置き場。

  - `relation_settings` —— 図ごとの設定。いまは**名簿の知名度の下限**だけ
    （芸能人の図はカテゴリだけで 3 万人に届くので、月の閲覧数で切ってから AI に回し、
    落ち着いたら下げて広げる）。Chiezo に送る設定は図の画面のほか設定画面からも
    送るので、どこから送っても同じ値になるよう tazuna に持つ
  - `face_thumbs` —— 顔写真の小さな写し。**1 人 1 回だけ**取りに行き、あとは tazuna が
    配る（見るたびに写真の置き場へ取りに行かせない）。取れなかったことも残す
    （無いものを取りに行き続けない）
  """

  use Ecto.Migration

  def change do
    create table(:relation_settings) do
      add(:view, :string, null: false)
      add(:min_pageviews, :integer, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:relation_settings, [:view]))

    create table(:face_thumbs) do
      # 元の画像の URL（Wikimedia）。**鍵はこれ** —— 記事名で持つと、同じ人の
      # 写真が差し替わったときに古い写しを配り続ける
      add(:source_url, :text, null: false)
      add(:content_type, :string, null: false, default: "")
      add(:image, :binary)
      # ok / missing（取れなかった。取りに行き直さない）
      add(:status, :string, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:face_thumbs, [:source_url]))
  end
end
