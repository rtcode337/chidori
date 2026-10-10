defmodule Chidori.Datasets.DiningAreasTest do
  @moduledoc """
  食事処の範囲の番号。見ているのは、**空いているいちばん小さい番号を使うこと**と、
  **Chiezo に同じ名前の収集が残っている番号は使わないこと**です（範囲の番号は
  Chiezo の収集の名前 `chidori_dining_<番号>` になる）。
  """

  use Chidori.DataCase, async: false

  alias Chidori.Datasets.DiningAreas

  @box %{"south" => 35.67, "west" => 139.75, "north" => 35.69, "east" => 139.78}

  defp create(name, chiezo_names \\ []),
    do: DiningAreas.create(Map.put(@box, "name", name), fn -> {:ok, chiezo_names} end)

  test "消した範囲の番号を、次に作る範囲で埋める" do
    {:ok, first} = create("一つ目")
    {:ok, second} = create("二つ目")
    {:ok, third} = create("三つ目")
    assert {first.id, second.id, third.id} == {1, 2, 3}

    DiningAreas.delete(second)
    {:ok, again} = create("埋める")
    assert again.id == 2
  end

  test "Chiezo に収集が残っている番号は使わない（前の範囲の店を引き継がない）" do
    {:ok, area} = create("一つ目", ["chidori_dining_1", "chidori_dining_2", "chidori_news"])
    assert area.id == 3
  end

  test "Chiezo の収集の一覧を読めなければ作らない" do
    assert {:error, changeset} =
             DiningAreas.create(Map.put(@box, "name", "一つ目"), fn ->
               {:error, :chiezo_unavailable}
             end)

    assert {"を決められません（Chiezo の収集の一覧を読めませんでした）", _} = changeset.errors[:id]
    assert DiningAreas.list() == []
  end

  test "入れた値がおかしければ、Chiezo を読む前に断る" do
    assert {:error, changeset} =
             DiningAreas.create(Map.put(@box, "name", ""), fn -> flunk("読まない") end)

    assert changeset.errors[:name]
  end

  describe "Chiezo から範囲を戻す" do
    defp dining(id, name, bbox) do
      %{
        "name" => "chidori_dining_#{id}",
        "description" => "Chidori のデータ収集（#{name}の食事処 / travel-log 向け）",
        "partition" => %{"by" => "geo", "bbox" => bbox}
      }
    end

    test "手元に無い範囲を、番号・名前・四角そのままで戻す" do
      {:ok, _kept} = create("残っている", ["chidori_dining_2"])

      collections = [
        dining(1, "残っている", [35.6, 139.7, 35.61, 139.71]),
        dining(2, "丸の内", [35.678, 139.76, 35.686, 139.77]),
        %{"name" => "chidori_news", "description" => "x"}
      ]

      assert {:ok, %{restored: [area], skipped: []}} =
               DiningAreas.restore(fn -> {:ok, collections} end)

      assert {area.id, area.name} == {2, "丸の内"}
      assert DiningAreas.bbox(area) == [35.678, 139.76, 35.686, 139.77]
      # 手元にある 1 番は上書きしない
      assert [%{id: 1, name: "残っている"}, %{id: 2}] = DiningAreas.list()
    end

    test "説明か区画が読めない収集は飛ばして名前を返す" do
      broken = %{"name" => "chidori_dining_5", "description" => "手で書き換えた説明"}

      assert {:ok, %{restored: [], skipped: ["chidori_dining_5"]}} =
               DiningAreas.restore(fn -> {:ok, [broken]} end)
    end

    test "Chiezo を読めなければ何もしない" do
      assert {:error, :chiezo_unavailable} =
               DiningAreas.restore(fn -> {:error, :chiezo_unavailable} end)

      assert DiningAreas.list() == []
    end
  end
end
