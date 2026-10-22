defmodule ChidoriWeb.BookModal do
  @moduledoc """
  技術書 1 冊の詳細（モーダル）。技術書の画面（本棚と上位の枠）と、トップページの
  上位の枠から同じものを開きます。

  **中身は本の説明・読んだ記録・勧めている記事です。** 技術書の画面だけは、その下に
  「この本を Chiezo に調べ直してもらう」口を足します（中身の枠 `inner_block`）——
  本棚の収集の整理の回へ割り込ませる口で、収集を持っている画面でしか頼めないため。

  押したときの動き（`close_book` / `save_book_mark`）は置いた画面の側が受けます。
  """

  use ChidoriWeb, :html

  alias Chidori.Datasets.BookMark
  alias Chidori.Jst
  alias Chidori.SafeUrl

  attr :book, :map, required: true
  # その本の「読んだ」印（無ければ空の印。`mark_of/2`）
  attr :mark, BookMark, required: true
  # 保存した直後か（「保存しました。」を出す）
  attr :saved, :boolean, default: false
  # 勧めている記事（nil / :loading / {:ok, 記事} / {:error, 理由}）
  attr :posts, :any, default: nil
  slot :inner_block

  def book_modal(assigns) do
    ~H"""
    <div class="artwork-backdrop" phx-window-keydown="close_book" phx-key="Escape">
      <section
        class="artwork book-detail"
        role="dialog"
        aria-modal="true"
        aria-labelledby="book-detail-title"
        phx-click-away="close_book"
      >
        <div class="artwork-head">
          <strong id="book-detail-title">
            {@book.name}
            <span :if={Map.get(@book, :oreilly)} class="book-badge is-oreilly">オライリー</span>
          </strong>
          <button type="button" phx-click="close_book">閉じる</button>
        </div>
        <div class="book-detail-body">
          <span :if={@book.cover_url} class="book-detail-cover">
            <img src={@book.cover_url} alt="" onerror="this.classList.add('is-missing')" />
          </span>
          <div>
            <p class="book-score">
              記事 {@book.docs} 本が勧めている<span :if={@book.recent > 0}>（直近 {@book.recent} 本）</span>
            </p>
            <p :if={@book.near != []} class="book-near">★ 興味: {Enum.join(@book.near, "・")}</p>
            <p :if={@book.fields != []} class="book-fields">{Enum.join(@book.fields, "・")}</p>
            <p :if={Map.get(@book, :topics, []) != []} class="book-topics">
              <span :for={topic <- @book.topics} class="book-topic">{topic}</span>
            </p>
            <p :if={@book.note != ""} class="book-note">{@book.note}</p>
            <p :if={@book.page_url} class="muted-note">
              ISBN {@book.isbn}・<a href={@book.page_url} target="_blank" rel="noreferrer">版元ドットコムで見る ↗</a>
            </p>
            <p :if={!@book.page_url} class="muted-note">
              ISBN はまだ分かっていません（本棚の整理の回が調べると、表紙も出ます）。
            </p>
          </div>
        </div>

        <%!-- 読んだ記録（関連図の「見た記録」と同じ形）。置き場は Chiezo の chidori_data。
             **最初から開いておく** —— 畳んでいた頃は、記録を付ける欄がどこにあるのか分からなかった --%>
        <details class="seen-mark" open>
          <summary>
            読んだ記録 <span :if={summary(@mark)} class="seen-badge">{summary(@mark)}</span>
          </summary>
          <form id="book-mark" phx-submit="save_book_mark">
            <input type="hidden" name="title" value={@book.title} />
            <p class="seen-row">
              <label><input type="checkbox" name="read" checked={@mark.read} /> 読んだ</label>
              <label>読んだ日 <input type="date" name="read_on" value={read_on_value(@mark)} /></label>
            </p>
            <p>
              <label>
                メモ（感想・どこが役に立ったか）<br />
                <textarea
                  name="note"
                  rows="3"
                  placeholder="例: 3 章の命名の話はすぐ使えた。後半は飛ばし読み"
                >{@mark.note}</textarea>
              </label>
            </p>
            <p class="muted-note">
              ここに書いたことは Chidori の置き場（Chiezo の chidori_data）に残ります（収集には書きません）。読んだ本は「いま勧められている未読の上位」から外れます。
              <strong>印もメモも空にして保存すると、記録ごと消えます。</strong>
            </p>
            <button type="submit" phx-disable-with="保存しています…">記録を保存</button>
            <span :if={@saved} class="muted-note">保存しました。</span>
          </form>
        </details>

        <h3>勧めている記事</h3>
        <%= case @posts do %>
          <% {:ok, [_ | _] = posts} -> %>
            <ul class="book-posts">
              <li :for={post <- posts}>
                <a :if={post.url} href={SafeUrl.href(post.url)} target="_blank" rel="noreferrer">{post.title}</a>
                <span :if={!post.url}>{post.title}</span>
                <span :if={post.published_at != ""} class="muted-note">
                  {String.slice(post.published_at, 0, 10)}
                </span>
              </li>
            </ul>
          <% {:ok, []} -> %>
            <p class="muted-note">記事が見つかりませんでした。</p>
          <% {:error, reason} -> %>
            <p class="muted-note">{ChidoriWeb.Collect.reason_text(reason)}</p>
          <% _loading -> %>
            <p class="muted-note">記事を読んでいます…</p>
        <% end %>

        {render_slot(@inner_block)}
      </section>
    </div>
    """
  end

  @doc "読んだ本の見出し（上位の枠から外す）。"
  def read_titles(marks),
    do: for({title, %BookMark{read: true}} <- marks, into: MapSet.new(), do: title)

  @doc "その本の「読んだ」印。まだ無ければ空の印（フォームを 2 通り書かずに済ませる）。"
  def mark_of(marks, title), do: Map.get(marks, title) || %BookMark{}

  @doc "「読んだ日」の欄に最初から入れておく日付（書いてあればそれ、無ければ JST の今日）。"
  def read_on_value(%BookMark{read_on: %Date{} = date}), do: Date.to_iso8601(date)
  def read_on_value(_mark), do: Jst.today() |> Date.to_iso8601()

  @doc "印を 1 行で言う（本棚の一覧と詳細の見出しに出す）。"
  def summary(%BookMark{read: true, read_on: %Date{} = date}),
    do: "読んだ（#{Date.to_iso8601(date)}）"

  def summary(%BookMark{read: true}), do: "読んだ"
  def summary(%BookMark{note: note}) when is_binary(note) and note != "", do: "メモあり"
  def summary(_mark), do: nil

  @doc """
  フォームの値から印の属性を作ります（チェックが外れているとキーごと来ない —— HTML の
  チェックボックス）。
  """
  def mark_attrs(params) do
    %{
      "read" => params["read"] == "on",
      "read_on" => blank_to_nil(params["read_on"]),
      "note" => params["note"] || ""
    }
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
