defmodule Chidori.AreaFixture do
  @moduledoc """
  食事処の範囲を 1 つ作る（番号 1・東京のあたり）。食事処は範囲ごとに画面があるので、
  画面を見るテストはこれを作ってから開く（`dining-1` / `chidori_dining_1`）。
  """

  alias Chidori.Datasets.DiningAreas

  def area! do
    Chidori.Repo.insert!(
      %DiningAreas{id: 1, name: "テスト範囲", south: 35.5, west: 139.5, north: 35.9, east: 139.9},
      on_conflict: :nothing
    )
  end
end
