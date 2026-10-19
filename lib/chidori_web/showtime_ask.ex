defmodule ChidoriWeb.ShowtimeAsk do
  @moduledoc """
  上映スケジュールを調べる動きと、映画館を AI に探させる動きの、画面どうしで共通の部分
  （映画の画面の「映画館」の欄と、映画の画面・トップ画面で開く作品の詳細）。**画面ごとに書かない** —— 頼み方・答えの
  受け取り方が画面ごとに違うと、片方だけ直して食い違う。

  置いた画面は次を受けて、ここへ渡します。
  - `handle_event("ask_showtimes", params, socket)` → `ask/2`
  - `handle_info({:showtimes, state}, socket)` → `received/2`
  - `handle_async(:showtime_backends, result, socket)` → `backends_loaded/2`
  - `handle_event("find_theaters", params, socket)` → `find_theaters/2`（映画の画面だけ）
  - `handle_info({:theater_search, state}, socket)` → `theaters_received/2`

  答えは押した画面に直接送らず `Chidori.News.AskStore` に置いて知らせるので、
  調べている最中に画面を移っても、戻ってきた画面・別の画面で読めます。
  """

  import Phoenix.Component, only: [assign: 2]

  require Phoenix.LiveView

  alias Chidori.News
  alias Chidori.News.AskStore
  alias Chidori.News.Showtimes
  alias Chidori.News.TheaterFinder
  alias Chidori.News.Theaters
  alias Chidori.Notify.Setting

  @doc """
  画面に要るものを置きます（お気に入りの館・調べている最中か前の答え・頼んだときのフォーム）。
  `on?` が false なら空にするだけ（映画でない話題）。つながっていれば答えの知らせを受け、
  頼める AI を読みに行きます。
  """
  def init(socket, on?) do
    empty = %{state: nil, form: %{}}
    store = if on?, do: AskStore.get(:showtimes), else: empty
    found = if on?, do: AskStore.get(:theater_search), else: empty

    socket =
      assign(socket,
        theater_favorites: if(on?, do: Theaters.favorites(), else: []),
        showtime_backends: nil,
        showtimes: store.state,
        showtime_form: store.form,
        theater_search: found.state,
        theater_form: found.form
      )

    if Phoenix.LiveView.connected?(socket) do
      for key <- [:showtimes, :theater_search] do
        Phoenix.PubSub.unsubscribe(Chidori.PubSub, AskStore.topic(key))
        if on?, do: Phoenix.PubSub.subscribe(Chidori.PubSub, AskStore.topic(key))
      end
    end

    # 前から入っているお気に入りに、最寄り駅を足しておく（次に開いたときから出る。AI は使わない）
    with true <- on? and Phoenix.LiveView.connected?(socket),
         true <- Enum.any?(socket.assigns.theater_favorites, &is_nil(&1.station)),
         base when is_binary(base) <- News.chiezo_base_url() do
      Task.Supervisor.start_child(Chidori.TaskSupervisor, fn -> Theaters.fill_stations(base) end)
    end

    case {on? and Phoenix.LiveView.connected?(socket), News.chiezo_base_url()} do
      {true, base} when is_binary(base) ->
        Phoenix.LiveView.start_async(socket, :showtime_backends, fn ->
          Showtimes.backends(base)
        end)

      _other ->
        socket
    end
  end

  @doc """
  作品の詳細（`ChidoriWeb.WorkModal`）に渡す材料。`init/2` を通していない画面では nil
  （欄を出さない）。
  """
  def for_modal(assigns) do
    if Map.has_key?(assigns, :theater_favorites),
      do: %{
        favorites: assigns.theater_favorites,
        backends: assigns.showtime_backends,
        state: assigns.showtimes,
        form: assigns.showtime_form || %{}
      }
  end

  @doc "頼める AI を読めた。"
  def backends_loaded(socket, {:ok, result}), do: assign(socket, showtime_backends: result)

  def backends_loaded(socket, {:exit, _reason}),
    do: assign(socket, showtime_backends: {:error, :collection_crashed})

  @doc "答えの知らせが届いた（ほかの画面で頼んだものも届く）。"
  def received(socket, state), do: assign(socket, showtimes: state)

  @doc "映画館を探した答えの知らせが届いた。"
  def theaters_received(socket, state), do: assign(socket, theater_search: state)

  @doc """
  映画館を AI に探させます（`Chidori.News.TheaterFinder`）。出発地は駅名・地名の欄、
  空なら「現在地を使う」で取った現在地（`theater_here`）。**重ねて押しても 1 本**。
  """
  def find_theaters(socket, params) do
    form = Map.take(params, ["region", "minutes", "backend"])
    base = News.chiezo_base_url()

    origin =
      case {String.trim(form["region"] || ""), socket.assigns[:theater_here]} do
        {"", {lat, lon}} -> {lat, lon}
        {"", _none} -> nil
        {region, _here} -> region
      end

    with true <- base != nil,
         true <- origin != nil,
         {minutes, ""} <- Integer.parse(form["minutes"] || ""),
         true <- minutes in TheaterFinder.minutes_choices(),
         backend when is_binary(backend) and backend != "" <- form["backend"] do
      started =
        Chidori.SingleFlight.start(:theater_search, fn ->
          AskStore.started(:theater_search, form)
          AskStore.finished(:theater_search, TheaterFinder.ask(base, backend, origin, minutes))
        end)

      case started do
        {:ok, _pid} -> assign(socket, theater_search: :loading, theater_form: form)
        {:error, :busy} -> assign(socket, theater_search: {:error, :busy}, theater_form: form)
      end
    else
      _invalid ->
        reason = if origin == nil, do: :no_origin, else: :bad_request
        assign(socket, theater_search: {:error, reason}, theater_form: form)
    end
  end

  @doc """
  お気に入りの館で調べ始めます。**重ねて押しても 1 本**（押すたびに AI の枠を使う）。
  """
  def ask(socket, params) do
    form = Map.take(params, ["title", "date", "from", "backend"])
    base = News.chiezo_base_url()
    favorites = socket.assigns.theater_favorites

    with true <- base != nil and favorites != [],
         title when is_binary(title) and title != "" <- form["title"],
         {:ok, date} <- Date.from_iso8601(form["date"] || ""),
         {:ok, from} <- Setting.parse(form["from"] || ""),
         backend when is_binary(backend) and backend != "" <- form["backend"] do
      started =
        Chidori.SingleFlight.start(:showtimes, fn ->
          AskStore.started(:showtimes, form)

          result =
            with {:ok, found} <- Showtimes.ask(base, backend, title, favorites, date, from) do
              {:ok,
               Map.merge(found, %{
                 title: title,
                 date: Date.to_iso8601(date),
                 from: Setting.format(from),
                 # 館の名前 → 最寄り駅の一言（答えの表で、どこの館かを添える）
                 stations: Map.new(favorites, &{&1.name, Theaters.station_label(&1)})
               })}
            end

          AskStore.finished(:showtimes, result)
        end)

      case started do
        {:ok, _pid} -> assign(socket, showtimes: :loading, showtime_form: form)
        {:error, :busy} -> assign(socket, showtimes: {:error, :busy}, showtime_form: form)
      end
    else
      _invalid -> assign(socket, showtimes: {:error, :bad_request}, showtime_form: form)
    end
  end
end
