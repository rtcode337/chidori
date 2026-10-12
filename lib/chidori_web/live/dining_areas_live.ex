defmodule ChidoriWeb.DiningAreasLive do
  @moduledoc """
  食事処を集める範囲を決める画面（`/datasets/areas`）。**地図に四角を描いて範囲を
  足します**。範囲 1 つにつき Chiezo の収集が 1 つで、範囲の名前から、その範囲の収集の画面を開きます。

  日本全体を 1 つの収集で回していた頃は、費用がかさみ、抜け漏れと間違いが多すぎて
  地図として使えなかった。見たい範囲だけを細かい区画で回す。

  **全体は手元の白地図**（`Chidori.Datasets.Map.blank/0`）、**寄ったら地理院タイル**
  （国土地理院の標準地図。`area_draw.js` が図の下に敷く）。白地図だけでは区や駅の
  細かさで場所が読めず、四角を決められなかった。タイルを取りに行くときは
  **参照元を送らない**（この画面のアドレスを外へ出さない）。地名で探して寄れる。

  四角を決めると、**中にある店の数（辞典ごと）と区画の数の見込み**をその場で出す ——
  広すぎる範囲は日本全体と同じことになる（一周のめどが立たない）。

  **作った範囲は地図に名前つきで出し、直せます。** 四角を変えたら、Chiezo の収集へ
  範囲で決まるところ（名簿の指定・区画）を送り、機械収集から走らせ直す
  （`Chidori.Datasets.reshape/1`）—— 送るだけだと、広げたぶんの店が名簿に入らない
  （機械収集は一度きりの回で、もう走らない）。

  **travel-log からの依頼もここで受けて、範囲ごとに配ります**（`Requests.route/2`）。
  travel-log はいくつもの範囲を 1 つの画面で扱うので、依頼のテキストにはどの範囲の店かが
  書いていない —— 範囲の画面ごとに貼り分けさせると、自分で座標を見て仕分けることになる。
  1 件ずつ座標の入る範囲へ控え、位置OK・位置修正はその範囲の収集で固定させる。
  頼むのはこれまでどおり範囲の画面の「この区画を頼む」から。

  **全範囲を 1 つの ZIP に書き出せます**（`ChidoriWeb.DatasetsController.export_areas/2`）。
  """

  use ChidoriWeb, :live_view

  alias Chidori.Chiezo
  alias Chidori.Datasets
  alias Chidori.Datasets.DiningAreas
  alias Chidori.Datasets.Dining
  alias Chidori.Datasets.Requests
  alias ChidoriWeb.DatasetsLive

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
       # データ収集の画面と同じタブ（この画面は「食事処」のタブにあたる）
       datasets: Datasets.list(),
       areas: DiningAreas.list(),
       # 直している範囲（nil なら足している）
       editing: nil,
       map: Chidori.Datasets.Map.blank(),
       draft: empty_draft(),
       errors: [],
       estimate: nil,
       query: "",
       places: nil,
       marker: nil,
       # travel-log からの依頼を配った結果と、位置の固定の結果
       routed: nil,
       held: nil,
       # 「AI を使わずにいま反映する」を頼んだ範囲（範囲の id → 結果）
       applied: %{}
     )
     |> assign_pending()}
  end

  # 範囲ごとに控えている依頼の数（範囲の id → 件数）
  defp assign_pending(socket) do
    counts =
      Map.new(socket.assigns.areas, fn area ->
        {area.id, Requests.pending_count(Dining.definition(area))}
      end)

    assign(socket, pending_counts: counts)
  end

  defp empty_draft, do: %{"name" => "", "south" => "", "west" => "", "north" => "", "east" => ""}

  # ---- travel-log からの依頼を配る ------------------------------------------

  @impl true
  def handle_event("route_requests", %{"text" => text}, socket) do
    areas = DiningAreas.list()
    %{areas: routed, outside: outside} = Requests.route(text, areas)

    stashed =
      for %{area: area, items: [_ | _] = items} <- routed do
        text = Enum.map_join(items, "\n", & &1.text)
        {area, Requests.stash(Dining.definition(area), text)}
      end

    holding = for %{area: area, confirms: [_ | _] = confirms} <- routed, do: {area, confirms}

    socket =
      socket
      |> assign(
        areas: areas,
        routed: %{
          stashed: stashed,
          outside: outside,
          empty: routed == [] and outside == %{confirms: [], items: []}
        },
        held: if(holding == [], do: nil, else: :holding)
      )
      |> assign_pending()

    socket =
      if holding == [],
        do: socket,
        else:
          start_async(socket, :route_hold, fn ->
            for {area, confirms} <- holding,
                do: {area, Requests.hold(Dining.definition(area), confirms)}
          end)

    {:noreply, socket}
  end

  # **AI を使わずに、固定した座標をいま反映する**（その範囲の機械収集を 1 回走らせる）。
  # 範囲の画面にある同じボタンと同じもの —— 配ったあとに範囲の画面へ移らずに済むように
  def handle_event("apply_locks", %{"id" => id}, socket) do
    with {n, ""} <- Integer.parse(id), %DiningAreas{} = area <- DiningAreas.get(n) do
      applied = Map.put(socket.assigns.applied, area.id, :applying)

      {:noreply,
       socket
       |> assign(applied: applied)
       |> start_async({:apply_locks, area.id}, fn ->
         Requests.apply_now(Dining.definition(area))
       end)}
    else
      _other -> {:noreply, socket}
    end
  end

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
         %{x: x, y: y} <- Chidori.Datasets.Map.point(socket.assigns.map, lat, lon) do
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

  # 作った範囲を直し始める（四角を欄に入れ、地図をその範囲へ寄せる）
  def handle_event("edit_area", %{"id" => id}, socket) do
    case find_area(socket, id) do
      %DiningAreas{} = area ->
        socket =
          socket
          |> assign(editing: area, draft: draft_of(area), marker: nil, places: nil)
          |> set_box(DiningAreas.bbox(area))

        {:noreply, frame(socket, DiningAreas.bbox(area))}

      nil ->
        {:noreply, socket}
    end
  end

  # 地図をその範囲へ寄せるだけ（直さない）
  def handle_event("show_area", %{"id" => id}, socket) do
    case find_area(socket, id) do
      %DiningAreas{} = area -> {:noreply, frame(socket, DiningAreas.bbox(area))}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing: nil, draft: empty_draft(), estimate: nil, errors: [])}
  end

  def handle_event("save", %{"area" => params}, socket) do
    draft = Map.merge(socket.assigns.draft, Map.take(params, Map.keys(empty_draft())))
    before = socket.assigns.editing

    case before && DiningAreas.update(before, draft) do
      {:ok, area} ->
        socket =
          assign(socket,
            areas: DiningAreas.list(),
            datasets: Datasets.list(),
            editing: nil,
            draft: empty_draft(),
            estimate: nil,
            errors: []
          )

        if DiningAreas.box_changed?(before, area) do
          dataset = Dining.definition(area)

          {:noreply,
           socket
           |> put_flash(:info, "範囲「#{area.name}」を直しました。Chiezo に送っています…")
           |> start_async(:reshape, fn -> {area, Datasets.reshape(dataset)} end)}
        else
          {:noreply,
           put_flash(
             socket,
             :info,
             "範囲「#{area.name}」の名前を直しました（四角は変わっていないので、走らせ直しません）。"
           )}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, draft: draft, errors: error_lines(changeset))}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("create", %{"area" => params}, socket) do
    draft = Map.merge(socket.assigns.draft, Map.take(params, Map.keys(empty_draft())))

    case DiningAreas.create(draft) do
      {:ok, area} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "範囲「#{area.name}」を作りました。「収集の設定を更新」を押すと、Chiezo にこの範囲の収集ができます。"
         )
         |> push_navigate(to: ~p"/datasets?view=#{Dining.definition(area).key}")}

      {:error, changeset} ->
        {:noreply, assign(socket, draft: draft, errors: error_lines(changeset))}
    end
  end

  # Chiezo に残っている範囲の収集から、手元に無い範囲を読み戻す（動かす場所を変えたとき）
  def handle_event("restore", _params, socket) do
    socket =
      case DiningAreas.restore() do
        {:ok, %{restored: [], skipped: []}} ->
          put_flash(socket, :info, "Chiezo に、ここに無い範囲の収集はありませんでした。")

        {:ok, %{restored: restored, skipped: skipped}} ->
          names = Enum.map_join(restored, "・", & &1.name)

          note =
            if skipped == [],
              do: "",
              else: "（#{Enum.join(skipped, "・")} は説明か区画が読めず、戻せませんでした）"

          socket
          |> assign(areas: DiningAreas.list(), datasets: Datasets.list())
          |> assign_pending()
          |> put_flash(:info, "#{length(restored)} 件の範囲（#{names}）を戻しました。#{note}")

        {:error, _reason} ->
          put_flash(socket, :error, "Chiezo の収集の一覧を読めませんでした。")
      end

    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with {n, ""} <- Integer.parse(id), %DiningAreas{} = area <- DiningAreas.get(n) do
      DiningAreas.delete(area)
      editing = socket.assigns.editing

      socket =
        if editing && editing.id == area.id,
          do: assign(socket, editing: nil, draft: empty_draft(), estimate: nil),
          else: socket

      {:noreply,
       socket
       |> assign(areas: DiningAreas.list(), datasets: Datasets.list())
       |> assign_pending()
       |> put_flash(
         :info,
         "範囲「#{area.name}」を外しました。Chiezo の収集（#{Dining.collection(area)}）は残っているので、要らなければ Chiezo の画面で止めるか消してください。"
       )}
    else
      _other -> {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:apply_locks, id}, {:ok, result}, socket),
    do: {:noreply, assign(socket, applied: Map.put(socket.assigns.applied, id, result))}

  def handle_async({:apply_locks, id}, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket, applied: Map.put(socket.assigns.applied, id, {:error, :chiezo_unavailable}))}

  def handle_async(:route_hold, {:ok, results}, socket),
    do: {:noreply, assign(socket, held: results)}

  def handle_async(:route_hold, {:exit, _}, socket),
    do: {:noreply, assign(socket, held: {:error, :chiezo_unavailable})}

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

  def handle_async(:reshape, {:ok, {area, result}}, socket) do
    {kind, text} = reshape_message(area, result)
    {:noreply, put_flash(socket, kind, text)}
  end

  def handle_async(:reshape, {:exit, _}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "範囲は保存しましたが、Chiezo へ送る途中で止まりました。データ収集の画面で「収集の設定を更新」を押してから、機械収集を走らせてください。"
     )}
  end

  @doc "範囲を直したあとの一言（Chiezo へ送った結果ごと）。"
  def reshape_message(area, :ok),
    do:
      {:info,
       "範囲「#{area.name}」を Chiezo に送り、機械収集から走らせ直しました。" <>
         "区画は次の回に新しい範囲で割り直されます。見終わった区画の印は残り、広げたところだけをざっと見るが見に行きます。"}

  def reshape_message(area, {:ok, :not_requested}),
    do:
      {:info,
       "範囲「#{area.name}」を直しました。Chiezo にはまだ収集が無いので、" <>
         "データ収集の画面で「収集の設定を更新」を押すと新しい範囲で作られます。"}

  def reshape_message(area, {:error, {:not_run, reason}}),
    do:
      {:error,
       "範囲「#{area.name}」を Chiezo に送りましたが、機械収集を走らせられませんでした。" <>
         ChidoriWeb.Collect.reason_text(reason) <>
         "動かせるようになったら、Chiezo の画面で機械収集を走らせてください（広げたぶんの店は、それまで名簿に入りません）。"}

  def reshape_message(area, {:error, reason}),
    do:
      {:error,
       "範囲「#{area.name}」は保存しましたが、Chiezo へ送れませんでした。" <>
         ChidoriWeb.Collect.reason_text(reason) <>
         "データ収集の画面で「収集の設定を更新」を押してから、機械収集を走らせてください。"}

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
      %{counts: counts, total: total, partitions: ceil(total / Dining.area_partition_target())}}}
  end

  defp current_box(socket), do: box_of(socket.assigns.draft)

  defp find_area(socket, id) do
    with {n, ""} <- Integer.parse(to_string(id)) do
      Enum.find(socket.assigns.areas, &(&1.id == n))
    else
      _other -> nil
    end
  end

  defp draft_of(area) do
    [s, w, n, e] = DiningAreas.bbox(area)

    %{
      "name" => area.name,
      "south" => fmt(s),
      "west" => fmt(w),
      "north" => fmt(n),
      "east" => fmt(e)
    }
  end

  # 地図をその四角へ寄せる（四角が画面に収まる倍率で、真ん中に）
  defp frame(socket, box) do
    r = Chidori.Datasets.Map.box(socket.assigns.map, box)

    push_event(socket, "map_frame", %{
      x: r.x + r.width / 2,
      y: r.y + r.height / 2,
      w: r.width,
      h: r.height
    })
  end

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
    labels = %{name: "名前", south: "南", west: "西", north: "北", east: "東", id: "番号"}

    Enum.map(changeset.errors, fn {field, {message, opts}} ->
      text =
        Enum.reduce(opts, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)

      "#{labels[field] || field}#{text}"
    end)
  end

  @doc "範囲を図の矩形に（描くため）。"
  def rect(map, area), do: Chidori.Datasets.Map.box(map, DiningAreas.bbox(area))

  @doc "いま決めている四角を図の矩形に。決まっていなければ nil。"
  def draft_rect(map, draft) do
    case box_of(draft) do
      nil -> nil
      box -> Chidori.Datasets.Map.box(map, box)
    end
  end

  @doc "辞典の呼び名。"
  def source_label("osm_japan"), do: "地図辞典（OpenStreetMap）"
  def source_label("overture_japan"), do: "店舗辞典（Overture）"
  def source_label(other), do: other

  @doc "四角を短く（`35.670,139.750 〜 35.690,139.780`）。"
  def bbox_text(area) do
    [s, w, n, e] = DiningAreas.bbox(area)
    "#{fmt2(s)},#{fmt2(w)} 〜 #{fmt2(n)},#{fmt2(e)}"
  end

  defp fmt2(value), do: :erlang.float_to_binary(value / 1, decimals: 3)

  @doc "範囲ごとに配った依頼の一言（範囲の名前を頭に付ける）。"
  def routed_lines(%{stashed: stashed}) do
    for {area, result} <- stashed, message = DatasetsLive.stashed_message(result) do
      "#{area.name}: " <> String.replace(message, "下の「控えている依頼」から、区画ごとに頼んでください。", "")
    end
  end

  @doc "範囲ごとの位置の固定の一言。"
  def held_lines(:holding), do: [DatasetsLive.held_message(:holding)]
  def held_lines({:error, _} = error), do: [DatasetsLive.held_message(error)]

  def held_lines(results) when is_list(results) do
    for {area, result} <- results, message = DatasetsLive.held_message(result), message != "" do
      "#{area.name}: " <>
        String.replace(message, "「AI を使わずにいま反映する」", "下の「AI を使わずにいま反映する」")
    end
  end

  def held_lines(_held), do: []

  @doc "位置を固定できた範囲（「AI を使わずにいま反映する」を出す先）。"
  def held_areas(results) when is_list(results) do
    for {area, {:ok, %{held: [_ | _]}}} <- results, do: area
  end

  def held_areas(_held), do: []

  @doc "どの範囲にも入らなかった依頼（行の頭だけ）。"
  def outside_lines(%{outside: %{confirms: confirms, items: items}}) do
    Enum.map(confirms, &"#{&1.name} (#{&1.lat},#{&1.lon})") ++
      Enum.map(items, &(&1.text |> String.split("\n") |> List.first()))
  end
end
