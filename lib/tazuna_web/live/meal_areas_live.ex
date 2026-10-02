defmodule TazunaWeb.MealAreasLive do
  @moduledoc """
  食事処を集める範囲を決める画面（`/datasets/areas`）。**地図に四角を描いて範囲を
  足します**。範囲 1 つにつき Chiezo の収集が 1 つで、データ収集の画面にタブが増えます。

  日本全体を 1 つの収集で回していた頃は、費用がかさみ、抜け漏れと間違いが多すぎて
  地図として使えなかった。見たい範囲だけを細かい区画で回す。

  **全体は手元の白地図**（`Tazuna.Datasets.Map.blank/0`）、**寄ったら地理院タイル**
  （国土地理院の標準地図。`area_draw.js` が図の下に敷く）。白地図だけでは区や駅の
  細かさで場所が読めず、四角を決められなかった。タイルを取りに行くときは
  **参照元を送らない**（この画面のアドレスを外へ出さない）。地名で探して寄れる。

  四角を決めると、**中にある店の数（辞典ごと）と区画の数の見込み**をその場で出す ——
  広すぎる範囲は日本全体と同じことになる（一周のめどが立たない）。
  """

  use TazunaWeb, :live_view

  alias Tazuna.Chiezo
  alias Tazuna.Datasets.MealAreas
  alias Tazuna.Datasets.Meals

  # 数える辞典とタグ（名簿を引く指定と同じもの）。**見込みは上限**で、同じ店が
  # 2 つの辞典に居れば 2 と数える（畳んだあとの数は名簿の回が引くまで分からない）
  @counted [{"osm_japan", "amenity=restaurant"}, {"overture_japan", "restaurant"}]
  # 地名の場所から四角を作るときの大きさ（片側。およそ 1.5 km）
  @around 0.014

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "食事処の範囲",
       areas: MealAreas.list(),
       map: Tazuna.Datasets.Map.blank(),
       draft: empty_draft(),
       errors: [],
       estimate: nil,
       query: "",
       places: nil,
       marker: nil
     )}
  end

  defp empty_draft, do: %{"name" => "", "south" => "", "west" => "", "north" => "", "east" => ""}

  # ---- 地名で寄る ----------------------------------------------------------

  @impl true
  def handle_event("search_place", %{"q" => q}, socket) do
    q = String.trim(q || "")

    cond do
      q == "" ->
        {:noreply, assign(socket, query: "", places: nil)}

      base = Chiezo.base_url() ->
        {:noreply,
         socket
         |> assign(query: q, places: :loading)
         |> start_async(:places, fn -> Chiezo.places(base, q) end)}

      true ->
        {:noreply, assign(socket, query: q, places: {:error, :chiezo_not_configured})}
    end
  end

  # 候補を選んだら、その場所へ寄って印を立てる（寄せるのは画面の側）
  def handle_event("focus_place", %{"index" => index}, socket) do
    with {:ok, places} <- socket.assigns.places,
         {i, ""} <- Integer.parse(index),
         %{lat: lat, lon: lon} = place <- Enum.at(places, i),
         %{x: x, y: y} <- Tazuna.Datasets.Map.point(socket.assigns.map, lat, lon) do
      {:noreply,
       socket
       |> assign(places: nil, marker: %{x: x, y: y, label: place.name, lat: lat, lon: lon})
       |> push_event("map_focus", %{x: x, y: y})}
    else
      _other -> {:noreply, socket}
    end
  end

  # 探した場所のまわりで四角を作る（描くより手早い。あとから描き直せる）
  def handle_event("around_marker", _params, socket) do
    case socket.assigns.marker do
      %{lat: lat, lon: lon} ->
        {:noreply,
         set_box(socket, [lat - @around, lon - @around * 1.2, lat + @around, lon + @around * 1.2])}

      _none ->
        {:noreply, socket}
    end
  end

  # ---- 四角を決める --------------------------------------------------------

  # 地図に描いた四角（画面が緯度経度に直して送る）
  def handle_event("drawn", %{"south" => s, "west" => w, "north" => n, "east" => e}, socket) do
    case Enum.map([s, w, n, e], &number/1) do
      [s, w, n, e] when is_number(s) and is_number(w) and is_number(n) and is_number(e) ->
        {:noreply, set_box(socket, [min(s, n), min(w, e), max(s, n), max(w, e)])}

      _unreadable ->
        {:noreply, socket}
    end
  end

  # 数で直す・名前を打つ
  def handle_event("edit", %{"area" => params}, socket) do
    draft = Map.merge(socket.assigns.draft, Map.take(params, Map.keys(empty_draft())))
    socket = assign(socket, draft: draft, errors: [])

    case box_of(draft) do
      nil -> {:noreply, socket}
      box -> {:noreply, if(box == current_box(socket), do: socket, else: set_box(socket, box))}
    end
  end

  def handle_event("create", %{"area" => params}, socket) do
    draft = Map.merge(socket.assigns.draft, Map.take(params, Map.keys(empty_draft())))

    case MealAreas.create(draft) do
      {:ok, area} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "範囲「#{area.name}」を作りました。「収集の設定を更新」を押すと、Chiezo にこの範囲の収集ができます。"
         )
         |> push_navigate(to: ~p"/datasets?view=#{Meals.definition(area).key}")}

      {:error, changeset} ->
        {:noreply, assign(socket, draft: draft, errors: error_lines(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with {n, ""} <- Integer.parse(id), %MealAreas{} = area <- MealAreas.get(n) do
      MealAreas.delete(area)

      {:noreply,
       socket
       |> assign(areas: MealAreas.list())
       |> put_flash(
         :info,
         "範囲「#{area.name}」を外しました。Chiezo の収集（#{Meals.collection(area)}）は残っているので、要らなければ Chiezo の画面で止めるか消してください。"
       )}
    else
      _other -> {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:places, {:ok, result}, socket), do: {:noreply, assign(socket, places: result)}

  def handle_async(:places, {:exit, _}, socket),
    do: {:noreply, assign(socket, places: {:error, :chiezo_unavailable})}

  def handle_async(:estimate, {:ok, {box, estimate}}, socket) do
    # **古い四角の答えは捨てる**（描き直しが続くと、遅れて届いた前の答えで上書きされる）
    if box == current_box(socket),
      do: {:noreply, assign(socket, estimate: estimate)},
      else: {:noreply, socket}
  end

  def handle_async(:estimate, {:exit, _}, socket),
    do: {:noreply, assign(socket, estimate: {:error, :chiezo_unavailable})}

  defp set_box(socket, [s, w, n, e]) do
    draft =
      Map.merge(socket.assigns.draft, %{
        "south" => fmt(s),
        "west" => fmt(w),
        "north" => fmt(n),
        "east" => fmt(e)
      })

    # **欄に入れた値（丸めたもの）で数える。** 生の値で問い合わせると、答えが届いたときに
    # 「いまの四角と同じか」の比べ方が食い違い、正しい答えまで捨てる
    box = box_of(draft)
    socket = assign(socket, draft: draft, estimate: :loading, errors: [])

    case Chiezo.base_url() do
      nil ->
        assign(socket, estimate: {:error, :chiezo_not_configured})

      base ->
        start_async(socket, :estimate, fn -> estimate(base, box) end)
    end
  end

  # 中にある店の数（辞典ごと）と区画の見込み
  defp estimate(base, box) do
    counts =
      for {source, tag} <- @counted do
        case Chiezo.count_in(base, source, tag, box) do
          {:ok, count} -> {source, count}
          {:error, _reason} -> {source, nil}
        end
      end

    total = counts |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1) |> Enum.sum()

    {box,
     {:ok,
      %{counts: counts, total: total, partitions: ceil(total / Meals.area_partition_target())}}}
  end

  defp current_box(socket), do: box_of(socket.assigns.draft)

  defp box_of(draft) do
    case Enum.map(~w(south west north east), &number(draft[&1])) do
      [s, w, n, e] = box when is_number(s) and is_number(w) and is_number(n) and is_number(e) ->
        if s < n and w < e, do: box

      _other ->
        nil
    end
  end

  defp number(value) when is_number(value), do: value / 1

  defp number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {n, ""} -> n
      _other -> nil
    end
  end

  defp number(_value), do: nil

  defp fmt(value), do: :erlang.float_to_binary(value / 1, decimals: 5)

  defp error_lines(changeset) do
    labels = %{name: "名前", south: "南", west: "西", north: "北", east: "東"}

    Enum.map(changeset.errors, fn {field, {message, opts}} ->
      text =
        Enum.reduce(opts, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)

      "#{labels[field] || field}#{text}"
    end)
  end

  @doc "範囲を図の矩形に（描くため）。"
  def rect(map, area), do: Tazuna.Datasets.Map.box(map, MealAreas.bbox(area))

  @doc "いま決めている四角を図の矩形に。決まっていなければ nil。"
  def draft_rect(map, draft) do
    case box_of(draft) do
      nil -> nil
      box -> Tazuna.Datasets.Map.box(map, box)
    end
  end

  @doc "辞典の呼び名。"
  def source_label("osm_japan"), do: "地図辞典（OpenStreetMap）"
  def source_label("overture_japan"), do: "店舗辞典（Overture）"
  def source_label(other), do: other

  @doc "四角を短く（`35.670,139.750 〜 35.690,139.780`）。"
  def bbox_text(area) do
    [s, w, n, e] = MealAreas.bbox(area)
    "#{fmt2(s)},#{fmt2(w)} 〜 #{fmt2(n)},#{fmt2(e)}"
  end

  defp fmt2(value), do: :erlang.float_to_binary(value / 1, decimals: 3)
end
