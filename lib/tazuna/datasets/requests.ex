defmodule Tazuna.Datasets.Requests do
  @moduledoc """
  travel-log から届いた「修正・追加の依頼」を、**その場所を含む区画の情報収集**として
  Chiezo に頼むところ。

  travel-log の管理画面の「テキストで表示」をそのまま貼る前提です
  （`- [修正] 名前 (緯度,経度): 理由` / `- [追加] (緯度,経度): 理由`）。
  **座標から区画を引く** —— 追加の依頼は名前を持たないので場所は座標でしか言えず、
  名前だけでは同名の店を取り違えます。

  **割り込みではなく、ふつうの回として走らせます**（`Chiezo.run/3` の `partitions` と
  `note`）。区画をいつもどおり見たうえで、貼ったテキストを補足として読んでもらう形で、
  区画には印が付きます。割り込みは「書かれたものだけを直す」回なので、
  足りないスポットを探しに行く仕事には向きません。
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
  テキストに書かれた座標（`{緯度, 経度}` の並び。書かれた順・重複なし）。
  """
  def points(text) when is_binary(text) do
    @point
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [lat, lon] -> {to_float(lat), to_float(lon)} end)
    |> Enum.filter(fn {lat, lon} -> abs(lat) <= 90 and abs(lon) <= 180 end)
    |> Enum.uniq()
  end

  def points(_text), do: []

  defp to_float(text) do
    {value, ""} = Float.parse(if String.contains?(text, "."), do: text, else: text <> ".0")
    value
  end

  @doc """
  座標を含む区画の鍵（区画の並びの順・重複なし）と、**どの区画にも入らなかった座標**。

  区画は矩形（`南,西/北,東`）のものだけを見ます。辺の上にある点は先に並んでいる区画に
  入れます（どちらで見ても同じ場所なので、1 つに決まればよい）。
  """
  def partitions_for(points, partitions) when is_list(points) and is_list(partitions) do
    boxes =
      Enum.flat_map(partitions, fn %{key: key} ->
        case box(key) do
          nil -> []
          box -> [{key, box}]
        end
      end)

    Enum.reduce(points, {[], []}, fn point, {keys, missed} ->
      case Enum.find(boxes, fn {_key, box} -> inside?(point, box) end) do
        {key, _box} -> {if(key in keys, do: keys, else: keys ++ [key]), missed}
        nil -> {keys, missed ++ [point]}
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
  頼む前の見積もり。`{:ok, %{keys, points, missed}}` か `{:error, 理由}`。

  **Chiezo に問い合わせずに決めます**（画面が読み込んである区画の一覧を使う）——
  押した直後に「何区画で頼むか」「どれが外れたか」を出せるようにするためです。
  """
  def plan(text, partitions) do
    case points(text) do
      [] ->
        {:error, :no_points}

      points ->
        case partitions_for(points, partitions) do
          {[], _missed} ->
            {:error, :no_partition}

          {keys, _missed} when length(keys) > @max_partitions ->
            {:error, {:too_many_partitions, length(keys)}}

          {keys, missed} ->
            {:ok, %{keys: keys, points: points, missed: missed}}
        end
    end
  end

  @doc """
  区画を名指しして、情報収集の巡回を 1 回走らせます。**貼ったテキストを補足として載せます**。

  取り込み中なら空くまで待ちます（`deadline` は `System.monotonic_time(:millisecond)` の値）。
  """
  def run(%{collection: name} = dataset, keys, text, deadline) do
    sweep = dataset.survey_plan_sweep

    with {:ok, base} <- Datasets.base_url() do
      Chiezo.when_free(
        fn -> Chiezo.run(base, name, sweep: sweep, partitions: keys, note: String.trim(text)) end,
        deadline
      )
    end
  end

  @doc "見積もりの段で断った理由の言い方（Chiezo が断った理由は画面の側が言う）。"
  def error_text(:no_points),
    do: "座標が見つかりませんでした。travel-log の「テキストで表示」をそのまま貼ってください。"

  def error_text(:no_partition),
    do: "どの座標も、いまの区画のどれにも入りませんでした（区画の外の場所です）。"

  def error_text({:too_many_partitions, count}),
    do: "区画が #{count} あります。1 回に頼めるのは #{@max_partitions} までなので、分けて貼ってください。"
end
