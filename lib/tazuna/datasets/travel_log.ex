defmodule Tazuna.Datasets.TravelLog do
  @moduledoc """
  集めたものを、travel-log が読める形（`travel-log-data` と同じフォルダ構成）で
  書き出します。

  **向こうに、こちらの決めごとを持たせないため**の層です。ジャンル・地域・ランクを
  タグでどう書くかは依頼文（`Tazuna.Datasets.Meals`）の取り決めで、travel-log には
  関係がありません。ここで travel-log の形（`settings.json` と `spots.csv`）に直せば、
  向こうは**リポジトリから取り込むのと同じ処理**でそのまま入れられます。

  **ZIP で渡すのは、ブラウザに直接 Chiezo を読ませないため**でもあります。
  読ませるには CORS を開けたうえで Chiezo 自身を https で出す必要があり、
  LAN の中だけで使う機械にそこまでさせる理由がありません。ファイルなら、
  どこから開いた travel-log にも持っていけます。

  ## 中身

  ```
  <キー>/settings.json   スポット種別の設定（名前・シリーズ一覧）
  <キー>/spots.csv       スポット（name,lat,lng,region,rank,series,categories,description,key）
  ```

  **`key` には Chiezo の `doc_id` を入れます。** 焼き直しても引き継がれる番号なので、
  AI が見出しを直した回でも同じスポットの更新として入ります（名前を鍵にすると、
  表記が変わった時点で別のスポットが増えます）。

  **座標か地域（都道府県）の無いものは書き出しません。** travel-log は地域が必須で、
  空のままでは地図に置けないためです。落とした件数は呼ぶ側へ返します
  —— 黙って減らすと、向こうで「なぜか少ない」になります。
  """

  alias Tazuna.Chiezo
  alias Tazuna.Datasets

  @csv_header ~w(name lat lng region rank series categories description key)

  # シリーズの色。**travel-log が自動で配るのと同じ並び**にしてある ——
  # 同じ収集を向こうの自動登録で入れたときと見た目が揃う
  @series_colors ~w(#0ea5e9 #f97316 #14b8a6 #e11d48 #8b5cf6 #65a30d #d946ef #0891b2 #ea580c #4f46e5)

  @doc """
  書き出せる対象か。**スポットにできる収集だけ**（タグの取り決めを持つもの）。

  技術ニュースのように地図に載らない収集もあるので、画面はこれで出し分けます。
  目印のタグ（`kind_tag`）も要ります —— 書き出すものはそれで引くためです。
  """
  def exportable?(%{module: module}),
    do: function_exported?(module, :area_tag, 0) and function_exported?(module, :kind_tag, 0)

  def exportable?(_dataset), do: false

  @doc """
  travel-log 用の ZIP を組み立てます。`{:ok, 名前, 中身, 内訳}` か `{:error, 理由}`。

  内訳は `%{rows: 書き出した件数, skipped: 落とした件数}`。
  """
  def bundle(%{key: key, name: name, collection: collection, module: module} = dataset) do
    with true <- exportable?(dataset) || {:error, :not_exportable},
         {:ok, base} <- Datasets.base_url(),
         {:ok, docs} <- fetch_all(base, collection, module.kind_tag()) do
      rows = docs |> Enum.map(&row(&1, dataset)) |> Enum.reject(&is_nil/1)

      files = [
        {~c"#{key}/settings.json", settings_json(key, name, rows)},
        {~c"#{key}/spots.csv", csv(rows)}
      ]

      case :zip.create(~c"#{key}.zip", files, [:memory]) do
        {:ok, {_name, binary}} ->
          {:ok, "#{key}.zip", binary, %{rows: length(rows), skipped: length(docs) - length(rows)}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :not_exportable}
    end
  end

  # 全ページ。**件数は 1 ページ目が教えてくれる**ので、何周するかはそこで決まる
  defp fetch_all(base, collection, tag, offset \\ 0, acc \\ []) do
    case Chiezo.spot_docs(base, collection, tag, offset) do
      {:ok, %{docs: []}} ->
        {:ok, acc}

      {:ok, %{total: total, docs: docs}} ->
        got = acc ++ docs

        if length(got) >= total,
          do: {:ok, got},
          else: fetch_all(base, collection, tag, length(got), got)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  1 件をスポットの行にします。**足りないものは作りません**（座標か地域が無ければ nil）。

  シリーズはジャンルの先頭、残りはカテゴリへ回します —— 地図の見た目を決めるのは
  1 つだけで、残りは絞り込みに使えるほうが無駄がないためです。
  """
  def row(doc, %{module: module, collection: collection}) do
    tags = Map.get(doc, "tags") || []
    extra = Map.get(doc, "extra") || %{}
    name = doc |> Map.get("title") |> clean() |> without_disambiguation()
    lat = number(Map.get(extra, "lat"))
    lon = number(Map.get(extra, "lon"))
    region = tags |> tagged(module.area_tag()) |> List.first()
    genres = tagged(tags, module.genre_tag())

    if name == "" or is_nil(lat) or is_nil(lon) or is_nil(region) do
      nil
    else
      %{
        "name" => name,
        "lat" => lat,
        "lng" => lon,
        "region" => region,
        "rank" => tags |> tagged(module.rank_tag()) |> List.first() || "",
        "series" => List.first(genres) || "",
        # カテゴリはパイプ区切りの 1 列（CSV の区切りと衝突しないため）
        "categories" => genres |> Enum.drop(1) |> Enum.join("|"),
        "description" => description(doc, tags, extra, collection, module),
        "key" => to_string(Map.get(doc, "doc_id"))
      }
    end
  end

  # 説明文。**出どころを必ず添える** —— 辞典ごとにライセンスが違う（OpenStreetMap は
  # ODbL、Overture は継承条件なし）ので、後から切り分けられないと外しようがない
  defp description(doc, tags, extra, collection, module) do
    from =
      tags
      |> tagged(module.source_tag_prefix())
      |> Enum.map(&source_label/1)

    [
      clean(Map.get(doc, "opening")),
      "出典: #{if from == [], do: "不明", else: Enum.join(from, " / ")}" <>
        "（tazuna の収集「#{collection}」から書き出し）",
      link(extra)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp source_label("OSM"), do: "OpenStreetMap"
  defp source_label("Overture"), do: "Overture Maps"
  defp source_label(other), do: other

  defp link(extra) do
    url = to_string(Map.get(extra, "website") || Map.get(extra, "url") || "")
    if String.starts_with?(url, "http"), do: url, else: ""
  end

  # そのタグの値だけを、付いている順で
  defp tagged(tags, prefix) do
    tags
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, prefix <> ":")))
    |> Enum.map(&String.trim(String.replace_prefix(&1, prefix <> ":", "")))
    |> Enum.reject(&(&1 == ""))
  end

  defp number(value) when is_number(value), do: value
  defp number(_value), do: nil

  # 見出しや本文に混じる制御文字を落とす（実データに BS が入っていた）
  defp clean(text) when is_binary(text) do
    text |> String.replace(~r/[\x00-\x08\x0b\x0c\x0e-\x1f]/, "") |> String.trim()
  end

  defp clean(_text), do: ""

  # Chiezo が見出しの重複を避けるために付ける番号を落とす（`A&W (node:5884951586)`・
  # `ほっともっと (454627)`）。**地図に出るのは名前なので、機械の都合は見せない。**
  # 畳んだ結果として同じ名前が並んでも困らない —— travel-log 側の鍵は doc_id のほう。
  # **丸かっこを一律には外さない**（`サンプル食堂 (SAMPLE)` のような別名は名前の一部）
  defp without_disambiguation(name) do
    name
    |> String.replace(~r/\s*\((?:node|way|relation):\d+\)$/u, "")
    |> String.replace(~r/\s*\(\d+\)$/u, "")
    |> String.trim()
  end

  @doc """
  スポット種別の設定。**シリーズは出てきた数の多い順**に並べます —— 並び順が
  そのまま絞り込みの並びとピンの色の並びになるので、よく出るものが先のほうが読みやすい。

  見た目（2 文字のラベルと色）もここで決めます。決めないと travel-log 側で
  全部が同じ灰色のピンになり、地図で見分けられません。
  """
  def settings_json(key, name, rows) do
    series =
      rows
      |> Enum.flat_map(fn row -> String.split(row["series"] <> "|" <> row["categories"], "|") end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.frequencies()
      |> Enum.sort_by(fn {series, count} -> {-count, series} end)
      |> Enum.with_index()
      |> Enum.map(fn {{series, _count}, index} ->
        %{
          series: series,
          label: series |> String.graphemes() |> Enum.take(2) |> Enum.join(),
          color: Enum.at(@series_colors, rem(index, length(@series_colors)))
        }
      end)

    Jason.encode!(
      %{
        key: key,
        label: name,
        # ランクは A〜E が入るので使う。公開するかどうかは向こうで決める（既定は非公開）
        settings: %{rank_enabled: true},
        series: series
      },
      pretty: true
    )
  end

  @doc """
  spots.csv。**改行は CRLF**（travel-log-data の CSV と揃える）。
  """
  def csv(rows) do
    [@csv_header | Enum.map(rows, fn row -> Enum.map(@csv_header, &to_string(row[&1])) end)]
    |> Enum.map_join("\r\n", fn cells -> Enum.map_join(cells, ",", &escape/1) end)
    |> Kernel.<>("\r\n")
  end

  # 区切り・引用符・改行を含む値だけ引用符でくくる（RFC 4180）
  defp escape(value) do
    if String.contains?(value, [",", "\"", "\r", "\n"]) do
      ~s("#{String.replace(value, "\"", "\"\"")}")
    else
      value
    end
  end
end
