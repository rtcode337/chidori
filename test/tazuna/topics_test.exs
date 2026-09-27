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

  describe "技術イベント" do
    setup do
      %{events: Topics.get("tazuna_events")}
    end

    test "国内を中心に、大きな海外も入れる", %{events: events} do
      assert events.name == "技術イベント"
      assert events.interest =~ "国内"
      assert events.interest =~ "海外"
    end

    test "技術ニュースの右隣に並ぶ" do
      assert Enum.map(Topics.list(), & &1.name) == ["一般ニュース", "技術ニュース", "技術イベント", "映画"]
    end

    test "要約は作らず、開催日のカレンダーを出す", %{events: events} do
      refute Topics.digest?(events)
      assert Topics.calendar?(events)
      assert Topics.digest?(Topics.get("tazuna_tech"))
      refute Topics.calendar?(Topics.get("tazuna_tech"))
    end

    test "カレンダーに要るタグを、並んだイベント全部に付けさせる", %{events: events} do
      assert events.note =~ ~s("開催日:<YYYY-MM-DD>")
      assert events.note =~ ~s("開催地:オンライン")
      assert events.note =~ ~s("注目度:高")
      assert events.note =~ "全部"
    end

    test "日付では古くならない", %{events: events} do
      # 半年先のイベントを 30 日の期限で落とすと、いちばん要るときに消える。
      # 古さは「終わったかどうか」だけ
      refute Topics.ages_out?(events)
      assert Topics.ages_out?(Topics.get("tazuna_tech"))
    end

    test "終わったものは整理の回が落とす", %{events: events} do
      assert events.note =~ "終わったイベントは消して"
    end

    test "行けるかどうかを決められる項目を書かせる", %{events: events} do
      # 開催日と場所が無いと、読む人は何も決められない
      assert events.note =~ "開催日"
      assert events.note =~ "開催地"
      assert events.note =~ "申込先の URL"
    end

    test "同じイベントの別の回は別の 1 件", %{events: events} do
      # 見出しが同じだと、第 3 回の内容が第 4 回で上書きされる
      assert events.note =~ "別の回は別の 1 件"
    end

    test "機械で引ける配信元を持つ", %{events: events} do
      assert events.feeds != []
    end
  end

  test "話題ごとに、古くなり方を選べる" do
    # 既定は「日が経てば古くなる」（ニュースも記事もそう）
    assert Topics.ages_out?(%{name: "何か"})
    refute Topics.ages_out?(%{name: "何か", ages_out: false})
  end

  describe "映画" do
    setup do
      %{movies: Topics.get("tazuna_movies")}
    end

    test "1 件 = 1 作品として育てる", %{movies: movies} do
      # 記事を溜めると、同じ作品の記事が何本も並び、作品ごとにまとまらない
      assert movies.name == "映画"
      assert Topics.works(movies) == Tazuna.News.Movies
      assert movies.feeds == []
      refute Topics.articles?(movies)
      assert Topics.articles?(Topics.get("tazuna_tech"))
    end

    test "要約は作らず、公開日のカレンダーを出す", %{movies: movies} do
      refute Topics.digest?(movies)
      assert Topics.calendar?(movies)
      assert Topics.date_tag(movies) == "公開日"
      assert Topics.item_word(movies) == "公開作"
      # 技術イベントは今までどおり
      assert Topics.date_tag(Topics.get("tazuna_events")) == "開催日"
    end

    test "日付では古くならない", %{movies: movies} do
      # 3 か月先の作品を、足した日から 30 日で落とすことになる
      refute Topics.ages_out?(movies)
    end
  end
end
