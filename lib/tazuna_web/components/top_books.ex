defmodule TazunaWeb.TopBooks do
  @moduledoc """
  本棚の**上位の数冊**だけを並べる枠。技術書の画面の頭と、トップページで使います。

  本棚ぜんたいは何百冊にもなるので、「いま何が勧められているか」を一目で見るには
  長すぎます —— 勧めている記事の多い順に数冊だけ出し、続きは技術書の画面で読みます。
  **1 冊 1 行で縦に並べます。** 何列かの札に並べていた頃は、順位が左右と上下の
  どちらに進むのかが読みにくかった —— 上から順に読めば順位どおりになるようにする。
  """

  use Phoenix.Component

  # 並べる数。**切りのいい数にする**（8 冊だと、何の区切りなのかが読めない）
  @count 10

  @doc "並べる数。"
  def count, do: @count

  attr :books, :list, required: true
  attr :more_href, :string, default: nil

  # **読んだ本は並べない**（`Tazuna.Datasets.BookMarks.read_titles/0`。本の見出しの集まり）。
  # この枠は次に何を読むかを決めるためのもので、読み終えた本が残ると押し出される
  attr :read, :any, default: MapSet.new()

  # **押すとその本を勧めている記事をたどれる**（画面が受ける event の名前。`title` を渡す）。
  # 書名のリンクは本の頁へ行くので、たどる口は札そのものに置く
  attr :open_event, :string, default: nil
  # いま開いている本（札に印を付ける）と、その本を勧めている記事
  # （nil / :loading / {:ok, 記事} / {:error, 理由}）。**開いた札の中に出す**
  attr :opened, :string, default: nil
  attr :posts, :any, default: nil

  def top_books(assigns) do
    unread = Enum.reject(assigns.books, &MapSet.member?(assigns.read, &1.title))
    assigns = assign(assigns, shown: Enum.with_index(Enum.take(unread, @count), 1))

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
        <%!-- 表紙の無い本は 404 が返る。**壊れた画像の印を出さず、枠だけ残す**。
             **表紙を押したときは書名と同じく本の頁へ**（札を開くのは札のほうの口。
             表紙は本そのものに見えるので、押して記事の一覧が開くと戸惑う） --%>
        <a
          :if={book.page_url}
          href={book.page_url}
          target="_blank"
          rel="noreferrer"
          class={["top-book-cover", !book.cover_url && "is-empty"]}
          aria-label={"#{book.name}の頁を開く"}
          onclick="event.stopPropagation()"
        >
          <img
            :if={book.cover_url}
            src={book.cover_url}
            alt=""
            loading="lazy"
            onerror="this.classList.add('is-missing')"
          />
        </a>
        <div :if={!book.page_url} class={["top-book-cover", !book.cover_url && "is-empty"]}>
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
            <%!-- **順位は書名の左に文字で出す**（丸い印にすると未読の数のように見え、
                 表紙の左に欄を取ると、その下が空いたままになる） --%>
            <span class="top-book-rank">{rank}位</span>
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

          <%!-- 勧めている記事。**押した札の中に開く**（札の下に離して出すと、どの本の
               記事なのかを目で行き来して確かめることになる）。記事のリンクは札を
               閉じないよう、押しても札まで伝えない --%>
          <div
            :if={@opened == book.title}
            class="top-book-posts"
            aria-label="勧めている記事"
            onclick="event.stopPropagation()"
          >
            <p :if={@posts in [nil, :loading]} class="muted-note">読み込んでいます…</p>
            <p :if={match?({:error, _}, @posts)} class="muted-note">記事を読めませんでした。</p>
            <%= if match?({:ok, _}, @posts) do %>
              <% {:ok, posts} = @posts %>
              <p :if={posts == []} class="muted-note">勧めている記事が見つかりませんでした。</p>
              <ol :if={posts != []} class="book-posts">
                <li :for={post <- posts}>
                  <a
                    :if={post.url}
                    href={post.url}
                    target="_blank"
                    rel="noreferrer"
                    onclick="event.stopPropagation()"
                  >
                    {post.title}
                  </a>
                  <span :if={!post.url}>{post.title}</span>
                  <span :if={post.published_at != ""} class="muted-note">
                    {String.slice(post.published_at, 0, 10)}
                  </span>
                </li>
              </ol>
            <% end %>
            <p class="muted-note">札の上のほうをもう一度押すと閉じます。</p>
          </div>
        </div>
      </li>
    </ol>
    <p :if={@shown == []} class="muted-note">まだ本棚に本がありません。</p>
    <p :if={@more_href}><a href={@more_href}>本棚をぜんぶ見る</a></p>
    """
  end
end
