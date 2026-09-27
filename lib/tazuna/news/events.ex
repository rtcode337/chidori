defmodule Tazuna.News.Events do
  @moduledoc """
  技術イベントの**開催日・開催地・注目度**を読み、月ごとのカレンダーに並べます。

  ## どこから読むか

  **タグが先、無ければ本文。** 整理の回に次のタグを付けさせています（`refine_note/0`）。

  - `開催日:2026-10-25`（初日）と、連日なら `終了日:2026-10-27`
  - `開催地:東京都` / `開催地:オンライン`（両方あれば両方）
  - `注目度:高` / `注目度:中` / `注目度:低`

  connpass の配信は本文の頭に `開催日時: 2026/10/25 17:00 ～ 19:00` と
  `開催場所: 東京都千代田区…` を必ず書いているので、タグが付く前でも
  そこから日付と都道府県は読めます（詳細に出すときの予備）。

  ## カレンダーはタグで引く

  月の日付ぶんの `開催日:` タグを並べて 1 回で引きます（Chiezo の `filter` は
  カンマで並べたタグを「どれか」で引く）。**溜まっている全部を読みに行かない** ——
  connpass の新着は 1 日に数十件入るので、月をまたいで読むと画面を開くたびに
  数千件を運ぶことになります。
  """

  alias Tazuna.Chiezo
  alias Tazuna.Jst

  @date_tag "開催日"
  @end_tag "終了日"
  @place_tag "開催地"
  @attention_tag "注目度"
  @online "オンライン"

  # 1 回に引く件数（Chiezo 側の上限）
  @page_limit 500

  # 都道府県の書き出し（本文の「開催場所:」から拾う）
  @prefecture ~r/^(北海道|東京都|(?:京都|大阪)府|.{2,3}県)/u

  @doc "開催日のタグの頭。"
  def date_tag, do: @date_tag

  @doc "開催地のタグの頭。"
  def place_tag, do: @place_tag

  @doc "注目度のタグの頭。"
  def attention_tag, do: @attention_tag

  @doc """
  整理の回の依頼文に足す、技術イベントならではの頼みごと（`Tazuna.Topics` の `note`）。

  **並んだイベントは全部返させます。** ふだんの整理は「触ったものだけ返す」ですが、
  開催日のタグが無いイベントはカレンダーに出ません —— タグを付けるだけの返りなので、
  本文は返さなくて構いません（Chiezo は本文を返さなかった直しで本文を残します）。
  """
  def refine_note do
    """
    **この話題では、上に並んでいるイベントを全部、次のタグを付けて返してください**
    （「触ったものだけ」の例外です。タグを付けるだけなら body は返さなくて構いません。
    今のまま残ります）。カレンダーはこのタグで作るので、**付いていないイベントは
    読む人の目に入りません**。

    - "#{@date_tag}:<YYYY-MM-DD>" —— **開催日（初日）を必ず 1 つ**。日本時間の日付で。
      connpass のものは本文の「開催日時:」に書いてあります
    - "#{@end_tag}:<YYYY-MM-DD>" —— **連日のときだけ**、最終日を
    - "#{@place_tag}:<都道府県>" / "#{@place_tag}:#{@online}" —— **開催地を必ず**。
      会場のある都道府県を「東京都」「大阪府」の形で。オンラインなら "#{@place_tag}:#{@online}"、
      会場とオンラインの両方なら両方。海外なら国名（"#{@place_tag}:アメリカ"）
    - "#{@attention_tag}:高" / "#{@attention_tag}:中" / "#{@attention_tag}:低" を**必ず 1 つ** ——
      **界隈がどれだけ注目しているか**です。カレンダーで目立たせるのに使います。
      - 高: 各社の年次カンファレンス・主要な国際会議・毎回満席になる大きな勉強会、
        界隈で話題になっている回（登壇者や題目で話題になっているものも）
      - 中: 名の通ったコミュニティの定例会、数十人規模で集まるもの
      - 低: 少人数の勉強会・もくもく会・社内向けに近いもの
      **迷ったら低に**（全部が高だと、目立たせる意味がなくなります）

    ほかにも次のことを守ってください。

    - **申込先の URL** を `url` に入れてください。締切や参加費が分かれば body に 1 行
    - **終わったイベントは消してください**（墓標）。この話題は日付では古くなりません
      —— 終わったかどうかだけが古さです
    - **同じイベントの別の回は別の 1 件**にしてください（第 3 回と第 4 回は別物）。
      見出しに回や年を入れると混ざりません
    - **外から足す大きなイベントにも、同じタグを付けてください**。開催日が未定のものは
      "#{@date_tag}:" を付けずに足し、body に「開催日は未定」と書いてください
    """
  end

  @doc """
  1 件を、カレンダーに並べる形にします。記事の形（`Tazuna.News`）でも、
  Chiezo の生の 1 件（`"title"` / `"tags"` / `"extra"` / `"opening"`）でも受けます。
  """
  def entry(%{"title" => title} = doc) do
    extra = if is_map(doc["extra"]), do: doc["extra"], else: %{}

    entry(%{
      title: title,
      tags: Enum.map(doc["tags"] || [], &to_string/1),
      url: extra["url"],
      summary: doc["opening"]
    })
  end

  def entry(%{title: title, tags: tags} = article) do
    summary = Map.get(article, :summary) || ""
    date = tag_date(tags, @date_tag) || body_date(summary)

    %{
      title: title,
      url: safe_url(Map.get(article, :url)),
      summary: summary,
      date: date,
      end_date: tag_date(tags, @end_tag),
      time: body_time(summary),
      places: places(tags, summary),
      attention: attention(tags)
    }
  end

  @doc """
  その月の日付ぶんの `開催日:` タグ（カンマ区切り）。Chiezo の `filter` にそのまま渡します。
  """
  def month_tags(%Date{} = first) do
    first
    |> days_of_month()
    |> Enum.map_join(",", &"#{@date_tag}:#{Date.to_iso8601(&1)}")
  end

  @doc """
  その月のイベントを Chiezo から引きます。`{:ok, [entry]}` か `{:error, 理由}`。
  """
  def fetch_month(base, collection, %Date{} = first) do
    fetch(base, collection, month_tags(first), 0, [])
  end

  defp fetch(base, collection, tags, offset, acc) do
    case Chiezo.spot_docs(base, collection, tags, offset, @page_limit) do
      {:ok, %{docs: []}} ->
        {:ok, finish(acc)}

      {:ok, %{total: total, docs: docs}} ->
        got = acc ++ docs

        if length(got) >= total,
          do: {:ok, finish(got)},
          else: fetch(base, collection, tags, length(got), got)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish(docs), do: docs |> Enum.map(&entry/1) |> Enum.reject(&is_nil(&1.date))

  @doc "今日（JST）を含む月の 1 日。"
  def this_month do
    today = Jst.today()
    Date.new!(today.year, today.month, 1)
  end

  @doc "前後の月の 1 日。"
  def shift_month(%Date{year: year, month: month}, by) do
    index = year * 12 + (month - 1) + by
    Date.new!(div(index, 12), rem(index, 12) + 1, 1)
  end

  @doc """
  月のカレンダー。**日曜はじまり**の週の並びで、1 マスは
  `%{date:, in_month:, events: [entry]}`（その日に始まるイベント。注目度の高い順）。
  """
  def weeks(%Date{} = first, entries) do
    by_day = Enum.group_by(entries, & &1.date)
    start = Date.add(first, -rem(Date.day_of_week(first), 7))
    last = Date.end_of_month(first)
    finish = Date.add(last, 6 - rem(Date.day_of_week(last), 7))

    Date.range(start, finish)
    |> Enum.map(fn day ->
      %{
        date: day,
        in_month: day.month == first.month,
        events: day |> then(&Map.get(by_day, &1, [])) |> sort()
      }
    end)
    |> Enum.chunk_every(7)
  end

  @doc "注目度の高い順（同じなら見出し順）。"
  def sort(entries), do: Enum.sort_by(entries, &{-rank(&1.attention), &1.title})

  @doc """
  出てくる開催地（多い順）。**オンラインは先頭に**（どこからでも行けるので、
  場所で絞る人もまず残したい）。
  """
  def places_of(entries) do
    entries
    |> Enum.flat_map(& &1.places)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {place, count} -> {place != @online, -count, place} end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "開催地で絞ります。**何も選んでいなければ全部**。開催地の分からないものは絞ると外れます。"
  def only_places(entries, []), do: entries

  def only_places(entries, picked) do
    Enum.filter(entries, fn entry -> Enum.any?(entry.places, &(&1 in picked)) end)
  end

  defp rank(:high), do: 3
  defp rank(:mid), do: 2
  defp rank(:low), do: 1
  defp rank(_other), do: 0

  defp days_of_month(first), do: Date.range(first, Date.end_of_month(first))

  defp tag_date(tags, head) do
    Enum.find_value(tags, fn tag ->
      with true <- String.starts_with?(tag, head <> ":"),
           {:ok, date} <-
             tag |> String.replace_prefix(head <> ":", "") |> String.trim() |> Date.from_iso8601() do
        date
      else
        _ -> nil
      end
    end)
  end

  defp body_date(text) do
    case Regex.run(~r/開催日時[:：]\s*(\d{4})\/(\d{1,2})\/(\d{1,2})/u, text) do
      [_, y, m, d] ->
        case Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
          {:ok, date} -> date
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # 始まりの時刻（本文の「開催日時:」から。無ければ nil）
  defp body_time(text) do
    case Regex.run(~r/開催日時[:：]\s*\d{4}\/\d{1,2}\/\d{1,2}\s+(\d{1,2}:\d{2})/u, text) do
      [_, time] -> time
      _ -> nil
    end
  end

  defp places(tags, summary) do
    from_tags =
      for tag <- tags,
          String.starts_with?(tag, @place_tag <> ":"),
          place = tag |> String.replace_prefix(@place_tag <> ":", "") |> String.trim(),
          place != "",
          do: place

    if from_tags != [], do: Enum.uniq(from_tags), else: body_places(summary)
  end

  defp body_places(text) do
    case Regex.run(~r/開催場所[:：]\s*([^\n<]+)/u, text) do
      [_, where] ->
        where = String.trim(where)

        [
          if(String.contains?(where, @online), do: @online),
          case Regex.run(@prefecture, where) do
            [_, pref] -> pref
            _ -> nil
          end
        ]
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp attention(tags) do
    Enum.find_value(tags, fn
      @attention_tag <> ":" <> level -> Map.get(%{"高" => :high, "中" => :mid, "低" => :low}, level)
      _ -> nil
    end)
  end

  defp safe_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> url
      _ -> nil
    end
  end

  defp safe_url(_url), do: nil
end
