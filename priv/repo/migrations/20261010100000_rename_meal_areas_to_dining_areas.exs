defmodule Chidori.Repo.Migrations.RenameMealAreasToDiningAreas do
  @moduledoc """
  食事処の範囲の表を `dining_areas` に改める（`Chidori.Datasets.DiningAreas`）。
  Chiezo の収集（`tazuna_dining_<番号>`）と travel-log の種別（`dining`）が dining なので、
  手元の名前もそちらに揃える。

  表の名前を変えても、主キー・索引・番号の列は元の名前のまま残るので、一緒に改める
  （主キーの名前は重なったときの知らせに使っている）。
  """

  use Ecto.Migration

  def up do
    execute("ALTER TABLE meal_areas RENAME TO dining_areas")
    execute("ALTER INDEX meal_areas_pkey RENAME TO dining_areas_pkey")
    execute("ALTER INDEX meal_areas_name_index RENAME TO dining_areas_name_index")
    execute("ALTER SEQUENCE meal_areas_id_seq RENAME TO dining_areas_id_seq")
  end

  def down do
    execute("ALTER SEQUENCE dining_areas_id_seq RENAME TO meal_areas_id_seq")
    execute("ALTER INDEX dining_areas_name_index RENAME TO meal_areas_name_index")
    execute("ALTER INDEX dining_areas_pkey RENAME TO meal_areas_pkey")
    execute("ALTER TABLE dining_areas RENAME TO meal_areas")
  end
end
