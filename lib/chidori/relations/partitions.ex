defmodule Chidori.Relations.Partitions do
  @moduledoc """
  画家がどの区画に入っているかを、**区画の鍵から割り出します**。

  Chiezo は区画ごとの中身を返す口（`/v1/collect/<name>/partition`）を持っていますが、
  1 区画ごとの問い合わせなので、400 区画ぶん引くと数分かかります。区画の一覧
  （鍵）と、画家に付いているタグがあれば所属は決まるので、ここで割り出します。

  **判定は Chiezo の `partition._band_locator` と同じ規則にしてあります** ——
  食い違うと、「この区画をざっと見て」と頼んだ区画に、画面で数えた未レビューの
  人がいない、ということが起きます。規則は次のとおり。

  - 分類（地域）は**最初の 1 つ**。値の中の `|` は `/` に置き換える（鍵の区切りと
    衝突するため）。分類を持たなければ `その他`
  - 値（年代）は**最初に出てくる数**（`1840-1926` なら 1840）
  - 値があれば、その分類の帯のうち「始まりが自分以下でいちばん大きいもの」。
    手前が無ければいちばん下の帯（端の帯は開いているので、外側も引き受ける）
  - 値が無ければ `分類|不明|A〜B` の置き場のうち、「`A〜B` が見出し以下で
    いちばん後ろのもの」（**鍵の文字列ごと比べる**のが Chiezo の規則）
  - **月で割った年**（`分類|2026|1-3月`。Chiezo の `detail`）は、細かい軸のタグ（公開月）の月で引く。
    数の軸の上では「年 + 月/13」で並ぶ（月の分からないもの・年の合わない月は「年 + 0」で、
    手前を開いた最初の月の帯に入る）。**月の帯は自分の年しか引き受けない**（ほかの年なら nil）
  """

  @sep "|"
  @unknown "不明"
  # 分類のタグを持たない文書が落ちる先（Chiezo の `DEFAULT_OTHER`）
  @other "その他"
  @span ~r/^(\d*)-(\d*)$/
  @month_span ~r/^(\d*)-(\d*)月$/
  # 月の帯を数の軸に並べる幅（Chiezo の `MONTH_SCALE`）
  @month_scale 13

  @doc """
  区画の一覧から、`(タグ, 見出し) -> 鍵 | nil` を組みます。

  `prefix` は分類のタグの頭（地域）、`value` は数の軸のタグの頭（年代）、`detail` は
  月で割った年を引く細かい軸のタグの頭（公開月。無ければ nil）。
  **組むのは 1 回**にして、全員に使い回してください（区画ごとに探すと重い）。
  """
  def locator(partitions, prefix, value, detail \\ nil) when is_list(partitions) do
    keys = Enum.map(partitions, &(&1[:key] || &1["key"]))
    {bands, piles} = Enum.reduce(keys, {%{}, %{}}, &add(&2, &1))

    bands = Map.new(bands, fn {name, rows} -> {name, rows |> Enum.sort() |> List.to_tuple()} end)
    piles = Map.new(piles, fn {name, rows} -> {name, rows |> Enum.sort() |> List.to_tuple()} end)
    # 月で割った年（分類ごと）と、月の帯の年
    year_of =
      for key <- keys, {:month, _names, _start, year} <- [parse(key)], into: %{}, do: {key, year}

    split_years =
      for key <- keys,
          {:month, names, _start, year} <- [parse(key)],
          name <- names,
          reduce: %{} do
        acc -> Map.update(acc, name, MapSet.new([year]), &MapSet.put(&1, year))
      end

    fn tags, title ->
      name = tag_value(tags, prefix) || @other

      case number_in(tag_value(tags, value)) do
        nil ->
          pick(Map.get(piles, name), title)

        year ->
          at =
            if MapSet.member?(Map.get(split_years, name, MapSet.new()), year),
              do: year + (month_in(tags, detail, year) || 0) / @month_scale,
              else: year

          case pick(Map.get(bands, name), at) do
            nil -> nil
            key -> if Map.get(year_of, key, year) == year, do: key
          end
      end
    end
  end

  defp add(acc, key) when is_binary(key) do
    case parse(key) do
      {:month, names, start, _year} ->
        add(acc, names, start, key)

      {:band, names, start} ->
        Enum.reduce(names, acc, fn name, {bands, piles} ->
          {Map.update(bands, name, [{start, key}], &[{start, key} | &1]), piles}
        end)

      {:pile, names, bounds} ->
        Enum.reduce(names, acc, fn name, {bands, piles} ->
          {bands, Map.update(piles, name, [{bounds, key}], &[{bounds, key} | &1])}
        end)

      nil ->
        acc
    end
  end

  defp add(acc, _key), do: acc

  defp add(acc, names, start, key) do
    Enum.reduce(names, acc, fn name, {bands, piles} ->
      {Map.update(bands, name, [{start, key}], &[{start, key} | &1]), piles}
    end)
  end

  # 始まりが自分以下のうち、いちばん後ろ。手前が無ければ先頭
  defp pick(nil, _at), do: nil
  defp pick({}, _at), do: nil

  defp pick(rows, at) do
    index = count_at_or_below(rows, at, 0, tuple_size(rows))
    rows |> elem(max(index - 1, 0)) |> elem(1)
  end

  # 二分探索（Python の `bisect_right`）。並びの中で `at` 以下のものの数
  defp count_at_or_below(_rows, _at, lo, hi) when lo >= hi, do: lo

  defp count_at_or_below(rows, at, lo, hi) do
    mid = div(lo + hi, 2)

    if at < rows |> elem(mid) |> elem(0),
      do: count_at_or_below(rows, at, lo, mid),
      else: count_at_or_below(rows, at, mid + 1, hi)
  end

  @doc """
  鍵を読みます。`{:band, 分類の並び, 始まり}`・`{:month, 分類の並び, 始まり, 年}`
  （月の帯。始まりは「年 + 月/13」）・`{:pile, 分類の並び, 見出しの範囲}` のどれか。

  開いた始まり（`-1869`）は負の無限大として扱います。数どうしの比べでしか
  使わないので、十分小さい数で足ります。
  """
  def parse(key) do
    parts = String.split(key, @sep)
    last = List.last(parts)

    cond do
      length(parts) < 2 ->
        nil

      length(parts) >= 3 and Regex.match?(~r/^\d+$/, Enum.at(parts, -2)) and
          Regex.match?(@month_span, last) ->
        names = Enum.drop(parts, -2)
        year = String.to_integer(Enum.at(parts, -2))
        [_, lo, _hi] = Regex.run(@month_span, last)
        first = if lo == "", do: 0, else: String.to_integer(lo)
        if Enum.all?(names, &(&1 != "")), do: {:month, names, year + first / @month_scale, year}

      match = Regex.run(@span, last) ->
        names = Enum.drop(parts, -1)
        [_, lo, _hi] = match

        if Enum.all?(names, &(&1 != "")),
          do: {:band, names, if(lo == "", do: -1.0e12, else: String.to_integer(lo))}

      length(parts) >= 3 and Enum.at(parts, -2) == @unknown ->
        names = Enum.drop(parts, -2)
        if Enum.all?(names, &(&1 != "")), do: {:pile, names, last}

      true ->
        nil
    end
  end

  # `地域:フランス` → `フランス`。**最初の 1 つだけ**
  defp tag_value(tags, prefix) do
    head = prefix <> ":"

    Enum.find_value(tags, fn tag ->
      tag = to_string(tag)

      if String.starts_with?(tag, head) do
        case tag
             |> String.replace_prefix(head, "")
             |> String.trim()
             |> String.replace(@sep, "/") do
          "" -> nil
          value -> value
        end
      end
    end)
  end

  # 細かい軸のタグ（`公開月:2026年3月`・`2026-03`）の月。**年が合わなければ読まない**（Chiezo の `month_in`）
  defp month_in(_tags, nil, _year), do: nil

  defp month_in(tags, detail, year) do
    numbers =
      ~r/\d+/
      |> Regex.scan(tag_value(tags, detail) || "")
      |> List.flatten()
      |> Enum.map(&String.to_integer/1)

    month =
      case numbers do
        [^year, month | _rest] -> month
        [first, _month | _rest] when first >= 100 -> nil
        [month] when month < 100 -> month
        _other -> nil
      end

    if month in 1..12, do: month
  end

  defp number_in(nil), do: nil

  defp number_in(value) do
    case Regex.run(~r/\d+/, value) do
      [digits] -> String.to_integer(digits)
      nil -> nil
    end
  end
end
