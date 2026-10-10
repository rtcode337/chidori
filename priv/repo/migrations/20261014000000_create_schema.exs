defmodule Chidori.Repo.Migrations.CreateSchema do
  @moduledoc """
  いまの表の形をまとめて作る（それまでの移行を 1 つに畳んだもの）。

  **番号は畳む前の最後の移行と同じ**にしてある —— 畳む前の移行を当て終えた DB には
  この番号がもう記録されているので、当て直されない。新しく作る DB だけがこれで作られる。
  """

  use Ecto.Migration

  def change do
    # トップページに並べる枠（`Chidori.Home`）
    create table(:home_panels) do
      add(:key, :string, null: false)
      add(:position, :integer, null: false, default: 0)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:home_panels, [:key]))

    # 話題ごとの通知と要約の時刻（`Chidori.Notify.Settings`）
    create table(:notify_settings) do
      add(:collection, :string, null: false)
      add(:digest_at, :string, null: false, default: "")
      add(:last_digest_at, :utc_datetime)
      add(:last_digest_result, :string, null: false, default: "")
      add(:notify, :boolean, null: false, default: false)
      add(:last_sent_at, :utc_datetime)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:notify_settings, [:collection]))

    # ntfy の宛先（`Chidori.Notify.Destination`。行は 1 つ）
    create table(:ntfy_settings) do
      add(:topic, :string, null: false, default: "")
      add(:base_url, :string, null: false, default: "")
      add(:enabled, :boolean, null: false, default: true)
      timestamps(type: :utc_datetime)
    end

    # 端末への通知（`Chidori.WebPush`）。送り手の鍵（行は 1 つ）と、登録した端末
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

    # 巡回の間隔と、整理を自動で回さない収集（`Chidori.CollectPace`）
    create table(:collect_paces) do
      add(:kind, :string, null: false)
      add(:minutes, :integer, null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:collect_paces, [:kind]))

    create table(:tidy_stops) do
      add(:collection, :string, null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:tidy_stops, [:collection]))

    # 関連図ごとの設定（`Chidori.Relations.Settings`）と顔写真の写し（`Chidori.Relations.Faces`）
    create table(:relation_settings) do
      add(:view, :string, null: false)
      add(:min_pageviews, :integer, null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:relation_settings, [:view]))

    create table(:face_thumbs) do
      add(:source_url, :text, null: false)
      add(:content_type, :string, null: false, default: "")
      add(:image, :binary)
      add(:status, :string, null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:face_thumbs, [:source_url]))

    # 食事処の範囲（`Chidori.Datasets.DiningAreas`）
    create table(:dining_areas) do
      add(:name, :string, null: false)
      add(:south, :float, null: false)
      add(:west, :float, null: false)
      add(:north, :float, null: false)
      add(:east, :float, null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:dining_areas, [:name]))

    # travel-log からの依頼の控えと、頼んだ記録（`Chidori.Datasets.Requests`）
    create table(:pending_requests) do
      add(:collection, :string, null: false)
      add(:text, :text, null: false)
      add(:lat, :float, null: false)
      add(:lon, :float, null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:pending_requests, [:collection, :text]))

    create table(:dataset_requests) do
      add(:collection, :string, null: false)
      add(:keys, {:array, :string}, null: false, default: [])
      add(:text, :text, null: false, default: "")
      add(:points, :integer, null: false, default: 0)
      add(:missed, :integer, null: false, default: 0)
      add(:status, :string, null: false, default: "waiting")
      add(:error, :text, null: false, default: "")
      add(:requested_at, :utc_datetime, null: false)
      timestamps(type: :utc_datetime)
    end

    create(index(:dataset_requests, [:collection, :requested_at]))
  end
end
