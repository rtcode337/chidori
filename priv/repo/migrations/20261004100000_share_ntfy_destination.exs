defmodule Chidori.Repo.Migrations.ShareNtfyDestination do
  @moduledoc """
  ntfy の宛先（トピック名と場所）を、話題ごとから**全部の通知で 1 つ**にする。

  話題ごとに同じトピックを書き写していて、変えるときに全部の画面を回る羽目に
  なっていた。宛先は設定画面の「通知」タブに 1 つだけ持ち、話題ごとには
  **知らせるかどうか**（`notify`）だけを残す。

  いまの宛先は、いちばん多く使われているものを共通の宛先に写す。
  トピックを書いてあった話題は「知らせる」にする（書いてなかった話題は知らせない）。
  """

  use Ecto.Migration

  def up do
    create table(:ntfy_settings) do
      add(:topic, :string, null: false, default: "")
      add(:base_url, :string, null: false, default: "")

      timestamps(type: :utc_datetime)
    end

    alter table(:notify_settings) do
      add(:notify, :boolean, null: false, default: false)
    end

    flush()

    execute("UPDATE notify_settings SET notify = (ntfy_topic <> '')")

    execute("""
    INSERT INTO ntfy_settings (topic, base_url, inserted_at, updated_at)
    SELECT ntfy_topic, ntfy_base_url, now(), now()
      FROM notify_settings
     WHERE ntfy_topic <> ''
     GROUP BY ntfy_topic, ntfy_base_url
     ORDER BY count(*) DESC, max(updated_at) DESC
     LIMIT 1
    """)

    alter table(:notify_settings) do
      remove(:ntfy_topic)
      remove(:ntfy_base_url)
    end
  end

  def down do
    alter table(:notify_settings) do
      add(:ntfy_topic, :string, null: false, default: "")
      add(:ntfy_base_url, :string, null: false, default: "")
    end

    flush()

    execute("""
    UPDATE notify_settings
       SET ntfy_topic = s.topic, ntfy_base_url = s.base_url
      FROM (SELECT topic, base_url FROM ntfy_settings LIMIT 1) s
     WHERE notify_settings.notify
    """)

    alter table(:notify_settings) do
      remove(:notify)
    end

    drop(table(:ntfy_settings))
  end
end
