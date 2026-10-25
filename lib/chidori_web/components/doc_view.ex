defmodule ChidoriWeb.DocView do
  @moduledoc """
  1 件の**いまの中身**（本文・タグ・脇書き）を Chiezo から読んで、画面の上に重ねて開く
  （空いている欄を埋める口の「選んだ欄が空いているもの」の名前を押したとき）。
  何が空いているかの一覧だけでは、ほかの欄に何が入っているのか・本文に書いてあるのかが
  分からないので、その場で 1 件を引く。Chiezo の管理画面へは飛ばさない。

  1 画面に 1 つ置き（`id="doc-view"`）、名前のボタンは `phx-target="#doc-view"` で
  ここへ届ける（`ChidoriWeb.DocDiff` と同じ形）。開いている 1 件と読んだ結果はこの部品が持つ。
  """

  use Phoenix.LiveComponent

  alias Chidori.Chiezo
  alias ChidoriWeb.Collect

  # 脇書きのうち出さないもの（直す前の控え。大きく、いまの中身ではない）
  @hidden_extra ~w(before)

  @impl true
  def mount(socket), do: {:ok, assign(socket, opened: nil, doc: nil)}

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("open", %{"collection" => name, "title" => title}, socket) do
    case Chidori.News.chiezo_base_url() do
      base when is_binary(base) ->
        {:noreply,
         socket
         |> assign(opened: {name, title}, doc: :loading)
         |> start_async(:doc, fn ->
           {{name, title}, Chiezo.doc(base, name, title, "title,tags,extra,body")}
         end)}

      _none ->
        {:noreply, assign(socket, opened: {name, title}, doc: {:error, :chiezo_not_configured})}
    end
  end

  def handle_event("close", _params, socket),
    do: {:noreply, assign(socket, opened: nil, doc: nil)}

  # 押した 1 件の答えだけ受け取る（続けて押すと、前の 1 件の答えが後から届く）
  @impl true
  def handle_async(:doc, {:ok, {key, result}}, socket) do
    if socket.assigns.opened == key,
      do: {:noreply, assign(socket, doc: result)},
      else: {:noreply, socket}
  end

  def handle_async(:doc, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, doc: {:error, :collection_crashed})}

  @doc "脇書きを並べる形（`[{鍵, 見せる値}]`。鍵の順。入れ子は JSON で 1 行に）。"
  def extra_rows(extra) when is_map(extra) do
    for {key, value} <- Enum.sort_by(extra, &elem(&1, 0)),
        key not in @hidden_extra,
        do: {key, show(value)}
  end

  def extra_rows(_extra), do: []

  defp show(value) when is_binary(value), do: value
  defp show(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp show(value), do: to_string(value)

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={@opened}
        class="artwork-backdrop"
        phx-window-keydown="close"
        phx-key="Escape"
        phx-target={@myself}
      >
        <section
          class="artwork doc-diff-detail"
          role="dialog"
          aria-modal="true"
          aria-labelledby="doc-view-title"
          phx-click-away="close"
          phx-target={@myself}
        >
          <div class="artwork-head">
            <strong id="doc-view-title">{elem(@opened, 1)}</strong>
            <button type="button" phx-click="close" phx-target={@myself}>閉じる</button>
          </div>
          <%= case @doc do %>
            <% :loading -> %>
              <p class="muted-note">Chiezo から読んでいます…</p>
            <% {:error, :not_found} -> %>
              <p class="muted-note">Chiezo に見当たりませんでした（消えたか、見出しが変わったのかもしれません）。</p>
            <% {:error, reason} -> %>
              <p class="muted-note">読めませんでした（{Collect.reason_text(reason)}）</p>
            <% {:ok, doc} -> %>
              <p class="muted-note">Chiezo にいま入っている中身です。</p>
              <p :if={(doc["tags"] || []) != []}>
                <strong>タグ</strong>: {Enum.join(doc["tags"], "、")}
              </p>
              <div :if={extra_rows(doc["extra"]) != []}>
                <p><strong>脇書き</strong></p>
                <ul class="doc-diff-extra">
                  <li :for={{key, value} <- extra_rows(doc["extra"])}>
                    <strong>{key}</strong>: {value}
                  </li>
                </ul>
              </div>
              <p :if={doc["body"] in [nil, ""]} class="muted-note">本文はありません。</p>
              <pre :if={doc["body"] not in [nil, ""]} class="doc-diff-body">{doc["body"]}</pre>
          <% end %>
        </section>
      </div>
    </div>
    """
  end
end
