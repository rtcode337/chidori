defmodule Tazuna.Datasets.OpeningHours do
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

      iex> Tazuna.Datasets.OpeningHours.features("Mo-Fr 11:00-15:00, 17:00-23:30")
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
end
