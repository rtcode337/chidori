defmodule Tazuna.Datasets.Requests do
  @moduledoc """
  travel-log から届いた「修正・追加の依頼」を、**その場所を含む区画の情報収集**として
  Chiezo に頼むところ。

  travel-log の管理画面の「渡すテキスト」をそのまま貼る前提です
  （`- [修正] 名前 (緯度,経度): 理由` / `- [追加] (緯度,経度): 理由`）。
  **座標から区画を引く** —— 追加の依頼は名前を持たないので場所は座標でしか言えず、
  名前だけでは同名の店を取り違えます。

  **割り込みではなく、ふつうの回として走らせます**（`Chiezo.run/3` の `partitions` と
  `notes`）。区画をいつもどおり見たうえで、依頼を補足として読んでもらう形で、
  区画には印が付きます。割り込みは「書かれたものだけを直す」回なので、
  足りないスポットを探しに行く仕事には向きません。

  **補足は区画ごとに分けて渡します。** Chiezo は区画ごとに AI を呼び、見せるのは
  その区画の中身だけです —— 全部の区画に同じ依頼を渡すと、その店を見ていない AI まで
  答えようとして、中身を知らないまま書き換えることがあります。
  """

  alias Tazuna.Chiezo
  alias Tazuna.Datasets

  # Chiezo が 1 回で受ける区画の数の天井（`MAX_TRIAL_PARTITIONS`）。**超えたら断る** ——
  # 黙って切ると、切られた区画の依頼だけが誰にも読まれない
  @max_partitions 20

  # 座標の書き方は travel-log のテキストの `(35.68123,139.76712)`。空白は許す
  @point ~r/\(\s*(-?\d{1,2}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)\s*\)/u

  @doc "1 回に頼める区画の数。"
  def max_partitions, do: @max_partitions

  @doc """
  テキストに書かれた座標（`{緯度, 経度}` の並び。書かれた順・重複なし。1 行に 1 つ）。
  """
  def points(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.flat_map(&List.wrap(point_of(&1)))
    |> Enum.uniq()
  end

  def points(_text), do: []

  # 1 行の座標（最初の 1 つ）。無ければ nil
  defp point_of(line) do
    with [lat, lon] <- Regex.run(@point, line, capture: :all_but_first),
         {lat, lon} = {to_float(lat), to_float(lon)},
         true <- abs(lat) <= 90 and abs(lon) <= 180 do
      {lat, lon}
    else
      _none -> nil
    end
  end

  defp to_float(text) do
    {value, ""} = Float.parse(if String.contains?(text, "."), do: text, else: text <> ".0")
    value
  end

  @doc """
  頼む前の見積もり。`{:ok, %{keys, notes, points, missed}}` か `{:error, 理由}`。

  1 行ずつ座標を読み、**その行を座標の入る区画の補足に振り分けます**（`notes` は
  区画の鍵 → その区画のぶんのテキスト）。

  - **最初の座標より前の行**（見出し）は、どの区画の補足にも付けます
  - **座標の無い行**（理由の続き）は、直前の座標の行と同じ区画に付けます
  - **どの区画にも入らない座標の行**は渡さず、`missed` に出します（黙って落とすと、
    その依頼だけが誰にも読まれない）

  区画は矩形（`南,西/北,東`）のものだけを見ます。辺の上にある点は先に並んでいる区画に
  入れます（どちらで見ても同じ場所なので、1 つに決まればよい）。
  **Chiezo に問い合わせずに決めます**（画面が読み込んである区画の一覧を使う）——
  押した直後に「何区画で頼むか」「どれが外れたか」を出せるようにするためです。
  """
  def plan(text, partitions) when is_list(partitions) do
    boxes = boxes(partitions)

    acc =
      (text || "")
      |> String.split("\n")
      |> Enum.reduce(
        %{header: [], order: [], lines: %{}, at: :header, points: [], missed: []},
        &take_line(&1, &2, boxes)
      )

    cond do
      acc.points == [] ->
        {:error, :no_points}

      acc.order == [] ->
        {:error, :no_partition}

      length(acc.order) > @max_partitions ->
        {:error, {:too_many_partitions, length(acc.order)}}

      true ->
        notes =
          Map.new(acc.order, fn key ->
            {key, (acc.header ++ acc.lines[key]) |> Enum.join("\n") |> String.trim()}
          end)

        {:ok,
         %{
           keys: acc.order,
           notes: notes,
           points: Enum.uniq(acc.points),
           missed: Enum.uniq(acc.missed)
         }}
    end
  end

  defp take_line(line, acc, boxes) do
    case point_of(line) do
      nil ->
        case acc.at do
          :header -> %{acc | header: acc.header ++ [line]}
          # 区画の外の依頼の続きは、その依頼と一緒に外す
          :outside -> acc
          key -> put_line(acc, key, line)
        end

      point ->
        acc = %{acc | points: acc.points ++ [point]}

        case Enum.find(boxes, fn {_key, box} -> inside?(point, box) end) do
          nil -> %{acc | at: :outside, missed: acc.missed ++ [point]}
          {key, _box} -> put_line(%{acc | at: key}, key, line)
        end
    end
  end

  defp put_line(acc, key, line) do
    order = if key in acc.order, do: acc.order, else: acc.order ++ [key]
    %{acc | order: order, lines: Map.update(acc.lines, key, [line], &(&1 ++ [line]))}
  end

  defp boxes(partitions) do
    Enum.flat_map(partitions, fn %{key: key} ->
      case box(key) do
        nil -> []
        box -> [{key, box}]
      end
    end)
  end

  defp box(key) when is_binary(key) do
    with [sw, ne] <- String.split(key, "/"),
         [s, w] <- String.split(sw, ","),
         [n, e] <- String.split(ne, ","),
         {s, ""} <- Float.parse(s),
         {w, ""} <- Float.parse(w),
         {n, ""} <- Float.parse(n),
         {e, ""} <- Float.parse(e) do
      {s, w, n, e}
    else
      _not_a_box -> nil
    end
  end

  defp box(_key), do: nil

  defp inside?({lat, lon}, {s, w, n, e}), do: lat >= s and lat <= n and lon >= w and lon <= e

  @doc """
  区画を名指しして、情報収集の巡回を 1 回走らせます。**区画ごとの補足を載せます**
  （`plan/2` の `keys` と `notes`）。

  取り込み中なら空くまで待ちます（`deadline` は `System.monotonic_time(:millisecond)` の値）。
  """
  def run(%{collection: name} = dataset, %{keys: keys, notes: notes}, deadline) do
    sweep = dataset.survey_plan_sweep

    with {:ok, base} <- Datasets.base_url() do
      Chiezo.when_free(
        fn -> Chiezo.run(base, name, sweep: sweep, partitions: keys, notes: notes) end,
        deadline
      )
    end
  end

  @doc "見積もりの段で断った理由の言い方（Chiezo が断った理由は画面の側が言う）。"
  def error_text(:no_points),
    do: "座標が見つかりませんでした。travel-log の「渡すテキスト」をそのまま貼ってください。"

  def error_text(:no_partition),
    do: "どの座標も、いまの区画のどれにも入りませんでした（区画の外の場所です）。"

  def error_text({:too_many_partitions, count}),
    do: "区画が #{count} あります。1 回に頼めるのは #{@max_partitions} までなので、分けて貼ってください。"
end
