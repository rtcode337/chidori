defmodule ChidoriWeb.DatasetsLive do
  @moduledoc """
  データ収集 —— 他のアプリで使うデータを、Chiezo に集めさせる依頼を出す画面です。

  **この画面は溜まったものを見せません。** 読むのは使う側のアプリ（食事処なら
  travel-log の地図）で、こちらが持つのは**依頼と進み具合**だけです ——
  同じものを 2 つの画面で見せると、どちらが本当の状態なのか読めなくなります。
  **例外は読む側のアプリを持たないもの**（技術書の本棚）。読むのは人なので、
  ここに並べないとどこからも読めません。

  **押しても走りません。** 作られる収集は止まった状態で、動き出すのは Chiezo の
  管理画面で有効にしたときだけです（この画面から AI が勝手に動くことはありません）。

  **収集の状態は覚えません。** 開いたときに Chiezo から読み、押したら送り直して
  読み直します —— 正は向こうが持っているものなので、写しを置くと食い違います。
  """

  use ChidoriWeb, :live_view

  import ChidoriWeb.Collect
  import ChidoriWeb.CollectPanel
  import ChidoriWeb.PartitionMap
  import ChidoriWeb.PrefectureMap

  alias Chidori.Chiezo
  alias Chidori.Datasets
  alias Chidori.Datasets.BookMarks
  alias Chidori.Datasets.DiningAreas
  alias Chidori.Datasets.DiningSurveySetting
  alias Chidori.Datasets.Requests
  alias Chidori.Datasets.ShelfCache
  alias Chidori.SingleFlight
  alias Chidori.Jst

  # 区画の一覧に出す数。**数百あるので全部は並べない**（並びは次に回ってくる順なので、
  # 先頭だけ見えれば足りる）
  @shown_partitions 60

  # travel-log からの依頼を、取り込みが空くまで待つ長さ。**1 回の焼きは十数分〜
  # 30 分かかる**ので、それより短いと混んでいるときに頼めない
  @request_wait_ms 60 * 60 * 1000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "データ収集",
       datasets: Datasets.list(),
       backends: [],
       # 巡回ごとに選んだ相手。**サーバー側で覚える** —— 覚えないと、状態が届いた
       # 拍子にフォームが描き直されて、選んだところが元の値に戻る
       picks: %{},
       # この収集から作る収集（本棚）の巡回ごとの相手。親の収集とは別に覚える
       derived_picks: %{},
       # この収集から作る収集に溜まっているもの（本棚の本）。nil は「並べない対象」
       shelf: nil,
       # レシピ集の絞り込み（国・種類・語）と、詳細を開いている料理、名簿を引き直した結果の一言
       recipe_filter: %{},
       recipe_open: nil,
       recipe_message: nil,
       # 本ごとの「勧めている記事」。**開いたものだけ引く**（79 冊ぶんを先に引かない）
       book_posts: %{},
       # 詳細を開いている本（見出し）。本を押すとモーダルで開く
       opened_book: nil,
       # 本に付けた「読んだ」印とメモ（Chidori が持つ。本の見出しで引く）
       book_marks: %{},
       book_mark_saved: nil,
       book_asking: false,
       book_asked: nil,
       # 興味トピックに近い本だけを並べるか
       shelf_near_only: false,
       # Pi-hole のドメインの絞り込み（"all" / "watch" / "blocked" / "caution"）
       domain_filter: "all",
       # **いま止めている通信**（Pi-hole のタブ）。流しているか・新しい順の行・続きの印
       live_on: false,
       live_rows: [],
       live_cursor: nil,
       live_error: nil,
       # 詳細を開いているドメインと、開いたものの本文（開いたときに初めて引く）
       opened_domain: nil,
       domain_docs: %{},
       # ドメインに付けた「見た」印とメモ（関連図の印と同じ置き場。Chiezo の chidori_data）
       domain_marks: %{},
       domain_mark_saved: nil,
       asking: false,
       asked: nil,
       # travel-log からの依頼。頼んでいる間は見積もり（何区画で頼むか）を持つ
       requesting: nil,
       requested: nil,
       # 直近の依頼と、その結果（Chiezo の変更履歴から引き当てたもの）
       request_results: [],
       # 最近の回（自動の回も依頼の回も。Chiezo の変更履歴から）
       recent_runs: [],
       # 「位置OK」「位置修正」の行を Chiezo に固定させた結果（`Requests.hold/2`）
       held: nil,
       # 「AI を使わずにいま反映する」の結果（`Requests.apply_now/1`）
       applied: nil,
       # 控えている依頼（区画ごと。`Requests.pending/2`）と、控えた・頼んだ結果の一言
       pending: [],
       stashed: nil,
       # 地図で選んでいる区画。**選ぶのと頼むのを分ける** —— 押した瞬間に走ると、
       # どこを押したのか確かめる前に AI が動く
       picked: nil,
       # 選んだ区画を走らせるときの、巡回と相手。**覚えるのはサーバー側** ——
       # 状態が届いた拍子にフォームが描き直されるので、覚えないと選び直した
       # ところが元へ戻る（巡回の表と同じ理由）
       run_sweep: nil,
       run_backend: nil,
       run_model: nil,
       # travel-log からの依頼を頼むときの相手（空なら巡回の設定のまま）。覚えるのは
       # 上と同じ理由でサーバー側
       request_backend: nil,
       request_model: nil,
       # 区画の地図の地名検索（打った語・候補・寄った場所の印）
       map_query: "",
       map_places: nil,
       map_marker: nil,
       # 設定欄を開いているか。**開いたときに初めて Chiezo から読む**（関連図と同じ）
       settings_open: false,
       # 本棚を最後に Chiezo から読んだ時刻（覚え書きのもの）
       shelf_checked_at: nil,
       shelf_loading: false,
       # 県ごとの進み具合（ご当地グルメ。数だけ。設定を開いたときに Chiezo から数える）
       prefecture_progress: nil,
       # 県の地図（数が届いたときに組む）
       prefecture_map: nil
     )
     |> assign(state: empty_state(), derived_state: empty_state())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    key = Datasets.valid_key(params["view"])
    dataset = Datasets.get(key)
    cached = if Datasets.listed?(dataset), do: ShelfCache.get(key)

    socket =
      socket
      |> assign(view: key, dataset: dataset, picks: %{}, asked: nil, picked: nil)
      |> assign(
        state: empty_state(),
        derived_state: empty_state(),
        derived_picks: %{},
        # **本棚は覚え書きから出す**（開くたびには Chiezo へ取りに行かない）
        shelf: cached && cached.shelf,
        shelf_checked_at: cached && cached.checked_at,
        # 対象を切り替えたら、設定は対象ごとの既定に戻す（別の収集のもの）
        settings_open: open_settings?(dataset),
        book_marks: if(dataset[:derived], do: BookMarks.all(), else: %{}),
        book_mark_saved: nil,
        opened_domain: nil,
        recipe_filter: %{},
        recipe_open: nil,
        recipe_message: nil,
        domain_filter: "all",
        domain_marks:
          if(dataset[:listing],
            do: Chidori.Relations.Marks.for_view(Chidori.Datasets.Pihole.mark_view()),
            else: %{}
          ),
        domain_mark_saved: nil,
        # 対象を切り替えたら流すのをやめる（別のタブで読み続けない）
        live_on: false,
        live_rows: [],
        live_cursor: nil,
        live_error: nil,
        prefecture_progress: nil,
        prefecture_map: nil,
        # 範囲ごとの食事処の、情報収集を起こす時刻（`Chidori.Datasets.DiningSurvey`）。
        # 設定ページの「Chiezo 収集」の表と同じ値（同じ表を読み書きする）
        survey_times: survey_times_of(dataset),
        survey_saved: nil,
        survey_run: nil
      )

    # **本棚のある対象は、開いただけでは Chiezo と話さない。** 本棚は覚え書きを出し、
    # 設定は開いたときに読む。**まだ 1 度も本棚を読んでいないときだけ**取りに行く
    # （関連図の図と同じ）。本棚の無い対象は設定を開いて出すので、ここで読む
    {:noreply,
     cond do
       not connected?(socket) -> socket
       socket.assigns.settings_open -> load_settings(socket)
       Datasets.listed?(dataset) && cached == nil -> read_shelf(socket, dataset)
       true -> socket
     end}
  end

  # 設定を開いた状態で出すか。**本棚を持たない対象（食事処の範囲）は開いて出す** ——
  # 本棚が無いので、この画面で見るものは設定（区画の地図・巡回・依頼）しか無い。
  # 畳んでおくと、開くたびに 1 手余計にかかる
  defp open_settings?(dataset), do: not Datasets.listed?(dataset)

  # 設定欄を開く・閉じる。**開いたときに Chiezo から読む** —— 設定は見たいときだけ
  # 見るもので、本棚を見に来るたびに収集の状態・巡回・相手の一覧まで運ぶ理由が無い。
  # **開くたびに読み直す**（閉じているあいだに Chiezo の側が進んでいる）
  def handle_event("toggle_settings", _params, socket) do
    if socket.assigns.settings_open do
      {:noreply, assign(socket, settings_open: false)}
    else
      {:noreply, socket |> assign(settings_open: true) |> load_settings()}
    end
  end

  @impl true
  # **情報収集を今すぐ 1 回走らせる**（範囲ごとの食事処だけ。区画は Chiezo が選ぶふつうの回）。
  # 押した人の 1 回なので、止めている収集でも走る（`Chiezo.by_hand/1`）
  def handle_event(
        "run_survey_now",
        _params,
        %{assigns: %{dataset: %{area: _} = dataset}} = socket
      ) do
    {:noreply,
     socket
     |> assign(survey_run: "頼んでいます…")
     |> start_async(:run_survey_now, fn ->
       with {:ok, base} <- Datasets.base_url() do
         Chiezo.by_hand(fn ->
           Chiezo.run(base, dataset.collection,
             sweep: Chidori.Datasets.Dining.survey_sweep(),
             timeout: 60_000
           )
         end)
       end
     end)}
  end

  def handle_event("run_survey_now", _params, socket), do: {:noreply, socket}

  # **情報収集を起こす時刻を直す**（範囲ごとの食事処だけ）。Chiezo には送らない ——
  # 時計を持つのは Chidori。設定ページの「Chiezo 収集」の表と同じ値を書き換える
  def handle_event("save_survey_times", %{"times" => times}, socket) do
    dataset = socket.assigns.dataset

    message =
      case dataset[:area] && DiningSurveySetting.put(dataset.collection, %{"run_at" => times}) do
        {:ok, _saved} -> "起こす時刻を保存しました。"
        {:error, %Ecto.Changeset{} = changeset} -> changeset_error(changeset)
        _other -> "起こす時刻を保存できませんでした。"
      end

    {:noreply, assign(socket, survey_times: survey_times_of(dataset), survey_saved: message)}
  end

  # **依頼を送って、そのまま読み直す。** 送っただけでは画面が変わらないので、
  # 効いたのかどうかが分かりません
  def handle_event("collect", params, socket) do
    # 範囲ごとの食事処は、情報収集が 1 回に回る区画の数も同じフォームで決める（覚えてから送る）
    dataset = with_survey_per_run(socket.assigns.dataset, params["survey_per_run"])
    socket = assign(socket, dataset: dataset)
    choices = merged_picks(socket.assigns.picks, params)

    # 同じ収集への送り直しは 1 本だけ（別のタブから押しても重ねない）。読み直しは重なってよい
    key = {:dataset_push, dataset.key}

    if SingleFlight.busy?(key) do
      {:noreply, assign(socket, state: %{socket.assigns.state | reason: :busy})}
    else
      {:noreply,
       socket
       |> assign(state: %{socket.assigns.state | pushing: true, reason: nil})
       |> start_async(:push, fn ->
         {SingleFlight.run(key, fn -> Datasets.push(dataset, choices) end),
          Datasets.read(dataset)}
       end)}
    end
  end

  # 選び直したら、その場で覚える。**送るのは押したときだけ**。
  #
  # **ここでは覚えているほうを勝たせません。** この事象そのものが選び直しなので、
  # 前に覚えた値を優先すると、一度覚えた欄を二度と変えられなくなります。
  def handle_event("pick_sweep", params, socket),
    do: {:noreply, assign(socket, picks: sweep_choices(params))}

  # 「最新の情報を取得」。本棚を読み直し、**設定欄を開いていれば設定も**読み直す
  def handle_event("reload", _params, socket) do
    dataset = socket.assigns.dataset

    socket = if Datasets.listed?(dataset), do: read_shelf(socket, dataset), else: socket

    {:noreply, if(socket.assigns.settings_open, do: load_settings(socket), else: socket)}
  end

  # **地図で区画を選ぶ。** ここでは頼みません —— 押した先に何があるのか
  # （件数・見終わったか）を読んでから頼めるように、選ぶのと頼むのを分けてあります
  def handle_event("pick_partition", %{"key" => key}, socket) do
    picked = if socket.assigns.picked == key, do: nil, else: key

    {:noreply, assign(socket, picked: picked, asked: nil)}
  end

  # **地図の上で地名を探す**（地図辞典）。候補を出すだけで、図はまだ動かさない
  def handle_event("search_map_place", %{"q" => q}, socket) do
    q = String.trim(q || "")

    cond do
      q == "" ->
        {:noreply, assign(socket, map_query: "", map_places: nil)}

      q == socket.assigns.map_query ->
        {:noreply, socket}

      base = Chiezo.base_url() ->
        {:noreply,
         socket
         |> assign(map_query: q, map_places: :loading)
         |> start_async(:map_places, fn -> Chiezo.places(base, q) end)}

      true ->
        {:noreply, assign(socket, map_query: q, map_places: {:error, :chiezo_not_configured})}
    end
  end

  def handle_event("clear_map_search", _params, socket),
    do: {:noreply, assign(socket, map_query: "", map_places: nil, map_marker: nil)}

  # 候補を選んだら、その場所へ寄って印を立てる。**寄せるのは画面の側**
  # （器の大きさは向こうしか知らない）。図の座標へ直すのは、区画と同じ投影で
  def handle_event("focus_map_place", %{"index" => index}, socket) do
    with {:ok, places} <- socket.assigns.map_places,
         {i, ""} <- Integer.parse(index),
         %{lat: lat, lon: lon} = place <- Enum.at(places, i),
         rows = partition_rows(socket.assigns.state, socket.assigns.dataset.partition_sweeps),
         %{x: x, y: y} <- Chidori.Datasets.Map.xy(Chidori.Datasets.Map.build(rows), lat, lon) do
      {:noreply,
       socket
       |> assign(map_places: nil, map_marker: %{x: x, y: y, label: place.name})
       |> push_event("map_focus", %{x: x, y: y})}
    else
      _other -> {:noreply, socket}
    end
  end

  def handle_event("unpick_partition", _params, socket),
    do: {:noreply, assign(socket, picked: nil)}

  # **この収集から作る収集**（本棚）を用意する。無ければ作り、あれば送り直す。
  # 巡回ごとの相手は親の収集と同じ形で選ぶ（送り直したら読み直す）
  def handle_event("collect_derived", params, socket) do
    dataset = socket.assigns.dataset
    choices = merged_picks(socket.assigns.derived_picks, params)

    key = {:dataset_push_derived, dataset.key}

    if SingleFlight.busy?(key) do
      {:noreply, assign(socket, derived_state: %{socket.assigns.derived_state | reason: :busy})}
    else
      {:noreply,
       socket
       |> assign(derived_state: %{socket.assigns.derived_state | pushing: true, reason: nil})
       |> start_async(:push_derived, fn ->
         {SingleFlight.run(key, fn -> Datasets.push_derived(dataset, choices) end),
          Datasets.read_derived(dataset)}
       end)}
    end
  end

  def handle_event("toggle_shelf_near", _params, socket),
    do: {:noreply, assign(socket, shelf_near_only: !socket.assigns.shelf_near_only)}

  # **本を押すと詳細を開く**（ほかの画面の詳細と同じくモーダル）。勧めている記事は
  # 開いたときに初めて引く（前に引いたものは覚えておく）
  def handle_event("open_book", %{"title" => title}, socket) do
    socket = assign(socket, opened_book: title, book_asked: nil)

    if Map.has_key?(socket.assigns.book_posts, title) do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(book_posts: Map.put(socket.assigns.book_posts, title, :loading))
       |> start_async({:book_posts, title}, fn ->
         with {:ok, base} <- Datasets.base_url(),
              do: Chidori.Datasets.Books.recommending(base, title)
       end)}
    end
  end

  # 「読んだ」印とメモを書く。**空にしたら消える**（関連図の「見た」と同じ）
  def handle_event("save_book_mark", %{"title" => title} = params, socket) do
    case BookMarks.put(title, ChidoriWeb.BookModal.mark_attrs(params)) do
      {:ok, mark} ->
        marks =
          if mark,
            do: Map.put(socket.assigns.book_marks, title, mark),
            else: Map.delete(socket.assigns.book_marks, title)

        {:noreply, assign(socket, book_marks: marks, book_mark_saved: title)}

      {:error, _changeset} ->
        # 書けなかったことは黙って捨てない
        {:noreply, put_flash(socket, :error, "読んだ記録を保存できませんでした。")}
    end
  end

  # **Pi-hole のドメイン。** 絞り込みは押したときだけ（一覧は全部読んである）
  def handle_event("filter_domains", %{"filter" => filter}, socket)
      when filter in ~w(all unseen watch blocked caution),
      do: {:noreply, assign(socket, domain_filter: filter)}

  # 押すと詳細を開く。**調べた中身の全文は開いたときに初めて引く**（一覧は冒頭だけ）
  # レシピ集（`ChidoriWeb.RecipeBook`）。絞り込みは手元の一覧で済ませる（Chiezo に聞き直さない）
  def handle_event("filter_recipes", params, socket),
    do: {:noreply, assign(socket, recipe_filter: Map.take(params, ["country", "kind", "q"]))}

  def handle_event("open_recipe", %{"title" => title}, socket),
    do: {:noreply, assign(socket, recipe_open: title)}

  def handle_event("close_recipe", _params, socket),
    do: {:noreply, assign(socket, recipe_open: nil)}

  # 名簿の広さを変えて引き直す（機械収集を 1 回。AI は使わない）。**重ねて押しても 1 本**
  def handle_event("reroster_recipes", %{"min" => min}, socket) do
    pid = self()

    started =
      with {n, ""} <- Integer.parse(min) do
        SingleFlight.start(:recipes_reroster, fn ->
          send(pid, {:recipes_rerostered, Chidori.Datasets.Recipes.reroster(n)})
        end)
      end

    message =
      case started do
        {:ok, _pid} -> "名簿を引き直しています…"
        {:error, :busy} -> "いま引き直している最中です。"
        _other -> "選べない下限です。"
      end

    {:noreply, assign(socket, recipe_message: message)}
  end

  def handle_event("open_domain", %{"domain" => domain}, socket) do
    socket = assign(socket, opened_domain: domain)

    if Map.has_key?(socket.assigns.domain_docs, domain) do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(domain_docs: Map.put(socket.assigns.domain_docs, domain, :loading))
       |> start_async({:domain_doc, domain}, fn ->
         with {:ok, base} <- Datasets.base_url(),
              do: Chidori.Datasets.Pihole.doc(base, domain)
       end)}
    end
  end

  # **いま止めている通信を流す**（Pi-hole の画面の「1件ずつ流す」に当たるもの）。押した時点から先を、
  # 5 秒ごとに Chiezo 越しに読んで 1 件 1 行で足す。止めたら読みに行かない
  def handle_event("live_start", _params, socket) do
    socket =
      assign(socket,
        live_on: true,
        live_rows: [],
        live_cursor: System.os_time(:second),
        live_error: nil
      )

    {:noreply, poll_live(socket)}
  end

  def handle_event("live_stop", _params, socket), do: {:noreply, assign(socket, live_on: false)}

  def handle_event("live_clear", _params, socket), do: {:noreply, assign(socket, live_rows: [])}

  # 「見た」印とメモを書く（関連図の「見た記録」と同じ形）。**空にしたら消える**
  def handle_event("save_domain_mark", %{"domain" => domain} = params, socket) do
    attrs = %{
      "seen" => params["seen"] == "on",
      "seen_on" => blank_to_nil(params["seen_on"]),
      "note" => params["note"] || ""
    }

    case Chidori.Relations.Marks.put(Chidori.Datasets.Pihole.mark_view(), domain, attrs) do
      {:ok, mark} ->
        marks =
          if mark,
            do: Map.put(socket.assigns.domain_marks, domain, mark),
            else: Map.delete(socket.assigns.domain_marks, domain)

        {:noreply, assign(socket, domain_marks: marks, domain_mark_saved: domain)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "見た記録を保存できませんでした。")}
    end
  end

  def handle_event("close_domain", _params, socket),
    do: {:noreply, assign(socket, opened_domain: nil)}

  def handle_event("close_book", _params, socket),
    do: {:noreply, assign(socket, opened_book: nil, book_asked: nil)}

  # **この本を詳しく調べて**、を本棚の整理の回へ割り込ませる（1 回だけ）
  # 同じ本への頼みは 1 本だけ（続けて押しても AI の回を重ねない）
  def handle_event("ask_book", %{"title" => title} = params, socket) do
    key = {:ask_book, title}

    if SingleFlight.busy?(key) do
      {:noreply, assign(socket, book_asked: {:error, :busy})}
    else
      {:noreply,
       socket
       |> assign(book_asking: true, book_asked: nil)
       |> start_async(:ask_book, fn ->
         SingleFlight.run(key, fn ->
           with {:ok, base} <- Datasets.base_url(),
                do: Chidori.Datasets.Bookshelf.focus_book(base, title, params["note"])
         end)
       end)}
    end
  end

  # 選び直したら、その場で覚える（親の収集の `pick_sweep` と同じ理由）
  def handle_event("pick_derived_sweep", params, socket),
    do: {:noreply, assign(socket, derived_picks: sweep_choices(params))}

  # **選んだ区画を、選んだ巡回で 1 回走らせる**（Chiezo の画面と同じ形）。
  #
  # 割り込みにしていた頃は、進み具合にも区画の印にも触らないので、
  # **押しても画面が何も変わらず**「何が起きたのか分からない」になっていた。
  def handle_event("run_partition", %{"key" => key} = params, socket) do
    dataset = socket.assigns.dataset
    opts = run_options(params, socket.assigns.backends)
    # 同じ区画の実行は 1 本だけ（続けて押しても AI の回を重ねない）
    flight = {:run_partition, dataset.key, key}

    if SingleFlight.busy?(flight) do
      {:noreply, assign(socket, asked: {:error, :busy})}
    else
      {:noreply,
       socket
       |> assign(asking: true, asked: nil)
       |> start_async(:ask, fn ->
         SingleFlight.run(flight, fn -> Datasets.run_partition(dataset, key, opts) end)
       end)}
    end
  end

  # 相手を選び直したら、そのぶんだけ覚える（モデルの候補は相手ごとに別物なので、
  # 覚えていないと選び直した拍子に前の相手のモデルが出る）
  def handle_event("pick_run", params, socket) do
    {:noreply,
     assign(socket,
       run_sweep: params["sweep"] || socket.assigns.run_sweep,
       run_backend: params["run|backend"] || socket.assigns.run_backend,
       run_model: params["run|model"] || socket.assigns.run_model
     )}
  end

  # 依頼を頼む相手を選び直したら覚える（`pick_run` と同じ）
  def handle_event("pick_request", params, socket) do
    {:noreply,
     assign(socket,
       request_backend: params["request|backend"] || socket.assigns.request_backend,
       request_model: params["request|model"] || socket.assigns.request_model
     )}
  end

  # **travel-log からの依頼は、すぐには頼まずに控える**（`Requests.stash/2`）。貼った
  # その場で頼むと、1 件しか依頼の無い区画にも AI の回が 1 回走って枠を使い潰す ——
  # 区画ごとに溜まった件数を見て、「この区画を頼む」で頼む（`send_pending`）。
  # **「位置OK」「位置修正」の行はこれまでどおりその場で固定させる**（AI を使わないので待つ理由が無い）
  # **範囲ごとの食事処では受けない**（貼る欄も出さない）。travel-log の食事処は範囲で分かれて
  # いないので、テキストに別の範囲の店が混ざる。配るのは「全体」のタブ（`DiningAreasLive`）
  def handle_event("travel_log_request", _params, %{assigns: %{dataset: %{area: _}}} = socket),
    do: {:noreply, socket}

  def handle_event("travel_log_request", %{"text" => text}, socket) do
    dataset = socket.assigns.dataset
    confirms = Requests.confirms(text)
    socket = hold_locations(socket, dataset, confirms)
    rest = Requests.without_confirms(text)

    stashed =
      case Requests.items(rest) do
        [] when confirms != [] -> nil
        [] -> {:refused, :no_points}
        _items -> Requests.stash(dataset, rest)
      end

    {:noreply, socket |> assign(stashed: stashed, requested: nil) |> assign_pending()}
  end

  # 1 つの区画に溜まった依頼を頼む。**待つのは画面ではなく chidori** —— 取り込みが空くまで
  # 最長 1 時間待つので、画面を閉じても頼み続けられるよう `Chidori.TaskSupervisor` の下で走らせる
  def handle_event("send_pending", %{"key" => key}, socket) do
    dataset = socket.assigns.dataset

    case Enum.find(socket.assigns.pending, &(&1.key == key)) do
      %{items: items} when items != [] ->
        live = self()
        deadline = System.monotonic_time(:millisecond) + @request_wait_ms
        plan = %{keys: [key], points: items, missed: []}
        opts = request_options(socket.assigns)

        # 同じ区画への依頼は 1 本だけ（別のタブから押しても重ねない）
        started =
          SingleFlight.start({:send_pending, dataset.key, key}, fn ->
            {_log, result, sent} = Requests.send_partition(dataset, key, items, deadline, opts)
            send(live, {:travel_log_request, result, sent})
          end)

        case started do
          {:ok, _pid} ->
            {:noreply, socket |> assign(requesting: plan, requested: nil, stashed: nil)}

          {:error, reason} ->
            reason = if reason == :busy, do: :busy, else: :collection_crashed
            {:noreply, assign(socket, requested: {{:error, reason}, plan}, stashed: nil)}
        end

      _none ->
        {:noreply, assign_pending(socket)}
    end
  end

  # 控えを取り消す（頼まずに捨てる）。**区画の外の依頼もここで捨てられる**
  def handle_event("drop_pending", %{"key" => key}, socket) do
    key = if key == "", do: nil, else: key

    case Enum.find(socket.assigns.pending, &(&1.key == key)) do
      %{items: items} -> Requests.drop(socket.assigns.dataset, Enum.map(items, & &1.id))
      nil -> 0
    end

    {:noreply, socket |> assign(stashed: nil) |> assign_pending()}
  end

  # **AI を使わずに、固定した座標をいま反映する**（機械収集の回を 1 回走らせる）
  def handle_event("apply_locks", _params, socket) do
    dataset = socket.assigns.dataset

    {:noreply,
     socket
     |> assign(applied: :applying)
     |> start_async(:apply_locks, fn -> Requests.apply_now(dataset) end)}
  end

  # 依頼の結果を読み直す（Chiezo の変更履歴は回が終わってから 1 行になる）
  def handle_event("reload_request_results", _params, socket),
    do: {:noreply, load_request_results(socket)}

  def handle_event("reload_recent_runs", _params, socket),
    do: {:noreply, load_recent_runs(socket)}

  defp hold_locations(socket, _dataset, []), do: assign(socket, held: nil)

  defp hold_locations(socket, dataset, confirms) do
    socket
    |> assign(held: :holding)
    |> start_async(:hold, fn -> Requests.hold(dataset, confirms) end)
  end

  # 定時の巡回とは別に、1 回だけ頼む
  @impl true
  def handle_async(:read, {:ok, result}, socket),
    do:
      {:noreply,
       socket |> assign(state: applied(socket.assigns.state, result)) |> assign_pending()}

  def handle_async(:read, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, state: crashed(socket.assigns.state))}

  # 送った結果と読み直した結果の両方を見る。**断られたら黙って済ませない** ——
  # 読み直しは成功するので、結果だけ見ていると「押したのに何も変わらない」としか映らず、
  # 送れていないことに気づけません
  def handle_async(:push, {:ok, {pushed, read}}, socket) do
    state = %{applied(socket.assigns.state, read) | pushing: false}

    {:noreply,
     assign(socket,
       state:
         case pushed do
           :ok -> state
           {:error, reason} -> %{state | reason: reason}
         end
     )}
  end

  def handle_async(:run_survey_now, {:ok, result}, socket) do
    message =
      case result do
        :ok -> "情報収集を 1 回頼みました（区画は Chiezo が選びます）。"
        {:error, reason} -> "頼めませんでした: #{inspect(reason)}"
        _other -> "頼めませんでした。"
      end

    {:noreply, assign(socket, survey_run: message)}
  end

  def handle_async(:run_survey_now, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, survey_run: "頼めませんでした。")}

  def handle_async(:push, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, state: %{crashed(socket.assigns.state) | pushing: false})}

  def handle_async(:read_derived, {:ok, result}, socket),
    do: {:noreply, assign(socket, derived_state: applied(socket.assigns.derived_state, result))}

  def handle_async(:read_derived, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, derived_state: crashed(socket.assigns.derived_state))}

  def handle_async(:shelf, {:ok, result}, socket) do
    now = DateTime.utc_now()
    ShelfCache.put(socket.assigns.view, result, now)
    {:noreply, assign(socket, shelf: result, shelf_checked_at: now, shelf_loading: false)}
  end

  def handle_async(:live, {:ok, {:ok, %{rows: rows, cursor: cursor}}}, socket) do
    # **新しいものを上に**（流し見るときに目が行くのは上）。古いものから落とす
    kept =
      (Enum.reverse(rows) ++ socket.assigns.live_rows)
      |> Enum.take(Chidori.Datasets.Pihole.live_keep())

    {:noreply,
     socket
     |> assign(
       live_rows: kept,
       live_cursor: cursor || socket.assigns.live_cursor,
       live_error: nil
     )
     |> schedule_live()}
  end

  # 読めなかった回は理由を出し、**止めずに次の回も試す**（Pi-hole の再起動などは待てば戻る）
  def handle_async(:live, {:ok, {:error, reason}}, socket),
    do: {:noreply, socket |> assign(live_error: reason) |> schedule_live()}

  def handle_async(:live, {:exit, _reason}, socket),
    do: {:noreply, socket |> assign(live_error: :collection_crashed) |> schedule_live()}

  def handle_async({:domain_doc, domain}, {:ok, result}, socket),
    do:
      {:noreply, assign(socket, domain_docs: Map.put(socket.assigns.domain_docs, domain, result))}

  def handle_async({:domain_doc, domain}, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket,
         domain_docs: Map.put(socket.assigns.domain_docs, domain, {:error, :collection_crashed})
       )}

  def handle_async({:book_posts, title}, {:ok, result}, socket),
    do: {:noreply, assign(socket, book_posts: Map.put(socket.assigns.book_posts, title, result))}

  def handle_async({:book_posts, title}, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket,
         book_posts: Map.put(socket.assigns.book_posts, title, {:error, :collection_crashed})
       )}

  def handle_async(:shelf, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, shelf: {:error, :collection_crashed}, shelf_loading: false)}

  def handle_async(:push_derived, {:ok, {pushed, read}}, socket) do
    state = %{applied(socket.assigns.derived_state, read) | pushing: false}

    {:noreply,
     assign(socket,
       derived_state:
         case pushed do
           :ok -> state
           {:error, reason} -> %{state | reason: reason}
         end
     )}
  end

  def handle_async(:push_derived, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket, derived_state: %{crashed(socket.assigns.derived_state) | pushing: false})}

  def handle_async(:ask_book, {:ok, result}, socket),
    do: {:noreply, assign(socket, book_asking: false, book_asked: result)}

  def handle_async(:ask_book, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, book_asking: false, book_asked: {:error, :collection_crashed})}

  def handle_async(:ask, {:ok, result}, socket),
    do: {:noreply, assign(socket, asking: false, asked: result)}

  def handle_async(:ask, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, asking: false, asked: {:error, :collection_crashed})}

  def handle_async(:map_places, {:ok, result}, socket),
    do: {:noreply, assign(socket, map_places: result)}

  def handle_async(:map_places, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, map_places: {:error, :chiezo_unavailable})}

  def handle_async(:backends, {:ok, backends}, socket),
    do: {:noreply, assign(socket, backends: backends)}

  def handle_async(:backends, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:request_results, {:ok, results}, socket),
    do: {:noreply, assign(socket, request_results: results)}

  def handle_async(:request_results, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:hold, {:ok, result}, socket),
    do: {:noreply, assign(socket, held: result, applied: nil)}

  def handle_async(:apply_locks, {:ok, result}, socket),
    do: {:noreply, assign(socket, applied: result)}

  def handle_async(:apply_locks, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, applied: {:error, :chiezo_unavailable})}

  def handle_async(:hold, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, held: {:error, :chiezo_unavailable})}

  def handle_async(:recent_runs, {:ok, {:ok, runs}}, socket),
    do: {:noreply, assign(socket, recent_runs: runs)}

  def handle_async(:recent_runs, _result, socket), do: {:noreply, socket}

  # 県の地図は**数が届いたときに 1 回だけ組む**（`Chidori.Datasets.Map.prefectures/1`）。
  # 画面で組むと、県を選び直すたびに 47 県ぶんの境目を送り直すことになる
  def handle_async(:prefecture_progress, {:ok, {:ok, progress} = result}, socket) do
    map =
      Chidori.Datasets.Map.prefectures(progress.rows,
        unresolved?: progress.unresolved_total != nil
      )

    {:noreply, assign(socket, prefecture_progress: result, prefecture_map: map)}
  end

  def handle_async(:prefecture_progress, {:ok, result}, socket),
    do: {:noreply, assign(socket, prefecture_progress: result, prefecture_map: nil)}

  def handle_async(:prefecture_progress, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket, prefecture_progress: {:error, :collection_crashed}, prefecture_map: nil)}

  # travel-log からの依頼が終わった（頼めた・断られた・待ちきれなかった）。
  # 見積もりは一言に使うので、結果と組にして残す
  @impl true
  def handle_info({:recipes_rerostered, result}, socket) do
    message =
      case result do
        :ok ->
          "名簿を引き直しました。新しく入った料理は、書く回が順にレシピを書きます（書き終えたものから並びます）。"

        {:error, reason} ->
          "名簿を引き直せませんでした: " <> reason_text(reason)
      end

    {:noreply, assign(socket, recipe_message: message)}
  end

  def handle_info(:live_tick, socket) do
    if socket.assigns.live_on and socket.assigns.dataset[:listing],
      do: {:noreply, poll_live(socket)},
      else: {:noreply, socket}
  end

  # 頼んだ組は押したときの区画と違うことがある（頼む直前に区画を読み直して振り分け直す。
  # `Requests.send_partition/5`）ので、一言には実際に頼んだ組を使う
  def handle_info({:travel_log_request, result, sent}, socket) do
    {:noreply,
     socket
     |> assign(requesting: nil, requested: {result, sent})
     |> assign_pending()
     |> load_request_results()}
  end

  # **まだ何も読んでいない状態。** 「収集が無い」と区別する —— 読めていないのに
  # 「まだ作られていません」と出すと、押した人は作り直そうとする
  # この収集から作る収集を持つ対象だけ読む
  defp read_derived(socket, %{derived: derived} = dataset) when not is_nil(derived) do
    socket
    |> assign(derived_state: %{empty_state() | status: :loading})
    |> start_async(:read_derived, fn -> Datasets.read_derived(dataset) end)
  end

  defp read_derived(socket, _dataset), do: socket

  # 本棚を Chiezo から読む（読めたら覚え書きにも残す）
  # 流し見の 1 回ぶん。**読み終えてから次を予約する**（Pi-hole が遅いときに重ならない）
  @live_every_ms 5_000

  defp poll_live(socket) do
    cursor = socket.assigns.live_cursor

    start_async(socket, :live, fn ->
      with {:ok, base} <- Datasets.base_url(),
           do: Chidori.Datasets.Pihole.blocked_since(base, cursor)
    end)
  end

  defp schedule_live(socket) do
    if socket.assigns.live_on, do: Process.send_after(self(), :live_tick, @live_every_ms)
    socket
  end

  defp read_shelf(socket, dataset) do
    socket
    |> assign(shelf_loading: true)
    |> start_async(:shelf, fn -> Datasets.shelf(dataset) end)
  end

  # 設定欄に出すものを Chiezo から読む（収集の状態・本棚の収集の状態・相手・依頼の結果）
  defp load_settings(socket) do
    dataset = socket.assigns.dataset

    socket
    |> assign(state: %{socket.assigns.state | status: :loading})
    |> start_async(:read, fn -> Datasets.read(dataset) end)
    |> read_derived(dataset)
    |> start_async(:backends, &Datasets.backends/0)
    |> load_request_results()
    |> load_recent_runs()
    |> load_prefecture_progress(dataset)
  end

  # **県ごとの進み具合**（区画が県の対象だけ。区画の地図の代わり）。数えるのに収集の
  # 全件を読むので、設定を開いたときと読み直したときだけ
  defp load_prefecture_progress(socket, %{prefectures: true, module: module}) do
    socket
    |> assign(prefecture_progress: :loading)
    |> start_async(:prefecture_progress, fn -> module.progress() end)
  end

  defp load_prefecture_progress(socket, _dataset), do: socket

  @doc "地名の候補を見分ける一言（地域と種別）。"
  def place_label(place) do
    [place[:area], place[:feature]] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("・")
  end

  defp empty_state,
    do: %{collection: nil, status: :idle, reason: nil, checked_at: nil, pushing: false}

  defp applied(state, {:ok, collection}),
    do: %{
      state
      | collection: collection,
        status: :ready,
        reason: nil,
        checked_at: DateTime.utc_now()
    }

  defp applied(state, {:error, reason}),
    do: %{state | status: :ready, reason: reason}

  defp crashed(state), do: %{state | status: :ready, reason: :collection_crashed}

  @doc """
  いつ Chiezo から読んだか（本棚と設定の、新しいほう）。まだ読んでいなければ nil。
  """
  def checked_at(assigns) do
    [assigns[:shelf_checked_at], assigns.state[:checked_at]]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  @doc "取り直している最中か（本棚か設定のどちらか）。"
  def reloading?(assigns), do: assigns[:shelf_loading] == true or assigns.state.status == :loading

  @doc """
  いまの状態を1文で言う。**断られた理由はそのまま出します**。
  """
  def status_message(%{reason: reason}) when not is_nil(reason), do: reason_text(reason)
  def status_message(%{pushing: true}), do: "Chiezo に依頼を送っています…"
  def status_message(%{status: :loading}), do: "Chiezo に問い合わせています…"

  def status_message(%{collection: nil, status: :idle}), do: "Chiezo の状態を読んでいません。"

  def status_message(%{collection: nil}),
    do: "この収集は、まだ Chiezo にありません。押すと、この内容で依頼します（止まった状態で作られます）。"

  def status_message(%{collection: %{enabled: false}}),
    do:
      "収集はありますが、Chiezo 側で止まっています。" <>
        "Chiezo の管理画面の「集める」で有効にすると、決まった間隔で集め始めます。"

  def status_message(%{collection: %{docs: 0}}),
    do: "有効になっています。まだ 1 件も溜まっていないので、最初の取り込みを待っています。"

  def status_message(_state), do: "有効になっています。溜まったものは Chiezo のソースとして引けます。"

  @doc "ボタンの文字。**まだ無いときと、あるときで頼むことが違います**。"
  def collect_label(%{pushing: true}), do: "送っています…"
  def collect_label(%{collection: nil}), do: "収集を依頼する"
  def collect_label(_state), do: "収集の設定を更新"

  @doc """
  押すと何が起きるかの一言。**走らせはしない**ことを、押す前に読めるようにします。
  """
  def push_note(%{collection: nil}),
    do:
      "押すと、この内容で Chiezo に収集を作ります。作られるのは止まった状態なので、" <>
        "押しただけで AI が動くことはありません。"

  def push_note(_state),
    do:
      "押すと、Chidori が持っている抽出の指定・依頼文・区画の割り方・巡回を Chiezo へ" <>
        "送り直します（走らせはしません。Chiezo の画面で手で直したものは上書きされます）。"

  @doc """
  travel-log からの依頼の一言。**何区画で頼んだか**と、**どの区画にも入らなかった座標**を
  言います —— 外れた座標を黙って落とすと、その依頼だけが誰にも読まれません。
  """
  def request_message(requesting, requested, sweep \\ "整理")

  def request_message(%{keys: keys, points: points, missed: missed}, _requested, sweep) do
    "座標 #{length(points)} 件を含む区画 #{length(keys)} つで、#{sweep}を頼んでいます" <>
      "（取り込み中なら空くまで最長 1 時間待ちます。画面を閉じても頼み続けます）。" <>
      missed_text(missed)
  end

  def request_message(nil, {:refused, reason}, _sweep), do: Requests.error_text(reason)

  def request_message(nil, {:ok, plan}, sweep) do
    "区画 #{length(plan.keys)} つで#{sweep}を頼みました（座標 #{length(plan.points)} 件）。" <>
      "区画はふつうの回として見られ、依頼は区画ごとに、その区画に入るぶんだけが補足として読まれます。" <>
      missed_text(plan.missed)
  end

  def request_message(nil, {{:error, reason}, _plan}, _sweep), do: reason_text(reason)
  def request_message(_requesting, _requested, _sweep), do: nil

  @doc "依頼を控えた結果の一言。"
  def stashed_message({:ok, %{added: added, skipped: 0}}),
    do: "#{added} 件を控えました。下の「控えている依頼」から、区画ごとに頼んでください。"

  def stashed_message({:ok, %{added: added, skipped: skipped}}),
    do: "#{added} 件を控えました（#{skipped} 件は控え済みの依頼と同じなので足していません）。"

  def stashed_message({:refused, reason}), do: Requests.error_text(reason)
  def stashed_message(_stashed), do: nil

  defp missed_text([]), do: ""

  defp missed_text(missed) do
    points = Enum.map_join(missed, "、", fn {lat, lon} -> "(#{lat},#{lon})" end)
    "区画の外だった座標: #{points}。"
  end

  @doc "割り込みの届き具合。**断られたことも出します**。"
  def ask_message(:ok), do: "Chiezo に頼みました。定時の巡回とは別に 1 回だけ走ります。"
  def ask_message({:error, reason}), do: reason_text(reason)
  def ask_message(_asked), do: nil

  @doc """
  区画への割り込みの指示文。**必ず区画の名前で始めます**。

  区画は別に渡していて Chiezo がそちらを見て範囲を差し込みますが、
  **指示文だけを読んだ人には、どこ宛てか分かりません**。
  """
  def partition_note(key, note) do
    case String.trim(note || "") do
      "" -> "#{key} の区画を先に調べてください。"
      written -> "#{key} の区画について。#{written}"
    end
  end

  @doc """
  travel-log がスポットにするときに読む項目（集めるものごとに違う）。
  """
  def field_rows(%{module: module}), do: module.fields()

  @doc "区画の一覧に出す数。"
  def shown_partitions, do: @shown_partitions

  @doc """
  「この区画で 1 回走らせる」に渡す指定。**ワーカーは相手とは別の鍵**で渡します ——
  渡す先はそのときの枠で決まるので、モデルを 1 つ選んでも意味が決まりません。
  """
  def run_options(params, backends) do
    picked = String.trim(params["run|backend"] || "")
    {_plain, hands} = ChidoriWeb.Collect.by_kind(backends)
    worker? = Enum.any?(hands, &(&1.id == picked))

    [sweep: blank_to_nil(params["sweep"])] ++
      cond do
        picked == "" -> []
        worker? -> [worker: picked]
        true -> [backend: picked, model: blank_to_nil(params["run|model"])]
      end
  end

  @doc """
  依頼を頼むときの相手の指定（`Requests.send_partition/5` に渡す）。選び方は
  「この区画で 1 回走らせる」と同じで、巡回は依頼の巡回のまま変えない。
  """
  def request_options(%{request_backend: backend, request_model: model, backends: backends}) do
    %{"run|backend" => backend, "run|model" => model}
    |> run_options(backends)
    |> Keyword.delete(:sweep)
  end

  defp blank_to_nil(value) do
    case String.trim(value || "") do
      "" -> nil
      text -> text
    end
  end

  @doc """
  選んでいる区画の 1 行ぶん。**選ばれていなければ nil**。

  一覧から探し直さずに済むように、鍵で引いてそのまま返します ——
  地図で押した区画の件数も「見終わったか」も、台帳にしかありません。
  """
  def picked_row(rows, key) when is_binary(key), do: Enum.find(rows, &(&1.key == key))
  def picked_row(_rows, _key), do: nil

  @doc """
  抽出の指定（機械で引く条件）。**何で埋まったのかが読めないと、間違いを
  AI のせいにしてしまいます** —— 名前と座標は辞典から引いたものです。

  **Chiezo が持っているものを出します**（依頼した後は向こうの画面から直せるので、
  Chidori の雛形を出し続けると食い違う）。
  """
  def extract_text(%{collection: %{extract: spec}}) when is_map(spec),
    do: Jason.encode!(spec, pretty: true)

  # **抽出の指定を持たない対象もある**（技術書は記事を溜めてからタグで数えるので、
  # 辞典から引かない）。持たなければ nil で、画面はその見出しごと出さない
  def extract_text(%{dataset: dataset}) do
    if defines?(dataset, :extract, 0),
      do: Jason.encode!(Datasets.call(dataset, :extract), pretty: true)
  end

  @doc """
  県ごとの進み具合の行に、その県の区画の「見終わった巡回」を添えます（区画の台帳から）。
  台帳に無い県（まだ区画が作られていない）は `by: nil`。
  """
  def prefecture_rows(rows, partition_rows) do
    seen = Map.new(partition_rows, &{&1.key, &1})

    Enum.map(rows, fn row ->
      case Map.get(seen, row.key) do
        nil -> Map.merge(row, %{by: nil, seen: nil, in_ledger: false})
        partition -> Map.merge(row, %{by: partition.by, seen: partition.seen, in_ledger: true})
      end
    end)
  end

  @doc """
  選んだ県の数（県ごとの進み具合の行）。まだ数えていない・県でない鍵なら nil。
  """
  def picked_prefecture({:ok, %{rows: rows}}, key) when is_binary(key),
    do: Enum.find(rows, &(&1.key == key))

  def picked_prefecture(_progress, _key), do: nil

  @doc "県ごとの進み具合の合計の一文（引き当ての口を持たない Chiezo では、その数を言わない）。"
  def progress_summary(progress, rows) do
    total = fn key -> Enum.sum(Enum.map(rows, &Map.get(&1, key, 0))) end

    failed =
      if progress.unresolved_total,
        do: "（うち引き当てできず #{total.(:unresolved)} 件）",
        else: ""

    "料理・店 #{total.(:dishes)} 件（うち店 #{total.(:shops)} 件）・" <>
      "代表店が決まって地図に置ける #{total.(:placed)} 件・" <>
      "代表店まだ #{total.(:pending)} 件#{failed}・代表店なし #{total.(:no_shop)} 件。"
  end

  @doc """
  引き当てと書式の指定（JSON）。**持つ対象だけ**（ご当地グルメ）。持たなければ nil。
  """
  def resolve_text(%{dataset: dataset}) do
    if defines?(dataset, :resolve, 0) and defines?(dataset, :formats, 0),
      do:
        Jason.encode!(
          %{resolve: Datasets.call(dataset, :resolve), formats: Datasets.call(dataset, :formats)},
          pretty: true
        )
  end

  @doc "区画の割り方。**座標で割るので、鍵は矩形になります**。"
  def partition_text(%{collection: %{partition: spec}}) when is_map(spec),
    do: Jason.encode!(spec, pretty: true)

  # 区画で回らない対象（技術書）は nil（画面はその見出しごと出さない）
  def partition_text(%{dataset: dataset}) do
    if defines?(dataset, :shape, 0),
      do: Jason.encode!(Datasets.call(dataset, :shape).partition, pretty: true)
  end

  # travel-log から依頼を受ける対象だけ読む（依頼の口があるのはそこだけ）
  defp load_request_results(%{assigns: %{dataset: %{reader: "travel-log"} = dataset}} = socket),
    do: start_async(socket, :request_results, fn -> Requests.results(dataset) end)

  defp load_request_results(socket), do: socket

  # 控えている依頼を、いま読めている区画で振り分け直す（travel-log から依頼を受ける対象だけ）
  defp assign_pending(%{assigns: %{dataset: %{reader: "travel-log"} = dataset}} = socket) do
    partitions = get_in(socket.assigns, [:state, :collection, :partitions]) || []
    assign(socket, pending: Requests.pending(dataset, partitions))
  end

  defp assign_pending(socket), do: socket

  defp load_recent_runs(%{assigns: %{dataset: dataset}} = socket),
    do: start_async(socket, :recent_runs, fn -> Requests.runs(dataset) end)

  @doc "「位置OK」「位置修正」の行を固定した結果の一言。"
  def held_message(nil), do: nil
  def held_message(:holding), do: "位置OK・位置修正の店の座標を、Chiezo に固定させています…"
  def held_message({:error, reason}), do: "位置を固定できませんでした。" <> reason_text(reason)

  def held_message({:ok, %{held: held, missed: missed, failed: failed}}) do
    [
      held != [] &&
        "位置を固定しました: #{Enum.join(held, "、")}（AI に座標を動かさせません。次に焼くときから効きます。待たずに出したいときは「AI を使わずにいま反映する」）。",
      missed != [] &&
        "近くに同じ名前の店が見つからず、固定できなかった: #{Enum.join(missed, "、")}。",
      failed != [] &&
        "固定を断られた: " <>
          Enum.map_join(failed, "、", fn {shop, reason} -> "#{shop}（#{reason_text(reason)}）" end)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end

  @doc "「AI を使わずにいま反映する」の結果の一言。"
  def applied_message(:applying), do: "機械収集の回を頼んでいます…"

  def applied_message(:ok),
    do: "機械収集の回を頼みました（AI は使いません）。焼き終わると、固定した座標が反映されます。"

  def applied_message({:error, reason}),
    do: "反映を頼めませんでした。" <> reason_text(reason)

  @doc "最近の回の一言（足した・直した・消した数。失敗ならその理由）。"
  def run_state(%{status: "ok", added: 0, updated: 0, removed: 0}), do: "変化なし"

  def run_state(%{status: "ok"} = run),
    do: "足した #{run.added} ・直した #{run.updated} ・消した #{run.removed}"

  def run_state(%{error: error}), do: "失敗（#{error}）"

  @doc "最近の回が見た範囲（区画の数。区画を回らない回は空）。"
  def run_scope(%{visited: [_ | _] = visited, scope: scope}) when visited != scope,
    do: "区画 #{length(visited)} / #{length(scope)} つ"

  def run_scope(%{scope: [_ | _] = scope}), do: "区画 #{length(scope)} つ"
  def run_scope(_run), do: ""

  @doc """
  travel-log からの依頼を頼む相手とモデル。**選ばなければ巡回の設定のまま**。
  区画の欄と「控えている依頼」の両方に置くので、どちらで選んでも同じ値を覚える。
  """
  attr :id, :string, required: true
  attr :backends, :list, required: true
  attr :backend, :string, default: nil
  attr :model, :string, default: nil

  def request_picker(assigns) do
    {plain, hands} = by_kind(assigns.backends)

    assigns =
      assign(assigns,
        plain: plain,
        hands: hands,
        models: models_for(assigns.backends, assigns.backend)
      )

    ~H"""
    <form id={@id} phx-change="pick_request" class="collect-form request-picker">
      <p>
        <label>
          頼む相手<br />
          <select name="request|backend">
            <option value="">巡回の設定のまま</option>
            <option :for={b <- @plain} value={b.id} selected={b.id == @backend}>{b.label}</option>
            <optgroup :if={@hands != []} label="ワーカー（枠を見て振り替える）">
              <option :for={b <- @hands} value={b.id} selected={b.id == @backend}>{b.label}</option>
            </optgroup>
          </select>
        </label>
        <label :if={@models != []}>
          モデル<br />
          <select name="request|model">
            <option value="">モデルは相手の既定</option>
            <option :for={m <- @models} value={m} selected={m == @model}>{m}</option>
          </select>
        </label>
      </p>
    </form>
    """
  end

  @doc """
  1 回ぶんの「足した・直した・消した」の見出しの一覧。**依頼の結果と最近の回で
  同じものを出す**（見出しを押すと、Chiezo の画面で直す前との違いが開く）。
  """
  attr :change, :map, required: true
  attr :collection, :string, required: true

  def change_lists(assigns) do
    ~H"""
    <div
      :for={
        {label, titles, count, class} <- [
          {"足した", @change.added_titles, @change.added, "is-added"},
          {"直した", @change.updated_titles, @change.updated, "is-updated"},
          {"消した", @change.removed_titles, @change.removed, "is-removed"}
        ]
      }
      :if={count > 0}
      class={["request-changes", class]}
    >
      <h4>{label}（{count} 件）</h4>
      <ul>
        <li :for={title <- titles}>
          <a
            :if={Chidori.Chiezo.doc_page_url(@collection, title)}
            href={Chidori.Chiezo.doc_page_url(@collection, title)}
            target="_blank"
            rel="noreferrer"
          >
            {title}
          </a>
          <span :if={!Chidori.Chiezo.doc_page_url(@collection, title)}>{title}</span>
        </li>
        <li :if={more_than_shown(count, titles) > 0} class="muted-note">
          ほか {more_than_shown(count, titles)} 件（Chiezo の控えは頭のほうだけ）
        </li>
      </ul>
    </div>
    """
  end

  @doc "依頼の状態の言い方。"
  def request_state(%{log: %{status: "failed", error: error}}),
    do: "頼めませんでした（#{error}）"

  def request_state(%{log: %{status: "waiting"}}),
    do: "取り込みが空くのを待っています"

  def request_state(%{result: nil}),
    do: "Chiezo が受けました。回が終わると、ここに結果が出ます"

  # **途中で止まった回は「動いた」と言わない。** 見終えた区画のぶんは直っているので
  # 件数は添えるが、頼んだ区画の残りはまだ誰も見ていない
  def request_state(%{
        result: %{status: "ok"} = result,
        unfinished: [_ | _] = unfinished,
        log: log
      }),
      do:
        "途中で止まりました（見終えたのは #{length(log.keys) - length(unfinished)} / #{length(log.keys)} 区画。" <>
          "足した #{result.added} ・直した #{result.updated} ・消した #{result.removed}）"

  def request_state(%{result: %{status: "ok"} = result}),
    do: "足した #{result.added} ・直した #{result.updated} ・消した #{result.removed}"

  def request_state(%{result: result}),
    do: "回が失敗しました（#{result.error}）"

  @doc "見出しの一覧に出しきれなかった数（Chiezo の控えは頭のほうだけ）。"
  def more_than_shown(count, titles) when count > length(titles), do: count - length(titles)
  def more_than_shown(_count, _titles), do: 0

  # 対象の関数を持つか。**範囲を持つ対象は範囲を最後の引数に足して呼ぶ**ので
  # （`Datasets.call/3`）、そのぶん引数が 1 つ多い
  defp defines?(%{module: module} = dataset, name, arity) do
    arity = if dataset[:area], do: arity + 1, else: arity
    Code.ensure_loaded?(module) and function_exported?(module, name, arity)
  end

  @doc """
  巡回ごとの依頼文。**回ごとに頼むことが違う**ので、1 つの文だけを出すと、
  実際に走っている内容と画面が食い違います。

  **Chiezo が持っているものを先に出します**（送った後は向こうが正）。
  """
  def sweep_prompts(%{collection: %{sweeps: sweeps}} = assigns) when is_list(sweeps) do
    written =
      for sweep <- sweeps,
          text = sweep_prompt_of(sweep, assigns),
          text != "",
          do: {sweep.name, text}

    if written == [], do: default_prompts(assigns), else: written
  end

  def sweep_prompts(assigns), do: default_prompts(assigns)

  # 巡回に書かれていなければ、収集ぜんたいの依頼文がその回の文になる（Chiezo の決まり）
  defp sweep_prompt_of(sweep, assigns) do
    case Map.get(sweep, :prompt) do
      text when is_binary(text) and text != "" -> text
      _ -> if sweep[:use_extract] || sweep[:use_pihole], do: "", else: collection_prompt(assigns)
    end
  end

  defp collection_prompt(%{state: %{collection: %{prompt: prompt}}}) when is_binary(prompt),
    do: prompt

  defp collection_prompt(_assigns), do: ""

  # **まだ Chiezo に無い収集では、対象の側の雛形を出す。** 巡回の名前も文も
  # 対象ごとに違うので、ここで決め打つと対象を足すたびに画面が食い違う
  defp default_prompts(%{dataset: dataset}), do: Datasets.call(dataset, :prompts)

  # 本の印の読み方は詳細（`ChidoriWeb.BookModal`）と同じものを使う（本棚の一覧にも出す）
  defdelegate read_titles(marks), to: ChidoriWeb.BookModal
  defdelegate book_mark_of(marks, title), to: ChidoriWeb.BookModal, as: :mark_of
  defdelegate book_mark_summary(mark), to: ChidoriWeb.BookModal, as: :summary

  @doc "詳細を開いているドメイン（一覧に無くなっていれば nil）。"
  def opened_domain(%{opened_domain: domain, shelf: {:ok, domains}}) when is_binary(domain),
    do: Enum.find(domains, &(&1.domain == domain))

  def opened_domain(_assigns), do: nil

  @doc "絞り込んだドメイン（`marks` は「見た」印。まだ見ていないものだけを出すのに使う）。"
  def domains_shown(domains, filter, marks \\ %{})

  def domains_shown(domains, "unseen", marks),
    do: Enum.reject(domains, &domain_seen?(marks, &1.domain))

  def domains_shown(domains, filter, _marks), do: shown_by(domains, filter)

  defp shown_by(domains, "watch"), do: Enum.filter(domains, & &1.watch)
  defp shown_by(domains, "blocked"), do: Enum.filter(domains, & &1.blocked)
  defp shown_by(domains, "caution"), do: Enum.filter(domains, &(&1.verdict == "要注意"))
  defp shown_by(domains, _all), do: domains

  @doc "そのドメインに「見た」が付いているか（メモだけのものは見ていない扱い）。"
  def domain_seen?(marks, domain), do: match?(%{seen: true}, Map.get(marks, domain))

  @doc "ドメインの印（無ければ空の印）。"
  def domain_mark_of(marks, domain),
    do: Map.get(marks, domain) || %Chidori.Relations.Mark{}

  @doc "「見た日」の欄に最初から入れる日付（書いてあればそれ、無ければ日本時間の今日）。"
  def domain_seen_on(%Chidori.Relations.Mark{seen_on: %Date{} = date}), do: Date.to_iso8601(date)
  def domain_seen_on(_mark), do: Jst.today() |> Date.to_iso8601()

  @doc "印を 1 行で言う（一覧の札に出す）。"
  def domain_mark_summary(%Chidori.Relations.Mark{seen: true, seen_on: %Date{} = date}),
    do: "見た（#{Date.to_iso8601(date)}）"

  def domain_mark_summary(%Chidori.Relations.Mark{seen: true}), do: "見た"

  def domain_mark_summary(%Chidori.Relations.Mark{note: note})
      when is_binary(note) and note != "",
      do: "メモあり"

  def domain_mark_summary(_mark), do: nil

  @doc "判定の札の色。"
  def verdict_class("要注意"), do: "verdict is-caution"
  def verdict_class("問題なし"), do: "verdict is-fine"
  def verdict_class(_verdict), do: "verdict"

  @doc "詳細を開いている本（本棚に無くなっていれば nil）。"
  def opened_book(%{opened_book: title, shelf: {:ok, books}}) when is_binary(title),
    do: Enum.find(books, &(&1.title == title))

  def opened_book(_assigns), do: nil

  @doc "この収集から作る収集（本棚）の、巡回ごとの依頼文。"
  def derived_prompts(%{derived: derived}) when not is_nil(derived) do
    Code.ensure_loaded(derived)
    if function_exported?(derived, :prompts, 0), do: derived.prompts(), else: []
  end

  def derived_prompts(_dataset), do: []

  @doc "この収集から作る収集の、機械で引く指定（JSON）。持たなければ nil。"
  def derived_extract(%{derived: derived}) when not is_nil(derived) do
    Code.ensure_loaded(derived)

    if function_exported?(derived, :extract_spec, 0),
      do: Jason.encode!(derived.extract_spec(), pretty: true)
  end

  def derived_extract(_dataset), do: nil

  # 情報収集が 1 回に回る区画の数を覚え、覚えた範囲で対象を作り直す（送る中身に効かせるため）。
  # 範囲ごとの食事処でなければ、そのまま
  defp with_survey_per_run(%{area: area, key: key} = dataset, value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n != area.survey_per_run ->
        case DiningAreas.set_survey_per_run(area, n) do
          {:ok, _saved} -> Datasets.get(key)
          {:error, _changeset} -> dataset
        end

      _same ->
        dataset
    end
  end

  defp with_survey_per_run(dataset, _value), do: dataset

  # 範囲ごとの食事処の、情報収集を起こす時刻（ほかの対象では nil = 欄を出さない）
  defp survey_times_of(dataset) do
    if dataset[:area], do: DiningSurveySetting.get(dataset.collection).run_at || ""
  end

  defp changeset_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Map.values()
    |> List.flatten()
    |> List.first("起こす時刻を保存できませんでした。")
  end
end
