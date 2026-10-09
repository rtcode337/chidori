defmodule Chidori.Datasets.OpeningHours do
  @moduledoc """
  地図辞典（OpenStreetMap）の営業時間（`opening_hours`）から、**昼に開いているか**と
  **夜遅くまで開いているか**だけを読み取ります。

  **曜日は見ません。** 知りたいのは「ランチをやっている店か」で、「今日の昼に開いているか」
  ではないので、どれか 1 日でも当てはまれば付けます。書式は `Mo-Fr 11:00-15:00; Sa off`
  のような OSM のもので、**時間帯（`HH:MM-HH:MM`）だけを拾います** —— 読めない書き方の
  部分は無視するので、付くべき印が付かないことはあっても、付かないはずの印は付きません
  （`24/7` だけは「一日中」として読みます）。
  """

  # 昼に開いているとみなす時刻。**この時刻をまたいで開いていれば**ランチ営業
  @lunch_at 12 * 60 + 30

  # 深夜営業とみなす閉店時刻（22 時より後まで開いている）
  @late_after 22 * 60

  @doc """
  営業時間から読み取れる特徴（`:lunch` / `:late`）。読めなければ空。

      iex> Chidori.Datasets.OpeningHours.features("Mo-Fr 11:00-15:00, 17:00-23:30")
      [:lunch, :late]
  """
  def features(text) when is_binary(text) do
    text = String.trim(text)

    ranges =
      if text == "24/7",
        do: [{0, 24 * 60}],
        else:
          ~r/(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})/
          |> Regex.scan(text, capture: :all_but_first)
          |> Enum.map(fn [h1, m1, h2, m2] ->
            {minutes(h1, m1), minutes(h2, m2)}
          end)

    [lunch: Enum.any?(ranges, &lunch?/1), late: Enum.any?(ranges, &late?/1)]
    |> Enum.filter(fn {_feature, yes} -> yes end)
    |> Enum.map(fn {feature, _yes} -> feature end)
  end

  def features(_text), do: []

  defp minutes(h, m), do: String.to_integer(h) * 60 + String.to_integer(m)

  # 日付をまたぐ時間帯（`18:00-02:00`）は、終わりを翌日として読む
  defp span({from, to}) when to <= from, do: {from, to + 24 * 60}
  defp span(range), do: range

  defp lunch?(range) do
    {from, to} = span(range)
    from <= @lunch_at and @lunch_at < to
  end

  defp late?(range) do
    {_from, to} = span(range)
    to > @late_after
  end

  # 曜日の言い換え（地図辞典の書き方 → 日本語）
  @days ~w(Mo Tu We Th Fr Sa Su)
  @day_names %{
    "Mo" => "月",
    "Tu" => "火",
    "We" => "水",
    "Th" => "木",
    "Fr" => "金",
    "Sa" => "土",
    "Su" => "日",
    "PH" => "祝"
  }

  @doc """
  営業時間を**日本語で読める形**にします（travel-log の説明に添える）。

  **全部を読めたときだけ言い換えます。** 月日の指定・第何曜日・コメントのような、
  ここが知らない書き方が 1 つでも混ざっていれば `nil` を返します（呼ぶ側は元の書き方の
  まま出す）—— 一部だけ読み替えると、例外を落として違う時間を書くことになるため。

      iex> Chidori.Datasets.OpeningHours.to_japanese("Mo-Fr 11:00-14:30,17:30-22:00; Sa,Su,PH 11:00-21:00; We off")
      "月〜金 11:00〜14:30、17:30〜22:00 / 土・日・祝 11:00〜21:00 / 定休日: 水"
  """
  def to_japanese(text) when is_binary(text) do
    case String.trim(text) do
      "24/7" ->
        "24時間営業"

      trimmed ->
        rules =
          trimmed |> String.split(";") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

        parsed = Enum.map(rules, &rule/1)

        if rules != [] and Enum.all?(parsed, &(&1 != :error)), do: japanese(parsed)
    end
  end

  def to_japanese(_text), do: nil

  defp japanese(parsed) do
    {off, open} = Enum.split_with(parsed, &match?({_days, :off}, &1))

    opened = for {days, ranges} <- open, do: day_text(days, "毎日") <> " " <> ranges_text(ranges)

    closed =
      case Enum.flat_map(off, fn {days, :off} -> days || [] end) do
        [] -> []
        days -> ["定休日: " <> day_text(days, "")]
      end

    Enum.join(opened ++ closed, " / ")
  end

  # 1 つの決まり（`Mo-Fr 11:00-14:00` / `We off` / `11:00-22:00`）。読めなければ :error
  defp rule(text) do
    {days, rest} =
      case String.split(text, " ", parts: 2) do
        [maybe_days, rest] ->
          case days(maybe_days) do
            :error -> {nil, text}
            days -> {days, String.trim(rest)}
          end

        [only] ->
          {nil, only}
      end

    cond do
      rest in ["off", "closed"] and days != nil -> {days, :off}
      (ranges = ranges(rest)) != :error -> {days, ranges}
      true -> :error
    end
  end

  # 曜日の並び（`Mo-Fr,Su` / `PH`）。範囲は 1 日ずつに開く
  defp days(text) do
    items = String.split(text, ",")

    expanded =
      Enum.map(items, fn item ->
        case String.split(item, "-") do
          ["PH"] -> ["PH"]
          [one] -> if one in @days, do: [one], else: :error
          [from, to] -> day_range(from, to)
          _other -> :error
        end
      end)

    if Enum.any?(expanded, &(&1 == :error)), do: :error, else: Enum.concat(expanded)
  end

  defp day_range(from, to) do
    with a when is_integer(a) <- Enum.find_index(@days, &(&1 == from)),
         b when is_integer(b) <- Enum.find_index(@days, &(&1 == to)) do
      # 週をまたぐ範囲（`Fr-Mo`）も読む
      if a <= b,
        do: Enum.slice(@days, a..b),
        else: Enum.slice(@days, a..6) ++ Enum.slice(@days, 0..b)
    else
      _missing -> :error
    end
  end

  # 時間帯の並び（`11:00-14:30,17:30-22:00`）
  defp ranges(text) do
    parsed =
      for part <- String.split(text, ",") do
        case Regex.run(~r/^\s*(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})\s*$/, part,
               capture: :all_but_first
             ) do
          [h1, m1, h2, m2] -> {minutes(h1, m1), minutes(h2, m2)}
          nil -> :error
        end
      end

    if parsed == [] or Enum.any?(parsed, &(&1 == :error)), do: :error, else: parsed
  end

  # 曜日を日本語に。**続いた曜日は「月〜金」**、ほかは「・」で並べる。7 日そろえば `all`
  defp day_text(nil, all), do: all

  defp day_text(days, all) do
    days = Enum.uniq(days)
    week = Enum.filter(@days, &(&1 in days))

    if length(week) == 7 and "PH" not in days and all != "" do
      all
    else
      runs =
        week
        |> Enum.map(&Enum.find_index(@days, fn d -> d == &1 end))
        |> Enum.chunk_while(
          [],
          fn
            i, [] -> {:cont, [i]}
            i, [last | _] = acc when i == last + 1 -> {:cont, [i | acc]}
            i, acc -> {:cont, Enum.reverse(acc), [i]}
          end,
          fn
            [] -> {:cont, []}
            acc -> {:cont, Enum.reverse(acc), []}
          end
        )
        |> Enum.map(fn
          [one] ->
            @day_names[Enum.at(@days, one)]

          [first | _] = run when length(run) >= 3 ->
            @day_names[Enum.at(@days, first)] <> "〜" <> @day_names[Enum.at(@days, List.last(run))]

          run ->
            Enum.map_join(run, "・", &@day_names[Enum.at(@days, &1)])
        end)

      Enum.join(runs ++ if("PH" in days, do: ["祝"], else: []), "・")
    end
  end

  defp ranges_text(ranges) do
    Enum.map_join(ranges, "、", fn {from, to} ->
      # 日付をまたぐ閉店（`18:00-02:00`）・24 時を超える書き方（`18:00-26:00`）は「翌」
      to_text =
        cond do
          to <= from -> "翌" <> clock(to)
          to > 24 * 60 -> "翌" <> clock(to - 24 * 60)
          true -> clock(to)
        end

      clock(from) <> "〜" <> to_text
    end)
  end

  defp clock(minutes),
    do:
      "#{div(minutes, 60)}:#{minutes |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
end
