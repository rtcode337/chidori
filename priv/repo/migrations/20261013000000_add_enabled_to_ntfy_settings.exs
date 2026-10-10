defmodule Chidori.Repo.Migrations.AddEnabledToNtfySettings do
  @moduledoc """
  ntfy へ送るかどうかの切り替え（`Chidori.Notify.Destination` の `enabled`）。
  トピック名を空にするのを「送らない」の印にしていると、送り直すときに名前を
  覚えておく羽目になる。**今までどおり送る**ので、既定は true。
  """

  use Ecto.Migration

  def change do
    alter table(:ntfy_settings) do
      add(:enabled, :boolean, null: false, default: true)
    end
  end
end
