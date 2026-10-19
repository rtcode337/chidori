defmodule Chidori.News.Theaters do
  @moduledoc """
  映画館を探してお気に入りに入れるところ（映画の画面の「映画館」）。

  ## 映画館を探すのは AI、ここは辞典の映画館とお気に入り

  映画館を探すのは AI（`Chidori.News.TheaterFinder`。着くまでの時間の短い順に）で、ここが持つのは
  **辞典の映画館の読み方**（`to_theater/1`。AI が挙げた館を確かめるのに使う）、**名前の比べ方**
  （`similar_name?/2`）、**最寄り駅**、**お気に入り**です。
  辞典（`overture_japan`）の `cinema` は映画館の入った商業施設や劇場にも付いているので、
  映画館が主な場所（`category=cinema`）だけを使い、試写室・会社（名前に「株式会社」）と、
  辞典の確からしさが低いもの（0.6 未満）は外す。

  ## 場所は最寄り駅で言う

  お気に入りの館が複数の駅にまたがると、館の名前だけではどこの館か分からない。
  **地図辞典で館の周りの駅を引き、いちばん近い駅と直線の距離から「新宿駅 徒歩約 3 分」と
  添えます**（`nearest_station/3`。AI は使わない）。徒歩は不動産の表示と同じ分速 80m で、
  直線の距離なので「約」を付ける。お気に入りに入れるときに 1 回引いて残し、前から入っている
  館には、映画の画面を開いたときに足します（`fill_stations/1`）。

  ## お気に入りは利用者の置き場に

  利用者が書いたことなので、Chiezo の `chidori_data` に 1 館 1 件で置きます
  （`Chidori.DataStore.MarkRecords`。種類 `theaters`、鍵は店舗辞典の id）。
  **住所・サイト・座標も一緒に持ちます**（`detail`）—— 上映時刻を調べるときに、
  同じ名前の別の館と取り違えないように渡すため。
  """

  alias Chidori.Chiezo
  alias Chidori.DataStore.MarkRecords

  @view "theaters"
  @cinema_feature "category=cinema"
  # 出さない確からしさ（辞典の `confidence`）
  @min_confidence 0.6

  @doc "お気に入りの記録の種類（`MarkRecords` の view）。"
  def view, do: @view

  @doc """
  名前が同じ館を指していそうか（AI が挙げた館と辞典の館を突き合わせる）。大文字小文字・全角半角・
  空白と記号と、ありふれた語（シネマ・シアター・劇場…）を除いた芯が、同じか、片方に含まれるか、
  **短いほうの 4 分の 3 以上**重なるとき。重なりを固定の文字数で見ると、会社の名前だけで当たる
  （「TOHOシネマズ 新宿」と「TOHOシネマズ 府中」は芯の「toho」の 4 文字が重なる）。
  """
  def similar_name?(a, b) when is_binary(a) and is_binary(b) do
    {x, y} = {name_core(a), name_core(b)}
    shorter = min(String.length(x), String.length(y))

    x != "" and y != "" and
      (x == y or String.contains?(x, y) or String.contains?(y, x) or
         common_length(x, y) >= max(4, ceil(shorter * 0.75)))
  end

  defp latin_only?(name), do: not Regex.match?(~r/[\p{Han}\p{Hiragana}\p{Katakana}]/u, name)

  @doc "名前の芯（大文字小文字・全角半角を揃え、空白と記号と、ありふれた語を除く）。"
  def name_core(name) do
    name
    |> String.normalize(:nfkc)
    |> String.downcase()
    |> String.replace(~r/シネマズ|シネマ|シアター|cinemas|cinema|theaters|theater|theatre|劇場|映画館/u, "")
    |> String.replace(~r/[\s・\-_()（）'"“”\.]/u, "")
  end

  # いちばん長い共通の部分文字列の長さ（名前は短いので素直に数える）
  defp common_length(a, b) do
    a = String.graphemes(a)
    b = String.graphemes(b)

    for i <- 0..(length(a) - 1)//1, j <- 0..(length(b) - 1)//1, reduce: 0 do
      best ->
        run =
          Enum.zip(Enum.drop(a, i), Enum.drop(b, j))
          |> Enum.take_while(fn {x, y} -> x == y end)
          |> length()

        max(best, run)
    end
  end

  @doc false
  def to_theater(%{"title" => name, "extra" => %{"feature" => @cinema_feature} = extra})
      when is_binary(name) do
    with lat when is_number(lat) <- extra["lat"],
         lon when is_number(lon) <- extra["lon"],
         confidence = extra["confidence"] || 1.0,
         true <- confidence >= @min_confidence and not excluded_name?(name) do
      [
        %{
          id: extra["overture_id"] || name,
          name: display_name(name),
          # 市区町村（辞典の住所は「新宿3丁目15-15」のように区や市を書かないことがあるので、別に持つ）
          locality: extra["locality"],
          confidence: confidence,
          address: extra["address"],
          website: Chidori.SafeUrl.href(extra["website"]),
          lat: lat,
          lon: lon
        }
      ]
    else
      _missing -> []
    end
  end

  def to_theater(_doc), do: []

  # 一般の人が観に行く館ではないと名前から分かるもの（試写室・会社）
  defp excluded_name?(name), do: String.contains?(name, ["試写室", "株式会社"])

  # 見せる名前。辞典が重なりを避けて付けた番号（「P2 (133255)」）と、日本語名の後ろの英語名
  # （「TOHOシネマズ 新宿 (TOHO CINEMAS Shinjuku)」）は落とす
  defp display_name(name) do
    name
    |> String.replace(~r/\s*\(\d+\)$/u, "")
    |> then(fn n ->
      stripped = String.replace(n, ~r/\s*\([\x00-\x7F]+\)$/u, "")
      if latin_only?(stripped), do: n, else: stripped
    end)
  end

  @doc "2 点のあいだの距離（m。大円距離）。"
  def distance(lat1, lon1, lat2, lon2) do
    rad = &(&1 * :math.pi() / 180)
    dlat = rad.(lat2 - lat1)
    dlon = rad.(lon2 - lon1)

    a =
      :math.pow(:math.sin(dlat / 2), 2) +
        :math.cos(rad.(lat1)) * :math.cos(rad.(lat2)) * :math.pow(:math.sin(dlon / 2), 2)

    round(2 * 6_371_000 * :math.asin(:math.sqrt(a)))
  end

  # 最寄り駅を探す広さ（m）。これより遠い駅しか無い館には添えない（遠い駅の名前はかえって迷う）
  @station_within 1_500
  # 徒歩の分速（m。不動産の表示と同じ）
  @walk_per_minute 80

  @doc """
  いちばん近い駅（`%{name: "新宿駅", distance: m}`）。1,500m 以内に無ければ `:none`。
  地図辞典は駅を路線や会社ごとに別の点で持つので、同じ名前のうち最も近い点で測る。
  """
  def nearest_station(base, lat, lon) when is_number(lat) and is_number(lon) do
    dlat = @station_within / 111_320
    dlon = @station_within / (111_320 * max(:math.cos(lat * :math.pi() / 180), 0.01))
    bbox = Enum.join([lat - dlat, lon - dlon, lat + dlat, lon + dlon], ",")

    query =
      URI.encode_query(%{
        "tag" => "railway=station",
        "bbox" => bbox,
        "limit" => 200,
        "fields" => "title,extra"
      })

    with {:ok, %{status: 200, body: body}} <- Chiezo.get(base <> "/v1/osm_japan/filter?" <> query),
         {:ok, %{"results" => results}} when is_list(results) <- Jason.decode(body) do
      results
      |> Enum.flat_map(fn
        %{"title" => title, "extra" => %{"lat" => slat, "lon" => slon}}
        when is_binary(title) and is_number(slat) and is_number(slon) ->
          name = String.replace(title, ~r/\s*\((?:node|way|relation):\d+\)$/u, "")
          [%{name: station_name(name), distance: distance(lat, lon, slat, slon)}]

        _other ->
          []
      end)
      |> Enum.filter(&(&1.distance <= @station_within))
      |> Enum.min_by(& &1.distance, fn -> :none end)
    else
      _other -> :none
    end
  end

  def nearest_station(_base, _lat, _lon), do: :none

  defp station_name(name), do: if(String.ends_with?(name, "駅"), do: name, else: name <> "駅")

  @doc "最寄り駅の一言（「新宿駅 徒歩約 3 分」）。分からなければ nil。"
  def station_label(%{station: station, station_distance: d})
      when is_binary(station) and is_integer(d),
      do: "#{station} 徒歩約 #{max(1, ceil(d / @walk_per_minute))} 分"

  # AI が挙げた館（距離は測っていない）は駅の名前だけ
  def station_label(%{station: station}) when is_binary(station) and station != "", do: station
  def station_label(_theater), do: nil

  @doc """
  最寄り駅をまだ持っていないお気に入りに足します（前から入っている館のため）。
  足した数を返す。読めなかった館は飛ばす（次に開いたときにまた試す）。
  """
  def fill_stations(base) do
    favorites()
    |> Enum.filter(&(is_nil(&1.station) and is_number(&1.lat) and is_number(&1.lon)))
    |> Enum.count(fn theater ->
      case nearest_station(base, theater.lat, theater.lon) do
        %{name: name, distance: d} ->
          match?({:ok, _}, add(Map.merge(theater, %{station: name, station_distance: d})))

        :none ->
          false
      end
    end)
  end

  @doc "お気に入りの映画館（入れた順ではなく名前の順）。"
  def favorites do
    for {id, doc} <- MarkRecords.for_view(@view) do
      %{label: label, detail: detail} = MarkRecords.fields(doc)
      detail = detail || %{}

      %{
        id: id,
        name: label || id,
        address: detail["address"],
        website: Chidori.SafeUrl.href(detail["website"]),
        lat: detail["lat"],
        lon: detail["lon"],
        station: detail["station"],
        station_distance: detail["station_distance"],
        access: detail["access"]
      }
    end
    |> Enum.sort_by(& &1.name)
  end

  @doc "お気に入りの id の集まり（一覧の印に使う）。"
  def favorite_ids, do: MapSet.new(Map.keys(MarkRecords.for_view(@view)))

  @doc "お気に入りに入れます（同じ館を入れ直しても増えない）。"
  def add(%{id: id, name: name} = theater) when is_binary(id) do
    doc_id =
      case MarkRecords.for_view(@view) do
        %{^id => doc} -> doc.doc_id
        _none -> nil
      end

    detail =
      theater
      |> Map.take([:address, :website, :lat, :lon, :station, :station_distance, :access])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

    fields = %{done: true, on: Chidori.Jst.today(), note: "", label: name, detail: detail}
    MarkRecords.put(@view, id, fields, doc_id)
  end

  @doc "お気に入りから外します。入っていなければ何もしない。"
  def remove(id) when is_binary(id) do
    case MarkRecords.for_view(@view) do
      %{^id => doc} -> MarkRecords.delete(doc.doc_id)
      _none -> :ok
    end
  end
end
