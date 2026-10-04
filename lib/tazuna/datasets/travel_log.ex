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
  <キー>/settings.json   スポット種別の設定（名前・シリーズ一覧・カテゴリの並び）
  <キー>/spots.csv       スポット（name,lat,lng,region,rank,series,categories,description,key）
  <キー>/excluded_candidates/exclude.txt   消えたスポットの key（1 行に 1 つ。無ければ入れない）
  ```

  **AI が目を通したあとで消えたもの（閉店・重複をまとめたもの）は exclude.txt で
  渡します。** spots.csv に載らないだけでは、travel-log が前の回で読み込んだぶんは
  消えません（向こうの取り込みは差分の追加・更新で、載っていない行を消しはしない）。
  travel-log-data と同じ置き場所なので、向こうは同じ取り込みの中で key の一致する
  スポットを消します。

  **最初の目通しで弾かれたものは入れません。** 一度も書き出されていないので、
  向こうに消すものがありません。どちらなのかは Chiezo が消した時点で脇書きに
  残します（`extra.removed_after_review`）。それより前に消えたものには残って
  いないので入りません。

  **`key` には Chiezo の `doc_id` を入れます。** 焼き直しても引き継がれる番号なので、
  AI が見出しを直した回でも同じスポットの更新として入ります（名前を鍵にすると、
  表記が変わった時点で別のスポットが増えます）。

  **座標か地域（都道府県）の無いものは書き出しません。** travel-log は地域が必須で、
  空のままでは地図に置けないためです。落とした件数は呼ぶ側へ返します
  —— 黙って減らすと、向こうで「なぜか少ない」になります。
  """

  alias Tazuna.Chiezo
  alias Tazuna.Datasets

  # 1 回に引く件数（Chiezo 側の上限）
  @page_limit 500

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

  内訳は `%{rows: 書き出した件数, skipped: 落とした件数, outside: 範囲の外の件数,
  excluded: 消えたもの（範囲の外を含む）の件数}`。
  """
  def bundle(%{key: zip_name, collection: collection, module: module} = dataset) do
    # **種別の key と名前は、範囲の収集では範囲によらず同じ**（`dining`）。書き出しは
    # 範囲ごとでも、travel-log では 1 つの種別に読み込む
    key = dataset[:export_key] || zip_name
    name = dataset[:export_name] || dataset.name

    with true <- exportable?(dataset) || {:error, :not_exportable},
         {:ok, base} <- Datasets.base_url(),
         {:ok, docs} <- fetch_all(base, collection, module.kind_tag()),
         {:ok, removed} <-
           fetch_all(base, collection, Chiezo.removed_tag(), include_removed: true) do
      {rows, outside} =
        docs |> Enum.map(&row(&1, dataset)) |> Enum.reject(&is_nil/1) |> split_outside(dataset)

      excluded = Enum.uniq(excluded_keys(removed, dataset) ++ Enum.map(outside, & &1["key"]))

      files =
        [
          {~c"#{key}/settings.json",
           settings_json(key, name, rows, category_order(module), dataset[:series_order])},
          {~c"#{key}/spots.csv", csv(rows)}
        ] ++
          if excluded == [],
            do: [],
            else: [{~c"#{key}/excluded_candidates/exclude.txt", exclude_txt(excluded)}]

      case :zip.create(~c"#{zip_name}.zip", files, [:memory]) do
        {:ok, {_name, binary}} ->
          {:ok, "#{zip_name}.zip", binary,
           %{
             rows: length(rows),
             skipped: length(docs) - length(rows) - length(outside),
             outside: length(outside),
             excluded: length(excluded)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :not_exportable}
    end
  end

  @doc """
  範囲の外の行を分けます（`{範囲の中, 範囲の外}`）。**範囲を持つ対象だけ**で、
  持たなければ全部が中。

  **範囲を狭めると、外した場所の店が収集に残る**（Chiezo は四角の外の文書を
  消さない。どの区画にも入らないので、AI にも回ってこない）。書き出しでは落とし、
  前に読み込んだぶんが travel-log に残らないよう exclude.txt にも載せる。
  """
  def split_outside(rows, dataset) do
    case dataset[:area] do
      nil ->
        {rows, []}

      area ->
        [s, w, n, e] = Tazuna.Datasets.MealAreas.bbox(area)

        Enum.split_with(rows, fn %{"lat" => lat, "lng" => lon} ->
          lat >= s and lat <= n and lon >= w and lon <= e
        end)
    end
  end

  # 収集が語彙を持っていれば、その並び（無ければ渡さない）
  defp category_order(module) do
    cond do
      function_exported?(module, :category_order, 0) -> module.category_order()
      function_exported?(module, :features, 0) -> module.features()
      true -> nil
    end
  end

  # 全ページ。**件数は 1 ページ目が教えてくれる**ので、何周するかはそこで決まる
  defp fetch_all(base, collection, tag, opts \\ [], offset \\ 0, acc \\ []) do
    case Chiezo.spot_docs(base, collection, tag, offset, @page_limit, opts) do
      {:ok, %{docs: []}} ->
        {:ok, acc}

      {:ok, %{total: total, docs: docs}} ->
        got = acc ++ docs

        if length(got) >= total,
          do: {:ok, got},
          else: fetch_all(base, collection, tag, opts, length(got), got)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  消えたもののうち、exclude.txt に書く key（doc_id）。重複を落として番号順に並べます。

  **AI が目を通したあとで消えたものだけ**です（Chiezo が消した時点で残す
  `extra.removed_after_review`）。最初の目通しで弾かれたものは一度も書き出されて
  いないので、渡す理由がありません。印の無いもの（印を残すようになる前に消えたもの）も
  入れません。収集の目印（`kind_tag`）の無いものも落とします —— 同じ収集に別の種類の
  文書が混ざっても、それは地図のスポットではないためです。
  """
  def excluded_keys(docs, %{module: module} = dataset) do
    docs
    |> Enum.filter(fn doc ->
      tags = Map.get(doc, "tags") || []
      extra = Map.get(doc, "extra") || %{}

      Chiezo.removed_tag() in tags and module.kind_tag() in tags and
        extra["removed_after_review"] == true
    end)
    |> Enum.map(&Map.get(&1, "doc_id"))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&spot_key(&1, dataset))
  end

  @doc """
  スポットの key。**範囲の収集では範囲の番号を頭に付けます**（`3-1234`）——
  `doc_id` は収集ごとに 1 から振られるので、付けないと範囲どうしで key がぶつかり、
  同じ種別へあとから読み込んだ範囲が、前の範囲のスポットを上書きする。
  """
  def spot_key(doc_id, dataset), do: "#{dataset[:key_prefix]}#{doc_id}"

  @doc """
  exclude.txt。1 行に 1 つの key で、改行は CRLF（spots.csv と揃える）。
  先頭の `#` の行は注記で、travel-log は読み飛ばします。
  """
  def exclude_txt(keys) do
    ["# tazuna の収集で消えたスポット（閉店・重複など）の key" | keys]
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  @doc """
  1 件をスポットの行にします。**足りないものは作りません**（座標か地域が無ければ nil）。

  シリーズはジャンルの先頭です（地図の見た目を決めるのは 1 つだけ）。
  **カテゴリは店の特徴**（ランチ営業・ゆっくりできる…）で、収集が `categories/2` で
  決めます。ジャンルの 2 つめ以降を回していた頃は、中身が粗いジャンルの重複
  （寿司屋の「和食」）ばかりで、絞り込みの軸になっていませんでした。
  `categories/2` を持たない収集は、今までどおりジャンルの 2 つめ以降を回します。
  """
  def row(doc, %{module: module, collection: collection} = dataset) do
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
        "categories" => categories(module, tags, extra, genres) |> Enum.join("|"),
        "description" => description(doc, tags, extra, collection, module),
        "key" => spot_key(Map.get(doc, "doc_id"), dataset)
      }
    end
  end

  defp categories(module, tags, extra, genres) do
    if function_exported?(module, :categories, 2),
      do: module.categories(tags, extra),
      else: Enum.drop(genres, 1)
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
      hours(extra),
      "出典: #{if from == [], do: "不明", else: Enum.join(from, " / ")}" <>
        "（tazuna の収集「#{collection}」から書き出し）",
      link(extra)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # 営業時間は地図辞典の書き方のまま添える（`Mo-Fr 11:00-15:00` のような形）。
  # **言い換えない** —— 祝日や例外の書き方まで読み替えると、違う時間を書くことになる
  defp hours(extra) do
    case clean(Map.get(extra, "opening_hours")) do
      "" -> ""
      text -> "営業時間: " <> text
    end
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

  **カテゴリの並びも渡します**（`categories`。収集が語彙を持っていれば、その並び）。
  travel-log はこれを絞り込みの並びに使います。カテゴリは見た目に効かないので、
  シリーズの一覧には混ぜません。
  """
  def settings_json(key, name, rows, categories \\ nil, order \\ nil) do
    series =
      rows
      |> Enum.map(& &1["series"])
      |> Enum.reject(&(&1 == ""))
      |> series_in_order(order)
      |> Enum.with_index()
      |> Enum.map(fn {series, index} ->
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
      }
      |> then(fn json ->
        if is_list(categories), do: Map.put(json, :categories, categories), else: json
      end),
      pretty: true
    )
  end

  # シリーズの並び。**語彙を持つ収集は語彙の順に固定する** —— settings.json は読み込む
  # たびに種別の設定を上書きするので、ZIP に入っている店から並びを作ると、別の範囲を
  # 読み込んだ拍子に並びも色も入れ替わり、前の範囲にしか無いジャンルは一覧から落ちる。
  # 語彙に無いジャンル（AI が付けたもの）は名前順で後ろに付ける。
  # 語彙を持たない収集は今までどおり件数の多い順
  defp series_in_order(found, order) when is_list(order) do
    extra = found |> Enum.uniq() |> Enum.reject(&(&1 in order)) |> Enum.sort()
    order ++ extra
  end

  defp series_in_order(found, _order) do
    found
    |> Enum.frequencies()
    |> Enum.sort_by(fn {series, count} -> {-count, series} end)
    |> Enum.map(&elem(&1, 0))
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
