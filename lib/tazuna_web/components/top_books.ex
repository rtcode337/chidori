defmodule TazunaWeb.TopBooks do
  @moduledoc """
  本棚の**上位の数冊**だけを並べる枠。技術書の画面の頭と、トップページで使います。

  本棚ぜんたいは何百冊にもなるので、「いま何が勧められているか」を一目で見るには
  長すぎます —— 勧めている記事の多い順に数冊だけ出し、続きは技術書の画面で読みます。
  """

  use Phoenix.Component

  # 並べる数
  @count 8

  @doc "並べる数。"
  def count, do: @count

  attr :books, :list, required: true
  attr :more_href, :string, default: nil

  # **押すとその本を勧めている記事をたどれる**（画面が受ける event の名前。`title` を渡す）。
  # 書名のリンクは本の頁へ行くので、たどる口は札そのものに置く
  attr :open_event, :string, default: nil
  # いま開いている本（札に印を付ける）
  attr :opened, :string, default: nil

  def top_books(assigns) do
    assigns = assign(assigns, shown: Enum.with_index(Enum.take(assigns.books, @count), 1))

    ~H"""
    <ol class="top-books">
      <li
        :for={{book, rank} <- @shown}
        class={[
          "top-book",
          book.near != [] && "is-near",
          @open_event && "is-openable",
          @opened == book.title && "is-opened"
        ]}
        phx-click={@open_event}
        phx-value-title={book.title}
        role={@open_event && "button"}
        tabindex={@open_event && "0"}
        aria-label={@open_event && "#{book.name}を勧めている記事を見る"}
      >
        <span class="top-book-rank" aria-label={"#{rank} 位"}>{rank}</span>
        <%!-- 表紙の無い本は 404 が返る。**壊れた画像の印を出さず、枠だけ残す** --%>
        <div class={["top-book-cover", !book.cover_url && "is-empty"]}>
          <img
            :if={book.cover_url}
            src={book.cover_url}
            alt=""
            loading="lazy"
            onerror="this.classList.add('is-missing')"
          />
        </div>
        <div class="top-book-body">
          <p class="top-book-title">
            <a
              :if={book.page_url}
              href={book.page_url}
              target="_blank"
              rel="noreferrer"
              onclick="event.stopPropagation()"
            >
              {book.name}
            </a>
            <span :if={!book.page_url}>{book.name}</span>
            <span :if={book.classic} class="book-badge">定番</span>
          </p>
          <p class="top-book-score">
            記事 <strong>{book.docs}</strong>
            本が勧めている<span :if={book.recent > 0}>（直近 {book.recent} 本）</span>
          </p>
          <p :if={book.near != []} class="book-near">★ 興味: {Enum.join(book.near, "・")}</p>
          <p :if={book.fields != []} class="top-book-fields">
            <span :for={field <- book.fields} class="book-topic">{field}</span>
          </p>
          <%!-- **説明は 3 行まで**（上位の枠は一目で見比べるためのもの。全文は本棚で） --%>
          <p :if={book.note != ""} class="top-book-note">{book.note}</p>
        </div>
      </li>
    </ol>
    <p :if={@shown == []} class="muted-note">まだ本棚に本がありません。</p>
    <p :if={@more_href}><a href={@more_href}>本棚をぜんぶ見る</a></p>
    """
  end
end
