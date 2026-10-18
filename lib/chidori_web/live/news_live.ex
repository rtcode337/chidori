defmodule ChidoriWeb.NewsLive do
  @moduledoc """
  最新情報の一覧。集めるのは Chiezo の「集める」層で、この画面は依頼と閲覧だけを持ちます。

  収集は数十秒から数分かかることがあるので、押した人に再読み込みをさせません。
  結果は `Chidori.News` からの通知で届きます。

  **話題ごとにタブで分けます。** 集めるものも溜まるものも話題ごとに別なので、
  1 つに混ぜると、どちらの状態を見ているのか読めなくなります。タブに並ぶのは
  `Chidori.Topics` の話題そのもので、並びも定義のとおりです。

  **一覧の並びは重要度です。** 先頭に出すのは要約の巡回が書いたまとめで、その下に
  1 件ずつを重要度の高い順に並べます —— どちらも収集の側が付けたもので、
  この画面では何も判断しません。
  """

  use ChidoriWeb, :live_view

  import ChidoriWeb.Collect
  import ChidoriWeb.CollectPanel
  import ChidoriWeb.Report
  import ChidoriWeb.TopicMap

  alias Chidori.Digest
  alias Chidori.Digest.Scheduler
  alias Chidori.Jst
  alias Chidori.News
  alias Chidori.News.Events
  alias Chidori.News.Favorites
  alias Chidori.News.Interests
  alias Chidori.News.Movies
  alias Chidori.Notify
  alias Chidori.Notify.Setting
  alias Chidori.Notify.Settings
  alias Chidori.Ntfy
  alias Chidori.Relations.Mark
  alias Chidori.Relations.Marks
  alias Chidori.Themes
  alias Chidori.Topics
  alias ChidoriWeb.WorkModal

  # お気に入りのタブの `view`（話題の収集の名前は `chidori_` で始まるので、ぶつからない）
  @favorites_view "favorites"

  @impl true
  def mount(_params, _session, socket) do
    # 相手の一覧は**繋がってから、待たずに**引く。画面の中で同期に引くと、Chiezo が
    # 遅いあいだページが固まる（選択肢が無くても記事は読めるので、待つ価値が無い）
    socket =
      assign(socket,
        topics: Topics.list(),
        backends: [],
        picks: %{},
        # トピックの網（記事から育つ話題）。**持つ話題だけ**読みに行く
        themes: empty_themes(),
        theme_picks: %{},
        asking: false,
        # 詳細を開いている記事（モーダル）。そこから頼んだ割り込みの結果も持つ
        opened_article: nil,
        article_asked: nil,
        # お気に入りのタブを開いているか（`?view=favorites`）と、お気に入りの記事の URL
        # （札に印を付ける）・一覧（タブを開いているときだけ）・入れ外しに失敗した旨
        favorites_view: false,
        favorite_urls: MapSet.new(),
        favorites: [],
        favorite_error: nil,
        digest_message: nil,
        notify_form: nil,
        # 全画面で開いているまとめ（何件目か。閉じていれば nil）と、どちらの並びか
        # （`:main` = ふつうのまとめ / `:interest` = 興味トピックの要約）
        digest_open: nil,
        digest_kind: :main,
        digest_wanted: false,
        # 興味トピック（話題ごと。Chidori が持つ）
        interests: [],
        # トピックの網で選んでいる語と、その記事（読み込み中は `:loading`）
        picked_theme: nil,
        theme_articles: nil,
        theme_query: "",
        # 記事一覧の並び（`:importance` = 重要度順 / `:interest` = 興味の近い順）
        article_sort: :importance,
        # 全画面で開いたときに、先に見せる章（目次から開いたとき。番号）
        digest_section: nil,
        # 本文を取り直したまとめ（見出し → まとめ）。**最初から本文を持つのは先頭の
        # 1 件だけ**なので、前後を開いたときに引いて覚える
        digest_full: %{},
        # 開催日のカレンダー（持つ話題だけ。`Chidori.Topics.calendar?/1`）。
        # 見ている月の 1 日・その月のイベント（読み込み中は `:loading`）・
        # 押した日・絞っている開催地
        cal_month: nil,
        cal_events: nil,
        cal_day: nil,
        cal_places: [],
        # 注目作の一覧（作品を育てる話題だけ。`Chidori.Topics.works/1`）。
        # 読み込み中は `:loading`、読めたら `{:ok, [entry]}`
        works: nil
      )

    socket =
      if connected?(socket) do
        start_async(socket, :backends, fn -> Chidori.Relations.ai_backends() end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # **お気に入りは話題ではない**（話題をまたいで 1 つの一覧）。開いているあいだは
    # 話題を選んでいない状態にして、話題ごとの節を出さない
    favorites_view = params["view"] == @favorites_view
    topic = if favorites_view, do: nil, else: pick_topic(socket.assigns.topics, params["view"])

    # 話題を切り替えたら購読も付け替える。付け替えないと、見ていない話題の
    # 収集結果でこの画面が書き換わる
    if connected?(socket) do
      if previous = socket.assigns[:topic] do
        News.unsubscribe(previous.collection)
      end

      if topic do
        News.subscribe(topic.collection)
        # Chiezo の側は勝手に進むので、開くたびにいまの状態を取り直す
        News.refresh(News.server(topic.collection))
      end
    end

    socket =
      assign(socket,
        topic: topic,
        page_title: page_title(topic, favorites_view),
        favorites_view: favorites_view,
        favorite_urls: Favorites.urls(),
        favorites: if(favorites_view, do: Favorites.list(), else: []),
        favorite_error: nil,
        news: if(topic, do: News.current(News.server(topic.collection)), else: News.empty()),
        notify_form: notify_form(topic),
        themes: empty_themes(),
        digest_open: nil,
        digest_kind: :main,
        digest_section: nil,
        digest_full: %{},
        interests: if(topic, do: Interests.list(topic.collection), else: []),
        picked_theme: nil,
        theme_articles: nil,
        theme_query: "",
        article_sort: :importance,
        cal_month: Events.this_month(),
        cal_events: nil,
        cal_day: nil,
        cal_places: [],
        works: nil,
        # 作品に付けた「見た」印とメモ（作品の見出し → 印。`Chidori.Relations.Marks`）
        work_marks: work_marks(topic),
        work_mark_saved: nil,
        # 詳細を開いている作品（`ChidoriWeb.WorkModal`）
        opened_work: nil,
        ai_digests: nil,
        # 通知から開いたとき（`digest=latest`）。まとめが届いたら全画面で開く
        digest_wanted: params["digest"] == "latest"
      )

    {:noreply,
     socket
     |> open_wanted_digest()
     |> load_themes()
     |> load_calendar()
     |> load_works()
     |> load_ai_digests()}
  end

  # **通知を押して来たら、いちばん新しいまとめを全画面で開く。** 通知の本文は要旨だけ
  # なので、押した人が読みたいのはその続き（話題の画面を開いて、まとめを探して押す、
  # の手間を省く）。まとめは収集の状態と一緒に後から届くので、届くまで待って 1 度だけ開く
  defp open_wanted_digest(%{assigns: %{digest_wanted: true, news: news}} = socket) do
    if digests_of(news, :main) == [] do
      socket
    else
      socket
      |> assign(digest_wanted: false, digest_kind: :main, digest_section: nil)
      |> show_digest(0)
    end
  end

  defp open_wanted_digest(socket), do: socket

  # 要約を別の収集から読む話題（市況ニュース）。書き手ごとに最新の 1 本（`Chidori.News.AiDigests`）
  defp load_ai_digests(socket) do
    topic = socket.assigns.topic
    base = News.chiezo_base_url()
    source = topic && Topics.digest_from(topic)

    cond do
      source == nil ->
        socket

      base == nil ->
        assign(socket, ai_digests: {:error, :chiezo_not_configured})

      connected?(socket) ->
        socket
        |> assign(ai_digests: :loading)
        |> start_async({:ai_digests, topic.collection}, fn ->
          Chidori.News.AiDigests.latest(base, source)
        end)

      true ->
        assign(socket, ai_digests: :loading)
    end
  end

  # 開催日のカレンダーは**その月のぶんだけ**引く（`Chidori.News.Events.fetch_month/3`）。
  # 記事の一覧とは別に読むので、読めなくても記事は出る
  defp load_calendar(socket) do
    topic = socket.assigns.topic
    base = News.chiezo_base_url()
    month = socket.assigns.cal_month

    if connected?(socket) and topic != nil and Topics.calendar?(topic) and base do
      socket
      |> assign(cal_events: :loading)
      |> start_async({:calendar, month}, fn ->
        Events.fetch_month(base, topic.collection, month,
          date_tag: Topics.date_tag(topic),
          body: Topics.works(topic) != nil
        )
      end)
    else
      socket
    end
  end

  # 注目作の一覧（映画）。**注目度が中以上のものだけ**をタグで引く —— 溜まっている
  # 作品を全部読みに行かない（並べるのも、読む人が観るかを決めたい作品だけ）
  defp load_works(socket) do
    topic = socket.assigns.topic
    base = News.chiezo_base_url()

    if connected?(socket) and topic != nil and Topics.works(topic) != nil and base do
      tags = Enum.map_join(["高", "中"], ",", &"#{Events.attention_tag()}:#{&1}")

      socket
      |> assign(works: :loading)
      |> start_async({:works, topic.collection}, fn ->
        Events.fetch_tagged(base, topic.collection, tags,
          date_tag: Topics.date_tag(topic),
          body: true
        )
      end)
    else
      socket
    end
  end

  # トピックの網は**記事とは別の収集**なので、別に読みに行く（読めなくても記事は出る）。
  # **持つ話題だけ**（`Chidori.Topics.themes?/1`）—— 押せる口だけあって中身が育たない
  # のは設定し忘れに見える
  defp load_themes(socket) do
    topic = socket.assigns.topic
    base = News.chiezo_base_url()

    if connected?(socket) and topic != nil and Topics.themes?(topic) and base do
      # **どの話題の網かを名前に入れる**（届いたときに、いま見ている話題か確かめる）
      start_async(socket, {:themes, topic.collection}, fn -> Themes.read(base, topic) end)
    else
      socket
    end
  end

  defp empty_themes, do: %{collection: nil, themes: [], checked_at: nil}

  @impl true

  # **選んだところはサーバーが覚える。** 覚えないと、収集の状態が届いた拍子に
  # フォームが描き直され、選んだ相手が元の値へ戻る（選んだつもりで押すと、
  # いま入っている値がそのまま送り返される）
  def handle_event("pick_sweep", params, socket) do
    {:noreply, assign(socket, picks: sweep_choices(params))}
  end

  # **押す口はここだけ。** 収集がまだ無ければ作り、あれば設定を送り直して読み直す ——
  # 関連図と同じ形にしてある。ボタンを役割ごとに並べていた頃は、どれを押せば
  # 何が起きるのかが押す前に読めなかった（しかも走らせる口が混ざっていた）
  def handle_event("collect", params, socket) do
    topic = socket.assigns.topic
    picks = merged_picks(socket.assigns.picks, params)
    with_server(socket, &News.setup(&1, topic, picks))
  end

  # 知らせるかどうかを書き換える。**押したときだけ送る**ので、ここでは保存だけ
  # **書いたそばから覚える。** 覚えないと、収集の状態が届いた拍子にフォームが
  # 描き直され、**書きかけが消えます**（保存したつもりで消えたように見える）
  # 要約の時刻と通知は**別のフォーム**（別の枠）だが、書きかけは 1 つに覚える ——
  # 片方を書き換えた拍子に、もう片方の書きかけが消えないように
  def handle_event("edit_notify", %{"setting" => attrs}, socket) do
    topic = socket.assigns.topic

    {:noreply, assign(socket, notify_form: notify_form(topic, pending(socket, attrs)))}
  end

  def handle_event("save_notify", %{"setting" => attrs}, socket) do
    topic = socket.assigns.topic
    pending = pending(socket, attrs)

    case Settings.put(topic.collection, attrs) do
      {:ok, _setting} ->
        # 保存したぶんは DB の値に戻し、もう片方の書きかけは残す
        {:noreply,
         socket
         |> assign(notify_form: notify_form(topic, Map.drop(pending, Map.keys(attrs))))
         |> put_flash(:info, "保存しました。")}

      {:error, changeset} ->
        # **書いたものは消さない。** 時刻の書き方を間違えただけで通知の設定まで
        # 書き直させられると、直すたびに全部を入れ直すことになる
        {:noreply,
         socket
         |> assign(notify_form: notify_form(topic, pending))
         |> put_flash(:error, first_error(changeset))}
    end
  end

  # **まとめを作らせて知らせる。** 整理を 1 回起こしてから要約を起こす ——
  # 整理されていないものでまとめさせると、宣伝も重複も読み物に入る。
  # **数分かかる**ので、待つのは押した人ではなく Task の側
  # 同じ話題のまとめが走っている間は断る（`Chidori.SingleFlight`）
  def handle_event("digest_now", _params, socket) do
    topic = socket.assigns.topic

    message =
      case Digest.start(topic) do
        {:ok, _pid} -> "整理から始めています…（数分かかります）"
        {:error, :busy} -> reason_text(:busy)
        {:error, _reason} -> "まとめを始められませんでした。もう一度押してください。"
      end

    {:noreply, assign(socket, digest_message: message)}
  end

  # **いまあるまとめをもう一度知らせる。** 作り直さずに送るだけ
  def handle_event("notify", _params, socket) do
    topic = socket.assigns.topic
    news = socket.assigns.news

    {:noreply,
     case Notify.deliver_latest(topic.collection, news) do
       {:ok, :sent} -> put_flash(socket, :info, "まとめを知らせました。")
       {:ok, :nothing_to_send} -> put_flash(socket, :error, "知らせるまとめがまだありません。")
       {:error, reason} -> put_flash(socket, :error, notify_error(reason))
     end}
  end

  # **この場で 1 回だけ頼む。** 定時の巡回は決まった仕事しかしないので、
  # 「この話の続きを追って」のような頼みごとの行き先がここしかない
  # **記事を押すと詳細を開く**（画家の図と同じくモーダル）。探すのは一覧と、
  # トピックで引いた記事の両方（どちらからも開ける）
  def handle_event("open_article", %{"title" => title}, socket) do
    theme_articles =
      if is_list(socket.assigns.theme_articles), do: socket.assigns.theme_articles, else: []

    article = Enum.find(socket.assigns.news.articles ++ theme_articles, &(&1.title == title))
    {:noreply, assign(socket, opened_article: article, article_asked: nil)}
  end

  # **お気に入りに入れる / 外す**（記事の詳細から）。残すのは URL と見出しだけ
  # （`Chidori.News.Favorites`）。記事そのものは Chiezo の期限で消えても、ここは残る
  def handle_event("toggle_favorite", %{"url" => url, "title" => title}, socket) do
    result =
      if MapSet.member?(socket.assigns.favorite_urls, url),
        do: Favorites.remove(url),
        else: Favorites.add(url, title)

    {:noreply, after_favorite(socket, result)}
  end

  # お気に入りの一覧から外す
  def handle_event("remove_favorite", %{"url" => url}, socket),
    do: {:noreply, after_favorite(socket, Favorites.remove(url))}

  def handle_event("close_article", _params, socket),
    do: {:noreply, assign(socket, opened_article: nil, article_asked: nil)}

  # **その記事について頼む**（割り込み）。記事を名指しするので、頼んだ 1 件は
  # 必ず AI に見せられる。定時の巡回の進み具合にも次の予定にも触らない
  def handle_event("ask_article", %{"note" => note}, socket) do
    topic = socket.assigns.topic
    article = socket.assigns.opened_article

    case {String.trim(note || ""), article} do
      {"", _} ->
        {:noreply, assign(socket, article_asked: {:error, :empty_note})}

      {_written, nil} ->
        {:noreply, socket}

      {written, article} ->
        text = "「#{article.title}」について。#{written}"

        # 同じ記事への頼みは 1 本だけ（続けて押しても AI の回を重ねない）
        key = {:ask_article, topic.collection, article.title}

        if Chidori.SingleFlight.busy?(key) do
          {:noreply, assign(socket, article_asked: {:error, :busy})}
        else
          {:noreply,
           socket
           |> assign(asking: true, article_asked: :asking)
           |> start_async(:ask, fn ->
             Chidori.SingleFlight.run(key, fn ->
               News.ask_focus(topic.collection, text, [article.title])
             end)
           end)}
        end
    end
  end

  # ---- トピックの網（記事とは別の収集）--------------------------------------

  # カレンダーの月を送る（`by` は -1 / 1）。押した日は月が変われば外す
  def handle_event("cal_shift", %{"by" => by}, socket) do
    month = Events.shift_month(socket.assigns.cal_month, String.to_integer(by))
    {:noreply, socket |> assign(cal_month: month, cal_day: nil) |> load_calendar()}
  end

  # 絵の無い注目作に絵を探させる（映画）。**頼むだけ**で、付いた絵は次に開いたとき出る
  def handle_event("fill_images", _params, socket) do
    topic = socket.assigns.topic

    with %{} <- topic,
         base when is_binary(base) <- News.chiezo_base_url(),
         works when works != nil <- Topics.works(topic),
         {:ok, count} <- works.fill_images(base, topic) do
      message =
        if count > 0,
          do: "絵の無い注目作 #{count} 本の絵を探すよう頼みました（数分かかります）。",
          else: "絵の無い注目作はありません。"

      {:noreply, put_flash(socket, :info, message)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, ask_error(reason))}
      _other -> {:noreply, put_flash(socket, :error, "Chiezo の場所が設定されていません。")}
    end
  end

  def handle_event("cal_today", _params, socket),
    do:
      {:noreply,
       socket |> assign(cal_month: Events.this_month(), cal_day: nil) |> load_calendar()}

  # 日を押すと、その日のイベントを下に並べる。**同じ日をもう一度押すと閉じる**
  def handle_event("cal_day", %{"date" => date}, socket) do
    case Date.from_iso8601(date) do
      {:ok, day} ->
        {:noreply, assign(socket, cal_day: if(socket.assigns.cal_day == day, do: nil, else: day))}

      _ ->
        {:noreply, socket}
    end
  end

  # 開催地で絞る（押すたびに入れる・外す。何も選んでいなければ全部）
  def handle_event("cal_place", %{"place" => place}, socket) do
    picked = socket.assigns.cal_places

    picked =
      if place in picked, do: List.delete(picked, place), else: picked ++ [place]

    {:noreply, assign(socket, cal_places: picked)}
  end

  def handle_event("cal_all_places", _params, socket),
    do: {:noreply, assign(socket, cal_places: [])}

  def handle_event("pick_theme_sweep", params, socket) do
    {:noreply, assign(socket, theme_picks: sweep_choices(params))}
  end

  # **押す口は 1 つ。** 無ければ作り、あれば設定を送り直す（記事のほうと同じ形）
  def handle_event("collect_themes", params, socket) do
    topic = socket.assigns.topic
    picks = merged_picks(socket.assigns.theme_picks, params)

    case with_base(&Themes.setup(&1, topic, picks)) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Chiezo へ送りました。") |> load_themes()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, ask_error(reason))}
    end
  end

  # **予定を待たずに 1 回、語を拾い直させる。** 拾うのは機械なので AI の枠を使わない
  def handle_event("pick_themes", _params, socket) do
    topic = socket.assigns.topic

    case with_base(&Themes.pick_now(&1, topic)) do
      :ok ->
        {:noreply, put_flash(socket, :info, "語を拾うよう頼みました。終わったら読み直してください。")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, ask_error(reason))}
    end
  end

  # **トピックの網で語を選ぶ**（札を押したとき。`TopicMap` が送る）。選んだ語の記事を
  # 引いて、図の下に並べる。**その語と、畳んだ言い換え**で引く（記事の側は畳む前の
  # 表記のまま残っている）。空の名前は「選ぶのをやめる」
  # **トピックを名前で探す**（表記ゆれ・畳んだ言い換えも。`Chidori.Themes.Search`）。
  # **候補を出すだけで、図はまだ動かさない**（画家の図と同じ）—— 打っている途中で
  # 図が飛び回ると、どこを見ていたのか分からなくなる
  def handle_event("search_theme", %{"q" => q}, socket),
    do: {:noreply, assign(socket, theme_query: q)}

  def handle_event("clear_theme_search", _params, socket),
    do: {:noreply, assign(socket, theme_query: "")}

  # 候補を選んだら、その札へ寄り、札を押したのと同じく記事を開く。
  # **寄せるのは画面の側**（`focus` を図へ送る）—— 器の大きさは向こうしか知らない
  def handle_event("focus_theme", %{"name" => name}, socket) do
    case Enum.find(
           Chidori.Themes.Graph.build(socket.assigns.themes.themes).nodes,
           &(&1.name == name)
         ) do
      nil ->
        {:noreply, socket}

      node ->
        {:noreply, socket} = handle_event("pick_theme", %{"name" => name}, socket)

        {:noreply,
         socket
         |> assign(theme_query: "")
         |> push_event("focus", %{x: node.x, y: node.y, name: name})}
    end
  end

  def handle_event("pick_theme", %{"name" => name}, socket) when name in [nil, ""],
    do: {:noreply, assign(socket, picked_theme: nil, theme_articles: nil)}

  def handle_event("pick_theme", %{"name" => name}, socket) do
    topic = socket.assigns.topic

    case Enum.find(socket.assigns.themes.themes, &(&1.name == name)) do
      nil ->
        {:noreply, socket}

      theme when topic != nil ->
        names = [theme.name | synonyms_of(theme)]

        {:noreply,
         socket
         |> assign(picked_theme: theme.name, theme_articles: :loading)
         |> start_async({:theme_articles, theme.name}, fn ->
           News.articles_tagged(topic.collection, names)
         end)}

      _no_topic ->
        {:noreply, socket}
    end
  end

  # **興味トピックを選ぶ・外す。** 選び直したら、**整理と興味の要約の依頼文を
  # Chiezo へ送り直す**（依頼文は Chiezo に置いてあるので、送らないと効かない）。
  # 送るときは、いま Chiezo に入っている巡回ごとの相手をそのまま載せる ——
  # 載せないと、送り直した拍子に画面で選んだ相手が既定へ戻る。
  # **付け終えた興味度は動かさない**（依頼文でそう頼んである。点はその時点の興味での判断）
  def handle_event("toggle_interest", %{"name" => name}, socket) do
    topic = socket.assigns.topic

    if topic do
      interests = Interests.toggle(topic.collection, name)
      socket = assign(socket, interests: interests)

      if socket.assigns.news.collection do
        News.push_settings(
          News.server(topic.collection),
          topic,
          current_choices(socket.assigns.news.collection)
        )

        push_followers(topic)

        {:noreply, put_flash(socket, :info, "興味トピックを変えて、整理と要約の依頼文を Chiezo へ送り直しました。")}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # 記事一覧の並びを切り替える
  def handle_event("sort_articles", %{"by" => "interest"}, socket),
    do: {:noreply, assign(socket, article_sort: :interest)}

  def handle_event("sort_articles", %{"by" => "newest"}, socket),
    do: {:noreply, assign(socket, article_sort: :newest)}

  def handle_event("sort_articles", %{"by" => "bookmarks"}, socket),
    do: {:noreply, assign(socket, article_sort: :bookmarks)}

  def handle_event("sort_articles", _params, socket),
    do: {:noreply, assign(socket, article_sort: :importance)}

  # **まとめを全画面で読む。** 記事の一覧の上に置いたままだと、長いまとめは
  # 一覧を押し下げ、通しで読むにも画面の端が気になる。開いたら左右で前後のまとめへ
  # 目次の項目から開いたときは、その章から見せる（`section`）
  # **作品を押すと詳細を開く**（`ChidoriWeb.WorkModal`）。探すのは注目作の一覧と
  # カレンダーの両方で、どちらにも無ければ（要約から開いた作品）Chiezo から引く
  def handle_event("open_work", %{"title" => title}, socket) do
    entries =
      Enum.flat_map([socket.assigns.works, socket.assigns.cal_events], fn
        {:ok, list} -> list
        _other -> []
      end)

    {:noreply, WorkModal.open(socket, title, socket.assigns.topic, entries)}
  end

  def handle_event("close_work", _params, socket), do: {:noreply, WorkModal.close(socket)}

  # 作品の「見た」印とメモを書く。**空にしたら消える**（関連図の「見た」と同じ）
  def handle_event("save_work_mark", params, socket),
    do: {:noreply, WorkModal.save_mark(socket, socket.assigns.topic, params)}

  def handle_event("open_digest", %{"index" => index} = params, socket) do
    section = if params["section"], do: to_index(params["section"])
    kind = if params["kind"] == "interest", do: :interest, else: :main

    {:noreply,
     socket
     |> assign(digest_kind: kind)
     |> show_digest(to_index(index))
     |> assign(digest_section: section)}
  end

  # 左右のスワイプ・矢印。**1 が古いほう**（まとめは新しい順に並んでいる）。
  # 前後へ動いたら、章の指定は捨てる（別のまとめの章番号になるため）
  def handle_event("digest_step", %{"by" => by}, socket) do
    case socket.assigns.digest_open do
      nil ->
        {:noreply, socket}

      at ->
        {:noreply, socket |> show_digest(at + to_index(by)) |> assign(digest_section: nil)}
    end
  end

  def handle_event("close_digest", _params, socket),
    do: {:noreply, assign(socket, digest_open: nil)}

  # 開いている間だけ、キーボードでも動かせる（← で古いほう、→ で新しいほう、Esc で閉じる）。
  # 向きは上の帯のボタンの並びと同じ（古いほうが左）
  def handle_event("digest_key", %{"key" => key}, socket) do
    case {socket.assigns.digest_open, key} do
      {nil, _key} ->
        {:noreply, socket}

      {_at, "Escape"} ->
        {:noreply, assign(socket, digest_open: nil)}

      {at, "ArrowLeft"} ->
        {:noreply, socket |> show_digest(at + 1) |> assign(digest_section: nil)}

      {at, "ArrowRight"} ->
        {:noreply, socket |> show_digest(at - 1) |> assign(digest_section: nil)}

      _other ->
        {:noreply, socket}
    end
  end

  defp to_index(value) when is_integer(value), do: value

  defp to_index(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _other -> 0
    end
  end

  defp to_index(_value), do: 0

  # 開くまとめを決め、**本文をまだ持っていなければ引きに行く**。端より先へは進まない
  defp show_digest(socket, index) do
    digests = digests_of(socket.assigns.news, socket.assigns.digest_kind)

    if digests == [] do
      assign(socket, digest_open: nil)
    else
      index = index |> max(0) |> min(length(digests) - 1)
      digest = Enum.at(digests, index)
      socket = assign(socket, digest_open: index)

      if index == 0 or Map.has_key?(socket.assigns.digest_full, digest.title) or
           socket.assigns.topic == nil do
        socket
      else
        collection = socket.assigns.topic.collection

        start_async(socket, {:digest, digest.title}, fn ->
          News.full_digest(collection, digest)
        end)
      end
    end
  end

  @doc """
  全画面で見せるまとめ。本文を取り直したものがあればそちら（先頭の 1 件は最初から持つ）。
  """
  def opened_digest(index, news, full, kind \\ :main)

  def opened_digest(nil, _news, _full, _kind), do: nil

  def opened_digest(index, news, full, kind) do
    case Enum.at(digests_of(news, kind), index) do
      nil -> nil
      digest -> Map.get(full, digest.title, digest)
    end
  end

  @doc "全画面で行き来する並び（ふつうのまとめ / 興味トピックの要約）。"
  def digests_of(news, :interest), do: Map.get(news, :interest_digests, [])
  def digests_of(news, _kind), do: Map.get(news, :digests, [])

  # 畳んだ言い換え（トピックの `同義:` のタグ）
  defp synonyms_of(theme), do: Themes.synonyms_of(theme)

  # 探す欄の候補の数。**多すぎると図を覆う**（絞りたい人は語を足す）
  @theme_hits 12

  @doc "探す欄の候補（近い順・上限つき）。言い換えで当たったものは、その言い換えを添える。"
  def theme_hits(themes, query) do
    needle = Chidori.Themes.Search.normalize(query)

    themes
    |> Chidori.Themes.Search.search(query)
    |> Enum.take(@theme_hits)
    |> Enum.map(fn theme ->
      alias_hit =
        if String.contains?(Chidori.Themes.Search.normalize(theme.name), needle),
          do: nil,
          else:
            Enum.find(
              Themes.synonyms_of(theme),
              &String.contains?(Chidori.Themes.Search.normalize(&1), needle)
            )

      %{name: theme.name, docs: theme.docs, alias: alias_hit}
    end)
  end

  # **この話題の興味トピックを使う話題も送り直す**（技術イベントは技術ニュースのものを
  # 使う。`Chidori.Topics` の `interests_from`）。送り直さないと、先の月を探す回が
  # 古い興味トピックのまま探し続ける。**読めている話題だけ** —— 巡回ごとに選んである
  # 相手は Chiezo から読んだものを引き継ぐので、読めていないと選んだ相手を消してしまう
  defp push_followers(topic) do
    for other <- Topics.list(), other[:interests_from] == topic.collection do
      server = News.server(other.collection)

      case News.current(server) do
        %{collection: %{} = collection} ->
          News.push_settings(server, other, current_choices(collection))

        _not_read ->
          :skip
      end
    end
  end

  @doc """
  いま Chiezo に入っている巡回ごとの相手（`News.attrs/3` の `choices` の形）。
  **送り直すときに載せる** —— 載せないと、画面で選んだ相手が既定へ戻る。
  """
  def current_choices(%{sweeps: sweeps}) when is_list(sweeps) do
    Map.new(sweeps, fn sweep ->
      {sweep.name, %{backend: sweep[:backend] || "", model: sweep[:model] || ""}}
    end)
  end

  def current_choices(_collection), do: %{}

  defp with_base(fun) do
    case News.chiezo_base_url() do
      nil -> {:error, :chiezo_not_configured}
      base -> fun.(base)
    end
  end

  defp with_server(socket, fun) do
    if topic = socket.assigns.topic, do: fun.(News.server(topic.collection))
    {:noreply, socket}
  end

  @impl true
  def handle_async(:ask, {:ok, :ok}, socket),
    do: {:noreply, assign(socket, asking: false, article_asked: :ok)}

  def handle_async(:ask, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, asking: false, article_asked: {:error, reason})}

  # 起きなかったことは黙って捨てない。押した人には確かめようがない
  def handle_async(:ask, _result, socket),
    do: {:noreply, assign(socket, asking: false, article_asked: {:error, :unknown})}

  # **見ている月の答えだけ受け取る**（月を続けて送ると、前の月の答えが後から届く）
  def handle_async({:calendar, month}, result, socket) do
    if month == socket.assigns.cal_month do
      events =
        case result do
          {:ok, {:ok, list}} -> {:ok, list}
          {:ok, {:error, reason}} -> {:error, reason}
          _exit -> {:error, :chiezo_unavailable}
        end

      {:noreply, assign(socket, cal_events: events)}
    else
      {:noreply, socket}
    end
  end

  # **見ている話題の答えだけ受け取る**（タブを続けて切り替えると、前の話題の答えが後から届く）
  def handle_async({:works, collection}, result, socket) do
    if socket.assigns.topic && socket.assigns.topic.collection == collection do
      works =
        case result do
          {:ok, {:ok, list}} -> {:ok, list}
          {:ok, {:error, reason}} -> {:error, reason}
          _exit -> {:error, :chiezo_unavailable}
        end

      {:noreply, assign(socket, works: works)}
    else
      {:noreply, socket}
    end
  end

  # **見ている話題の網だけ受け取る。** タブを続けて切り替えると、前の話題の網が
  # 後から届く —— 受け取ると、網を持たない話題のページに別の話題の図が出る
  def handle_async({:themes, collection}, {:ok, state}, socket) when is_map(state) do
    case socket.assigns.topic do
      %{collection: ^collection} = topic ->
        if Topics.themes?(topic),
          do: {:noreply, assign(socket, themes: state)},
          else: {:noreply, socket}

      _other ->
        {:noreply, socket}
    end
  end

  # 読めなくても記事は読める（何が読めていないかは収集の枠に出る）
  def handle_async({:themes, _collection}, _result, socket), do: {:noreply, socket}

  # **いま見ている話題の答えだけ受け取る**（話題を切り替えた直後に前の答えが届くことがある）
  def handle_async({:ai_digests, collection}, result, socket) do
    if socket.assigns.topic && socket.assigns.topic.collection == collection do
      value =
        case result do
          {:ok, answer} -> answer
          {:exit, _reason} -> {:error, :chiezo_unavailable}
        end

      {:noreply, assign(socket, ai_digests: value)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:backends, {:ok, list}, socket) when is_list(list),
    do: {:noreply, assign(socket, backends: list)}

  # 引けなくても記事は読める。**選べないだけ**
  def handle_async(:backends, _result, socket), do: {:noreply, socket}

  # 選んだ語の記事。**選び直したあとに前の語の結果が届くことがある**ので、語で確かめる
  def handle_async({:theme_articles, name}, {:ok, result}, socket) do
    if socket.assigns.picked_theme == name do
      case result do
        {:ok, articles} -> {:noreply, assign(socket, theme_articles: articles)}
        {:error, reason} -> {:noreply, assign(socket, theme_articles: {:error, reason})}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async({:theme_articles, name}, _exit, socket) do
    if socket.assigns.picked_theme == name,
      do: {:noreply, assign(socket, theme_articles: {:error, :chiezo_unavailable})},
      else: {:noreply, socket}
  end

  # 作品の詳細で引いた作品（開いている作品の答えだけ受け取る）
  def handle_async({:work, title}, result, socket),
    do: {:noreply, WorkModal.loaded(socket, title, result)}

  def handle_async({:digest, title}, {:ok, digest}, socket),
    do: {:noreply, update(socket, :digest_full, &Map.put(&1, title, digest))}

  # 取れなくても冒頭は出ている（開けないより、切れた文でも読めるほうがよい）
  def handle_async({:digest, _title}, _result, socket), do: {:noreply, socket}

  @impl true
  # まとめを作らせている最中の一言。**収集の状態とは別に受ける** ——
  # 状態に混ぜると、届くたびに画面ぜんたいが書き換わる
  def handle_info({:digest_progress, collection, message}, socket) do
    topic = socket.assigns.topic

    if topic && collection == topic.collection do
      {:noreply, assign(socket, digest_message: message)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:news_updated, news}, socket) do
    topic = socket.assigns.topic

    # 話題を切り替えた直後は、前の話題の結果が遅れて届くことがある
    if topic && news.name == topic.collection do
      {:noreply, socket |> assign(news: news) |> open_wanted_digest()}
    else
      {:noreply, socket}
    end
  end

  defp after_favorite(socket, result) do
    socket =
      assign(socket,
        favorite_urls: Favorites.urls(),
        favorites: if(socket.assigns.favorites_view, do: Favorites.list(), else: [])
      )

    case result do
      {:error, _reason} -> assign(socket, favorite_error: "お気に入りを保存できませんでした")
      _ok -> assign(socket, favorite_error: nil)
    end
  end

  defp page_title(_topic, true), do: "最新情報（お気に入り）"
  defp page_title(nil, false), do: "最新情報"
  defp page_title(topic, false), do: "最新情報（#{topic.name}）"

  @doc "お気に入りのタブの `view` の値（話題の収集の名前とぶつからない語）。"
  def favorites_view, do: @favorites_view

  @doc "その記事がお気に入りに入っているか（URL で見る）。"
  def favorite?(urls, %{url: url}) when is_binary(url), do: MapSet.member?(urls, url)
  def favorite?(_urls, _article), do: false

  @doc """
  どの話題を見るか。**知らない名前が来たら先頭に落とします** ——
  消した話題のリンクを踏んだだけで空白の画面を出す理由が無い。
  """
  def pick_topic(topics, view) do
    Enum.find(topics, &(&1.collection == view)) || List.first(topics)
  end

  @doc """
  重要度の高い順に並べる。**同じ重さのものは新しい順のまま**（並べ替えは安定なので、
  Chiezo が返した並びがそのまま残る）。

  重要度を付けるのは整理の巡回で、読んだうえでの判断です。ここで並べ替えずに
  出すと、その判断が画面に現れません —— 新しい順に並ぶだけなら、印を付けた意味が
  一覧から消えます。

  **低いものも消しません** —— 重要度は並びであって、ふるい分けではない。
  """
  def sorted_articles(news, sort \\ :importance)

  # **興味の近い順**。点の無いもの（興味トピックを選ぶ前に入った・まだ整理が
  # 読んでいない）は後ろへ。同じ点なら重要度の順
  def sorted_articles(%{articles: articles}, :interest),
    do: Enum.sort_by(articles, &{-(&1[:interest] || -1), -&1.importance})

  # 新しい順は、読み込んだときの並び（公開の新しい順。`News.in_window/2`）のまま
  def sorted_articles(%{articles: articles}, :newest), do: articles

  # **反応の多い順**（はてブ数の実数）。数の無い記事は後ろ、同じ数なら重要度順
  def sorted_articles(%{articles: articles}, :bookmarks),
    do: Enum.sort_by(articles, &{-(&1[:bookmarks] || -1), -&1.importance})

  def sorted_articles(%{articles: articles}, _sort), do: Enum.sort_by(articles, &(-&1.importance))

  def sorted_articles(_news, _sort), do: []

  attr :digests, :list, required: true
  attr :kind, :string, required: true
  attr :label, :string, default: nil
  attr :articles, :list, default: []
  # 頭におすすめの絵を並べるか（作品を育てる話題の要約。`hero?/1`）
  attr :hero, :boolean, default: false

  @doc """
  要約の窓。**見出し・要旨・目次はここで読める。** 章と出典は全画面で読む ——
  長いまとめをここに全部広げると、下の話題と記事一覧が遠くなる。
  押すと全画面で開き、目次の項目を押すとその章から開く。
  """
  def digest_preview(assigns) do
    assigns = assign(assigns, digest: List.first(assigns.digests))

    ~H"""
    <div
      class="digest-preview"
      role="button"
      tabindex="0"
      phx-click="open_digest"
      phx-value-index="0"
      phx-value-kind={@kind}
      aria-label="要約を全画面で読む"
    >
      <.report
        title={@digest.title}
        at={@digest.collected_at}
        body={@digest.summary}
        label={@label}
        articles={@articles}
        cited={@digest.cited}
        id_prefix={"preview-#{@kind}"}
        hero={@hero}
        intro_only
        open_event="open_digest"
        open_kind={@kind}
      />
      <p class="digest-open-hint">
        タップで全文を全画面で読む<span :if={length(@digests) > 1}>（左右のスワイプで前後の要約へ）</span>
      </p>
    </div>
    """
  end

  attr :news, :map, required: true
  # 開いている要約の位置（新しい順の何番目か）。nil なら閉じている
  attr :open, :integer, default: nil
  attr :full, :map, default: %{}
  attr :kind, :atom, default: :main
  attr :section, :integer, default: nil
  attr :label, :string, default: nil
  attr :hero, :boolean, default: false

  # 章ごとに、紹介した作品を開く口を添えるか（映画・アニメの要約。押したときの
  # イベント名。`ChidoriWeb.Report.report/1` の `open_work_event`）
  attr :open_work_event, :string, default: nil

  # ←・→・Esc を受けるか。**作品の詳細を上に開いている間は受けない** —— 受けると、
  # 詳細を閉じるつもりの Esc で要約まで閉じる
  attr :keys, :boolean, default: true

  @doc """
  全画面の要約。**左右のスワイプで前後の要約へ**（`DigestSwipe`）。最新情報の画面と
  トップページで同じもの（押したときの動き —— `open_digest` / `digest_step` /
  `close_digest` / `digest_key` —— は、置いた画面の側が受ける）。

  **古いほうを左に置く** —— 右へ払う（左のものを引き出す）のは「戻る」の
  動きなので、戻る先が古いほう。新しいほうへは左へ払う。
  """
  def digest_viewer(assigns) do
    assigns =
      assign(assigns,
        viewing: digests_of(assigns.news, assigns.kind),
        viewed: opened_digest(assigns.open, assigns.news, assigns.full, assigns.kind)
      )

    ~H"""
    <div
      :if={@viewed}
      id="digest-viewer"
      class="digest-viewer"
      role="dialog"
      aria-modal="true"
      aria-label="要約"
      phx-hook="DigestSwipe"
      phx-window-keydown={@keys && "digest_key"}
      data-index={@open}
      data-section={@section}
    >
      <nav class="digest-viewer-bar" aria-label="要約の切り替え">
        <button
          type="button"
          phx-click="digest_step"
          phx-value-by="1"
          disabled={@open >= length(@viewing) - 1}
          aria-label="古い要約"
        >
          ← 古い
        </button>
        <span class="digest-viewer-count">{@open + 1} / {length(@viewing)}</span>
        <button
          type="button"
          phx-click="digest_step"
          phx-value-by="-1"
          disabled={@open == 0}
          aria-label="新しい要約"
        >
          新しい →
        </button>
        <button
          type="button"
          class="digest-viewer-close"
          phx-click="close_digest"
          aria-label="閉じる"
        >
          ×
        </button>
      </nav>
      <div class="digest-viewer-body">
        <.report
          title={@viewed.title}
          at={@viewed.collected_at}
          body={@viewed.summary}
          label={@label}
          articles={@news.articles}
          cited={@viewed.cited}
          id_prefix="digest-viewer"
          hero={@hero}
          open_work_event={@open_work_event}
        />
      </div>
    </div>
    """
  end

  # 上映館を聞けるのは、公開日がこの日数より前のものまで（前売りが始まっている頃）
  @showing_within_days 7

  @doc "公開中か、もうすぐ公開される作品か（上映館を聞くリンクを出すか）。"
  def showing_soon?(entry, today \\ Jst.today())

  def showing_soon?(%{date: %Date{} = date}, today),
    do: Date.diff(date, today) <= @showing_within_days

  def showing_soon?(_entry, _today), do: false

  @doc """
  近くで上映している映画館を聞く質問文。`where` は現在地（「緯度,経度」）か、
  書いてもらった地域（`{:region, "新宿"}`）。無ければ「いまいる場所」とだけ書きます
  （AI モードの側でおおよその場所は分かる）。
  **答えの順番まで頼みます** —— 観に行けるかを決めるのは、どこで・何時からか。
  """
  def theaters_question(title, where \\ nil) do
    near =
      case where do
        {:region, region} -> "#{region}の近くにあるところ"
        coords when is_binary(coords) -> "現在地（#{coords}）から近いところ"
        _none -> "いまいる場所から近いところ"
      end

    "映画「#{title}」を上映している映画館のうち、#{near}を教えてください。" <>
      "今日は #{Jst.today() |> Date.to_iso8601()} です。" <>
      "まず近い順に 3 館ほど、映画館の名前・最寄り駅からの行き方・今日と明日の上映時間を" <>
      "箇条書きで手短に。上映形式（IMAX・字幕・吹替など）が分かれば添えてください。" <>
      "上映時間は変わりやすいので、確かでないところはそう言い添え、" <>
      "映画館の上映スケジュールの頁の URL も教えてください。"
  end

  @doc """
  その質問を入れて Gemini（Google 検索の AI モード。`udm=50`）を開く URL。
  **gemini.google.com は URL で質問文を渡せない**ので、同じ Gemini が答える AI モードを使う。
  """
  def theaters_url(title, where \\ nil),
    do: ai_mode_url(theaters_question(title, where))

  @doc "質問文を入れて Google 検索の AI モードを開く URL。"
  def ai_mode_url(question),
    do: "https://www.google.com/search?" <> URI.encode_query(%{"udm" => "50", "q" => question})

  # 作品に付けた「見た」印（映画・アニメの話題だけ。ほかの話題では nil）
  defp work_marks(topic) do
    case topic && Topics.works(topic) do
      works when is_atom(works) and works != nil ->
        if function_exported?(works, :mark_view, 0),
          do: Marks.for_view(works.mark_view()),
          else: nil

      _none ->
        nil
    end
  end

  @doc "その作品を見たか（見出しの横の印）。"
  def seen_work?(marks, title) when is_map(marks), do: match?(%Mark{seen: true}, marks[title])
  def seen_work?(_marks, _title), do: false

  @doc "見た記録の札の一言（「見た（2026-10-11）」「見た」「メモあり」）。"
  def mark_summary(%Mark{seen: true, seen_on: %Date{} = date}), do: "見た（#{Date.to_iso8601(date)}）"
  def mark_summary(%Mark{seen: true}), do: "見た"
  def mark_summary(%Mark{note: note}) when is_binary(note) and note != "", do: "メモあり"
  def mark_summary(_mark), do: nil

  @doc "1 行を、地の文と URL に分けます（URL はリンクにするため）。"
  def link_parts(line) do
    ~r{https?://[^\s　、。）)」]+}u
    |> Regex.split(line, include_captures: true, trim: true)
    |> Enum.map(fn part ->
      if String.match?(part, ~r{\Ahttps?://}), do: {:url, part}, else: {:text, part}
    end)
  end

  @doc "記事 1 件の札（記事一覧と、トピックから引いた記事で同じもの）。"
  attr :article, :map, required: true
  attr :interests, :list, default: []
  attr :near, :map, default: %{}
  # お気に入りに入っているか（日付の並びに印を出す）
  attr :favorite, :boolean, default: false

  def article_card(assigns) do
    ~H"""
    <%!-- **押すと詳細が開く**（画家の図と同じくモーダル）。原文へのリンクは詳細の中に
         置く —— 札の中にもリンクがあると、押した場所で起きることが変わってしまう --%>
    <article
      class="article-card"
      phx-click="open_article"
      phx-value-title={@article.title}
      role="button"
      tabindex="0"
    >
      <%!-- 配信元が配っている絵。**無いほうが多い**ので、あるときだけ出す --%>
      <img
        :if={@article.image}
        class="news-thumb"
        src={SafeUrl.src(@article.image)}
        alt=""
        loading="lazy"
      />
      <div>
        <%!-- 反応の大きさ・興味の近さは重要度と別の軸なので、印の隣ではなく日付の並びに置く --%>
        <p class="news-source">
          <span :if={@favorite} class="favorite-mark" title="お気に入り">★</span>{@article.collected_at}<span
            :if={is_integer(@article[:bookmarks]) and @article[:bookmarks] > 0}
            class="bookmark-count"
          >・{@article[:bookmarks]} users</span><span :if={buzz_text(@article)}>・{buzz_text(@article)}</span><span
            :if={interest_text(@article)}
            class="interest-score"
          >・{interest_text(@article)}</span>
        </p>
        <h2>{@article.title}</h2>
        <p :if={@article.summary} class="news-summary">{@article.summary}</p>
        <.tag_chips tags={article_tags(@article, @interests, @near)} />
        <%!-- なぜこの重さなのか。読んだ AI が付けた印なら、その旨も含めて出る --%>
        <p class="news-reason">{@article.reason}</p>
      </div>
      <span class={importance_class(@article.importance)}>
        {importance_label(@article.importance)}
      </span>
    </article>
    """
  end

  attr :tags, :list, required: true

  @doc "記事のタグ。**興味トピックに当たるものは強調する**（そのもの / 近いもの）。"
  def tag_chips(assigns) do
    ~H"""
    <p :if={@tags != []} class="article-tags">
      <span
        :for={{tag, mark} <- @tags}
        class={["article-tag", mark == :exact && "is-interest", mark == :near && "is-near"]}
        title={mark_title(mark)}
      >
        {tag}
      </span>
    </p>
    """
  end

  defp mark_title(:exact), do: "興味トピック"
  defp mark_title(:near), do: "興味トピックに近い語（言い換え・すぐ下の話題）"
  defp mark_title(_mark), do: nil

  @doc "興味度の見え方（無ければ nil）。"
  def interest_text(%{interest: n}) when is_integer(n), do: "興味 #{n}"
  def interest_text(_article), do: nil

  @doc "重要度の見え方。0〜2 の 3 段で、高いものだけ色を変える。"
  def importance_class(2), do: "priority"
  def importance_class(0), do: "later"
  def importance_class(_importance), do: "standard"

  def importance_label(2), do: "優先"
  def importance_label(0), do: "急がない"
  def importance_label(_importance), do: "注目"

  @doc """
  どれだけ反応されているか（整理の回が付けた `話題度` の印）。

  **重要度とは別の軸**なので、別の場所に出します —— 話題になっていないが効くものも、
  効かないが沸いているものもあり、同じ印にすると、どちらの読み方もできません。

  **印が無ければ何も出しません。** まだ整理が読んでいないだけの 1 件に
  「広がっていません」と書くと、読んだうえでの判断に見えます。
  """
  def buzz_text(%{buzz: "高"}), do: "よく読まれています"
  def buzz_text(%{buzz: "中"}), do: "そこそこ読まれています"
  def buzz_text(%{buzz: "低"}), do: "まだ広がっていません"
  def buzz_text(_article), do: nil

  @doc """
  いまの状態を1文で言う。押した人が次に何をすればよいか分かる言い方にする。
  """
  def status_message(%{configured: false}),
    do: "Chiezo の場所が設定されていません。`CHIEZO_BASE_URL` を渡すと使えるようになります。"

  def status_message(%{status: :loading}), do: "Chiezo に問い合わせています。"

  def status_message(%{reason: reason}) when not is_nil(reason), do: reason_text(reason)

  def status_message(%{collection: nil}),
    do:
      "まだ Chiezo に収集を依頼していません。「収集を依頼する」を押すと、" <>
        "止めた状態の収集が Chiezo に作られます。"

  def status_message(%{collection: %{enabled: false}}),
    do:
      "収集は Chiezo にありますが、まだ止まっています。" <>
        "動かすかどうかは Chiezo 側で決めるので、Chiezo の管理画面の「集める」で有効にしてください。"

  def status_message(%{collection: %{docs: 0}}),
    do: "収集は動いていますが、まだ1件も溜まっていません。"

  def status_message(_news), do: nil

  @doc """
  AI に頼んでいる本文。

  **依頼した後は Chiezo が持っているものを出す** —— 向こうの画面から直せるので、
  Chidori の雛形を出し続けると、実際に投げている文と画面が食い違う。
  まだ依頼していないときは、これから送る雛形を出す。
  """
  def prompt_text(%{collection: %{prompt: prompt}}, _topic)
      when is_binary(prompt) and prompt != "",
      do: prompt

  def prompt_text(_news, topic), do: News.prompt(topic)

  def prompt_note(%{collection: nil}), do: "「収集を依頼する」を押すと、この内容で Chiezo に頼みます。"

  def prompt_note(_news),
    do: "いま Chiezo が持っている内容です。直すのは Chiezo の管理画面の「集める」から。"

  @doc """
  トピックの収集の整理の回の依頼文。**Chiezo が持っているものを先に出します**
  （まだ依頼していなければ、送る予定の内容）。
  """
  def theme_prompt_text(%{collection: %{prompt: prompt}}, _topic)
      when is_binary(prompt) and prompt != "",
      do: prompt

  def theme_prompt_text(_themes, topic), do: Themes.tidy_prompt(topic)

  def theme_prompt_note(%{collection: c}) when is_map(c),
    do: "いま Chiezo が持っている内容です。直すのは Chiezo の管理画面の「集める」から。"

  def theme_prompt_note(_themes),
    do: "この節の「収集を依頼する」を押すと、この内容で Chiezo に頼みます。"

  @doc "知らせられる状態か。**押せない口は出さない**。"
  def can_notify?(nil), do: false

  def can_notify?(%{collection: collection}),
    do: match?({:ok, _channels}, Notify.ready(collection))

  @doc "最後に知らせた時刻。押した結果がここに出ます。"
  def last_sent_text(nil), do: nil

  def last_sent_text(%{collection: collection}) do
    case Notify.last_sent_at(collection) do
      nil -> "まだ知らせていません。"
      at -> "最後に知らせたのは #{Jst.format(at)}。"
    end
  end

  @doc false
  def notify_error(reason)
      when reason in [:no_destination, :notify_off, :push_failed, :push_expired],
      do: Digest.error_text(reason)

  def notify_error(:ntfy_unavailable), do: "ntfy に接続できませんでした。"
  def notify_error({:ntfy_status, status}), do: "ntfy が #{status} を返しました。"
  def notify_error(reason), do: "知らせられませんでした（#{inspect(reason)}）。"

  defp first_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {_field, messages} -> messages end)
    |> List.first() || "書いた内容を保存できませんでした。"
  end

  @doc """
  通知の設定の一言。**押す前に、届くのかどうかが読めるように**。

  黙って何もしないと、設定を間違えているのか、まだまとめが無いだけなのかを
  区別できません。**書き先まで出します** —— どこへ書けばよいか分からないと、
  設定しようがありません。
  """
  def notify_note(nil), do: nil

  def notify_note(%{collection: collection}) do
    case Notify.ready(collection) do
      {:ok, channels} ->
        Enum.map_join(channels, "と、", fn
          :ntfy -> "#{Ntfy.base_url()} の「#{Ntfy.topic()}」"
          :push -> "登録した端末 #{length(Chidori.WebPush.Subscriptions.list())} 台"
        end) <> "へ送ります。"

      {:error, :notify_off} ->
        "この話題は知らせません。"

      {:error, :no_destination} ->
        "知らせる設定ですが、通知先（ntfy のトピック名か、通知を受ける端末）が無いので送れません。"
    end
  end

  # 通知の設定のフォーム。**組むのはここだけ** —— 描くたびに DB から組み直すと、
  # 書きかけが消える
  defp notify_form(nil), do: nil

  defp notify_form(%{collection: collection}, attrs \\ %{}) do
    to_form(Settings.changeset(collection, attrs), as: :setting)
  end

  @doc """
  設定の枠の見出し。**画面の名前に合わせます** —— 「設定」とだけ書くと、
  何の設定なのかがタブを切り替えた後に読めません。
  """
  def settings_title(%{name: name}), do: "#{name}の設定"
  def settings_title(_topic), do: "設定"

  @doc """
  要約を作る時刻の一言。**次にいつ知らせるのかまで出します** ——
  時刻だけ書かれていても、それが今日のぶんとして残っているのかは読めません。
  """
  def digest_note(nil), do: nil

  def digest_note(%{collection: collection}) do
    setting = Settings.get(collection)

    case Setting.digest_times(setting) do
      [] ->
        "時刻を書くと、その時刻に整理→要約を起こします。知らせる設定なら、作った後に知らせます" <>
          "（空なら自分からは回りません。08:00 でも 0800 でも 8 でも読めます）。"

      times ->
        "この時刻に、整理を 1 回起こしてからまとめを作らせます（知らせる設定なら、作った後に知らせます。JST）: " <>
          Enum.map_join(times, "、", fn {hour, minute} ->
            String.pad_leading("#{hour}", 2, "0") <>
              ":" <> String.pad_leading("#{minute}", 2, "0")
          end)
    end
  end

  @doc """
  定時の回がどうなったか。**結果まで出します** —— 誰も見ていない時刻に走る回なので、
  「作らせた時刻」だけだと、知らせが来なかったのか、そもそも走っていないのかが
  読めません（実際、ntfy の場所が空のまま走って、静かに送れずにいました）。

  **「前回の」と断ります。** これは記録で、いまの状態ではありません ——
  理由の文は現在形なので（「Chiezo 側で止まっています」）、断らないと、
  ずっと前に止まった回の理由が**いまの状態として読まれます**（実際に読まれました。
  そのときは収集も要約も動いていました）。いまの状態は `digest_state_text/2`。
  """
  def last_digest_text(nil), do: nil

  def last_digest_text(%{collection: collection}) do
    setting = Settings.get(collection)

    case {setting.last_digest_at, setting.last_digest_result} do
      {nil, _result} -> "まだ作らせていません。"
      {_at, result} when is_binary(result) and result != "" -> "前回の定時の回: " <> result
      {at, _result} -> "前回の定時の回: #{Jst.format(at)}。"
    end
  end

  @doc """
  定時の回の、いまの見通し。**記録とは別に出します**。

  下に並ぶのは前に走った回の記録なので、それだけだと「いま動いているのか、
  止まったままなのか」が読めません —— 止まった回の理由が現在形で残るぶん、
  なおさら取り違えます。

  **止まっているときは、次の回も止まると言い切ります**（動かせるのは Chiezo 側
  だけなので、待っていても直りません）。
  """
  def digest_state_text(news, topic)

  def digest_state_text(_news, nil), do: nil

  def digest_state_text(%{collection: %{enabled: false}}, _topic),
    do: "いまは Chiezo 側で止まっています。戻すまでは、次の定時の回もここで止まります。"

  def digest_state_text(%{collection: %{}}, topic) do
    case Scheduler.next(topic) do
      nil -> nil
      at -> "いまは動いています（次の定時の回は #{Jst.format(at)}）。"
    end
  end

  def digest_state_text(_news, _topic), do: nil

  @doc """
  押す口の文字。**何を待っているのかまで出します** ——
  「送っています…」だけだと、押せていないのと区別が付きません。
  """
  def collect_label(%{status: :loading, pushing: true}), do: "送っています…"

  # 開いたときの読み直し。何も送っていないので「送っています」とは出さない
  def collect_label(%{status: :loading}), do: "読み込んでいます…"
  def collect_label(%{collection: nil}), do: "収集を依頼する"
  def collect_label(_news), do: "収集の設定を更新"

  @doc """
  収集がどうなっているかの一言。**押す前に、何が起きるのかが読めるように**。
  """
  def collection_note(%{collection: nil, configured: false}),
    do: "Chiezo の場所（CHIEZO_BASE_URL）が設定されていないので、まだ依頼できません。"

  def collection_note(%{collection: nil}),
    do: "まだ Chiezo に収集がありません。押すと、止まった状態の収集が作られます。"

  def collection_note(%{collection: %{enabled: false}}),
    do: "Chiezo 側で止まっています。動かすのは Chiezo の画面からです。"

  def collection_note(_news), do: "押すと、いまの設定を Chiezo へ送り直します（走らせはしません）。"

  @doc """
  トピックの収集の状態の一言。**押す前に、何が起きるのかが読めるように**。
  """
  def theme_note(%{collection: nil}),
    do: "まだ Chiezo に収集がありません。押すと、止まった状態の収集が作られます。"

  def theme_note(%{collection: %{enabled: false}}),
    do: "Chiezo 側で止まっています。動かすのは Chiezo の画面からです。"

  def theme_note(_state), do: "押すと、いまの設定を Chiezo へ送り直します（走らせはしません）。"

  @doc "トピックの収集の、押す口の文字。何が起きるのかまで出します。"
  def theme_collect_label(%{collection: nil}), do: "収集を依頼する"
  def theme_collect_label(_state), do: "収集の設定を更新"

  # ---- 開催日のカレンダー --------------------------------------------------

  @weekdays ~w(月 火 水 木 金 土 日)

  # マスに名前を出す数。**それより多い日は件数に畳む**（マスが縦に伸びて月が読めなくなる）
  @cal_names 3

  @doc "カレンダーの見出し（「2026年10月」）。"
  def cal_title(%Date{year: year, month: month}), do: "#{year}年#{month}月"
  def cal_title(_month), do: ""

  @doc "日付の呼び名（「10月25日（土）」）。"
  def day_label(%Date{} = date),
    do: "#{date.month}月#{date.day}日（#{Enum.at(@weekdays, Date.day_of_week(date) - 1)}）"

  @doc "カレンダーが読めなかったときの一言。"
  def cal_error({:error, :chiezo_not_configured}), do: "Chiezo の場所が設定されていません。"

  def cal_error({:error, {:chiezo_status, 404}}),
    do: "まだ何も溜まっていません（収集を依頼して、整理が一度回るとここに並びます）。"

  def cal_error(_error), do: "カレンダーを読めませんでした（Chiezo に繋がらないかもしれません）。"

  @doc """
  マスに名前を出すイベント。**注目度が中以上のものだけ**、高い順に数件 ——
  低いものまで並べると、勉強会の多い日はマスが埋まって注目のものが埋もれる。
  """
  def cal_prominent(events) do
    events
    |> Enum.filter(&(&1.attention in [:high, :mid]))
    |> Enum.take(@cal_names)
  end

  @doc "マスの札に添える開催地（海外は「海外」を頭に）。"
  def cal_where(entry) do
    if Events.abroad?(entry),
      do: "海外 " <> Events.short_places(entry),
      else: Events.short_places(entry)
  end

  @doc "開催地のまとめて選ぶ口（その月に国内・海外の両方があるときだけ出す）。"
  def cal_groups(entries) do
    regions = entries |> Enum.flat_map(& &1.places) |> Enum.map(&Events.region/1) |> MapSet.new()

    if MapSet.member?(regions, :japan) and MapSet.member?(regions, :abroad),
      do: [Events.japan(), Events.abroad()],
      else: []
  end

  @doc "マスに名前を出さなかった件数。"
  def cal_rest(events), do: length(events) - length(cal_prominent(events))

  @doc "注目度の呼び名。"
  def attention_label(:high), do: "高"
  def attention_label(:mid), do: "中"
  def attention_label(:low), do: "低"
  def attention_label(_attention), do: ""

  @doc """
  注目作の一覧の並び。**公開中（新しい順）とこれから（近い順）に分けます** ——
  公開中のものは口コミで観るかを決め、これからのものは公開日で予定を立てるので、
  読み方が違います。
  """
  def works_groups(entries, today \\ Chidori.Jst.today(), works \\ Movies) do
    # 始まってから何日前までを並べるか。**整理の回が落とすのと同じ長さ**
    # （それより前のものは、落とし損ねていても並べない）
    from = Date.add(today, -works.recent_days())
    {started, upcoming} = works.group_labels()

    {showing, coming} =
      entries
      |> Enum.filter(&(Date.compare(&1.date, from) != :lt))
      |> Enum.split_with(&(Date.compare(&1.date, today) != :gt))

    [
      {started, Enum.sort_by(showing, &{rank(&1.attention), -Date.to_gregorian_days(&1.date)})},
      {upcoming, Enum.sort_by(coming, & &1.date, Date)}
    ]
    |> Enum.reject(fn {_label, list} -> list == [] end)
  end

  # 公開中は注目度の高い順、同じなら公開の新しい順
  defp rank(:high), do: 0
  defp rank(:mid), do: 1
  defp rank(_attention), do: 2

  @doc """
  一覧に添える絵の場所。**Chiezo が縮めて持っているものを先に使う**（`thumb`。
  見る人のブラウザが知らない外のサイトへつながないため）。無ければ配信元が
  配っている絵（技術イベントの告知サイトのもの）。どちらも無ければ nil。
  """
  def entry_thumb(%{thumb: thumb}) when is_binary(thumb), do: Chidori.Chiezo.thumb_path(thumb)
  def entry_thumb(%{image: image}) when is_binary(image), do: Chidori.SafeUrl.src(image)
  def entry_thumb(_entry), do: nil

  @doc "絵の無い注目作の数（`fill_images` のボタンに添える）。"
  def missing_images(entries), do: Enum.count(entries, &(is_nil(&1.thumb) and is_nil(&1.image)))

  @doc """
  要約の頭に絵を並べる話題か。**作品を育てる話題**（映画。ポスターがあると、
  どれを観るかを要旨より先に決められる）と、**記事の絵を Chiezo に持たせている話題**
  （ニュース。絵があると、どの出来事の話かが読む前に掴める）。

  絵を持たせない話題（市況）は並べない —— 売買提案の AI が読む決まった形の要約で、
  記事の絵がほとんど無い。
  """
  def hero?(nil), do: false
  def hero?(topic), do: Topics.works(topic) != nil or Map.get(topic, :thumbs) != nil

  @doc "作品の事実（公開日・上映形式・配信開始、放送開始・曜日・放送局など）を 1 行で。"
  def work_facts(entry, works \\ Movies) do
    ["#{day_label(entry.date)} #{works.date_word()}" | works.facts(entry)]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" / ")
  end

  @doc "1 件の開催の事実（時刻・会期・開催地）を 1 行で。"
  def event_facts(entry) do
    [
      entry.time && "#{entry.time} から",
      entry.end_date && entry.end_date != entry.date && "#{day_label(entry.end_date)} まで",
      if(entry.places == [], do: "開催地は不明", else: Enum.join(entry.places, "・"))
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" / ")
  end

  @doc false
  # 断られた理由。**数字だけ出しても、押した人には次に何をすればよいか分からない**
  def ask_error(:collection_disabled), do: "この収集は Chiezo 側で止まっています。"
  def ask_error(:not_requested), do: "まだ収集を依頼していません。"
  def ask_error(:busy), do: reason_text(:busy)
  def ask_error(:chiezo_busy), do: "Chiezo がいま別の依頼を抱えています。少し待ってください。"
  def ask_error(:chiezo_not_configured), do: "Chiezo の場所が設定されていません。"
  def ask_error({:chiezo_refused, _status, reason}) when is_binary(reason), do: reason
  def ask_error(:empty_note), do: "頼みたいことを書いてください。"
  def ask_error(_reason), do: "Chiezo へ頼めませんでした。"

  @doc "記事の詳細で頼んだ結果の一言。"
  def article_ask_message(:ok),
    do: "Chiezo へ頼みました。定時の巡回とは別に 1 回だけ走ります（この記事は必ず AI に見せます）。"

  def article_ask_message({:error, reason}), do: ask_error(reason)
  def article_ask_message(_asked), do: nil

  # 画面に出さない印（重要度などは別の場所に出す。Chiezo の内部の印も出さない）
  @meta_tag_prefixes ["重要度:", "話題度:", "興味度:", "_chiezo"]

  @doc """
  記事に付いたタグのうち、画面に出すもの。**興味トピックに当たるものに印**を付ける ——
  `:exact` は興味トピックそのもの、`:near` は言い換えかすぐ下の子
  （`Chidori.Themes.Search.near_map/2`。均した形で比べる）。
  """
  def article_tags(article, interests, near) do
    exact = MapSet.new(interests, &Chidori.Themes.Search.normalize/1)

    for tag <- article.tags || [],
        not Enum.any?(@meta_tag_prefixes, &String.starts_with?(tag, &1)) do
      key = Chidori.Themes.Search.normalize(tag)

      mark =
        cond do
          MapSet.member?(exact, key) -> :exact
          Map.has_key?(near, key) -> :near
          true -> nil
        end

      {tag, mark}
    end
  end

  @doc "興味トピックに近い語（均した形 → 興味トピック）。"
  def near_tags(themes, interests), do: Chidori.Themes.Search.near_map(themes, interests)

  @doc """
  その話題を何で集めているかの一言。**機械で引いているかどうかが読めないと、
  抜けを AI のせいにしてしまいます**。
  """
  def sweep_note(%{feeds: [_ | _] = feeds}) do
    "見出しは #{length(feeds)} 本の配信元から機械的に取り込みます（AI は呼びません）。" <>
      "整理と要約だけが AI の仕事です。"
  end

  def sweep_note(_topic),
    do: "この話題には配信元を付けていないので、集めるところから AI に頼みます。"

  @doc """
  巡回ごとの依頼文。**回ごとに頼むことが違う**ので、1 つの文だけを出すと、
  実際に走っている内容と画面が食い違います。
  """
  def sweep_prompts(%{} = topic) do
    for sweep <- News.sweeps(topic),
        text = Map.get(sweep, :prompt),
        is_binary(text) and text != "",
        do: {sweep.name, text}
  end

  def sweep_prompts(_topic), do: []

  # いまの書きかけに、届いたぶんを重ねる
  defp pending(socket, attrs) do
    case socket.assigns[:notify_form] do
      %{params: params} when is_map(params) -> Map.merge(params, attrs)
      _ -> attrs
    end
  end
end
