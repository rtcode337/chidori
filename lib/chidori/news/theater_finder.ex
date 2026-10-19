defmodule Chidori.News.TheaterFinder do
  @moduledoc """
  映画館を **AI に web で探させる**ところ（映画の画面の「映画館」の欄）。

  ## 辞典だけで探すのをやめた理由

  店舗辞典を点の周りで引いて距離の順に並べていた頃は、**同じ館が英語名・旧名・別表記で
  何件も並び**（辞典が複数の出どころを束ねたもののため。名前と距離でまとめても残った）、
  しかも**距離しか見られなかった** —— 観に行くかを決めるのは、隣の駅の館に何分で着くか
  なのに、直線の距離では電車の乗り換えも駅からの徒歩も分からない。

  ## AI に頼むこと

  出発地（駅名・地名か現在地）から**決めた時間（既定 30 分）以内に着ける館**を、
  **着くまでの時間が短い順に**、館ごとに最寄り駅・行き方・かかる時間・住所・公式サイトつきで
  返させる（`prompt/2`）。**同じ館は 1 つにまとめ、営業中の館だけ**を挙げさせる。
  押したときだけで、押すたびに AI を 1 回使い、数十秒〜数分かかる（`Chidori.News.Showtimes` と
  同じ `/v1/ai/complete` の `web: true`）。

  ## 辞典で確かめる

  AI が挙げた館は、店舗辞典の映画館（全国。`category=cinema`）と**名前と住所で突き合わせる**
  （`match/2`）。合ったものには辞典の座標と id を付け（地図のリンク・お気に入りの鍵）、
  合わないものは「辞典で確かめられない」と印を付けて出す —— AI が存在しない館を挙げても
  見分けられるように。辞典の映画館は 1 日覚える（数百 KB。探すたびに読み直さない）。
  """

  alias Chidori.Chiezo
  alias Chidori.Jst
  alias Chidori.News.Theaters

  # 着くまでの時間（分）の選べる値と既定
  @minutes_choices [15, 30, 45, 60]
  @default_minutes 30
  # AI に挙げさせる館の数の上限
  @max_results 15
  # 答えを待つ上限（web で何頁も当たるので長くかかる）
  @timeout 10 * 60 * 1000
  # 辞典の映画館を覚えておく長さ
  @cinemas_ttl_ms 24 * 60 * 60 * 1000
  @cinemas_key {__MODULE__, :cinemas}

  @doc "着くまでの時間（分）の選べる値。"
  def minutes_choices, do: @minutes_choices

  @doc "既定の着くまでの時間（分）。"
  def default_minutes, do: @default_minutes

  @doc """
  探します。`origin` は駅名・地名（文字）か現在地（`{lat, lon}`）、`minutes` は着くまでの時間の上限。
  `{:ok, %{origin: 出発地の書き方, minutes: 分, theaters: [館], raw: 答えの文}}` か `{:error, 理由}`。
  館は `%{id, name, station, access, minutes, address, website, lat, lon, verified}`。
  """
  def ask(base, backend, origin, minutes) when minutes in @minutes_choices do
    body =
      Jason.encode!(%{
        backend: backend,
        web: true,
        requested_by: "chidori",
        messages: [%{role: "user", content: prompt(origin, minutes)}]
      })

    case Chiezo.post(base <> "/v1/ai/complete", body, @timeout) do
      {:ok, %{status: 200, body: raw}} ->
        with {:ok, %{"content" => content}} when is_binary(content) <- Jason.decode(raw) do
          cinemas =
            case cinemas(base) do
              {:ok, list} -> list
              {:error, _reason} -> []
            end

          {:ok,
           %{
             origin: origin_label(origin),
             minutes: minutes,
             theaters: content |> parse() |> Enum.map(&match(&1, cinemas)),
             raw: content
           }}
        else
          _other -> {:error, :chiezo_unexpected_body}
        end

      {:ok, %{status: status, body: raw}} ->
        {:error, {:chiezo_refused, status, Chiezo.reason_of(raw)}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  def ask(_base, _backend, _origin, _minutes), do: {:error, :bad_request}

  @doc "出発地の書き方（画面と頼む文に出す）。"
  def origin_label({lat, lon}) when is_number(lat) and is_number(lon),
    do: "現在地（#{Float.round(lat * 1.0, 4)},#{Float.round(lon * 1.0, 4)}）"

  def origin_label(name) when is_binary(name), do: String.trim(name)

  @doc "頼む文。"
  def prompt(origin, minutes) do
    """
    映画を観に行ける映画館を探してください。今日は #{Date.to_iso8601(Jst.today())} です。

    - 出発地: #{origin_label(origin)}
    - **#{minutes} 分以内に着ける映画館**（電車・バス・徒歩。乗り換えと駅からの徒歩も含めた時間）。
      **直線の距離ではなく、着くまでの時間で選んでください**（隣の駅や数駅先の館も入る）
    - **着くまでの時間が短い順に**、#{@max_results} 館まで
    - **同じ映画館は 1 つにまとめてください**（英語名・旧名・別の表記を別の館として挙げない）
    - **いま営業している映画館だけ**（閉館した館・試写室・イベントホール・映画の学校は入れない）
    - 確かめられないことは書かないでください（推し量った時間や住所を書かない）

    答えは次の JSON だけを返してください（前後に文を書かない）。
    {"theaters": [
      {"name": "映画館の正式な名前",
       "station": "最寄り駅（「〇〇駅」の形）",
       "access": "出発地からの行き方を短く（例: JR 中央線で 1 駅、駅から徒歩 3 分）",
       "minutes": 着くまでの時間（分。数）,
       "address": "住所",
       "website": "公式サイトの URL"}
    ]}
    """
  end

  @doc """
  答えを読みます（`%{name, station, access, minutes, address, website}` の並び。時間の短い順）。
  答えの中の最初の `{` から最後の `}` までを JSON として読む。読めなければ空。
  """
  def parse(content) when is_binary(content) do
    with [json] <- Regex.run(~r/\{.*\}/su, content),
         {:ok, %{"theaters" => list}} when is_list(list) <- Jason.decode(json) do
      list
      |> Enum.flat_map(fn
        %{"name" => name} = item when is_binary(name) and name != "" ->
          [
            %{
              name: String.trim(name),
              station: text(item["station"]),
              access: text(item["access"]),
              minutes: if(is_integer(item["minutes"]), do: item["minutes"]),
              address: text(item["address"]),
              website: Chidori.SafeUrl.href(item["website"])
            }
          ]

        _other ->
          []
      end)
      |> Enum.uniq_by(&Theaters.name_core(&1.name))
      |> Enum.sort_by(&(&1.minutes || 999))
    else
      _other -> []
    end
  end

  def parse(_content), do: []

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: nil

  @doc """
  AI が挙げた館を辞典の映画館と突き合わせます。**名前が似ていて、住所の市区町村が合うもの**
  （住所が無ければ名前だけ）を採る。合えば辞典の id と座標を付けて `verified: true`、
  合わなければ id は `ai:<名前>` で `verified: false`。
  """
  def match(found, cinemas) do
    hit =
      Enum.find(cinemas, fn c ->
        Theaters.similar_name?(c.name, found.name) and
          same_place?(Enum.join([c[:locality], c.address], " "), found.address)
      end)

    case hit do
      %{} = c ->
        Map.merge(found, %{
          id: c.id,
          lat: c.lat,
          lon: c.lon,
          website: found.website || c.website,
          address: found.address || c.address,
          verified: true
        })

      nil ->
        Map.merge(found, %{id: "ai:" <> found.name, lat: nil, lon: nil, verified: false})
    end
  end

  # 住所の市区町村が合うか（どちらかが無ければ名前だけで決める）。辞典の住所は「新宿3丁目」の
  # ように都道府県から書いていないことがあるので、短いほうが長いほうに含まれるかで見る
  defp same_place?(a, b) when is_binary(a) and is_binary(b) do
    [x, y] = Enum.map([a, b], &place_core/1)

    x == "" or y == "" or String.contains?(x, y) or String.contains?(y, x) or
      shared_town?(x, y)
  end

  defp same_place?(_a, _b), do: true

  defp place_core(address) do
    address
    |> String.normalize(:nfkc)
    |> String.replace(~r/\s|日本|〒\d{3}-?\d{4}/u, "")
  end

  # 「東京都新宿区新宿3-15-15」と「新宿3丁目15-15」のように書き方が違うときのため、
  # 市区町村の名前（「〇〇区」「〇〇市」「〇〇町」）が両方にあれば同じ場所とみなす
  # **どちらかに市区町村が読めなければ、名前だけで決める**（辞典の住所には区や市の無いものがある）
  defp shared_town?(x, y) do
    towns = fn s ->
      Regex.scan(~r/[^都道府県\d\-\s]{1,6}?[区市町村]/u, s) |> List.flatten() |> MapSet.new()
    end

    {a, b} = {towns.(x), towns.(y)}
    MapSet.size(a) == 0 or MapSet.size(b) == 0 or not MapSet.disjoint?(a, b)
  end

  @doc """
  辞典の映画館（全国。`Chidori.News.Theaters.to_theater/1` の形）。1 日覚える。
  `{:ok, [館]}` か `{:error, 理由}`。
  """
  def cinemas(base) do
    case :persistent_term.get(@cinemas_key, nil) do
      {at, list} when is_list(list) ->
        if System.monotonic_time(:millisecond) - at < @cinemas_ttl_ms,
          do: {:ok, list},
          else: load_cinemas(base)

      _none ->
        load_cinemas(base)
    end
  end

  @doc "覚えた映画館を忘れる（テスト用）。"
  def forget_cinemas, do: :persistent_term.erase(@cinemas_key)

  defp load_cinemas(base) do
    with {:ok, list} <- cinema_pages(base, 0, []) do
      :persistent_term.put(@cinemas_key, {System.monotonic_time(:millisecond), list})
      {:ok, list}
    end
  end

  @page 500

  defp cinema_pages(base, offset, acc) do
    query =
      URI.encode_query(%{
        "tag" => "cinema",
        "fields" => "title,extra",
        "limit" => @page,
        "offset" => offset
      })

    with {:ok, %{status: 200, body: body}} <-
           Chiezo.get(base <> "/v1/overture_japan/filter?" <> query),
         {:ok, %{"results" => results}} when is_list(results) <- Jason.decode(body) do
      acc = acc ++ Enum.flat_map(results, &Theaters.to_theater/1)

      if length(results) < @page,
        do: {:ok, acc},
        else: cinema_pages(base, offset + @page, acc)
    else
      {:ok, %{status: status}} -> {:error, {:chiezo_status, status}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
      _other -> {:error, :chiezo_unexpected_body}
    end
  end
end
