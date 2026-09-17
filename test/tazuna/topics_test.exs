defmodule Tazuna.TopicsTest do
  @moduledoc """
  話題の定義。**足すのはここへ 1 つ書くだけ**なので、見ているのは
  「タブも収集も増えるか」ではなく、**書いた中身が形として正しいか**です。
  """

  use ExUnit.Case, async: true

  alias Tazuna.Topics

  test "収集の名前は Chiezo のソース名になる" do
    # 英小文字・数字・_ だけ。後から変えると、それまで溜めた先を見失う
    for topic <- Topics.list() do
      assert topic.collection =~ ~r/\A[a-z][a-z0-9_]{1,30}\z/, topic.collection
    end
  end

  test "話題には名前と関心がある" do
    # 関心が空だと、何を集めればよいか決まらないまま AI が埋めることになる
    for topic <- Topics.list() do
      assert topic.name != ""
      assert String.trim(topic.interest) != "", topic.name
    end
  end

  test "配信元は http(s) だけ" do
    for topic <- Topics.list(), feed <- topic.feeds do
      assert feed.url =~ ~r{\Ahttps?://}, feed.url
      assert feed.tags != []
    end
  end

  test "映画の話題が入っている" do
    movies = Topics.get("tazuna_movies")

    assert movies.name == "映画"
    # 公開情報は機械で引き、評判と興行成績は整理の回が足す
    assert length(movies.feeds) >= 3
    assert movies.interest =~ "公開"
  end
end
