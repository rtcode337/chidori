defmodule Antenna.TopicsTest do
  use Antenna.DataCase, async: true

  alias Antenna.Topics

  test "話題は定義から出る（DB に行が無くても出る）" do
    # **話題は antenna の機能。** 関連図の「人物」「画家」と同じ立ち位置で、
    # 集め方も関心も話題ごとに違う。DB に持たせていた頃は、コードに足した話題が
    # 既に使っている環境へ永遠に届かなかった（最初の 1 回だけ配る作りだったため）
    names = Enum.map(Topics.list(), & &1.name)

    assert "ニュース" in names
    assert "技術ニュース" in names
    assert Enum.map(Topics.defined(), & &1.collection) == Enum.map(Topics.list(), & &1.collection)
  end

  test "設定していない話題は、相手が未指定で出る" do
    topic = Topics.get("antenna_tech")

    assert topic.interest =~ "ソフトウェア開発"
    assert topic.collect_backend == nil
    assert topic.select_backend == nil
  end

  test "設定は保存でき、次に読むとき重なる" do
    assert {:ok, _row} =
             Topics.save_settings("antenna_tech", %{
               "collect_backend" => "claude",
               "collect_model" => "haiku",
               "select_backend" => "antigravity",
               "select_effort" => "low"
             })

    topic = Topics.get("antenna_tech")
    assert topic.collect_backend == "claude"
    assert topic.select_effort == "low"
    # 名前も関心も定義のまま（保存で上書きされない）
    assert topic.name == "技術ニュース"
    assert topic.interest =~ "ソフトウェア開発"
  end

  test "同じ話題を 2 回保存しても行は増えない" do
    {:ok, _} = Topics.save_settings("antenna_tech", %{"collect_backend" => "claude"})
    {:ok, _} = Topics.save_settings("antenna_tech", %{"collect_backend" => "codex"})

    assert Topics.get("antenna_tech").collect_backend == "codex"
    assert Antenna.Repo.aggregate(Antenna.Topics.Topic, :count) == 1
  end

  test "空欄は「指定しない」に倒す" do
    # 画面のフォームは空欄を空文字で送る。空のまま持つと Chiezo へ空の相手を送ることになる
    {:ok, _} = Topics.save_settings("antenna_news", %{"collect_backend" => "  ",
                                                      "select_model" => ""})
    topic = Topics.get("antenna_news")
    assert topic.collect_backend == nil
    assert topic.select_model == nil
  end

  test "名前と収集名は画面から書き換えられない" do
    # **定義と DB が別々に動き出さないように**、設定だけを読む
    {:ok, _} =
      Topics.save_settings("antenna_tech", %{
        "name" => "別の名前",
        "collection" => "other",
        "interest" => "別の関心",
        "collect_backend" => "claude"
      })

    topic = Topics.get("antenna_tech")
    assert topic.name == "技術ニュース"
    assert topic.interest =~ "ソフトウェア開発"
    assert Topics.get("other") == nil
  end

  test "定義に無い話題は保存できない" do
    assert Topics.save_settings("nosuch", %{"collect_backend" => "claude"}) ==
             {:error, :unknown_topic}
  end

  test "知らない収集の名前を引いても壊れない" do
    assert Topics.get("nosuch") == nil
    assert Topics.get(nil) == nil
  end
end
