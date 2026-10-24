defmodule ChidoriWeb.BookshelfList do
  @moduledoc """
  技術書の本棚（全冊の一覧）と、本の詳細から「この本を調べ直してもらう」口。
  トップページの「技術書」の枠で使う。

  **本棚は畳んでおく**（`<details>`）。何百冊にもなるので、開いた瞬間に並べると
  上の「未読の上位」の枠が一覧に埋もれる。押す画面ではなく、たまに見渡すためのもの。
  """

  use Phoenix.Component

  alias ChidoriWeb.BookModal

  attr :books, :list, required: true
  attr :marks, :map, required: true
  attr :near_only, :boolean, default: false

  def shelf(assigns) do
    near_count = Enum.count(assigns.books, &(&1.near != []))

    assigns =
      assign(assigns,
        near_count: near_count,
        shown:
          if(assigns.near_only,
            do: Enum.filter(assigns.books, &(&1.near != [])),
            else: assigns.books
          )
      )

    ~H"""
    <details id="bookshelf" class="bookshelf" aria-label="本棚">
      <summary>
        本棚 <span class="muted-note">（{length(@books)} 冊・おすすめ度の高い順）</span>
      </summary>
      <%!-- **興味トピックに近い本は強調する**（技術ニュースで選んだもの。言い換えと
           すぐ下の子も近いと数える）。絞り込みは押したときだけ --%>
      <p :if={@near_count > 0} class="shelf-near">
        <button
          type="button"
          class={["shelf-near-toggle", @near_only && "is-on"]}
          phx-click="toggle_shelf_near"
          aria-pressed={to_string(@near_only)}
        >
          ★ 興味トピックに近い本だけ（{@near_count} 冊）
        </button>
      </p>
      <p class="muted-note">
        おすすめ度は<strong>その本を勧めている記事の本数</strong>です（機械が数えたもの）。表紙は
        <a href="https://www.hanmoto.com/" target="_blank" rel="noreferrer">版元ドットコム</a>
        の書影です。
      </p>
      <ol class="book-list">
        <li
          :for={book <- @shown}
          class={[
            "book-card",
            book.near != [] && "is-near",
            BookModal.mark_of(@marks, book.title).read && "is-read"
          ]}
        >
          <%!-- **本を押すと詳細が開く**（ほかの画面の詳細と同じくモーダル）。
               表紙も押せる —— 目に入るのは表紙のほうが先 --%>
          <button
            type="button"
            class={["book-cover", !book.cover_url && "is-empty"]}
            phx-click="open_book"
            phx-value-title={book.title}
            aria-label={"#{book.name} の詳細を開く"}
          >
            <%!-- 表紙の無い本は 404 が返る。**壊れた画像の印を出さず、枠だけ残す** --%>
            <img
              :if={book.cover_url}
              src={book.cover_url}
              alt=""
              loading="lazy"
              onerror="this.classList.add('is-missing')"
            />
          </button>
          <div class="book-body">
            <p class="book-title">
              <button
                type="button"
                class="book-name"
                phx-click="open_book"
                phx-value-title={book.title}
              >
                {book.name}
              </button>
              <span :if={Map.get(book, :oreilly)} class="book-badge is-oreilly">オライリー</span>
              <%!-- **読んだ本は印で分かるように**（本棚には残す。上位の枠からは外す） --%>
              <span
                :if={BookModal.summary(BookModal.mark_of(@marks, book.title))}
                class="read-badge"
              >
                {BookModal.summary(BookModal.mark_of(@marks, book.title))}
              </span>
            </p>
            <p class="book-score">
              記事 {book.docs} 本が勧めている<span :if={book.recent > 0}>（直近 {book.recent} 本）</span>
            </p>
            <p :if={book.near != []} class="book-near">★ 興味: {Enum.join(book.near, "・")}</p>
            <p :if={book.fields != []} class="book-fields">{Enum.join(book.fields, "・")}</p>
            <p :if={book.topics != []} class="book-topics">
              <span :for={topic <- book.topics} class="book-topic">{topic}</span>
            </p>
            <p :if={book.note != ""} class="book-note">{book.note}</p>
          </div>
        </li>
      </ol>
    </details>
    """
  end

  attr :book, :map, required: true
  attr :asking, :boolean, default: false
  attr :message, :string, default: nil

  @doc """
  本の詳細の中に置く「この本を Chiezo に調べ直してもらう」口（本棚の整理の回への割り込み）。
  頼みごとは本を見ながら思いつくので、設定の欄に離して置くと、どの本の話か書き直すことになる。
  """
  def ask_form(assigns) do
    ~H"""
    <form id="book-ask" phx-submit="ask_book" class="article-ask">
      <input type="hidden" name="title" value={@book.title} />
      <label>
        この本を Chiezo に調べ直してもらう<br />
        <textarea
          name="note"
          rows="3"
          placeholder="例: 表紙が別の本になっている / 分野が違う / 第 2 版が出ている"
        ></textarea>
      </label>
      <p class="muted-note">
        本棚の収集（{Chidori.Datasets.Bookshelf.collection()}）の「整理」の回として、
        この本だけを 1 回調べ直します（分野・タグ・説明・ISBN を確かめ、違っていれば直す）。
        定時の巡回の進み具合にも次の予定にも触りません。書き添えたことは補足として渡します。
      </p>
      <div class="button-row">
        <button type="submit" disabled={@asking} phx-disable-with="頼んでいます…">
          Chiezo に頼む
        </button>
      </div>
      <p :if={@message} class="muted-note" aria-live="polite">{@message}</p>
    </form>
    """
  end
end
