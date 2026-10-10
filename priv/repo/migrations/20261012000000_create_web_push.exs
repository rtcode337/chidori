defmodule Chidori.Repo.Migrations.CreateWebPush do
  @moduledoc """
  端末へ知らせる（Web Push）ための表。

  - `web_push_keys` —— 送り手の鍵（VAPID）。**行は 1 つだけ**で、最初に要ったときに
    作る。イメージや環境変数に持たせないのは、手で用意させないため。鍵を替えると
    登録済みの端末がすべて受け取れなくなるので、DB に置いて作り直さない
  - `web_push_subscriptions` —— 通知を受け取る端末。ブラウザが渡す宛先（endpoint）と、
    中身を暗号にするための端末の鍵（p256dh・auth）を持つ
  """

  use Ecto.Migration

  def change do
    create table(:web_push_keys) do
      add(:public_key, :binary, null: false)
      add(:private_key, :binary, null: false)

      timestamps(type: :utc_datetime)
    end

    create table(:web_push_subscriptions) do
      add(:endpoint, :text, null: false)
      add(:p256dh, :string, null: false)
      add(:auth, :string, null: false)
      add(:label, :string, null: false, default: "")

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:web_push_subscriptions, [:endpoint]))
  end
end
