defmodule ChidoriWeb.SeenFilms do
  @moduledoc """
  趣味の映画のタブの中の「見た映画」（`/news?view=chidori_movies&section=seen`）。見た映画の一覧と、
  見た映画を足す口（関連図の画面から移した）。

  見た記録は映画の話題と映画の図で同じ置き場（`Chidori.Relations.Marks` の `movies`）。
  **足した作品が映画の図にまだ無ければ、図の収集に足すよう頼む**（`FilmCarry.carry_now/2`。
  AI が監督・主演を調べて足すので、載るのは取り込みが終わってから）。図にもうある作品は
  記録を付けるだけで頼まない。一覧の作品を押すと、作品の詳細（`ChidoriWeb.WorkModal`。置く画面の
  `open_work`）が開く。

  **作品の絵は、最新の映画の収集（置く画面の話題の `collection`）にあればそれ、無ければ映画の
  目録（`Films.collection/0`。見出しか `記録:` で引く）のものを出す**（Chiezo が縮めて持っている
  `thumb`。開いたあとに 1 本ずつ引く）。昔の作品は Wikipedia にポスターが無く、目録にも初めは
  絵が無いので、**「絵を探してもらう」で AI に探させる**（`Films.fill_images/2`。目録にある作品
  だけを名指しする）。絵が付くまでは枠だけを出す。
  """

  use Phoenix.LiveComponent

  alias Chidori.Jst
  alias Chidori.Relations.FilmCarry
  alias Chidori.Relations.Films
  alias Chidori.Relations.Marks

  # 絵を引くのを並べる数（13 本なら 4 本ずつ）
  @thumb_concurrency 4

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         marks: Marks.for_view(Films.mark_view()),
         message: nil,
         adding: false,
         thumbs: %{},
         collection: nil,
         # 目録にあって絵の無い作品（目録の見出し）。「絵を探してもらう」で名指しする
         imageless: [],
         asking_images: false,
         images_message: nil
       )}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # つながってから 1 度だけ絵を引く（最初の描画では引かない）
    if connected?(socket) and socket.assigns.thumbs == %{} and socket.assigns.collection,
      do: {:ok, load_thumbs(socket)},
      else: {:ok, socket}
  end

  defp load_thumbs(socket) do
    titles = socket.assigns.marks |> seen() |> Enum.map(& &1.node_name)
    collection = socket.assigns.collection

    case {titles, Chidori.News.chiezo_base_url()} do
      {[], _base} ->
        socket

      {_titles, nil} ->
        socket

      {titles, base} ->
        socket
        |> assign(thumbs: Map.new(titles, &{&1, nil}))
        |> start_async(:thumbs, fn -> thumbs(base, collection, titles) end)
    end
  end

  @doc """
  見た作品の絵。`{見出し → 絵の道（/thumbs/…）, 目録にあって絵の無い作品の目録の見出し}`。
  最新の映画の収集を先に見て、無ければ映画の目録（見出しか `記録:` の見出し）を見る。
  """
  def thumbs(base, collection, titles) do
    found =
      titles
      |> Task.async_stream(&thumb_of(base, collection, &1),
        max_concurrency: @thumb_concurrency,
        timeout: 10_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, found} -> [found]
        _exit -> []
      end)

    {
      for({title, {:thumb, path}} <- found, into: %{}, do: {title, path}),
      for({_title, {:missing, catalog_title}} <- found, uniq: true, do: catalog_title)
    }
  end

  defp thumb_of(base, collection, title) do
    with nil <- thumb_in(Chidori.Chiezo.doc(base, collection, title, "title,extra")) do
      case catalog_doc(base, title) do
        %{"title" => catalog_title} = doc ->
          case thumb_in({:ok, doc}) do
            nil -> {title, {:missing, catalog_title}}
            path -> {title, {:thumb, path}}
          end

        _none ->
          {title, :none}
      end
    else
      path -> {title, {:thumb, path}}
    end
  end

  defp thumb_in({:ok, %{"extra" => %{"thumb" => thumb}}}) when is_binary(thumb),
    do: Chidori.Chiezo.thumb_path(thumb)

  defp thumb_in(_doc), do: nil

  # 目録の 1 件（見出しで、無ければ `記録:` の見出しで）
  defp catalog_doc(base, title) do
    case Chidori.Chiezo.doc(base, Films.collection(), title, "title,extra") do
      {:ok, doc} ->
        doc

      _missing ->
        case Chidori.Chiezo.spot_docs(
               base,
               Films.collection(),
               Films.record_tag() <> ":" <> title,
               0,
               1
             ) do
          {:ok, %{docs: [doc | _]}} -> doc
          _none -> nil
        end
    end
  end

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

  # 目録にあって絵の無い作品に、絵を探させる（AI を 1 回使う。重ねて押しても 1 本）
  def handle_event("fill_images", _params, socket) do
    titles = socket.assigns.imageless

    case Chidori.News.chiezo_base_url() do
      base when is_binary(base) and titles != [] ->
        {:noreply,
         socket
         |> assign(asking_images: true, images_message: nil)
         |> start_async(:images, fn ->
           Chidori.SingleFlight.run({:film_images}, fn -> Films.fill_images(base, titles) end)
         end)}

      _none ->
        {:noreply, socket}
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

  def handle_async(:thumbs, {:ok, {found, imageless}}, socket),
    do:
      {:noreply,
       assign(socket, thumbs: Map.merge(socket.assigns.thumbs, found), imageless: imageless)}

  def handle_async(:images, {:ok, result}, socket) do
    message =
      case result do
        {:ok, count} ->
          "#{count} 本の絵を探すよう頼みました（Chiezo が取り込んだあと、開き直すと出ます）。"

        {:error, :busy} ->
          "いま頼んでいるところです。"

        {:error, reason} ->
          "絵を探すよう頼めませんでした: " <> ChidoriWeb.Collect.reason_text(reason)
      end

    # 頼めたら口を引っ込める（取り込みが終わるまで絵は付かないので、続けて押すと AI の回が重なる）
    imageless = if match?({:ok, _}, result), do: [], else: socket.assigns.imageless

    {:noreply,
     assign(socket, asking_images: false, images_message: message, imageless: imageless)}
  end

  def handle_async(:images, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, asking_images: false, images_message: "絵を探すよう頼めませんでした。")}

  def handle_async(:thumbs, {:exit, _reason}, socket), do: {:noreply, socket}

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
          <%!-- 絵の無い作品も枠だけ出す（行の並びをそろえる） --%>
          <img
            :if={@thumbs[mark.node_name]}
            class="event-thumb"
            src={@thumbs[mark.node_name]}
            alt=""
            loading="lazy"
          />
          <span :if={!@thumbs[mark.node_name]} class="event-thumb is-empty" aria-hidden="true"></span>
          <div class="event-item-head">
            <strong>{mark.node_name}</strong>
            <span class="muted-note">
              {if mark.seen_on, do: "#{Date.to_iso8601(mark.seen_on)} に見た", else: "見た日は書いていません"}
            </span>
          </div>
          <p :if={mark.note != ""} class="event-item-facts">{mark.note}</p>
        </li>
      </ul>

      <%!-- 絵の無い作品に絵を探させる口（目録にある作品だけ。AI を 1 回使う） --%>
      <p :if={@imageless != []} class="seen-images">
        <button
          type="button"
          phx-click="fill_images"
          phx-target={@myself}
          disabled={@asking_images}
          phx-disable-with="頼んでいます…"
        >
          絵の無い {length(@imageless)} 本の絵を探してもらう
        </button>
        <span class="muted-note">AI が公式サイトなどでポスターを探し、Chiezo が縮めて持ちます。</span>
      </p>
      <p :if={@images_message} class="muted-note" aria-live="polite">{@images_message}</p>

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
