defmodule Chidori.News.InterestsTest do
  @moduledoc """
  興味トピックの読み書き。**選べば末尾に足し、もう一度選べば外す**。
  """

  use Chidori.DataCase, async: false

  alias Chidori.News.Interests

  test "選んだ順に並び、もう一度選ぶと外れる" do
    assert Interests.toggle("chidori_tech", "LLM") == ["LLM"]
    assert Interests.toggle("chidori_tech", "Rust") == ["LLM", "Rust"]
    assert Interests.toggle("chidori_tech", "LLM") == ["Rust"]
  end

  test "話題ごとに別に持つ" do
    Interests.toggle("chidori_tech", "LLM")

    assert Interests.list("chidori_news") == []
  end

  test "依頼文を組む前に、話題へ載せる" do
    Interests.toggle("chidori_tech", "LLM")

    assert %{interests: ["LLM"]} = Interests.attach(%{collection: "chidori_tech"})
  end

  test "ほかの話題の興味トピックを使う話題には、そちらを載せる" do
    # 技術イベントには興味トピックを選ぶ図が無いので、技術ニュースのものを使う
    Interests.toggle("chidori_tech", "LLM")

    events = Chidori.Topics.get("chidori_events")
    assert events.interests_from == "chidori_tech"
    assert %{interests: ["LLM"]} = Interests.attach(events)
  end
end
