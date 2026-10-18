defmodule Chidori.Datasets.TravelLog do
  @moduledoc """
  集めたものを、travel-log が読める形（`travel-log-data` と同じフォルダ構成）で
  書き出します。

  **向こうに、こちらの決めごとを持たせないため**の層です。ジャンル・地域・ランクを
  タグでどう書くかは依頼文（`Chidori.Datasets.Dining`）の取り決めで、travel-log には
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

  alias Chidori.Chiezo
  alias Chidori.Datasets

  # 1 回に引く件数（Chiezo 側の上限）
  @page_limit 500

  # `opening_hours` は地図辞典の書き方のまま渡す —— travel-log の「今営業中」の絞り込みが
  # この列を読む（説明文の日本語の営業時間は人が読むためのもので、機械は読まない）
  @csv_header ~w(name lat lng region rank series categories description opening_hours key)

  # シリーズの色は**並びの番号から計算する**（`series_color/1`）。決まった 10 色を
  # 回していた頃は、60 ほどあるジャンルで 6 つずつ同じ色になり、地図で見分けられなかった。
  # 色相は黄金角ずつずらし（隣どうしが離れる）、明るさを 3 段で回す（色相が近くなっても
  # 明るさで分かれる）。ピンの文字の色は travel-log が面の明るさから選ぶ
  @golden_angle 137.508
  @lightness [42, 55, 32]
  # **訪問済みの緑に近い色相は使わない**（`series_color/1`）。travel-log は訪問済みのピンを
  # 緑（`#16a34a`。色相およそ 142°）で塗るので、シリーズが緑〜青緑だと行ったところと
  # 見分けがつかない。黄金角で回した値をこの帯を除いた 270° に詰めてから、帯の後ろへずらす
  @avoid_hue_from 95.0
  @avoid_hue_width 90.0

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
  def bundle(%{key: zip_name, module: module} = dataset) do
    # **種別の key と名前は、範囲の収集では範囲によらず同じ**（`dining`）。書き出しは
    # 範囲ごとでも、travel-log では 1 つの種別に読み込む
    key = dataset[:export_key] || zip_name
    name = dataset[:export_name] || dataset.name

    with true <- exportable?(dataset) || {:error, :not_exportable},
         {:ok, base} <- Datasets.base_url(),
         {:ok, part} <- gather(base, dataset) do
      zip(zip_name, key, name, part, module, dataset[:series_order])
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :not_exportable}
    end
  end

  @doc """
  **いくつもの範囲を 1 つの ZIP に**まとめます（食事処の範囲の画面から）。travel-log では
  範囲によらず 1 つの種別（`dining`）に読み込むので、範囲ごとに読み込ませる手間を省く。
  返すのは `bundle/1` と同じ形。

  **範囲が重なっていると、同じ店が 2 つの範囲に 1 件ずつ居る**（見分けの鍵は範囲ごとに
  違う）。名前と場所（`@twin_meters` 以内）が同じ行は先の範囲のものだけを残し、
  後のものは exclude.txt へ回す —— 範囲ごとの ZIP で前に読み込んでいれば、それが消える。
  **書き出す行と同じ鍵は exclude.txt に入れない**（同じ鍵を残しつつ消す、にならないように）。
  """
  def bundle_all([first | _rest] = datasets, zip_name) do
    %{module: module} = first
    key = first[:export_key] || first.key
    name = first[:export_name] || first.name

    with true <- Enum.all?(datasets, &exportable?/1) || {:error, :not_exportable},
         {:ok, base} <- Datasets.base_url(),
         {:ok, parts} <- gather_all(base, datasets) do
      {rows, twins} = without_twins(Enum.flat_map(parts, & &1.rows))
      living = MapSet.new(rows, & &1["key"])

      excluded =
        parts
        |> Enum.flat_map(& &1.excluded)
        |> Kernel.++(Enum.map(twins, & &1["key"]))
        |> Enum.reject(&MapSet.member?(living, &1))
        |> Enum.uniq()

      part = %{
        rows: rows,
        excluded: excluded,
        outside: Enum.sum(Enum.map(parts, & &1.outside)),
        skipped: Enum.sum(Enum.map(parts, & &1.skipped)) + length(twins)
      }

      zip(zip_name, key, name, part, module, first[:series_order])
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :not_exportable}
    end
  end

  def bundle_all([], _zip_name), do: {:error, :nothing_to_export}

  defp gather_all(base, datasets) do
    Enum.reduce_while(datasets, {:ok, []}, fn dataset, {:ok, acc} ->
      case gather(base, dataset) do
        {:ok, part} -> {:cont, {:ok, acc ++ [part]}}
        {:error, reason} -> {:halt, {:error, {dataset.collection, reason}}}
      end
    end)
  end

  # 1 つの収集ぶんの行（範囲の中）と、消えたもの・範囲の外の鍵
  defp gather(base, %{collection: collection, module: module} = dataset) do
    with {:ok, docs} <- fetch_all(base, collection, module.kind_tag()),
         {:ok, removed} <-
           fetch_all(base, collection, Chiezo.removed_tag(), include_removed: true) do
      links = link_checks(base, collection)

      made = Enum.map(docs, &{&1, row(&1, dataset, links)})

      {rows, outside} =
        made
        |> Enum.map(&elem(&1, 1))
        |> Enum.reject(&is_nil/1)
        |> split_outside(dataset)

      {:ok,
       %{
         rows: rows,
         excluded:
           Enum.uniq(
             excluded_keys(removed, dataset) ++
               Enum.map(outside, & &1["key"]) ++ unplaced_keys(made, dataset)
           ),
         outside: length(outside),
         skipped: length(docs) - length(rows) - length(outside)
       }}
    end
  end

  # **地図に置けなくなった 1 件の key**（自分で行を組む対象 = `spot/2` を持つものだけ）。
  # ご当地グルメは代表店が閉店して外れたり、引き当てられなくなったりすると座標を失う ——
  # spots.csv に載らないだけでは、前に読み込んだピンが閉店した店の上に残る。
  # **一度も書き出していない 1 件も入る**が、travel-log の削除は key の突き合わせなので、
  # 向こうに無い key は何も消さない
  defp unplaced_keys(made, %{module: module} = dataset) do
    if function_exported?(module, :spot, 2) do
      for {doc, nil} <- made, doc["doc_id"] != nil, do: spot_key(doc["doc_id"], dataset)
    else
      []
    end
  end

  # 同じ店とみなす近さ（m）。範囲が重なったところで、同じ 1 件が 2 つの収集に居る
  @twin_meters 30

  # 名前と場所が同じ行を畳む（`{残す行, 畳んだ行}`）。**先に来たほうを残す**
  defp without_twins(rows) do
    {kept, twins, _seen} =
      Enum.reduce(rows, {[], [], %{}}, fn row, {kept, twins, seen} ->
        same = Map.get(seen, row["name"], [])

        if Enum.any?(same, &(meters(&1, {row["lat"], row["lng"]}) <= @twin_meters)) do
          {kept, [row | twins], seen}
        else
          {[row | kept], twins, Map.put(seen, row["name"], [{row["lat"], row["lng"]} | same])}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(twins)}
  end

  defp meters({lat1, lon1}, {lat2, lon2}) do
    dy = (lat2 - lat1) * 111_320
    dx = (lon2 - lon1) * 111_320 * :math.cos(lat1 * :math.pi() / 180)
    :math.sqrt(dx * dx + dy * dy)
  end

  defp zip(zip_name, key, name, part, module, series_order) do
    %{rows: rows, excluded: excluded} = part

    files =
      [
        {~c"#{key}/settings.json",
         settings_json(key, name, rows, category_order(module), series_order)},
        {~c"#{key}/spots.csv", csv(rows, csv_header(module))}
      ] ++
        if excluded == [],
          do: [],
          else: [{~c"#{key}/excluded_candidates/exclude.txt", exclude_txt(excluded)}]

    case :zip.create(~c"#{zip_name}.zip", files, [:memory]) do
      {:ok, {_name, binary}} ->
        {:ok, "#{zip_name}.zip", binary,
         %{
           rows: length(rows),
           skipped: part.skipped,
           outside: part.outside,
           excluded: length(excluded)
         }}

      {:error, reason} ->
        {:error, reason}
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
        [s, w, n, e] = Chidori.Datasets.DiningAreas.bbox(area)

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
    ["# Chidori の収集で消えたスポット（閉店・重複など）の key" | keys]
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
  def row(doc, dataset, links \\ %{})

  # **行を自分で組む対象**（ご当地グルメ。列も説明文の組み方もランクの決め方も違う）
  def row(doc, %{module: module} = dataset, links) do
    if Code.ensure_loaded?(module) and function_exported?(module, :spot, 2),
      do: module.spot(doc, dataset),
      else: plain_row(doc, dataset, links)
  end

  defp plain_row(doc, %{module: module, collection: collection} = dataset, links) do
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
        "description" => description(doc, tags, extra, collection, module, {name, links}),
        "opening_hours" => clean(Map.get(extra, "opening_hours")),
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
  defp description(doc, tags, extra, collection, module, {name, links}) do
    from =
      tags
      |> tagged(module.source_tag_prefix())
      |> Enum.map(&source_label/1)

    [
      clean(Map.get(doc, "opening")),
      hours(extra),
      "出典: #{if from == [], do: "不明", else: Enum.join(from, " / ")}" <>
        "（Chidori の収集「#{collection}」から書き出し）",
      Chidori.Datasets.ShopLinks.pick(extra, name, links)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # 営業時間は**日本語に直して**添える（`月〜金 11:00〜15:00 / 定休日: 水`）。
  # **全部を読めたときだけ**直し、知らない書き方（月日の指定・第何曜日など）が混ざって
  # いれば地図辞典の書き方のまま出す —— 一部だけ読み替えると、例外を落として
  # 違う時間を書くことになる（`Chidori.Datasets.OpeningHours.to_japanese/1`）
  defp hours(extra) do
    case clean(Map.get(extra, "opening_hours")) do
      "" -> ""
      text -> "営業時間: " <> (Chidori.Datasets.OpeningHours.to_japanese(text) || text)
    end
  end

  defp source_label("OSM"), do: "OpenStreetMap"
  defp source_label("Overture"), do: "Overture Maps"
  defp source_label(other), do: other

  # Chiezo が URL を確かめた結果（`Chidori.Datasets.ShopLinks`）。**読めなければ空** ——
  # 確かめていない URL は今までどおり書くので、読めないだけで書き出しを止めない
  defp link_checks(base, collection) do
    case Chiezo.link_checks(base, collection) do
      {:ok, links} -> links
      {:error, _reason} -> %{}
    end
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
  全部が同じ灰色のピンになり、地図で見分けられません。**ただし既にある見た目は
  残してもらいます**（`keep_series_styles`）—— 足されるのはまだ無かったシリーズだけ。

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
          color: series_color(index)
        }
      end)

    Jason.encode!(
      %{
        key: key,
        label: name,
        # ランクは A〜E が入るので使う。公開するかどうかは向こうで決める（既定は非公開）
        settings: %{rank_enabled: true},
        series: series,
        # **見た目は travel-log 側で付けたものを残してもらう**。ここで決めているのは
        # 機械の見た目（2 文字のラベルと色）だけなので、範囲ごとの ZIP を同じ種別へ
        # 読み込むたびに上書きされると、画面で付けたアイコンや色が消える。
        # 足されるのは、まだ無かったシリーズだけ
        keep_series_styles: true
      }
      |> then(fn json ->
        if is_list(categories), do: Map.put(json, :categories, categories), else: json
      end),
      pretty: true
    )
  end

  @doc "並びの番号からシリーズの色（`#rrggbb`）。同じ番号ならいつも同じ色。訪問済みの緑に近い色相は避ける。"
  def series_color(index) when is_integer(index) and index >= 0 do
    hue = :math.fmod(index * @golden_angle, 360.0 - @avoid_hue_width)
    hue = if hue >= @avoid_hue_from, do: hue + @avoid_hue_width, else: hue
    lightness = Enum.at(@lightness, rem(index, length(@lightness)))
    hsl_hex(hue, 70, lightness)
  end

  defp hsl_hex(h, s, l) do
    s = s / 100
    l = l / 100
    c = (1 - abs(2 * l - 1)) * s
    x = c * (1 - abs(:math.fmod(h / 60, 2) - 1))
    m = l - c / 2

    {r, g, b} =
      cond do
        h < 60 -> {c, x, 0}
        h < 120 -> {x, c, 0}
        h < 180 -> {0, c, x}
        h < 240 -> {0, x, c}
        h < 300 -> {x, 0, c}
        true -> {c, 0, x}
      end

    ("#" <>
       Enum.map_join([r, g, b], fn v ->
         (v + m)
         |> Kernel.*(255)
         |> round()
         |> Integer.to_string(16)
         |> String.pad_leading(2, "0")
       end))
    |> String.downcase()
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

  # spots.csv の列。**対象が列を持っていればそれ**（ご当地グルメは提供の時期と営業時間の
  # 2 列を足す。travel-log は列ごと省いた CSV では既存の値を変えないので、食事処は今のまま）
  defp csv_header(module) do
    if function_exported?(module, :csv_header, 0), do: module.csv_header(), else: @csv_header
  end

  @doc """
  spots.csv。**改行は CRLF**（travel-log-data の CSV と揃える）。
  """
  def csv(rows, header \\ @csv_header) do
    [header | Enum.map(rows, fn row -> Enum.map(header, &to_string(row[&1])) end)]
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
