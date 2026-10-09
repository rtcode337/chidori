defmodule Chidori.News.InterestsTest do
  @moduledoc """
  興味トピックの読み書き。**選べば末尾に足し、もう一度選べば外す**。
  """

  use Chidori.DataCase, async: false

  alias Chidori.News.Interests

  test "選んだ順に並び、もう一度選ぶと外れる" do
    assert Interests.toggle("tazuna_tech", "LLM") == ["LLM"]
    assert Interests.toggle("tazuna_tech", "Rust") == ["LLM", "Rust"]
    assert Interests.toggle("tazuna_tech", "LLM") == ["Rust"]
  end

  test "話題ごとに別に持つ" do
    Interests.toggle("tazuna_tech", "LLM")

    assert Interests.list("tazuna_news") == []
  end

  test "依頼文を組む前に、話題へ載せる" do
    Interests.toggle("tazuna_tech", "LLM")

    assert %{interests: ["LLM"]} = Interests.attach(%{collection: "tazuna_tech"})
  end

  test "ほかの話題の興味トピックを使う話題には、そちらを載せる" do
    # 技術イベントには興味トピックを選ぶ図が無いので、技術ニュースのものを使う
    Interests.toggle("tazuna_tech", "LLM")

    events = Chidori.Topics.get("tazuna_events")
    assert events.interests_from == "tazuna_tech"
    assert %{interests: ["LLM"]} = Interests.attach(events)
  end
end
