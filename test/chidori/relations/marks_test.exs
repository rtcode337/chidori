defmodule Chidori.Relations.MarksTest do
  use Chidori.DataCase, async: false

  alias Chidori.Relations.Marks

  defp attrs(overrides \\ %{}) do
    Map.merge(%{"seen" => true, "seen_on" => "2026-09-12", "note" => "回顧展で見た"}, overrides)
  end

  test "書いた印を、図とノード名で引ける" do
    {:ok, mark} = Marks.put("painters", "フィンセント・ファン・ゴッホ", attrs())

    assert mark.seen
    assert mark.seen_on == ~D[2026-09-12]
    assert mark.note == "回顧展で見た"
    assert Marks.get("painters", "フィンセント・ファン・ゴッホ").doc_id == mark.doc_id
  end

  test "同じノードに書き直しても増えない" do
    {:ok, first} = Marks.put("painters", "クロード・モネ", attrs())
    {:ok, second} = Marks.put("painters", "クロード・モネ", attrs(%{"note" => "書き直した"}))

    assert first.doc_id == second.doc_id
    assert second.note == "書き直した"
  end

  test "見た印を付けた時刻を残し、メモを直しただけでは動かさない" do
    {:ok, first} = Marks.put("movies", "時刻の映画", attrs())
    assert %DateTime{} = first.seen_at
    assert Marks.get("movies", "時刻の映画").seen_at == first.seen_at

    {:ok, again} = Marks.put("movies", "時刻の映画", attrs(%{"note" => "メモだけ直した"}))
    assert again.seen_at == first.seen_at

    {:ok, unseen} = Marks.put("movies", "時刻の映画", attrs(%{"seen" => false}))
    assert unseen.seen_at == nil
  end

  test "見た映画は、同じ日なら記録した新しい順に並べる（時刻の無い前の記録は記録の番号の順）" do
    alias Chidori.Relations.Mark

    marks = %{
      "古い記録" => %Mark{node_name: "古い記録", seen: true, seen_on: ~D[2026-10-01], doc_id: 5},
      "朝" => %Mark{
        node_name: "朝",
        seen: true,
        seen_on: ~D[2026-10-01],
        seen_at: ~U[2026-10-01 01:00:00Z],
        doc_id: 1
      },
      "夜" => %Mark{
        node_name: "夜",
        seen: true,
        seen_on: ~D[2026-10-01],
        seen_at: ~U[2026-10-01 12:00:00Z],
        doc_id: 2
      },
      "前の日" => %Mark{node_name: "前の日", seen: true, seen_on: ~D[2026-09-30], doc_id: 9}
    }

    assert Enum.map(ChidoriWeb.SeenFilms.seen(marks), & &1.node_name) == ["夜", "朝", "古い記録", "前の日"]
  end

  test "図が違えば別の印になる" do
    {:ok, _} = Marks.put("painters", "同じ名前", attrs())
    {:ok, _} = Marks.put("people", "同じ名前", attrs(%{"note" => "人物のほう"}))

    assert Marks.get("painters", "同じ名前").note == "回顧展で見た"
    assert Marks.get("people", "同じ名前").note == "人物のほう"
  end

  test "印も日付もメモも空にすると、記録ごと消える" do
    # 空の行が残っていると、図の上で「見た」ものと見分けが付かない
    {:ok, _} = Marks.put("painters", "エドガー・ドガ", attrs())

    assert {:ok, nil} =
             Marks.put("painters", "エドガー・ドガ", %{
               "seen" => false,
               "seen_on" => nil,
               "note" => "  "
             })

    assert Marks.get("painters", "エドガー・ドガ") == nil
  end

  test "一度も書いていないものを空で保存しても、行を作らない" do
    assert {:ok, nil} =
             Marks.put("painters", "誰か", %{"seen" => false, "seen_on" => nil, "note" => ""})

    assert Marks.for_view("painters") == %{}
  end

  test "その図のぶんだけを、ノード名で引ける形で返す" do
    {:ok, _} = Marks.put("painters", "あ", attrs())
    {:ok, _} = Marks.put("painters", "い", attrs())
    {:ok, _} = Marks.put("people", "う", attrs())

    marks = Marks.for_view("painters")

    assert Map.keys(marks) |> Enum.sort() == ["あ", "い"]
    assert marks["あ"].seen
  end

  test "見た日を書かずに、印とメモだけでも残せる" do
    # 展覧会の日付を覚えていないことはある。それで記録ごと消える理由が無い
    {:ok, mark} =
      Marks.put("painters", "誰か", %{"seen" => true, "seen_on" => nil, "note" => ""})

    assert mark.seen
    assert mark.seen_on == nil
  end
end
