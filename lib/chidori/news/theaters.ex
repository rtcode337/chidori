defmodule Chidori.News.Theaters do
  @moduledoc """
  映画館を探してお気に入りに入れるところ（映画の画面の「映画館」）。

  ## 映画館は地図辞典から引く

  **映画館の名簿は持たず、Chiezo の店舗辞典（`overture_japan`）から引きます。**
  種類 `cinema` の付いた場所のうち、主な種類が映画館のもの（`category=cinema`）だけを
  使います —— `cinema` は、映画館の入った商業施設や劇場にも付いている（本番で数えると
  1,294 件のうち映画館が主なものは 983 件。うち 802 件がサイトの URL を持つ。2026-10）。
  探すのは**点の周りの四角**（`bbox`）と種類のタグの組で、四角の中の店を全部読むことはしない。
  地域の名前で探すときは、地名の辞典で座標に直してから同じように探します（`Chidori.Chiezo.places/2`）。

  ## 同じ館は 1 つにまとめる

  店舗辞典は複数の出どころを束ねたもので、**同じ館が別の名前で何件も入っている**
  （英語名と日本語名「TOHO Cinemas Shinjuku」と「TOHOシネマズ 新宿」は 15m、旧名
  「ワーナー・マイカル・シネマズ浦和美園」と「イオンシネマ 浦和美園」は 14m、同じサイトの
  「White Cine Quinto」と「シネクイント」は 69m 離れて入っていた）。一方で**同じ建物に入った
  別の館も近くに並ぶ**（「シネマート新宿」と「角川シネマ新宿」は 19m）ので、距離だけでは
  決めない。次のどれかなら同じ館とみなす（`same?/2`）:

  - 30m 以内で、片方の名前が英字だけ（英語名で入った写し）
  - 100m 以内で、サイトのドメインが同じ
  - 100m 以内で、ありふれた語（シネマ・シアター・劇場…）を除いた名前が 4 文字以上重なる

  残すのはサイトを持ち・名前に日本語があり・辞典の確からしさが高いもの（`keep_score/1`）。
  **試写室・会社（名前に「株式会社」）と、辞典の確からしさが低いもの（0.6 未満）は出さない**
  （一般の人が観に行く館ではない・閉じた館や場所違いが多い）。辞典の種類の付け違いはほかにもあり
  （写真スタジオ・映画の学校が `category=cinema` で入っている）、名前で見分けられないものは残る。

  ## お気に入りは利用者の置き場に

  利用者が書いたことなので、Chiezo の `chidori_data` に 1 館 1 件で置きます
  （`Chidori.DataStore.MarkRecords`。種類 `theaters`、鍵は店舗辞典の id）。
  **住所・サイト・座標も一緒に持ちます**（`detail`）—— 上映時刻を調べるときに、
  同じ名前の別の館と取り違えないように渡すため。
  """

  alias Chidori.Chiezo
  alias Chidori.DataStore.MarkRecords

  @view "theaters"
  @source "overture_japan"
  @cinema_tag "cinema"
  @cinema_feature "category=cinema"
  # 探す広さ（m）と、並べる数
  @radius 5_000
  @max_results 30

  @doc "お気に入りの記録の種類（`MarkRecords` の view）。"
  def view, do: @view

  # 同じ館とみなす距離（m）。英語名の写しは近く、サイトや名前が同じものは少し離れても
  @latin_copy_within 30
  @same_within 100
  # 出さない確からしさ（辞典の `confidence`）
  @min_confidence 0.6
  # 探す広さ（m）の選べる値
  @radius_choices [1_000, 3_000, 5_000, 10_000]

  @doc "探す広さ（m）の選べる値。"
  def radius_choices, do: @radius_choices

  @doc "既定の探す広さ（m）。"
  def default_radius, do: @radius

  @doc """
  点の近くの映画館を近い順に（`%{id, name, address, website, lat, lon, distance}`。距離は m）。
  **同じ館は 1 つにまとめます**（`dedupe/1`）。`{:ok, [theater]}` か `{:error, 理由}`。
  """
  def near(base, lat, lon, radius \\ @radius) when is_number(lat) and is_number(lon) do
    dlat = radius / 111_320
    dlon = radius / (111_320 * max(:math.cos(lat * :math.pi() / 180), 0.01))
    bbox = Enum.join([lat - dlat, lon - dlon, lat + dlat, lon + dlon], ",")

    query =
      URI.encode_query(%{
        "tag" => @cinema_tag,
        "bbox" => bbox,
        "limit" => 500,
        "fields" => "title,extra"
      })

    case Chiezo.get(base <> "/v1/" <> @source <> "/filter?" <> query) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"results" => results}} when is_list(results) ->
            {:ok,
             results
             |> Enum.flat_map(&to_theater/1)
             |> dedupe()
             |> Enum.map(&Map.put(&1, :distance, distance(lat, lon, &1.lat, &1.lon)))
             |> Enum.filter(&(&1.distance <= radius))
             |> Enum.sort_by(& &1.distance)
             |> Enum.take(@max_results)}

          _other ->
            {:error, :chiezo_unexpected_body}
        end

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  @doc """
  地域の名前（「川崎」）の候補（`%{label, lat, lon}`）。**最初に当たった場所で決めずに選んでもらう**
  —— 地名の辞典は「川崎」で埼玉県の地区を先に返すことがある。**駅 → 市区町村 → そのほか**
  の順に、同じ名前と都道府県のものは 1 つにまとめて 8 件まで。見つからなければ空。
  """
  def places(base, name) when is_binary(name) do
    with {:ok, found} <- Chiezo.places(base, String.trim(name)) do
      {:ok,
       found
       |> Enum.map(
         &%{label: place_label(&1), lat: &1.lat, lon: &1.lon, rank: place_rank(&1.feature)}
       )
       |> Enum.sort_by(& &1.rank)
       |> Enum.uniq_by(& &1.label)
       |> Enum.take(8)
       |> Enum.map(&Map.delete(&1, :rank))}
    end
  end

  # 「川崎駅（神奈川県）」「川崎市（神奈川県）」の形。種類が分からなければ名前だけ
  defp place_label(%{name: name, area: area, feature: feature}) do
    name =
      if place_rank(feature) == 0 and not String.ends_with?(name, "駅"),
        do: name <> "駅",
        else: name

    if is_binary(area) and area != "", do: "#{name}（#{area}）", else: name
  end

  defp place_rank(feature)
       when feature in ["railway=station", "public_transport=station", "railway=halt"], do: 0

  defp place_rank("place=" <> kind) when kind in ["city", "town", "village", "suburb"], do: 1
  defp place_rank(_feature), do: 2

  @doc """
  同じ館を 1 つにまとめます（`same?/2` で同じとみなした組の、`keep_score/1` の高いほうを残す）。
  """
  def dedupe(theaters) do
    theaters
    |> Enum.sort_by(&keep_score/1, :desc)
    |> Enum.reduce([], fn theater, kept ->
      if Enum.any?(kept, &same?(&1, theater)), do: kept, else: [theater | kept]
    end)
    |> Enum.reverse()
  end

  @doc "同じ館か（距離と、名前・サイトで見る。くわしくは moduledoc）。"
  def same?(a, b) do
    d = distance(a.lat, a.lon, b.lat, b.lon)

    (d <= @latin_copy_within and (latin_only?(a.name) or latin_only?(b.name))) or
      (d <= @same_within and
         ((domain(a.website) != nil and domain(a.website) == domain(b.website)) or
            common_length(core(a.name), core(b.name)) >= 4))
  end

  @doc "残す優先（サイトがある・名前に日本語がある・辞典の確からしさが高い）。"
  def keep_score(theater) do
    if(theater.website, do: 2, else: 0) + if(latin_only?(theater.name), do: 0, else: 2) +
      (theater[:confidence] || 0)
  end

  defp latin_only?(name), do: not Regex.match?(~r/[\p{Han}\p{Hiragana}\p{Katakana}]/u, name)

  # 「hlo.tohotheater.jp」と「www.tohotheater.jp」を同じに読む（末尾 2 つ。.co.jp などは 3 つ）
  defp domain(nil), do: nil

  defp domain(url) do
    with %URI{host: host} when is_binary(host) <- URI.parse(url) do
      labels = host |> String.downcase() |> String.split(".")
      take = if Enum.at(labels, -2) in ~w(co or ne ac go ed lg), do: 3, else: 2
      labels |> Enum.take(-take) |> Enum.join(".")
    end
  end

  # 名前の芯（大文字小文字・全角半角を揃え、空白と記号と、ありふれた語を除く）
  defp core(name) do
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
        lon: detail["lon"]
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
      |> Map.take([:address, :website, :lat, :lon])
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
