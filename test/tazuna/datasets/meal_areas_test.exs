defmodule Tazuna.Datasets.MealAreasTest do
  @moduledoc """
  食事処の範囲の番号。見ているのは、**空いているいちばん小さい番号を使うこと**と、
  **Chiezo に同じ名前の収集が残っている番号は使わないこと**です（範囲の番号は
  Chiezo の収集の名前 `tazuna_dining_<番号>` になる）。
  """

  use Tazuna.DataCase, async: false

  alias Tazuna.Datasets.MealAreas

  @box %{"south" => 35.67, "west" => 139.75, "north" => 35.69, "east" => 139.78}

  defp create(name, chiezo_names \\ []),
    do: MealAreas.create(Map.put(@box, "name", name), fn -> {:ok, chiezo_names} end)

  test "消した範囲の番号を、次に作る範囲で埋める" do
    {:ok, first} = create("一つ目")
    {:ok, second} = create("二つ目")
    {:ok, third} = create("三つ目")
    assert {first.id, second.id, third.id} == {1, 2, 3}

    MealAreas.delete(second)
    {:ok, again} = create("埋める")
    assert again.id == 2
  end

  test "Chiezo に収集が残っている番号は使わない（前の範囲の店を引き継がない）" do
    {:ok, area} = create("一つ目", ["tazuna_dining_1", "tazuna_dining_2", "tazuna_news"])
    assert area.id == 3
  end

  test "Chiezo の収集の一覧を読めなければ作らない" do
    assert {:error, changeset} =
             MealAreas.create(Map.put(@box, "name", "一つ目"), fn ->
               {:error, :chiezo_unavailable}
             end)

    assert {"を決められません（Chiezo の収集の一覧を読めませんでした）", _} = changeset.errors[:id]
    assert MealAreas.list() == []
  end

  test "入れた値がおかしければ、Chiezo を読む前に断る" do
    assert {:error, changeset} =
             MealAreas.create(Map.put(@box, "name", ""), fn -> flunk("読まない") end)

    assert changeset.errors[:name]
  end
end
