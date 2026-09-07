defmodule Antenna.TopicsTest do
  use Antenna.DataCase, async: true

  alias Antenna.Topics

  defp valid(overrides \\ %{}) do
    Map.merge(%{name: "ニュース", collection: "antenna_news"}, overrides)
  end

  test "話題を作れる" do
    assert {:ok, topic} = Topics.create(valid())
    assert topic.name == "ニュース"
    # 相手は未指定が初期状態（Chiezo の既定にまかせる）
    assert topic.collect_backend == nil
    assert topic.select_backend == nil
  end

  test "集める相手と選ぶ相手を別に持てる" do
    assert {:ok, topic} =
             Topics.create(
               valid(%{
                 collect_backend: "claude",
                 collect_model: "haiku",
                 select_backend: "antigravity",
                 select_effort: "low"
               })
             )

    assert topic.collect_backend == "claude"
    assert topic.select_backend == "antigravity"
    assert topic.select_effort == "low"
  end

  test "空欄は「指定しない」に倒す" do
    # 画面のフォームは空欄を空文字で送る。空のまま持つと Chiezo へ空の相手を送ることになる
    assert {:ok, topic} = Topics.create(valid(%{collect_backend: "  ", select_model: ""}))
    assert topic.collect_backend == nil
    assert topic.select_model == nil
  end

  test "収集の名前は Chiezo のソース名の決まりに従う" do
    assert {:error, changeset} = Topics.create(valid(%{collection: "Antenna News"}))
    assert %{collection: [_]} = errors_on(changeset)
  end

  test "同じ名前も同じ収集も 2 つ持てない" do
    assert {:ok, _} = Topics.create(valid())
    assert {:error, changeset} = Topics.create(valid(%{collection: "other_news"}))
    assert %{name: [_]} = errors_on(changeset)

    assert {:error, changeset} = Topics.create(valid(%{name: "別の話題"}))
    assert %{collection: [_]} = errors_on(changeset)
  end

  test "収集の名前から引ける" do
    {:ok, topic} = Topics.create(valid())
    assert Topics.get_by_collection("antenna_news").id == topic.id
    assert Topics.get_by_collection("nosuch") == nil
  end

  test "1 つも無ければニュースの話題を置く" do
    assert Topics.list() == []
    Topics.ensure_default()
    assert [%{name: "ニュース", collection: "antenna_news"}] = Topics.list()
  end

  test "すでにあれば置き直さない" do
    {:ok, _} = Topics.create(valid(%{name: "自分で作った", collection: "mine"}))
    Topics.ensure_default()
    assert [%{name: "自分で作った"}] = Topics.list()
  end
end
