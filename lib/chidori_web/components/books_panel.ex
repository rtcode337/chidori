defmodule ChidoriWeb.BooksPanel do
  @moduledoc """
  趣味の「技術書」のタブに出す本棚（未読の上位 10 冊・畳んだ本棚の全冊・本の詳細）。

  **本の一覧は置く画面が読む**（趣味の画面の本棚の覚え書き。`books`）。読んだ印・詳細を
  開いている本・勧めている記事・「この本を調べ直してもらう」の状態は**この部品が持つ** ——
  置く画面に本の操作を抱えさせない。
  """

  use Phoenix.LiveComponent

  alias Chidori.Datasets.Bookshelf
  alias Chidori.Datasets.BookMarks
  alias ChidoriWeb.BookModal
  alias ChidoriWeb.BookshelfList

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       marks: BookMarks.all(),
       mark_saved: nil,
       near_only: false,
       opened: nil,
       posts: nil,
       asking: false,
       asked: nil
     )}
  end

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  # 本を押すと詳細（`ChidoriWeb.BookModal`）を開く。勧めている記事は開いたときに引く
  @impl true
  def handle_event("open_book", %{"title" => title}, socket) do
    socket = assign(socket, opened: title, mark_saved: nil, asked: nil)

    case Chidori.News.chiezo_base_url() do
      nil ->
        {:noreply, assign(socket, posts: {:error, :chiezo_not_configured})}

      base ->
        {:noreply,
         socket
         |> assign(posts: :loading)
         |> start_async({:posts, title}, fn ->
           Chidori.Datasets.Books.recommending(base, title)
         end)}
    end
  end

  def handle_event("close_book", _params, socket),
    do: {:noreply, assign(socket, opened: nil, posts: nil, mark_saved: nil, asked: nil)}

  # 本棚を興味トピックに近い本だけに絞る / 戻す
  def handle_event("toggle_shelf_near", _params, socket),
    do: {:noreply, assign(socket, near_only: !socket.assigns.near_only)}

  # 「読んだ」印とメモを書く。**空にしたら消える**。読んだ本は上位の枠から外れるが、
  # 詳細は開いたままにする（保存したことを見せる）
  def handle_event("save_book_mark", %{"title" => title} = params, socket) do
    case BookMarks.put(title, BookModal.mark_attrs(params)) do
      {:ok, mark} ->
        marks =
          if mark,
            do: Map.put(socket.assigns.marks, title, mark),
            else: Map.delete(socket.assigns.marks, title)

        {:noreply, assign(socket, marks: marks, mark_saved: title)}

      {:error, _changeset} ->
        {:noreply, assign(socket, asked: {:error, :mark_not_saved})}
    end
  end

  # **この本を詳しく調べて**、を本棚の整理の回へ割り込ませる（1 回だけ）。
  # 同じ本への頼みは 1 本だけ（続けて押しても AI の回を重ねない）
  def handle_event("ask_book", %{"title" => title} = params, socket) do
    key = {:ask_book, title}

    if Chidori.SingleFlight.busy?(key) do
      {:noreply, assign(socket, asked: {:error, :busy})}
    else
      {:noreply,
       socket
       |> assign(asking: true, asked: nil)
       |> start_async(:ask, fn ->
         Chidori.SingleFlight.run(key, fn ->
           with {:ok, base} <- Chidori.Datasets.base_url(),
                do: Bookshelf.focus_book(base, title, params["note"])
         end)
       end)}
    end
  end

  # **押した本の答えだけ受け取る**（続けて押すと、前の本の答えが後から届く）
  @impl true
  def handle_async({:posts, title}, result, socket) do
    if socket.assigns.opened == title do
      posts =
        case result do
          {:ok, {:ok, posts}} -> {:ok, posts}
          {:ok, {:error, reason}} -> {:error, reason}
          _exit -> {:error, :chiezo_unavailable}
        end

      {:noreply, assign(socket, posts: posts)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:ask, {:ok, result}, socket),
    do: {:noreply, assign(socket, asking: false, asked: result)}

  def handle_async(:ask, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, asking: false, asked: {:error, :collection_crashed})}

  @doc "本の詳細から頼んだ結果の一言。"
  def ask_message(:ok), do: "Chiezo に頼みました。定時の巡回とは別に 1 回だけ走ります。"
  def ask_message({:error, :mark_not_saved}), do: "読んだ記録を保存できませんでした。"
  def ask_message({:error, reason}), do: ChidoriWeb.Collect.reason_text(reason)
  def ask_message(_asked), do: nil

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        book: assigns.opened && Enum.find(assigns.books, &(&1.title == assigns.opened))
      )

    ~H"""
    <section id={@id} class="books-panel" aria-label="技術書">
      <h2>未読の上位 {ChidoriWeb.TopBooks.count()} 冊</h2>
      <%!-- 押すと本の詳細が開く。オライリーの本は札の印で見分ける --%>
      <ChidoriWeb.TopBooks.top_books
        books={@books}
        read={BookModal.read_titles(@marks)}
        open_event="open_book"
        target={@myself}
      />
      <%!-- **本棚（全冊）は畳んでおく**（何百冊にもなるので、上位の枠が一覧に埋もれない） --%>
      <BookshelfList.shelf books={@books} marks={@marks} near_only={@near_only} target={@myself} />

      <%!-- 本の詳細。読んだ記録と、その本を調べ直してもらう口はここで --%>
      <BookModal.book_modal
        :if={@book}
        book={@book}
        mark={BookModal.mark_of(@marks, @book.title)}
        saved={@mark_saved == @book.title}
        posts={@posts}
        target={@myself}
      >
        <BookshelfList.ask_form
          book={@book}
          asking={@asking}
          message={ask_message(@asked)}
          target={@myself}
        />
      </BookModal.book_modal>
    </section>
    """
  end
end
