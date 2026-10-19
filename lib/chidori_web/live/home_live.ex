defmodule ChidoriWeb.HomeLive do
  @moduledoc """
  トップページ。**設定ページで選んだ枠をタブで並べ、最初の枠を開いた状態で出します**
  （`Chidori.Home`）。

  - 書き手ごとの要約 —— 要約を別の収集から読む話題（市況ニュース）。書き手ごとに最新の 1 本
  - 話題の要約 —— その話題のいちばん新しい要約を全文で。**右上のアイコンで全画面に
    開き、左右のスワイプで前後の要約へ**（最新情報の画面と同じ部品）
  - 興味トピックの要約 —— 同じ話題を、選んだ興味トピックに絞って書いたもの
  - 関連図 —— 関連図の画面をそのまま埋め込む（操作も同じ）
  - 技術書 —— 本棚の上位の数冊（`ChidoriWeb.TopBooks`）。**押すとその本を勧めている
    記事をたどれる**（札の下に開く）
  - これからの注目イベント —— 注目度が高いもの（話題によっては中も）で、これから 2 か月のもの

  **枠の中を左右に払うと、隣のタブへ移ります**（`PanelSwipe`）。
  """

  use ChidoriWeb, :live_view

  alias Chidori.Datasets.Bookshelf
  alias Chidori.Home
  alias Chidori.Jst
  alias Chidori.News
  alias Chidori.News.Events
  alias Chidori.Topics
  alias ChidoriWeb.NewsLive
  alias ChidoriWeb.WorkModal

  # 注目イベントを先まで見る月数。**並べる注目度は話題ごとに絞る**ので、数では切らない
  # （技術イベントで中まで入れていた頃は、20 件の上限で 1 か月先あたりまでしか見えなかった）
  @events_months 2

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "トップ",
       panels: Home.selected(),
       news: nil,
       books: nil,
       # 本に付けた「読んだ」印とメモ（`Chidori.Datasets.BookMarks`。読んだ本は上位の枠から外す）
       book_marks: %{},
       book_mark_saved: nil,
       events: nil,
       # 書き手ごとの要約（市況ニュース。`Chidori.News.AiDigests`）
       ai_digests: nil,
       # 詳細を開いている本（書名の見出し。`本:<書名>`。`ChidoriWeb.BookModal`）と、
       # それを勧めている記事
       opened_book: nil,
       book_posts: nil,
       # 全画面で開いている要約（`ChidoriWeb.NewsLive.digest_viewer/1`）
       digest_open: nil,
       digest_section: nil,
       digest_full: %{},
       # 要約から開いた作品（`ChidoriWeb.WorkModal`）と、その話題の「見た」印
       # （作品を開いたときに読む。枠を移ったら読み直す）
       opened_work: nil,
       work_marks: nil,
       work_mark_saved: nil,
       # 作品を育てる話題（映画・アニメ）の要約の枠に並べる、公開中・放送中の注目作
       works: nil
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
     |> assign(
       panel: panel,
       digest_open: nil,
       digest_section: nil,
       digest_full: %{},
       opened_work: nil,
       work_marks: nil,
       work_mark_saved: nil,
       works: nil
     )
     |> load(panel)
     # 作品の詳細から上映スケジュールを調べられるように（映画の要約の枠だけ。`ChidoriWeb.ShowtimeAsk`）
     |> ChidoriWeb.ShowtimeAsk.init(movies_panel?(panel))}
  end

  defp subscribe(%{kind: kind, topic: topic}) when kind in [:topic, :interest] do
    News.subscribe(topic.collection)
    News.refresh(News.server(topic.collection))
  end

  defp subscribe(_panel), do: :ok

  defp unsubscribe(%{kind: kind, topic: topic}) when kind in [:topic, :interest],
    do: News.unsubscribe(topic.collection)

  defp unsubscribe(_panel), do: :ok

  defp load(socket, %{kind: kind, topic: topic}) when kind in [:topic, :interest] do
    socket
    |> assign(news: News.current(News.server(topic.collection)))
    |> load_works(kind, topic)
  end

  defp load(socket, %{kind: :books}) do
    socket = assign(socket, book_marks: Chidori.Datasets.BookMarks.all())

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

  # 出す注目度のものだけをタグで引く（溜まっている全部は読みに行かない）
  defp load(socket, %{kind: :events, topic: topic}) do
    case News.chiezo_base_url() do
      nil ->
        assign(socket, events: {:error, :chiezo_not_configured})

      base ->
        if connected?(socket) do
          tags = Enum.map_join(Topics.home_attention(topic), ",", &Events.attention_tag/1)

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

  # 要約を別の収集から読む話題（市況ニュース）。書き手ごとに最新の 1 本
  defp load(socket, %{kind: :ai_digests, topic: topic}) do
    case News.chiezo_base_url() do
      nil ->
        assign(socket, ai_digests: {:error, :chiezo_not_configured})

      base ->
        if connected?(socket) do
          source = Topics.digest_from(topic)

          socket
          |> assign(ai_digests: :loading)
          |> start_async(:ai_digests, fn -> Chidori.News.AiDigests.latest(base, source) end)
        else
          assign(socket, ai_digests: :loading)
        end
    end
  end

  defp load(socket, _panel), do: socket

  # **作品を育てる話題の要約の枠には、公開中（放送中）の注目作も並べる**（映画・アニメ）。
  # 要約は 1 日 1 本なので、いま観られる作品の顔ぶれは要約だけでは見渡せない。
  # 注目度が中以上のものだけをタグで引く（最新情報の画面の注目作と同じ）
  defp load_works(socket, :topic, topic) do
    base = News.chiezo_base_url()
    works = Topics.works(topic)

    if connected?(socket) and works != nil and base do
      tags = Enum.map_join([:high, :mid], ",", &Events.attention_tag/1)

      socket
      # **見た印も読む**（一覧の見出しの横に「見た」を出す。作品の詳細の記録の欄もこれを使う）
      |> assign(works: :loading, work_marks: work_marks_of(works))
      |> start_async(:works, fn ->
        Events.fetch_tagged(base, topic.collection, tags,
          date_tag: Topics.date_tag(topic),
          body: true
        )
      end)
    else
      socket
    end
  end

  defp load_works(socket, _kind, _topic), do: socket

  defp work_marks_of(works) do
    if function_exported?(works, :mark_view, 0),
      do: Chidori.Relations.Marks.for_view(works.mark_view()),
      else: nil
  end

  defp movies_panel?(%{kind: :topic, topic: topic}),
    do: Topics.works(topic) == Chidori.News.Movies

  defp movies_panel?(_panel), do: false

  @doc """
  要約の枠に並べる、始まっている注目作（映画なら公開中、アニメなら放送中）と、その見出し。
  最新情報の画面の注目作と同じ分け方（`ChidoriWeb.NewsLive.works_groups/3`）の先頭の組。
  始まっているものが無ければ nil。
  """
  def started_works({:ok, entries}, topic) do
    works = Topics.works(topic)
    {started, _upcoming} = works.group_labels()

    case NewsLive.works_groups(entries, Jst.today(), works) do
      [{^started, list} | _rest] -> {started, list}
      _other -> nil
    end
  end

  def started_works(_works, _topic), do: nil

  @doc """
  見た作品（見た印の付いた記録）。**見た日の新しい順**、日付の無いものはその後ろに名前順。
  印がまだ読めていなければ空。
  """
  def seen_works(marks) when is_map(marks) do
    {dated, undated} =
      marks
      |> Map.values()
      |> Enum.filter(& &1.seen)
      |> Enum.split_with(&match?(%Date{}, &1.seen_on))

    Enum.sort_by(dated, & &1.seen_on, {:desc, Date}) ++ Enum.sort_by(undated, & &1.node_name)
  end

  def seen_works(_marks), do: []

  @doc "見た作品の組の見出し（映画なら「見た映画」）。"
  def seen_label(topic) do
    if Topics.works(topic) == Chidori.News.Movies, do: "見た映画", else: "見た作品"
  end

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
  これからの注目イベント。**`levels` の注目度のもの**（既定は高だけ。
  `Chidori.Topics.home_attention/1`）を、**今日から #{@events_months} か月先まで**、
  開催日の近い順に。
  """
  def upcoming(entries, levels \\ [:high], today \\ Jst.today()) do
    until = Date.shift(today, month: @events_months)

    entries
    |> Enum.filter(&(&1.attention in levels))
    |> Enum.filter(&(Date.compare(&1.date, today) != :lt and Date.compare(&1.date, until) != :gt))
    # 同じ日のものは注目度の高い順（中も並べる話題で、高が中の後ろに埋もれないように）
    |> Events.sort()
    |> Enum.sort_by(&Date.to_gregorian_days(&1.date))
  end

  @impl true
  def handle_async(:books, {:ok, result}, socket), do: {:noreply, assign(socket, books: result)}

  def handle_async(:books, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, books: {:error, :chiezo_unavailable})}

  def handle_async(:events, {:ok, result}, socket), do: {:noreply, assign(socket, events: result)}

  def handle_async(:works, {:ok, result}, socket), do: {:noreply, assign(socket, works: result)}

  def handle_async(:showtime_backends, result, socket),
    do: {:noreply, ChidoriWeb.ShowtimeAsk.backends_loaded(socket, result)}

  def handle_async(:works, {:exit, _reason}, socket), do: {:noreply, assign(socket, works: nil)}

  # 要約から開いた作品（開いている作品の答えだけ受け取る）
  def handle_async({:work, title}, result, socket),
    do: {:noreply, WorkModal.loaded(socket, title, result)}

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

  def handle_async(:ai_digests, {:ok, result}, socket),
    do: {:noreply, assign(socket, ai_digests: result)}

  def handle_async(:ai_digests, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, ai_digests: {:error, :chiezo_unavailable})}

  @impl true
  # **要約を全画面で読む**（最新情報の画面と同じ動き）。目次の項目から開いたときは、その章から
  def handle_event("open_digest", %{"index" => index} = params, socket) do
    section = if params["section"], do: to_index(params["section"])
    {:noreply, socket |> show_digest(to_index(index)) |> assign(digest_section: section)}
  end

  # **要約が紹介した作品を押すと詳細を開く**（最新情報の画面と同じもの）。
  # トップページは作品の一覧を持たないので、Chiezo から 1 件引く
  def handle_event("open_work", %{"title" => title}, socket) do
    topic = socket.assigns.panel && socket.assigns.panel[:topic]

    entries =
      case socket.assigns.works do
        {:ok, list} -> list
        _other -> []
      end

    {:noreply, WorkModal.open(socket, title, topic, entries)}
  end

  def handle_event("close_work", _params, socket), do: {:noreply, WorkModal.close(socket)}

  # 作品の詳細から上映スケジュールを調べる（`ChidoriWeb.ShowtimeAsk`）
  def handle_event("ask_showtimes", params, socket),
    do: {:noreply, ChidoriWeb.ShowtimeAsk.ask(socket, params)}

  def handle_event("save_work_mark", params, socket) do
    topic = socket.assigns.panel && socket.assigns.panel[:topic]
    {:noreply, WorkModal.save_mark(socket, topic, params)}
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

  # 本を押すと詳細（`ChidoriWeb.BookModal`）を開く。勧めている記事は開いたときに引く
  def handle_event("open_book", %{"title" => title}, socket) do
    socket = assign(socket, opened_book: title, book_mark_saved: nil)

    case News.chiezo_base_url() do
      nil ->
        {:noreply, assign(socket, book_posts: {:error, :chiezo_not_configured})}

      base ->
        {:noreply,
         socket
         |> assign(book_posts: :loading)
         |> start_async({:book_posts, title}, fn ->
           Chidori.Datasets.Books.recommending(base, title)
         end)}
    end
  end

  def handle_event("close_book", _params, socket),
    do: {:noreply, assign(socket, opened_book: nil, book_posts: nil, book_mark_saved: nil)}

  # 「読んだ」印とメモを書く（技術書の画面と同じ）。**空にしたら消える**。
  # 読んだ本は上位の枠から外れるが、詳細は開いたままにする（保存したことを見せる）
  def handle_event("save_book_mark", %{"title" => title} = params, socket) do
    case Chidori.Datasets.BookMarks.put(title, ChidoriWeb.BookModal.mark_attrs(params)) do
      {:ok, mark} ->
        marks =
          if mark,
            do: Map.put(socket.assigns.book_marks, title, mark),
            else: Map.delete(socket.assigns.book_marks, title)

        {:noreply, assign(socket, book_marks: marks, book_mark_saved: title)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "読んだ記録を保存できませんでした。")}
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

  # 上映スケジュールの答え（ほかの画面で頼んだものも届く）
  def handle_info({:showtimes, state}, socket),
    do: {:noreply, ChidoriWeb.ShowtimeAsk.received(socket, state)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @doc "詳細を開いている本（本棚に無くなっていれば nil）。"
  def opened_book(%{opened_book: title, books: {:ok, books}}) when is_binary(title),
    do: Enum.find(books, &(&1.title == title))

  def opened_book(_assigns), do: nil
end
