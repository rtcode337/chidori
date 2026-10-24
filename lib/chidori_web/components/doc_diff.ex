defmodule ChidoriWeb.DocDiff do
  @moduledoc """
  最近の回・依頼の結果に並ぶ見出しを押したときの、**その 1 件がどう書き換わったか**
  （Chiezo の `GET /v1/collect/{name}/diff`）。Chiezo の管理画面へ飛ばさず、Chidori の
  画面の上に重ねて開く。

  1 画面に 1 つ置き（`id="doc-diff"`）、見出しのボタンは `phx-target="#doc-diff"` で
  ここへ届ける（`ChidoriWeb.RecentRuns.change_lists/1`）。開いている 1 件と読んだ結果は
  この部品が持つ —— 置く画面が開閉の状態を抱えずに済む。
  """

  use Phoenix.LiveComponent

  alias Chidori.Chiezo
  alias ChidoriWeb.Collect

  @impl true
  def mount(socket), do: {:ok, assign(socket, opened: nil, diff: nil)}

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("open", %{"collection" => name, "title" => title}, socket) do
    case Chidori.News.chiezo_base_url() do
      base when is_binary(base) ->
        {:noreply,
         socket
         |> assign(opened: {name, title}, diff: :loading)
         |> start_async(:diff, fn -> {{name, title}, Chiezo.doc_diff(base, name, title)} end)}

      _none ->
        {:noreply, assign(socket, opened: {name, title}, diff: {:error, :chiezo_not_configured})}
    end
  end

  def handle_event("close", _params, socket),
    do: {:noreply, assign(socket, opened: nil, diff: nil)}

  # **押した 1 件の答えだけ受け取る**（続けて押すと、前の 1 件の答えが後から届く）
  @impl true
  def handle_async(:diff, {:ok, {key, result}}, socket) do
    if socket.assigns.opened == key,
      do: {:noreply, assign(socket, diff: result)},
      else: {:noreply, socket}
  end

  def handle_async(:diff, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, diff: {:error, :collection_crashed})}

  @doc "何が起きたかの一言（`what`）。"
  def what_text("rewritten", by) when by not in [nil, ""], do: "「#{by}」が書き換えたもの"
  def what_text("rewritten", _by), do: "直近の回が書き換えたもの"
  def what_text("added", _by), do: "足されたもの（1 つ前の世代にはありませんでした）"
  def what_text("removed", _by), do: "消えたもの（いまの世代にはありません）"

  def what_text("unchanged", _by),
    do: "中身は変わっていません（直した回に名前が挙がっていても、本文もタグも同じなら書き換わっていない）"

  def what_text("changed", _by), do: "書き換わったもの"

  def what_text(_what, _by),
    do: "この見出しは、いまの世代にも 1 つ前の世代にもありません（比べられるのは 1 つ前の世代までです）。"

  @doc "何と何を比べたか。**必ず出す** —— 世代の差分をその回の変更として読まれないように。"
  def compared_text(%{"compared" => "kept", "changed_by" => by}) when by not in [nil, ""],
    do: "この 1 件が控えている「#{by}」が直す前の中身との比較（控えは 1 回分だけで、次に同じ 1 件が動くと入れ替わります）"

  def compared_text(%{"compared" => "kept"}),
    do: "この 1 件が控えている直す前の中身との比較（控えは 1 回分だけです）"

  def compared_text(%{"before_stamp" => before, "now_stamp" => now}) when before not in [nil, ""],
    do: "1 つ前（#{stamp(before)}）→ いま（#{stamp(now)}）の世代の比較"

  def compared_text(%{"now_stamp" => now}),
    do: "いまの世代（#{stamp(now)}）だけ。1 つ前の世代はまだありません"

  # 世代の日付（`YYYYMMDDHHMMSS`。UTC）を JST の読める形に
  defp stamp(<<y::binary-4, m::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2>>) do
    case NaiveDateTime.from_iso8601("#{y}-#{m}-#{d}T#{h}:#{mi}:#{s}") do
      {:ok, at} -> at |> DateTime.from_naive!("Etc/UTC") |> Chidori.Jst.format()
      _error -> "#{y}-#{m}-#{d} #{h}:#{mi}"
    end
  end

  defp stamp(other), do: to_string(other)

  @doc "本文の差分の 1 行の印（足した・消した・区切り）。"
  def line_class("+" <> _rest), do: "added"
  def line_class("-" <> _rest), do: "removed"
  def line_class("@@" <> _rest), do: "muted-note"
  def line_class(_line), do: nil

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
          aria-labelledby="doc-diff-title"
          phx-click-away="close"
          phx-target={@myself}
        >
          <div class="artwork-head">
            <strong id="doc-diff-title">{elem(@opened, 1)} の変更</strong>
            <button type="button" phx-click="close" phx-target={@myself}>閉じる</button>
          </div>
          <%= case @diff do %>
            <% :loading -> %>
              <p class="muted-note">Chiezo から読んでいます…</p>
            <% {:error, reason} -> %>
              <p class="muted-note">読めませんでした（{Collect.reason_text(reason)}）</p>
            <% {:ok, diff} -> %>
              <p><strong>{what_text(diff["what"], diff["changed_by"])}</strong></p>
              <p :if={diff["what"] != "missing"} class="muted-note">{compared_text(diff)}</p>
              <p :if={diff["tags_added"] != [] or diff["tags_removed"] != []}>
                <span :if={diff["tags_added"] != []}>
                  <strong>足したタグ</strong>: {Enum.join(diff["tags_added"], "、")}
                </span>
                <br :if={diff["tags_added"] != [] and diff["tags_removed"] != []} />
                <span :if={diff["tags_removed"] != []} class="removed">
                  <strong>外したタグ</strong>: {Enum.join(diff["tags_removed"], "、")}
                </span>
              </p>
              <div :if={diff["extra"] != []}>
                <p>脇書きの変化</p>
                <ul class="doc-diff-extra">
                  <li :for={row <- diff["extra"]}>
                    <strong>{row["key"]}</strong>:
                    <%= cond do %>
                      <% row["before"] == nil -> %>
                        {row["after"]}
                      <% row["after"] == nil -> %>
                        <span class="removed">{row["before"]}（落ちた）</span>
                      <% true -> %>
                        {row["before"]} → {row["after"]}
                    <% end %>
                  </li>
                </ul>
              </div>
              <pre :if={diff["body_diff"] != []} class="doc-diff-body"><span
                  :for={line <- diff["body_diff"]}
                  class={line_class(line)}
                >{line}
    </span></pre>
              <pre :if={diff["body_full"] not in [nil, ""]} class="doc-diff-body">{diff["body_full"]}</pre>
          <% end %>
        </section>
      </div>
    </div>
    """
  end
end
