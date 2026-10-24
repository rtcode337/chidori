defmodule ChidoriWeb.SeenFilms do
  @moduledoc """
  趣味の映画のタブの中の「見た映画」（`/news?view=chidori_movies&section=seen`）。見た映画の一覧と、
  見た映画を足す口（関連図の画面から移した）。

  見た記録は映画の話題と映画の図で同じ置き場（`Chidori.Relations.Marks` の `movies`）。
  **足した作品が映画の図にまだ無ければ、図の収集に足すよう頼む**（`FilmCarry.carry_now/2`。
  AI が監督・主演を調べて足すので、載るのは取り込みが終わってから）。図にもうある作品は
  記録を付けるだけで頼まない。一覧の作品を押すと、作品の詳細（`ChidoriWeb.WorkModal`。置く画面の
  `open_work`）が開く。
  """

  use Phoenix.LiveComponent

  alias Chidori.Jst
  alias Chidori.Relations.FilmCarry
  alias Chidori.Relations.Films
  alias Chidori.Relations.Marks

  @impl true
  def mount(socket),
    do:
      {:ok, assign(socket, marks: Marks.for_view(Films.mark_view()), message: nil, adding: false)}

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  # 見た映画を足す。**記録はその場で書き**、図に無ければ図へは AI に足させる
  @impl true
  def handle_event("add_film", params, socket) do
    title = String.trim(params["title"] || "")
    hint = params["hint"] || ""

    attrs = %{
      "seen" => true,
      "seen_on" => blank_to_nil(params["seen_on"]),
      "note" => params["note"] || ""
    }

    cond do
      title == "" ->
        {:noreply, socket}

      true ->
        case Marks.put(Films.mark_view(), title, attrs) do
          {:ok, _mark} ->
            {:noreply,
             socket
             |> assign(
               marks: Marks.for_view(Films.mark_view()),
               adding: true,
               message: "「#{title}」を記録しました。映画の図にあるか確かめています…"
             )
             |> start_async(:carry, fn -> {title, carry(title, hint)} end)}

          {:error, _changeset} ->
            {:noreply, assign(socket, message: "記録を保存できませんでした。")}
        end
    end
  end

  # 図にもうあれば頼まない（記録だけ）。無ければ図の収集に足すよう頼む
  defp carry(title, hint) do
    case Chidori.News.chiezo_base_url() do
      base when is_binary(base) ->
        case Chidori.Chiezo.doc(base, Films.collection(), title, "title") do
          {:ok, _doc} -> :already
          _missing -> FilmCarry.carry_now([title], hint)
        end

      _none ->
        {:error, :chiezo_not_configured}
    end
  end

  @impl true
  def handle_async(:carry, {:ok, {title, result}}, socket) do
    message =
      case result do
        :already ->
          "「#{title}」を記録しました（映画の図にもうあります）。"

        {:ok, _count} ->
          "「#{title}」を記録しました。映画の図に足すよう頼みました（取り込みが終わって図を取り直すと載ります）。"

        {:error, reason} ->
          "「#{title}」を記録しましたが、映画の図に足すよう頼めませんでした: " <>
            ChidoriWeb.Collect.reason_text(reason) <> "（あとで自動でもう一度頼みます）"
      end

    {:noreply, assign(socket, adding: false, message: message)}
  end

  def handle_async(:carry, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, adding: false, message: "映画の図に足すよう頼めませんでした。")}

  @doc "見た映画（見た日の新しい順。日付の無いものは後ろに名前順。見ていない記録は入れない）。"
  def seen(marks) when is_map(marks) do
    {dated, undated} =
      marks
      |> Map.values()
      |> Enum.filter(& &1.seen)
      |> Enum.split_with(&match?(%Date{}, &1.seen_on))

    Enum.sort_by(dated, & &1.seen_on, {:desc, Date}) ++ Enum.sort_by(undated, & &1.node_name)
  end

  def seen(_marks), do: []

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  @impl true
  def render(assigns) do
    assigns = assign(assigns, films: seen(assigns.marks))

    ~H"""
    <section id={@id} class="seen-films" aria-label="見た映画">
      <h2 class="news-section-title">見た映画（{length(@films)} 本）</h2>
      <p :if={@films == []} class="muted-note">まだありません。下の「見た映画を足す」で書けます。</p>
      <ul :if={@films != []} class="seen-film-list">
        <li
          :for={mark <- @films}
          class="event-item is-work"
          phx-click="open_work"
          phx-value-title={mark.node_name}
          role="button"
          tabindex="0"
        >
          <div class="event-item-head">
            <strong>{mark.node_name}</strong>
            <span class="muted-note">
              {if mark.seen_on, do: "#{Date.to_iso8601(mark.seen_on)} に見た", else: "見た日は書いていません"}
            </span>
          </div>
          <p :if={mark.note != ""} class="event-item-facts">{mark.note}</p>
        </li>
      </ul>

      <%!-- **見た映画を足す**（関連図の画面から移した）。図に無い作品は、図の収集に足すよう頼む --%>
      <details class="seen-mark film-add">
        <summary>見た映画を足す</summary>
        <form phx-submit="add_film" phx-target={@myself}>
          <p>
            <label>
              題名 <input type="text" name="title" required placeholder="例: 七人の侍" />
            </label>
          </p>
          <p>
            <label>
              手がかり（任意） <input type="text" name="hint" placeholder="例: 1954年・黒澤明監督" />
            </label>
          </p>
          <p class="seen-row">
            <label>
              見た日 <input type="date" name="seen_on" value={Date.to_iso8601(Jst.today())} />
            </label>
          </p>
          <p>
            <label>
              メモ<br />
              <textarea name="note" rows="2"></textarea>
            </label>
          </p>
          <p class="muted-note">
            映画の図に無い作品は、図の収集に足すよう頼みます（AI が監督・主演を調べて足すので、
            載るのは取り込みが終わって図を取り直してから）。題名は正確でなくて構いません ——
            AI が作品を確かめて Wikipedia の記事名で足し、ここで書いた題名は記録との結び付けに残します。
            同じ題名の別の作品があるときや、うろ覚えのときは手がかりを添えてください。
          </p>
          <button type="submit" disabled={@adding} phx-disable-with="記録しています…">記録して足す</button>
          <span :if={@message} class="muted-note" aria-live="polite">{@message}</span>
        </form>
      </details>
    </section>
    """
  end
end
