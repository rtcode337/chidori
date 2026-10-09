defmodule Chidori.Datasets.BookMarksTest do
  @moduledoc """
  技術書の「読んだ」印。見ているのは、**書いて読み直せること**、**空にすると消えること**、
  **読んだ本だけが上位の枠から外す集まりに入ること**です。
  """

  use Chidori.DataCase, async: false

  alias Chidori.Datasets.BookMarks

  test "書いた印は本の見出しで引ける" do
    assert {:ok, mark} =
             BookMarks.put("本:A", %{"read" => true, "read_on" => "2026-10-01", "note" => " 良書 "})

    assert mark.read
    assert mark.read_on == ~D[2026-10-01]
    assert mark.note == "良書"
    assert %{"本:A" => _} = BookMarks.all()
  end

  test "印も日付もメモも空にすると、記録ごと消える" do
    {:ok, _mark} = BookMarks.put("本:A", %{"read" => true})

    assert {:ok, nil} = BookMarks.put("本:A", %{"read" => false, "read_on" => nil, "note" => ""})
    assert BookMarks.get("本:A") == nil
  end

  test "上位の枠から外すのは、読んだ本だけ（メモだけの本は外さない）" do
    {:ok, _mark} = BookMarks.put("本:A", %{"read" => true})
    {:ok, _mark} = BookMarks.put("本:B", %{"note" => "気になる"})

    assert BookMarks.read_titles() == MapSet.new(["本:A"])
  end
end
