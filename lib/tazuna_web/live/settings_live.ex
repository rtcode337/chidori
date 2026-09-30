defmodule TazunaWeb.SettingsLive do
  @moduledoc """
  設定ページ。**タブで仕事を分けます**。

  - Chiezo 収集 —— tazuna が Chiezo に頼んでいる収集の一覧（巡回の間隔・相手・
    前回・次回）と、ワーカーと取り込みの待ち行列。**待ち行列が溜まってきたときに、
    何がどれだけの間隔で回っているかを 1 枚で読むため**（`Tazuna.CollectOverview`）
  - トップページ —— トップに並べる枠と、その順（`Tazuna.Home`）
  """

  use TazunaWeb, :live_view

  alias Tazuna.CollectOverview
  alias Tazuna.CollectPace
  alias Tazuna.Home
  alias Tazuna.News

  @tabs [{"chiezo", "Chiezo 収集"}, {"home", "トップページ"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "設定",
       tabs: @tabs,
       overview: nil,
       home_keys: [],
       pace_message: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in Enum.map(@tabs, &elem(&1, 0)), do: params["tab"], else: "chiezo"

    {:noreply,
     socket
     |> assign(tab: tab, catalog: Home.catalog(), home_keys: Home.selected_keys())
     |> load(tab)}
  end

  # **開くたびに読み直す**（Chiezo の側は勝手に進む。写しは持たない）
  defp load(socket, "chiezo") do
    case News.chiezo_base_url() do
      nil ->
        assign(socket, overview: {:error, :chiezo_not_configured})

      base ->
        if connected?(socket) do
          socket
          |> assign(overview: :loading)
          |> start_async(:overview, fn -> CollectOverview.load(base) end)
        else
          assign(socket, overview: :loading)
        end
    end
  end

  defp load(socket, _tab), do: socket

  @impl true
  def handle_async(:overview, {:ok, result}, socket),
    do: {:noreply, assign(socket, overview: result)}

  def handle_async(:overview, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, overview: {:error, :chiezo_unavailable})}

  def handle_async(:pace, {:ok, result}, socket) do
    {:noreply, socket |> assign(pace_message: pace_text(result)) |> load("chiezo")}
  end

  def handle_async(:pace, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, pace_message: pace_text({:error, :chiezo_unavailable}))}

  @impl true
  def handle_event("reload", _params, socket), do: {:noreply, load(socket, "chiezo")}

  # **保存してから送る。** 送れなくても保存は残る（次に「収集の設定を更新」を押した
  # ときにも、この間隔で組んで送られる）
  def handle_event("save_pace", %{"pace" => pace}, socket) do
    saved =
      for kind <- CollectPace.kinds(),
          value = pace[to_string(kind)],
          {minutes, ""} <- [Integer.parse(to_string(value))],
          do: CollectPace.put(kind, minutes)

    cond do
      Enum.any?(saved, &(&1 != :ok)) ->
        {:noreply, assign(socket, pace_message: "選べない間隔が含まれていました。")}

      base = News.chiezo_base_url() ->
        {:noreply,
         socket
         |> assign(pace_message: "保存しました。Chiezo に送っています…")
         |> start_async(:pace, fn -> CollectPace.apply(base) end)}

      true ->
        {:noreply,
         assign(socket,
           pace_message: "保存しました（Chiezo の場所が設定されていないので送っていません）。"
         )}
    end
  end

  # **並びは送られてきた順**（チェックした枠の順番の欄で決める）
  def handle_event("save_home", params, socket) do
    keys =
      params
      |> Map.get("panels", %{})
      |> Enum.filter(fn {_key, value} -> value["on"] == "true" end)
      |> Enum.sort_by(fn {key, value} -> {order(value["order"]), key} end)
      |> Enum.map(&elem(&1, 0))

    Home.put(keys)

    {:noreply,
     socket
     |> assign(home_keys: Home.selected_keys())
     |> put_flash(:info, "トップページに並べる枠を保存しました。")}
  end

  defp order(value) do
    case Integer.parse(to_string(value || "")) do
      {n, _} -> n
      :error -> 999
    end
  end

  @doc "間隔を送った結果の言い方。"
  def pace_text({:ok, %{sent: sent, failed: []}}),
    do: "保存して、#{length(sent)} 本の巡回に送りました。"

  def pace_text({:ok, %{sent: sent, failed: failed}}) do
    names = Enum.map_join(failed, "、", fn {name, sweep, _reason} -> "#{name} / #{sweep}" end)
    "保存して、#{length(sent)} 本の巡回に送りました。送れなかったもの: #{names}"
  end

  def pace_text({:error, _reason}),
    do: "保存しました。Chiezo に送れませんでした（繋がらないかもしれません）。各画面の「収集の設定を更新」でも送れます。"

  @doc """
  日時を JST で短く（「9/28 09:53」。空なら —）。**表に何行も並ぶので年と「JST」は
  落とす**（見出しに JST と書く）—— 全部書くと欄が折り返して読めない。
  """
  def at(nil), do: "—"
  def at(""), do: "—"

  def at(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        jst = DateTime.add(dt, 9 * 3600, :second)

        "#{jst.month}/#{jst.day} " <>
          String.pad_leading("#{jst.hour}", 2, "0") <>
          ":" <> String.pad_leading("#{jst.minute}", 2, "0")

      _ ->
        value
    end
  end

  @doc "読めなかったときの一言。"
  def error_text({:error, :chiezo_not_configured}), do: "Chiezo の場所（CHIEZO_BASE_URL）が設定されていません。"
  def error_text({:error, :collect_disabled}), do: "Chiezo の収集が無効です。"
  def error_text(_error), do: "Chiezo から読めませんでした（繋がらないかもしれません）。"

  @doc "キューの口が無い古い Chiezo のときの一言。"
  def queue_error_text(:queue_unsupported),
    do: "この Chiezo は待ち行列を配る口（/v1/collect/queue）をまだ持っていません。Chiezo を新しくすると出ます。"

  def queue_error_text(_reason), do: "待ち行列を読めませんでした。"

  @doc """
  並べ替えの一覧に出す順。**並べている枠を並べている順に先に、残りを後ろに**
  （残りは選べる順のまま）。
  """
  def ordered(catalog, keys) do
    by_key = Map.new(catalog, &{&1.key, &1})
    picked = keys |> Enum.map(&by_key[&1]) |> Enum.reject(&is_nil/1)
    picked ++ Enum.reject(catalog, &(&1.key in keys))
  end
end
