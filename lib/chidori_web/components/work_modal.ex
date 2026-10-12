defmodule ChidoriWeb.WorkModal do
  @moduledoc """
  映画・アニメの作品 1 本の詳細（モーダル）。最新情報の画面（注目作の一覧・
  カレンダーの日の一覧・要約）と、トップページの要約から同じものを開きます。

  **中身は作品の説明・出典・近くの上映館を聞く口（映画だけ）・見た記録です。**
  札に全部を並べていた頃は、口コミまで入った本文と記録の欄で一覧が長くなり、
  どの作品があるのかを見渡せなかった。札は見出しと事実の 1 行だけにして、
  押したらここで読む（記事の札と同じ動き）。

  **作品は手元にあればそれを使い、無ければ Chiezo から 1 件だけ引きます**
  （要約が紹介した作品が注目作の一覧に無いとき・トップページから開いたとき）。

  押したときの動き —— `open_work` / `close_work` / `save_work_mark` と、
  作品を引いた答え（`{:work, 見出し}`）—— は置いた画面の側が受け、ここの
  `open/4` / `close/1` / `save_mark/3` / `loaded/3` に渡します。
  """

  use ChidoriWeb, :html

  # `start_async` はマクロ（置いた画面の LiveView の中で走る）
  require Phoenix.LiveView

  alias Chidori.Chiezo
  alias Chidori.News
  alias Chidori.News.Events
  alias Chidori.News.Movies
  alias Chidori.Relations.Mark
  alias Chidori.Relations.Marks
  alias Chidori.Topics
  alias ChidoriWeb.NewsLive

  # 作品を引くときの項目（注目作の一覧と同じ。口コミは本文の末尾にあるので本文ごと）
  @doc_fields "title,tags,extra,opening,body"

  @doc """
  作品を開きます。`entries` は画面が持っている作品（注目作・カレンダー）で、
  そこに無ければ Chiezo から引きます。見た記録（`work_marks`）をまだ持っていない
  画面（トップページ）では、記録も一緒に読みます。
  """
  def open(socket, title, topic, entries \\ []) do
    works = topic && Topics.works(topic)
    entry = Enum.find(entries, &(&1.title == title))
    marks = socket.assigns[:work_marks]
    opened = %{title: title, works: works, entry: :loading}

    cond do
      works == nil ->
        socket

      entry != nil and (is_map(marks) or not marks_kept?(works)) ->
        assign(socket, opened_work: %{opened | entry: {:ok, entry}}, work_mark_saved: nil)

      base = News.chiezo_base_url() ->
        load_marks? = marks_kept?(works) and not is_map(marks)

        socket
        |> assign(opened_work: opened, work_mark_saved: nil)
        |> Phoenix.LiveView.start_async({:work, title}, fn ->
          {if(entry, do: {:ok, entry}, else: fetch(base, topic, title)),
           if(load_marks?, do: Marks.for_view(works.mark_view()))}
        end)

      true ->
        assign(socket,
          opened_work: %{opened | entry: {:error, :chiezo_not_configured}},
          work_mark_saved: nil
        )
    end
  end

  @doc "作品を 1 件、Chiezo から引きます（`{:ok, entry}` か `{:error, 理由}`）。"
  def fetch(base, topic, title) do
    case Chiezo.doc(base, topic.collection, title, @doc_fields) do
      {:ok, doc} -> {:ok, Events.entry(doc, Topics.date_tag(topic))}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  引いた作品を受け取ります。**開いている作品の答えだけ**（続けて押すと、前の作品の
  答えが後から届く）。
  """
  def loaded(socket, title, result) do
    case socket.assigns[:opened_work] do
      %{title: ^title} = opened ->
        {entry, marks} =
          case result do
            {:ok, {entry, marks}} -> {entry, marks}
            _exit -> {{:error, :chiezo_unavailable}, nil}
          end

        socket = assign(socket, opened_work: %{opened | entry: entry})
        if is_map(marks), do: assign(socket, work_marks: marks), else: socket

      _other ->
        socket
    end
  end

  @doc "閉じます。"
  def close(socket), do: assign(socket, opened_work: nil, work_mark_saved: nil)

  @doc """
  作品の「見た」印とメモを書きます。**空にしたら消える**（関連図の「見た」と同じ）。
  """
  def save_mark(socket, topic, %{"title" => title} = params) do
    works = topic && Topics.works(topic)

    attrs = %{
      # チェックが外れているとキーごと来ない（HTML のチェックボックス）
      "seen" => params["seen"] == "on",
      "seen_on" => if(params["seen_on"] in [nil, ""], do: nil, else: params["seen_on"]),
      "note" => params["note"] || ""
    }

    with true <- marks_kept?(works),
         {:ok, mark} <- Marks.put(works.mark_view(), title, attrs) do
      marks = socket.assigns[:work_marks] || %{}
      marks = if mark, do: Map.put(marks, title, mark), else: Map.delete(marks, title)
      assign(socket, work_marks: marks, work_mark_saved: title)
    else
      _error ->
        # 書けなかったことは黙って捨てない
        Phoenix.LiveView.put_flash(socket, :error, "見た記録を保存できませんでした。")
    end
  end

  defp marks_kept?(works),
    do: is_atom(works) and works != nil and function_exported?(works, :mark_view, 0)

  @doc """
  作品の出典（重複なし）。作品のページ（`url`）を先に、本文に出てくる URL を出てきた順に。
  """
  def sources(entry, works \\ Movies) do
    in_body =
      for line <- works.body_lines(entry),
          {:url, url} <- NewsLive.link_parts(line),
          do: url

    [Map.get(entry, :url) | in_body]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  @doc "作品が読めなかったときの一言。"
  def error_text(:chiezo_not_configured), do: "Chiezo の場所が設定されていません。"
  def error_text(:not_found), do: "この作品は Chiezo に見当たりませんでした（整理で外れたのかもしれません）。"
  def error_text(_reason), do: "作品を読めませんでした（Chiezo に繋がらないかもしれません）。"

  # 開いている作品（`open/4`）。nil なら閉じている
  attr :opened, :map, default: nil

  # 作品に付けた「見た」印（見出し → 印）。nil なら記録の欄を出さない
  attr :marks, :map, default: nil
  attr :saved, :string, default: nil

  @doc """
  作品のモーダル。**全画面の要約より手前に出します**（要約から開いたとき、閉じると
  要約に戻る）。閉じるのはボタン・外側を押す・Esc。
  """
  def work_modal(assigns) do
    ~H"""
    <div
      :if={@opened}
      class="artwork-backdrop work-modal-backdrop"
      phx-window-keydown="close_work"
      phx-key="Escape"
    >
      <section
        id="work-modal"
        class="artwork work-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="work-modal-title"
        phx-click-away="close_work"
      >
        <div class="artwork-head">
          <strong id="work-modal-title">{@opened.title}</strong>
          <button type="button" phx-click="close_work">閉じる</button>
        </div>
        <p :if={@opened.entry == :loading} class="muted-note">読み込んでいます…</p>
        <p :if={match?({:error, _}, @opened.entry)} class="muted-note">
          {error_text(elem(@opened.entry, 1))}
        </p>
        <.work_body
          :if={match?({:ok, _}, @opened.entry)}
          entry={elem(@opened.entry, 1)}
          works={@opened.works}
          marks={@marks}
          saved={@saved}
        />
      </section>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :works, :atom, default: Movies
  attr :marks, :map, default: nil
  attr :saved, :string, default: nil

  @doc """
  作品 1 本の中身（事実の 1 行・本文・出典・上映館・見た記録）。
  **本文は切らずに出します** —— 口コミは本文の末尾にあるので、頭だけで切ると
  いちばん見たいところが落ちる。本文の URL はリンクにします。
  """
  def work_body(assigns) do
    assigns =
      assign(assigns,
        mark: if(assigns.marks, do: Map.get(assigns.marks, assigns.entry.title) || %Mark{}),
        key: :erlang.phash2(assigns.entry.title),
        sources: sources(assigns.entry, assigns.works)
      )

    ~H"""
    <img
      :if={NewsLive.entry_thumb(@entry)}
      class="work-modal-thumb"
      src={NewsLive.entry_thumb(@entry)}
      alt=""
      loading="lazy"
    />
    <p class="event-item-facts">
      {NewsLive.work_facts(@entry, @works)}
      <span :if={NewsLive.mark_summary(@mark)} class="seen-badge">
        {NewsLive.mark_summary(@mark)}
      </span>
    </p>
    <%!-- **映画だけ**、近くで上映している映画館を Gemini（Google 検索の AI モード）に聞く。
         地域を書けばその近く、空なら押したときにブラウザから現在地を取って聞く（`AskNearby`。
         取れなければ場所を書かずに開く。AI モードの側でもおおよその場所は分かる）。
         **公開中か、1 週間以内に公開されるものだけ**（先の作品はまだどこも上映していない） --%>
    <div
      :if={@works == Movies and NewsLive.showing_soon?(@entry)}
      id={"ask-nearby-#{@key}"}
      class="ask-nearby"
      phx-hook="AskNearby"
      data-question={NewsLive.theaters_question(@entry.title)}
      data-region-question={NewsLive.theaters_question(@entry.title, {:region, "{region}"})}
    >
      <label class="ask-nearby-region">
        地域（空なら現在地）
        <input
          id={"ask-nearby-region-#{@key}"}
          type="text"
          name="region"
          placeholder="例: 新宿"
          autocomplete="off"
          phx-update="ignore"
        />
      </label>
      <a
        href={NewsLive.theaters_url(@entry.title)}
        target="_blank"
        rel="noopener noreferrer"
      >
        近くの上映館を Gemini に聞く
      </a>
    </div>
    <div class="event-item-detail">
      <p :for={line <- @works.body_lines(@entry)}>
        <%= for part <- NewsLive.link_parts(line) do %>
          <a
            :if={match?({:url, _}, part)}
            href={SafeUrl.href(elem(part, 1))}
            target="_blank"
            rel="noreferrer"
          >
            {elem(part, 1)}
          </a>
          <span :if={match?({:text, _}, part)}>{elem(part, 1)}</span>
        <% end %>
      </p>
    </div>
    <%!-- 出典。作品のページと、本文が引いたページ（どこを見て書いたのかを確かめる） --%>
    <div :if={@sources != []} class="report-refs work-modal-refs">
      <p class="report-refs-label">出典</p>
      <ol>
        <li :for={url <- @sources}>
          <a href={SafeUrl.href(url)} target="_blank" rel="noreferrer">{url}</a>
          <span :if={url == @entry[:url]} class="report-ref-host">作品のページ</span>
        </li>
      </ol>
    </div>
    <%!-- 見た記録（関連図の「見た記録」と同じ形）。置き場は Chiezo の chidori_data --%>
    <section :if={@mark} class="seen-mark" aria-label="見た記録">
      <p class="seen-mark-title">見た記録</p>
      <form id={"work-mark-#{@key}"} phx-submit="save_work_mark">
        <input type="hidden" name="title" value={@entry.title} />
        <p class="seen-row">
          <label><input type="checkbox" name="seen" checked={@mark.seen} /> 見た</label>
          <label>
            見た日
            <input
              type="date"
              name="seen_on"
              value={if @mark.seen_on, do: Date.to_iso8601(@mark.seen_on)}
            />
          </label>
        </p>
        <p>
          <label>
            メモ（どこで見たか・感想）<br />
            <textarea name="note" rows="2">{@mark.note}</textarea>
          </label>
        </p>
        <button type="submit" phx-disable-with="保存しています…">記録を保存</button>
        <span :if={@saved == @entry.title} class="muted-note">保存しました。</span>
      </form>
    </section>
    """
  end
end
