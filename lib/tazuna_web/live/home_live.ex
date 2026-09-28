defmodule TazunaWeb.HomeLive do
  @moduledoc """
  トップページ。**設定ページで選んだ枠をタブで並べ、最初の枠を開いた状態で出します**
  （`Tazuna.Home`）。

  - 話題の要約 —— その話題のいちばん新しい要約を全文で
  - 関連図 —— 関連図の画面をそのまま埋め込む（操作も同じ）
  - 技術書 —— 本棚の上位の数冊（`TazunaWeb.TopBooks`）。**押すとその本を勧めている
    記事をたどれる**（札の下に開く）
  - これからの注目イベント —— 注目度が中以上で、これから 2 か月のもの
  """

  use TazunaWeb, :live_view

  alias Tazuna.Datasets.Bookshelf
  alias Tazuna.Home
  alias Tazuna.Jst
  alias Tazuna.News
  alias Tazuna.News.Events
  alias Tazuna.Topics

  # 注目イベントを先まで見る日数と、並べる数
  @events_days 60
  @events_max 20

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "トップ",
       panels: Home.selected(),
       news: nil,
       books: nil,
       events: nil,
       # 押した本（書名の見出し。`本:<書名>`）と、それを勧めている記事
       opened_book: nil,
       book_posts: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    panels = socket.assigns.panels
    panel = Enum.find(panels, &(&1.key == params["panel"])) || List.first(panels)

    if connected?(socket) do
      if previous = socket.assigns[:panel], do: unsubscribe(previous)
      if panel, do: subscribe(panel)
    end

    {:noreply, socket |> assign(panel: panel) |> load(panel)}
  end

  defp subscribe(%{kind: :topic, topic: topic}) do
    News.subscribe(topic.collection)
    News.refresh(News.server(topic.collection))
  end

  defp subscribe(_panel), do: :ok

  defp unsubscribe(%{kind: :topic, topic: topic}), do: News.unsubscribe(topic.collection)
  defp unsubscribe(_panel), do: :ok

  defp load(socket, %{kind: :topic, topic: topic}),
    do: assign(socket, news: News.current(News.server(topic.collection)))

  defp load(socket, %{kind: :books}) do
    case News.chiezo_base_url() do
      nil ->
        assign(socket, books: {:error, :chiezo_not_configured})

      base ->
        if connected?(socket) do
          socket
          |> assign(books: :loading)
          |> start_async(:books, fn -> Bookshelf.list(base) end)
        else
          assign(socket, books: :loading)
        end
    end
  end

  # 注目度が中以上だけをタグで引く（溜まっている全部は読みに行かない）
  defp load(socket, %{kind: :events, topic: topic}) do
    case News.chiezo_base_url() do
      nil ->
        assign(socket, events: {:error, :chiezo_not_configured})

      base ->
        if connected?(socket) do
          tags = Enum.map_join(["高", "中"], ",", &"#{Events.attention_tag()}:#{&1}")

          socket
          |> assign(events: :loading)
          |> start_async(:events, fn ->
            Events.fetch_tagged(base, topic.collection, tags, date_tag: Topics.date_tag(topic))
          end)
        else
          assign(socket, events: :loading)
        end
    end
  end

  defp load(socket, _panel), do: socket

  @doc """
  これからの注目イベント。**今日から #{@events_days} 日先まで**を、開催日の近い順に
  （同じ日なら注目度の高い順）#{@events_max} 件まで。
  """
  def upcoming(entries, today \\ Jst.today()) do
    until = Date.add(today, @events_days)

    entries
    |> Enum.filter(&(Date.compare(&1.date, today) != :lt and Date.compare(&1.date, until) != :gt))
    |> Enum.sort_by(
      &{Date.to_gregorian_days(&1.date), if(&1.attention == :high, do: 0, else: 1), &1.title}
    )
    |> Enum.take(@events_max)
  end

  @impl true
  def handle_async(:books, {:ok, result}, socket), do: {:noreply, assign(socket, books: result)}

  def handle_async(:books, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, books: {:error, :chiezo_unavailable})}

  def handle_async(:events, {:ok, result}, socket), do: {:noreply, assign(socket, events: result)}

  # **押した本の答えだけ受け取る**（続けて押すと、前の本の答えが後から届く）
  def handle_async({:book_posts, title}, result, socket) do
    if socket.assigns.opened_book == title do
      posts =
        case result do
          {:ok, {:ok, posts}} -> {:ok, posts}
          {:ok, {:error, reason}} -> {:error, reason}
          _exit -> {:error, :chiezo_unavailable}
        end

      {:noreply, assign(socket, book_posts: posts)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:events, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, events: {:error, :chiezo_unavailable})}

  @impl true
  # 本を押すと、その本を勧めている記事を開く。**同じ本をもう一度押すと閉じる**
  def handle_event("open_book", %{"title" => title}, socket) do
    cond do
      socket.assigns.opened_book == title ->
        {:noreply, assign(socket, opened_book: nil, book_posts: nil)}

      base = News.chiezo_base_url() ->
        {:noreply,
         socket
         |> assign(opened_book: title, book_posts: :loading)
         |> start_async({:book_posts, title}, fn ->
           Tazuna.Datasets.Books.recommending(base, title)
         end)}

      true ->
        {:noreply,
         assign(socket, opened_book: title, book_posts: {:error, :chiezo_not_configured})}
    end
  end

  @doc "書名（見出しの「本:」を落としたもの）。"
  def book_name(title),
    do:
      title |> String.replace_prefix(Tazuna.Datasets.Books.book_tag() <> ":", "") |> String.trim()

  @impl true
  # **見ている話題の知らせだけ受け取る**（切り替えた直後に前の話題の結果が届くことがある）
  def handle_info({:news_updated, news}, socket) do
    case socket.assigns.panel do
      %{kind: :topic, topic: %{collection: collection}} when news.name == collection ->
        {:noreply, assign(socket, news: news)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
