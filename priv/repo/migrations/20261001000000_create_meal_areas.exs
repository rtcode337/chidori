defmodule Tazuna.Repo.Migrations.CreateMealAreas do
  @moduledoc """
  食事処を集める範囲（`Tazuna.Datasets.MealAreas`）。1 行 1 範囲で、**範囲ごとに
  Chiezo の収集が 1 つ**できます（`tazuna_dining_<id>`）。

  日本全体を 1 つの収集で回していた頃は、59.7 万件・4,105 区画で一周のめどが立たず、
  AI の費用もかさみ、抜け漏れと間違いが多すぎて地図として使えなかった。
  見たい範囲だけを、細かい区画で回す。
  """

  use Ecto.Migration

  def change do
    create table(:meal_areas) do
      add(:name, :string, null: false)
      add(:south, :float, null: false)
      add(:west, :float, null: false)
      add(:north, :float, null: false)
      add(:east, :float, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:meal_areas, [:name]))
  end
end
