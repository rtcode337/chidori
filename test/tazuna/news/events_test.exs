defmodule Tazuna.News.EventsTest do
  use ExUnit.Case, async: true

  alias Tazuna.News.Events

  @connpass "開催日時: 2026/10/25 17:00 ～ 19:00\n開催場所: 東京都千代田区外神田1-18-19 新秋葉原ビルB1F\n技術発表会です。"

  describe "1 件を読む" do
    test "タグがあればタグから" do
      entry =
        Events.entry(%{
          title: "大きなカンファレンス",
          tags: ["開催日:2026-11-05", "終了日:2026-11-06", "開催地:東京都", "開催地:オンライン", "注目度:高"],
          url: "https://example.test/conf",
          summary: ""
        })

      assert entry.date == ~D[2026-11-05]
      assert entry.end_date == ~D[2026-11-06]
      assert entry.places == ["東京都", "オンライン"]
      assert entry.attention == :high
      assert entry.url == "https://example.test/conf"
    end

    test "タグが無ければ connpass の本文の頭から、日付・時刻・都道府県を読む" do
      entry = Events.entry(%{title: "技術発表会 #36", tags: ["勉強会"], summary: @connpass})

      assert entry.date == ~D[2026-10-25]
      assert entry.time == "17:00"
      assert entry.places == ["東京都"]
      assert entry.attention == nil
    end

    test "Chiezo の生の 1 件も読む" do
      entry =
        Events.entry(%{
          "title" => "勉強会",
          "tags" => ["開催日:2026-10-01", "注目度:低"],
          "extra" => %{"url" => "javascript:alert(1)"},
          "opening" => ""
        })

      assert entry.date == ~D[2026-10-01]
      assert entry.attention == :low
      # 出典は AI が入れたものなので、http(s) でなければリンクにしない
      assert entry.url == nil
    end
  end

  test "月の日付ぶんの開催日のタグを、カンマで並べる" do
    tags = Events.month_tags(~D[2026-02-01]) |> String.split(",")

    assert length(tags) == 28
    assert hd(tags) == "開催日:2026-02-01"
    assert List.last(tags) == "開催日:2026-02-28"
  end

  test "月を送る（年をまたぐ）" do
    assert Events.shift_month(~D[2026-12-01], 1) == ~D[2027-01-01]
    assert Events.shift_month(~D[2026-01-01], -1) == ~D[2025-12-01]
  end

  test "カレンダーは日曜はじまりの週で、その日に始まるイベントを注目度の高い順に並べる" do
    low = %{title: "もくもく会", date: ~D[2026-10-25], attention: :low, places: []}
    high = %{title: "年次カンファレンス", date: ~D[2026-10-25], attention: :high, places: []}

    weeks = Events.weeks(~D[2026-10-01], [low, high])

    assert Enum.all?(weeks, &(length(&1) == 7))
    # 2026-10-01 は木曜なので、先頭の週は 9/27（日）から
    assert hd(hd(weeks)).date == ~D[2026-09-27]
    refute hd(hd(weeks)).in_month

    cell = weeks |> List.flatten() |> Enum.find(&(&1.date == ~D[2026-10-25]))
    assert Enum.map(cell.events, & &1.title) == ["年次カンファレンス", "もくもく会"]
  end

  test "開催地はオンラインを先頭に、多い順に。絞ると開催地の分からないものは外れる" do
    entries = [
      %{places: ["大阪府"]},
      %{places: ["東京都"]},
      %{places: ["東京都", "オンライン"]},
      %{places: []}
    ]

    assert Events.places_of(entries) == ["オンライン", "東京都", "大阪府"]
    assert length(Events.only_places(entries, [])) == 4
    assert length(Events.only_places(entries, ["東京都"])) == 2
  end
end
