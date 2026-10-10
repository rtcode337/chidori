defmodule Chidori.Repo.Migrations.RenameCollectionsToChidori do
  @moduledoc """
  Chiezo の収集の名前を `tazuna_*` から `chidori_*` へ改めたので、手元に控えている
  収集の名前も書き換える（トップの並び・通知の設定・整理を止める収集・控えている依頼・
  依頼の記録）。トップの並びの鍵は `topic:tazuna_news` のように頭に種類が付く。
  """

  use Ecto.Migration

  @columns [
    {"home_panels", "key"},
    {"notify_settings", "collection"},
    {"tidy_stops", "collection"},
    {"pending_requests", "collection"},
    {"dataset_requests", "collection"}
  ]

  def up, do: replace_prefix("tazuna_", "chidori_")

  def down, do: replace_prefix("chidori_", "tazuna_")

  # 語の頭（`tazuna_…` か `<種類>:tazuna_…`）だけを置き換える
  defp replace_prefix(from, to) do
    for {table, column} <- @columns do
      execute("""
      UPDATE #{table}
         SET #{column} = regexp_replace(#{column}, '(^|:)#{from}', '\\1#{to}')
       WHERE #{column} ~ '(^|:)#{from}'
      """)
    end
  end
end
