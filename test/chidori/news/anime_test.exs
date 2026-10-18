defmodule Chidori.News.AnimeTest do
  @moduledoc """
  アニメの話題（`Chidori.News.Anime`）。**映画と同じ 1 件 = 1 作品の形**で、今期と来期を追う。
  """

  use ExUnit.Case, async: true

  alias Chidori.News.Anime
  alias ChidoriWeb.NewsLive

  describe "情報収集の回" do
    setup do
      %{prompt: Anime.survey_prompt("今期のアニメ")}
    end

    test "見出しの一覧に並ぶまとめを真似て、まとめの 1 件を返させない", %{prompt: prompt} do
      # 同じ収集に要約も溜まるので、見出しの一覧（`{names}`）に「まとめ: …」が並ぶ
      assert prompt =~ "{names}"
      assert prompt =~ "まとめ・要約・一覧の 1 件は返さないでください"
    end

    test "今期は曜日で分け、1 回に 1 区切りを探させて、次の区切りをカーソルに返させる", %{prompt: prompt} do
      assert prompt =~ "今回探すのは「{cursor}」の区切りだけです"
      assert prompt =~ "今期・月火"
      assert prompt =~ "来期"
      assert prompt =~ "next_cursor には、今回の次の区切りの名前"
    end

    test "放送開始日の決まった新作だけで、劇場アニメと再放送は入れない", %{prompt: prompt} do
      assert prompt =~ "放送（配信）開始日が決まっているものだけ"
      assert prompt =~ "劇場アニメ・再放送・ショートアニメは入れないでください"
    end

    test "今あるものを見せて、足し直させない", %{prompt: prompt} do
      assert prompt =~ "{names}"
      assert prompt =~ "上に並んでいる作品は足さないでください"
    end

    test "放送開始・曜日・放送局・配信・注目度のタグを付けさせる", %{prompt: prompt} do
      for tag <- ~w(放送開始: 曜日: 放送: 配信: 期: 注目度:高) do
        assert prompt =~ tag
      end
    end
  end

  describe "整理の回" do
    setup do
      %{prompt: Anime.refine_prompt("今期のアニメ")}
    end

    test "評判は注目度の高い放送中の作品だけで、感想は写させない", %{prompt: prompt} do
      assert prompt =~ "放送が始まったもの"
      assert prompt =~ "感想の本文は写さないでください"
      assert prompt =~ "先の展開は書かないでください"
    end

    test "放送が終わって時間が経ったものを落とさせる", %{prompt: prompt} do
      assert prompt =~ "最終回から 30 日以上経ったもの"
      assert prompt =~ Chidori.Chiezo.tombstone_tag()
    end
  end

  test "日付のあとに曜日・放送局・配信・最終回を並べる" do
    entry = %{
      date: ~D[2026-10-03],
      tags: ["放送開始:2026-10-03", "曜日:土", "放送:TOKYO MX", "配信:Netflix", "放送終了:2026-12-19"]
    }

    assert NewsLive.work_facts(entry, Anime) ==
             "10月3日（土） 放送開始 / 毎週土曜 / TOKYO MX / 配信: Netflix / 12月19日に最終回"
  end

  test "注目作の一覧は、放送中とこれから放送に分ける" do
    today = ~D[2026-10-04]

    groups =
      NewsLive.works_groups(
        [
          %{title: "放送中", date: ~D[2026-10-01], attention: :high},
          %{title: "来期", date: ~D[2027-01-08], attention: :mid}
        ],
        today,
        Anime
      )

    assert [{"放送中", [%{title: "放送中"}]}, {"これから放送", [%{title: "来期"}]}] = groups
  end

  test "要約に名指しするのは、終わって時間の経ったものを除いた注目作" do
    today = ~D[2026-10-04]

    titles =
      Anime.pick_for_digest(
        [
          %{title: "放送中", date: ~D[2026-10-01], attention: :high, tags: []},
          %{title: "前の期で終わった", date: ~D[2026-07-01], attention: :high, tags: ["放送終了:2026-08-01"]},
          %{title: "来期", date: ~D[2027-01-08], attention: :high, tags: []}
        ],
        today
      )

    assert titles == ["放送中", "来期"]
  end

  test "要約は終わったばかり・放送中を先に並べ、これから始まるものは注目度が高いものだけ" do
    today = ~D[2026-10-04]

    titles =
      Anime.pick_for_digest(
        [
          %{title: "来期の大作", date: ~D[2026-10-10], attention: :high, tags: []},
          %{title: "来期の中", date: ~D[2026-10-08], attention: :mid, tags: []},
          %{title: "放送中の中", date: ~D[2026-10-02], attention: :mid, tags: []},
          %{title: "放送中の高", date: ~D[2026-07-05], attention: :high, tags: []},
          %{title: "完走した", date: ~D[2026-07-03], attention: :high, tags: ["放送終了:2026-09-27"]}
        ],
        today
      )

    assert titles == ["完走した", "放送中の高", "放送中の中", "来期の大作"]
  end
end
