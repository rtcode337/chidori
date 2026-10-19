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

  @doc """
  点の近くの映画館を近い順に（`%{id, name, address, website, lat, lon, distance}`。距離は m）。
  `{:ok, [theater]}` か `{:error, 理由}`。
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
  地域の名前（「新宿」）の近くの映画館。地名の辞典で最初に当たった場所の座標で探します。
  `{:ok, %{place: 地名, theaters: [...]}}` か `{:error, 理由}`（地名が見つからなければ `:no_place`）。
  """
  def near_place(base, name) when is_binary(name) do
    with {:ok, [place | _]} <- Chiezo.places(base, String.trim(name)),
         {:ok, theaters} <- near(base, place.lat, place.lon) do
      {:ok, %{place: place.name, theaters: theaters}}
    else
      {:ok, []} -> {:error, :no_place}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def to_theater(%{"title" => name, "extra" => %{"feature" => @cinema_feature} = extra})
      when is_binary(name) do
    with lat when is_number(lat) <- extra["lat"],
         lon when is_number(lon) <- extra["lon"] do
      [
        %{
          id: extra["overture_id"] || name,
          name: name,
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
