defmodule Tazuna.News.MoviesTest do
  @moduledoc """
  映画（1 件 = 1 作品）の依頼文とタグの読み方。
  """

  use ExUnit.Case, async: true

  alias Tazuna.News.Events
  alias Tazuna.News.Movies

  describe "情報収集の回" do
    setup do
      %{prompt: Movies.survey_prompt("映画")}
    end

    test "公開中の作品も探させる", %{prompt: prompt} do
      # 映画は公開されてからが本番。未来だけを探すと、公開中の作品が入らない
      assert prompt =~ "いま公開中の映画と、これから公開される映画"
      assert hd(Movies.segments()) == "公開中"
    end

    test "劇場公開で、公開日の決まったものだけ", %{prompt: prompt} do
      assert prompt =~ "配信だけの作品は入れないでください"
      assert prompt =~ "公開日が決まっているものだけ"
      assert prompt =~ ~s("公開日:<YYYY-MM-DD>")
    end

    test "1 回に探すのは 1 区切りで、次の区切りをカーソルに返させる", %{prompt: prompt} do
      # 公開中と 3 か月先までを 1 回で頼むと、数百本になって途中で打ち切られる
      assert prompt =~ "今回探すのは「{cursor}」の区切りだけです"
      assert prompt =~ "next_cursor"

      for segment <- Movies.segments() do
        assert prompt =~ "- #{segment} —— "
      end

      # 初めての回（カーソルが空）は公開中から
      assert prompt =~ ~s(初めての回など）は「公開中」)
    end

    test "ポスターの画像の URL も返させる", %{prompt: prompt} do
      # Chiezo が 1 回だけ取って縮めて持つ（画面が公式サイトの絵を直に指さないように）
      assert prompt =~ "- image: ポスターかキービジュアルの画像の URL"
    end

    test "1 館だけの作品までは追わない", %{prompt: prompt} do
      assert prompt =~ "全国規模で公開される作品と、小規模でも話題になっている作品"
    end

    test "今あるものを見せて、足し直させない", %{prompt: prompt} do
      assert prompt =~ "{names}"
      assert prompt =~ "{now}"
    end
  end

  describe "整理の回" do
    setup do
      %{prompt: Movies.refine_prompt("映画")}
    end

    test "口コミは注目度の高い公開済みの作品だけ", %{prompt: prompt} do
      # 全部に書かせると、1 回で数十本の評判を当たりに行くことになる
      assert prompt =~ ~s("注目度:高" の作品のうち、**日本で公開されたもの**)
      assert prompt =~ ~s("口コミ:<YYYY-MM-DD>")
    end

    test "口コミは写さず、結末も書かせない", %{prompt: prompt} do
      assert prompt =~ "口コミの本文は写さないでください"
      assert prompt =~ "結末や仕掛けは書かないでください"
      assert prompt =~ "出どころ"
    end

    test "公開から時間が経ったものは墓標で落とす", %{prompt: prompt} do
      assert prompt =~ Tazuna.Chiezo.tombstone_tag()
      assert prompt =~ "60 日以上経ったもの"
    end

    test "情報収集の回の区切りを動かさない", %{prompt: prompt} do
      # カーソルは収集に 1 つ。整理の回が返すと、次に探す区切りが飛ぶ
      assert prompt =~ "next_cursor は返さないでください"
    end

    test "今ある作品を本文ごと見せる", %{prompt: prompt} do
      # 口コミは本文に書き足すので、本文が見えないと前の中身を消してしまう
      assert prompt =~ "{current}"
    end
  end

  test "Chiezo が縮めた絵は、その形の場所だけ通す" do
    thumb = "/v1/thumbs/" <> String.duplicate("a", 40) <> ".webp"

    doc = fn extra -> %{"title" => "作品A", "tags" => ["公開日:2026-10-16"], "extra" => extra} end

    assert Events.entry(doc.(%{"thumb" => thumb}), "公開日").thumb == thumb
    # 外を指すものは混ぜない（画面が Chiezo の URL に繋いで出すため）
    assert Events.entry(doc.(%{"thumb" => "https://example.com/a.webp"}), "公開日").thumb == nil
    assert Events.entry(doc.(%{"thumb" => "/v1/thumbs/../x.webp"}), "公開日").thumb == nil
  end

  test "本文を引いたときは本文を使う" do
    # 冒頭は 240 字で切れていて、口コミは本文の末尾にある
    entry =
      Events.entry(
        %{"title" => "作品A", "tags" => [], "opening" => "頭", "body" => "頭\n口コミ: 好評"},
        "公開日"
      )

    assert entry.summary == "頭\n口コミ: 好評"
  end

  test "公開日のタグでカレンダーに並ぶ" do
    entry =
      Events.entry(
        %{
          "title" => "作品A",
          "tags" => ["公開日:2026-10-16", "注目度:高", "上映形式:IMAX", "配信開始:2027-01-10"],
          "extra" => %{"url" => "https://example.com/a"},
          "opening" => "どんな作品か: 何か。\n口コミ（10月20日時点）: 好評。"
        },
        Movies.date_tag()
      )

    assert entry.date == ~D[2026-10-16]
    assert entry.thumb == nil
    assert entry.attention == :high
    assert Movies.formats(entry) == ["IMAX"]
    assert Movies.streaming(entry) == ~D[2027-01-10]
    assert Movies.body_lines(entry) == ["どんな作品か: 何か。", "口コミ（10月20日時点）: 好評。"]
    assert Events.month_tags(~D[2026-10-01], "公開日") =~ "公開日:2026-10-16"
  end
end
