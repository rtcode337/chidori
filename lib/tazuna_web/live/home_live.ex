defmodule TazunaWeb.HomeLive do
  @moduledoc """
  トップページ。**設定ページで選んだ枠をタブで並べ、最初の枠を開いた状態で出します**
  （`Tazuna.Home`）。

  - 話題の要約 —— その話題のいちばん新しい要約を全文で。**右上のアイコンで全画面に
    開き、左右のスワイプで前後の要約へ**（最新情報の画面と同じ部品）
  - 興味トピックの要約 —— 同じ話題を、選んだ興味トピックに絞って書いたもの
  - 関連図 —— 関連図の画面をそのまま埋め込む（操作も同じ）
  - 技術書 —— 本棚の上位の数冊（`TazunaWeb.TopBooks`）。**押すとその本を勧めている
    記事をたどれる**（札の下に開く）
  - これからの注目イベント —— 注目度が中以上で、これから 2 か月のもの

  **枠の中を左右に払うと、隣のタブへ移ります**（`PanelSwipe`）。
  """

  use TazunaWeb, :live_view

  alias Tazuna.Datasets.Bookshelf
  alias Tazuna.Home
  alias Tazuna.Jst
  alias Tazuna.News
  alias Tazuna.News.Events
  alias Tazuna.Topics
  alias TazunaWeb.NewsLive

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
       # 読んだ本（上位の枠から外す。`Tazuna.Datasets.BookMarks`）
       read_books: MapSet.new(),
       events: nil,
       # 押した本（書名の見出し。`本:<書名>`）と、それを勧めている記事
       opened_book: nil,
       book_posts: nil,
       # 全画面で開いている要約（`TazunaWeb.NewsLive.digest_viewer/1`）
       digest_open: nil,
       digest_section: nil,
       digest_full: %{}
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

    {:noreply,
     socket
     |> assign(panel: panel, digest_open: nil, digest_section: nil, digest_full: %{})
     |> load(panel)}
  end

  defp subscribe(%{kind: kind, topic: topic}) when kind in [:topic, :interest] do
    News.subscribe(topic.collection)
    News.refresh(News.server(topic.collection))
  end

  defp subscribe(_panel), do: :ok

  defp unsubscribe(%{kind: kind, topic: topic}) when kind in [:topic, :interest],
    do: News.unsubscribe(topic.collection)

  defp unsubscribe(_panel), do: :ok

  defp load(socket, %{kind: kind, topic: topic}) when kind in [:topic, :interest],
    do: assign(socket, news: News.current(News.server(topic.collection)))

  defp load(socket, %{kind: :books}) do
    socket = assign(socket, read_books: Tazuna.Datasets.BookMarks.read_titles())

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

  @doc "全画面で行き来する並び（話題の要約なら `:main`、興味トピックの要約なら `:interest`）。"
  def digest_kind(%{kind: :interest}), do: :interest
  def digest_kind(_panel), do: :main

  # 開く要約を決め、**本文をまだ持っていなければ引きに行く**（先頭の 1 件は最初から持つ）
  defp show_digest(%{assigns: %{news: nil}} = socket, _index), do: socket

  defp show_digest(socket, index) do
    %{news: news, panel: panel, digest_full: full} = socket.assigns
    digests = NewsLive.digests_of(news, digest_kind(panel))

    if digests == [] do
      assign(socket, digest_open: nil)
    else
      index = index |> max(0) |> min(length(digests) - 1)
      digest = Enum.at(digests, index)
      socket = assign(socket, digest_open: index)

      if index == 0 or Map.has_key?(full, digest.title) do
        socket
      else
        collection = panel.topic.collection

        start_async(socket, {:digest, digest.title}, fn ->
          News.full_digest(collection, digest)
        end)
      end
    end
  end

  defp to_index(value) when is_integer(value), do: value

  defp to_index(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _other -> 0
    end
  end

  defp to_index(_value), do: 0

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

  def handle_async({:digest, title}, {:ok, digest}, socket),
    do: {:noreply, update(socket, :digest_full, &Map.put(&1, title, digest))}

  # 取り直せなければ、持っている頭だけで見せる
  def handle_async({:digest, _title}, _result, socket), do: {:noreply, socket}

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
  # **要約を全画面で読む**（最新情報の画面と同じ動き）。目次の項目から開いたときは、その章から
  def handle_event("open_digest", %{"index" => index} = params, socket) do
    section = if params["section"], do: to_index(params["section"])
    {:noreply, socket |> show_digest(to_index(index)) |> assign(digest_section: section)}
  end

  # 左右のスワイプ・矢印。**1 が古いほう**（要約は新しい順に並んでいる）
  def handle_event("digest_step", %{"by" => by}, socket) do
    case socket.assigns.digest_open do
      nil -> {:noreply, socket}
      at -> {:noreply, socket |> show_digest(at + to_index(by)) |> assign(digest_section: nil)}
    end
  end

  def handle_event("close_digest", _params, socket),
    do: {:noreply, assign(socket, digest_open: nil)}

  # ← で古いほう、→ で新しいほう、Esc で閉じる（開いている間だけ）
  def handle_event("digest_key", %{"key" => key}, socket) do
    case {socket.assigns.digest_open, key} do
      {nil, _key} ->
        {:noreply, socket}

      {_at, "Escape"} ->
        {:noreply, assign(socket, digest_open: nil)}

      {at, "ArrowLeft"} ->
        {:noreply, socket |> show_digest(at + 1) |> assign(digest_section: nil)}

      {at, "ArrowRight"} ->
        {:noreply, socket |> show_digest(at - 1) |> assign(digest_section: nil)}

      _other ->
        {:noreply, socket}
    end
  end

  # **枠の中を左右に払うと、隣のタブへ**（`PanelSwipe`）。左へ払う → 右隣（1）、
  # 右へ払う → 左隣（-1）。端より先へは回り込まない
  def handle_event("panel_step", %{"by" => by}, socket) do
    %{panels: panels, panel: panel} = socket.assigns
    at = Enum.find_index(panels, &(panel && &1.key == panel.key)) || 0
    to = at + to_index(by)

    case if(to >= 0, do: Enum.at(panels, to)) do
      nil -> {:noreply, socket}
      next -> {:noreply, push_patch(socket, to: ~p"/?panel=#{next.key}")}
    end
  end

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

  @impl true
  # **見ている話題の知らせだけ受け取る**（切り替えた直後に前の話題の結果が届くことがある）
  def handle_info({:news_updated, news}, socket) do
    case socket.assigns.panel do
      %{kind: kind, topic: %{collection: collection}}
      when kind in [:topic, :interest] and news.name == collection ->
        {:noreply, assign(socket, news: news)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
