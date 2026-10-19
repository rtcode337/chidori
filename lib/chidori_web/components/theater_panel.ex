defmodule ChidoriWeb.TheaterPanel do
  @moduledoc """
  映画の画面の「映画館」の欄。映画館を AI に探させてお気に入りに入れ（`Chidori.News.TheaterFinder`・
  `Chidori.News.Theaters`）、お気に入りの館で、選んだ映画を指定の時刻より後に上映する回を調べる
  （`Chidori.News.Showtimes`）。

  押したときの動き（`find_theaters` / `theater_here` / `favorite_theater` /
  `unfavorite_theater` / `ask_showtimes`）は置いた画面（`ChidoriWeb.NewsLive`）が受けます。
  現在地は `TheaterNearby`（`assets/js/theater_nearby.js`）が取って送ります。
  """

  use ChidoriWeb, :html

  alias Chidori.Jst

  attr :search, :any, default: nil
  attr :search_form, :map, default: %{}
  attr :here, :any, default: nil
  attr :favorites, :list, default: []
  attr :showing, :list, default: []
  attr :backends, :any, default: nil
  attr :showtimes, :any, default: nil
  attr :form, :map, default: %{}

  def panel(assigns) do
    assigns = assign(assigns, favorite_ids: MapSet.new(assigns.favorites, & &1.id))

    ~H"""
    <section class="event-calendar theater-panel" aria-label="映画館">
      <h2 class="news-section-title">映画館</h2>

      <%!-- 映画館を **AI に探させる**。出発地（駅名・地名か現在地）から、決めた時間以内に**着ける**館を、
           着くまでの時間が短い順に（直線の距離ではなく、隣の駅の館も入る）。同じ館は 1 つにまとめさせ、
           辞典の映画館と突き合わせて確かめる（`Chidori.News.TheaterFinder`） --%>
      <form id="theater-find" phx-submit="find_theaters" class="theater-find-form">
        <label>
          出発地（駅名・地名）
          <input
            type="text"
            name="region"
            value={@search_form["region"]}
            placeholder={if match?({_, _}, @here), do: "空なら現在地", else: "例: 新宿駅・川崎"}
            autocomplete="off"
          />
        </label>
        <label>
          着くまで
          <select name="minutes">
            <option
              :for={m <- Chidori.News.TheaterFinder.minutes_choices()}
              value={m}
              selected={
                to_string(m) ==
                  (@search_form["minutes"] || to_string(Chidori.News.TheaterFinder.default_minutes()))
              }
            >
              {m} 分以内
            </option>
          </select>
        </label>
        <label :if={match?({:ok, [_ | _]}, @backends)}>
          探す AI
          <select name="backend">
            <option
              :for={b <- elem(@backends, 1)}
              value={b.id}
              selected={@search_form["backend"] == b.id}
            >
              {b.label}
            </option>
          </select>
        </label>
        <button type="submit" disabled={@search == :loading or not match?({:ok, [_ | _]}, @backends)}>
          {if @search == :loading, do: "探しています…", else: "AI で探す"}
        </button>
      </form>
      <div id="theater-nearby" phx-hook="TheaterNearby" class="theater-here">
        <button type="button">現在地を使う</button>
        <span class="muted-note" data-status>
          {case @here do
            {_, _} -> "現在地を使います（出発地の欄が空のとき）"
            :unavailable -> "現在地を取れませんでした（位置情報の利用を許可してください）"
            _ -> ""
          end}
        </span>
      </div>
      <p class="muted-note">
        押すと AI が web で調べます（AI を 1 回使い、数十秒〜数分かかります。画面を移っても、戻ってくると出ます）。
      </p>
      <p :if={@search == :loading} class="muted-note">探しています…</p>
      <p :if={match?({:error, _}, @search)} class="muted-note">{search_error(elem(@search, 1))}</p>
      <%= if match?({:ok, _}, @search) do %>
        <% {:ok, found} = @search %>
        <p class="muted-note">
          {found.origin}から {found.minutes} 分以内に着ける映画館（{length(found.theaters)} 館。着くまでの時間が短い順）
        </p>
        <ul :if={found.theaters != []} class="theater-list">
          <li :for={t <- found.theaters}>
            <span class="theater-name">
              <a :if={t.website} href={t.website} target="_blank" rel="noopener noreferrer">{t.name}</a>
              <strong :if={!t.website}>{t.name}</strong>
              <span class="muted-note">
                <strong :if={t.minutes} class="theater-station">約 {t.minutes} 分</strong>
                <span :if={t.station}>{t.station}</span>
                <span :if={t.access}>· {t.access}</span>
              </span>
              <span class="muted-note">
                <span :if={t.address}>{t.address}</span>
                <a :if={map_url(t)} href={map_url(t)} target="_blank" rel="noopener noreferrer">地図</a>
                <span :if={!t.verified} class="seen-badge">辞典で確かめられない</span>
              </span>
            </span>
            <button
              :if={!MapSet.member?(@favorite_ids, t.id)}
              type="button"
              phx-click="favorite_theater"
              phx-value-id={t.id}
            >
              お気に入りに入れる
            </button>
            <span :if={MapSet.member?(@favorite_ids, t.id)} class="seen-badge">お気に入り</span>
          </li>
        </ul>
        <%!-- 決めた形で返らなかったときは、答えの文をそのまま出す（捨てない） --%>
        <pre :if={found.theaters == []} class="showtime-raw">{found.raw}</pre>
      <% end %>

      <h3>お気に入りの映画館</h3>
      <p :if={@favorites == []} class="muted-note">まだありません。上で探してお気に入りに入れてください。</p>
      <ul :if={@favorites != []} class="theater-list">
        <li :for={t <- @favorites}>
          <span class="theater-name">
            <a :if={t.website} href={t.website} target="_blank" rel="noopener noreferrer">{t.name}</a>
            <strong :if={!t.website}>{t.name}</strong>
            <%!-- **どこの館かを最寄り駅で言う**（複数の駅の館をお気に入りにすると、名前だけでは
                 見分けにくい）。地図は見る人のブラウザで開く --%>
            <span class="muted-note">
              <span :if={Chidori.News.Theaters.station_label(t)} class="theater-station">
                {Chidori.News.Theaters.station_label(t)}
              </span>
              <span :if={t.address}>{t.address}</span>
              <a :if={map_url(t)} href={map_url(t)} target="_blank" rel="noopener noreferrer">地図</a>
            </span>
          </span>
          <button
            type="button"
            phx-click="unfavorite_theater"
            phx-value-id={t.id}
            data-confirm={"「#{t.name}」をお気に入りから外します。よろしいですか？"}
          >
            外す
          </button>
        </li>
      </ul>

      <%!-- 上映スケジュール。**押したときだけ** AI に web で調べさせる（枠を 1 回使い、数十秒〜数分かかる） --%>
      <h3>上映スケジュール</h3>
      <p :if={@favorites == []} class="muted-note">お気に入りの映画館を入れると調べられます。</p>
      <form
        :if={@favorites != []}
        id="showtime-form"
        phx-submit="ask_showtimes"
        class="showtime-form"
      >
        <label>
          映画
          <select name="title" required>
            <option
              :for={entry <- @showing}
              value={entry.title}
              selected={@form["title"] == entry.title}
            >
              {entry.title}
            </option>
          </select>
        </label>
        <label>
          日付 <input type="date" name="date" value={@form["date"] || Date.to_iso8601(Jst.today())} />
        </label>
        <label>
          この時刻より後 <input type="time" name="from" value={@form["from"] || now_text()} />
        </label>
        <label :if={match?({:ok, [_ | _]}, @backends)}>
          調べる AI
          <select name="backend">
            <option
              :for={b <- elem(@backends, 1)}
              value={b.id}
              selected={@form["backend"] == b.id}
            >
              {b.label}
            </option>
          </select>
        </label>
        <button
          type="submit"
          disabled={@showtimes == :loading or not match?({:ok, [_ | _]}, @backends)}
        >
          {if @showtimes == :loading, do: "調べています…", else: "お気に入りの館で調べる"}
        </button>
      </form>
      <p :if={@favorites != [] and match?({:ok, []}, @backends)} class="muted-note">
        web で調べられる AI が Chiezo にありません（Chiezo の AI 設定で、CLI ブリッジの相手を有効にしてください）。
      </p>
      <p :if={@favorites != []} class="muted-note">
        AI が各映画館のサイトで調べます（押すたびに AI を 1 回使い、数十秒〜数分かかります）。
        上映時刻は変わることがあるので、出どころの頁で確かめてください。
      </p>
      <.showtime_result state={@showtimes} />
    </section>
    """
  end

  attr :state, :any, default: nil

  @doc """
  調べた答え（館ごとの表）。映画館の欄と作品の詳細で同じものを出す。
  `state` は `nil` / `:loading` / `{:ok, 結果}` / `{:error, 理由}`。
  """
  def showtime_result(assigns) do
    ~H"""
    <p :if={@state == :loading} class="muted-note">調べています…（数分かかることがあります。画面を移っても、戻ってくると出ます）</p>
    <p :if={match?({:error, _}, @state)} class="muted-note">{showtime_error(elem(@state, 1))}</p>
    <%= if match?({:ok, _}, @state) do %>
      <% {:ok, result} = @state %>
      <% stations = Map.get(result, :stations, %{}) %>
      <p class="muted-note">{result.title} / {result.date} {result.from} より後</p>
      <%!-- **上映の始まる順に 1 本の表で**（館ごとに分けると、いちばん早い回を探して館を
           見比べることになる）。どこの館かは最寄り駅で添える --%>
      <ol :if={timeline(result.theaters) != []} class="showtime-timeline">
        <li :for={row <- timeline(result.theaters)}>
          <strong class="showtime-start">{row.start}</strong><span
            :if={row.end != ""}
            class="muted-note"
          >〜{row.end}</span>
          <span class="showtime-theater-name">{row.theater}</span>
          <span :if={stations[row.theater]} class="muted-note">{stations[row.theater]}</span>
          <span :if={row.format != ""} class="seen-badge">{row.format}</span>
        </li>
      </ol>
      <%!-- 確かめられなかった館と、館ごとの補足・出どころ（表の下にまとめる） --%>
      <ul :if={result.theaters != []} class="showtime-notes">
        <li :for={t <- result.theaters}>
          <span>{t.name}</span><span :if={stations[t.name]} class="muted-note">（{stations[t.name]}）</span>:
          <span :if={!t.found} class="muted-note">確かめられませんでした（または、この時刻より後の上映はありません）。</span>
          <span :if={t.note != ""} class="muted-note">{t.note}</span>
          <a :if={t.source} href={t.source} target="_blank" rel="noopener noreferrer">出どころ</a>
        </li>
      </ul>
      <%!-- 決めた形で返らなかったときは、答えの文をそのまま出す（捨てない） --%>
      <pre :if={result.theaters == []} class="showtime-raw">{result.raw}</pre>
    <% end %>
    """
  end

  attr :title, :string, required: true
  attr :favorites, :list, default: []
  attr :backends, :any, default: nil
  attr :state, :any, default: nil
  attr :form, :map, default: %{}

  @doc """
  作品の詳細に置く、**その作品の上映スケジュールを調べる欄**（映画を選ぶ欄は無い）。
  答えはその作品のものだけを出す（ほかの作品を調べた答えは、この作品の詳細には出さない）。
  """
  def showtime_box(assigns) do
    assigns =
      assign(assigns,
        mine:
          case assigns.state do
            {:ok, %{title: title}} -> title == assigns.title
            :loading -> assigns.form["title"] == assigns.title
            {:error, _reason} -> assigns.form["title"] == assigns.title
            _other -> false
          end
      )

    ~H"""
    <section class="showtime-box" aria-label="上映スケジュール">
      <p class="seen-mark-title">上映スケジュール</p>
      <p :if={@favorites == []} class="muted-note">
        映画の画面の「映画館」でお気に入りの映画館を入れると、ここから調べられます。
        <.link navigate={~p"/news?view=chidori_movies"}>映画の画面へ</.link>
      </p>
      <form
        :if={@favorites != []}
        id={"showtime-box-#{:erlang.phash2(@title)}"}
        phx-submit="ask_showtimes"
        class="showtime-form"
      >
        <input type="hidden" name="title" value={@title} />
        <label>
          日付
          <input
            type="date"
            name="date"
            value={(@mine && @form["date"]) || Date.to_iso8601(Jst.today())}
          />
        </label>
        <label>
          この時刻より後 <input type="time" name="from" value={(@mine && @form["from"]) || now_text()} />
        </label>
        <label :if={match?({:ok, [_ | _]}, @backends)}>
          調べる AI
          <select name="backend">
            <option :for={b <- elem(@backends, 1)} value={b.id} selected={@form["backend"] == b.id}>
              {b.label}
            </option>
          </select>
        </label>
        <button type="submit" disabled={@state == :loading or not match?({:ok, [_ | _]}, @backends)}>
          {if @state == :loading, do: "調べています…", else: "お気に入りの館で調べる"}
        </button>
      </form>
      <p :if={@favorites != []} class="muted-note">
        お気に入りの館（{Enum.map_join(@favorites, "・", & &1.name)}）で、AI が各館のサイトを調べます（押すたびに AI を 1 回使います）。
      </p>
      <p :if={@state == :loading and !@mine} class="muted-note">ほかの作品を調べている最中です。終わるまで待ってください。</p>
      <.showtime_result :if={@mine} state={@state} />
    </section>
    """
  end

  @doc """
  館ごとの答えを、上映の始まる順の 1 本の並びに（`%{start, end, format, theater}`）。
  同じ時刻なら館の名前順。始まりが「HH:MM」でないものは後ろ（並べられない）。
  """
  def timeline(theaters) do
    for t <- theaters, t.found, s <- t.showings do
      Map.put(s, :theater, t.name)
    end
    |> Enum.sort_by(fn row -> {start_key(row.start), row.theater} end)
  end

  defp start_key(start) do
    case Chidori.Notify.Setting.parse(start) do
      {:ok, {h, m}} -> h * 60 + m
      :error -> 24 * 60 + 1
    end
  end

  @doc "地図で館を開く URL（座標が無ければ nil）。見る人のブラウザで開く。"
  def map_url(%{lat: lat, lon: lon}) when is_number(lat) and is_number(lon),
    do: "https://www.google.com/maps/search/?api=1&query=#{lat},#{lon}"

  def map_url(_theater), do: nil

  @doc "距離の書き方（1km 未満は m、それ以上は km を小数 1 桁）。"
  def distance_label(m) when is_integer(m) and m < 1000, do: "#{m}m"
  def distance_label(m) when is_integer(m) and rem(m, 1000) == 0, do: "#{div(m, 1000)}km"
  def distance_label(m) when is_integer(m), do: "#{Float.round(m / 1000, 1)}km"
  def distance_label(_m), do: ""

  defp now_text, do: Chidori.Notify.Setting.format(Jst.now_hm())

  defp showtime_error(:busy), do: "いま調べている最中です。終わるまで待ってください。"
  defp showtime_error(:bad_request), do: "映画・日付・時刻・調べる AI を選んでください。"
  defp showtime_error(reason), do: "調べられませんでした: " <> ChidoriWeb.Collect.reason_text(reason)

  defp search_error(:no_origin), do: "出発地を書くか、「現在地を使う」を押してください。"
  defp search_error(:busy), do: "いま探している最中です。終わるまで待ってください。"
  defp search_error(:bad_request), do: "着くまでの時間と探す AI を選んでください。"
  defp search_error(reason), do: "映画館を探せませんでした: " <> ChidoriWeb.Collect.reason_text(reason)
end
