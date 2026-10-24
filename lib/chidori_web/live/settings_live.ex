defmodule ChidoriWeb.SettingsLive do
  @moduledoc """
  設定ページ。**タブで仕事を分けます**。

  - 写真と表紙 —— 顔写真・レシピの写真・技術書の表紙を取る様子
  - 通知 —— まとめの知らせ先（ntfy の宛先と、通知を受け取る端末。`Chidori.WebPush`）と、
    知らせる話題

  **収集の画面（`/collect`）も同じ LiveView**（`live_action` が `:collect`）。Chidori が Chiezo に
  頼んでいる収集の一覧（巡回の間隔・相手・前回・次回）と、ワーカーと取り込みの待ち行列。
  **待ち行列が溜まってきたときに、何がどれだけの間隔で回っているかを 1 枚で読むため**
  （`Chidori.CollectOverview`）。収集ごとに、巡回の相手と整理を自動で回すかを選んで送れる。
  もとは設定ページの「Chiezo 収集」のタブだった
  """

  use ChidoriWeb, :live_view

  import ChidoriWeb.Collect, only: [sweep_choices: 1, models_for: 2, by_kind: 1, reason_text: 1]

  alias Chidori.Chiezo
  alias Chidori.CollectCatalog
  alias Chidori.CollectOverview
  alias Chidori.CollectPace
  alias Chidori.News
  alias Chidori.Notify.Destination
  alias Chidori.Notify.Settings
  alias Chidori.Topics
  alias Chidori.WebPush
  alias Chidori.WebPush.Subscriptions

  require Logger

  # **Chiezo 収集の表は収集の画面（`/collect`）へ移した** —— 同じ LiveView を収集の形で開く。
  # トップページ（閲覧）は廃止したので、並べる枠を選ぶタブも無い
  @tabs [
    {"photos", "写真と表紙"},
    {"notify", "通知"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "設定",
       tabs: @tabs,
       overview: nil,
       pace_message: nil,
       restore_message: nil,
       # 収集ごとに選んでいるもの（`%{収集 => %{"sweeps" => 巡回ごとの相手, "tidy" => bool}}`）。
       # **覚えておく** —— 表を読み直すとフォームは Chiezo の値に戻るので、覚えていないと
       # 選んだところが勝手に元へ戻る
       picks: %{},
       # 収集ごとに、送った結果の一言
       sent: %{},
       # ワーカーごとに、止めた・起こした結果の一言
       worker_sent: %{},
       # 収集ごとの検索文の控え（開いたときだけ読む。`{:ok, 行}` / `{:error, 理由}` / `:loading`）
       queries: %{},
       # 「最後に取得」（Chiezo から表を読めた時刻）と、読み直している最中か
       checked_at: nil,
       reloading: false,
       # 写真と表紙の取得（Chidori の列・持っている写し・Chiezo の具合と直近の依頼）
       photo_status: nil,
       photo_counts: nil,
       chiezo_thumbs: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    cond do
      # 収集の画面（`/collect`）は、収集の表だけを出す
      socket.assigns.live_action == :collect ->
        {:noreply,
         socket
         |> assign(tab: "chiezo", page_title: "収集")
         |> load("chiezo")}

      # 前の「設定 › Chiezo 収集」へのリンクは、収集の画面へ送る
      params["tab"] == "chiezo" ->
        {:noreply, push_navigate(socket, to: ~p"/collect", replace: true)}

      true ->
        tab = if params["tab"] in Enum.map(@tabs, &elem(&1, 0)), do: params["tab"], else: "photos"

        {:noreply, socket |> assign(tab: tab) |> load(tab)}
    end
  end

  # **開くたびに読み直す**（Chiezo の側は勝手に進む。写しは持たない）
  defp load(socket, "chiezo") do
    case News.chiezo_base_url() do
      nil ->
        assign(socket, overview: {:error, :chiezo_not_configured})

      base ->
        if connected?(socket) do
          # **読めている表は読み直すあいだも出しておく**（消すと、送った結果の一言も
          # 表と一緒に消える）
          socket
          |> update(:overview, &if(match?({:ok, _}, &1), do: &1, else: :loading))
          |> assign(reloading: true)
          |> start_async(:overview, fn -> load_overview(base) end)
        else
          assign(socket, overview: :loading)
        end
    end
  end

  # 通知の宛先。**全部の通知で 1 つ**（話題ごとに決めるのは知らせるかどうかだけ）
  defp load(socket, "notify") do
    assign(socket,
      ntfy_form: ntfy_form(),
      notify_topics: notify_topics(),
      push_key: push_key(),
      push_devices: Subscriptions.list(),
      push_message: nil,
      push_testing: false
    )
  end

  # 写真と表紙の取得。**Chidori の列と写しは手元、取れているかと直近の依頼は Chiezo から**
  # （頼みが Chidori の列で待っているのか、Chiezo へ届いて断られているのかを並べて読めるように）
  defp load(socket, "photos") do
    socket =
      assign(socket,
        photo_status: Chidori.Relations.Faces.status(),
        photo_counts: Chidori.Relations.Faces.counts()
      )

    case News.chiezo_base_url() do
      nil ->
        assign(socket, chiezo_thumbs: {:error, :chiezo_not_configured})

      base ->
        if connected?(socket) do
          socket
          |> assign(chiezo_thumbs: :loading)
          |> start_async(:chiezo_thumbs, fn -> Chidori.Chiezo.thumbs_health(base) end)
        else
          assign(socket, chiezo_thumbs: :loading)
        end
    end
  end

  defp load(socket, _tab), do: socket

  defp ntfy_form(attrs \\ %{}), do: to_form(Destination.change(attrs), as: :ntfy)

  # 要約を作る話題と、それぞれ知らせるかどうか（ここでも各話題の画面でも切り替えられる）
  defp notify_topics do
    for topic <- Topics.list(), Topics.digest?(topic) do
      %{
        name: topic.name,
        collection: topic.collection,
        notify: Settings.get(topic.collection).notify
      }
    end
  end

  # 送り手の公開鍵（無ければここで作る）。**表がまだ無い DB では nil**（マイグレーション前）——
  # 通知のタブごと落とすより、端末の欄だけ出さないほうが ntfy の設定を続けられる
  defp push_key do
    WebPush.public_key()
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning("送り手の鍵を読めなかった: #{Exception.message(error)}")
      nil
  end

  # 収集の表は **Chidori の画面の並び**で、Chiezo にまだ無い収集も出す（`CollectCatalog`）
  defp load_overview(base) do
    with {:ok, overview} <- CollectOverview.load(base) do
      {:ok, %{overview | collections: CollectCatalog.rows(overview.collections)}}
    end
  end

  @impl true
  def handle_async(:chiezo_thumbs, {:ok, result}, socket),
    do: {:noreply, assign(socket, chiezo_thumbs: result)}

  def handle_async(:chiezo_thumbs, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, chiezo_thumbs: {:error, :chiezo_unavailable})}

  def handle_async(:overview, {:ok, result}, socket),
    do: {:noreply, assign(socket, overview: result, reloading: false) |> stamp(result)}

  def handle_async(:overview, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, overview: {:error, :chiezo_unavailable}, reloading: false)}

  def handle_async(:pace, {:ok, result}, socket) do
    {:noreply, socket |> assign(pace_message: pace_text(result)) |> load("chiezo")}
  end

  def handle_async({:send, name}, {:ok, results}, socket) do
    {:noreply,
     socket
     |> update(:sent, &Map.put(&1, name, send_text(results)))
     |> update(:picks, &Map.delete(&1, name))
     |> load("chiezo")}
  end

  def handle_async({:switch, name}, {:ok, {on?, result}}, socket) do
    {:noreply,
     socket
     |> update(:sent, &Map.put(&1, name, switch_text(on?, result)))
     |> load("chiezo")}
  end

  def handle_async({:switch, name}, {:exit, _reason}, socket),
    do: {:noreply, update(socket, :sent, &Map.put(&1, name, "切り替えられませんでした。"))}

  def handle_async({:operate, name}, {:ok, {op, result}}, socket) do
    {:noreply,
     socket
     |> update(:sent, &Map.put(&1, name, operate_text(op, result)))
     |> load("chiezo")}
  end

  def handle_async({:operate, name}, {:exit, _reason}, socket),
    do: {:noreply, update(socket, :sent, &Map.put(&1, name, "頼めませんでした。"))}

  def handle_async({:worker, id}, {:ok, {op, result}}, socket) do
    {:noreply,
     socket
     |> update(:worker_sent, &Map.put(&1, id, worker_text(op, result)))
     |> load("chiezo")}
  end

  def handle_async({:worker, id}, {:exit, _reason}, socket),
    do: {:noreply, update(socket, :worker_sent, &Map.put(&1, id, "頼めませんでした。"))}

  def handle_async({:queries, name}, {:ok, result}, socket),
    do: {:noreply, update(socket, :queries, &Map.put(&1, name, result))}

  def handle_async({:queries, name}, {:exit, _reason}, socket),
    do: {:noreply, update(socket, :queries, &Map.put(&1, name, {:error, :chiezo_unavailable}))}

  def handle_async({:send, name}, {:exit, _reason}, socket),
    do: {:noreply, update(socket, :sent, &Map.put(&1, name, "送れませんでした。"))}

  def handle_async(:restore, {:ok, result}, socket),
    do: {:noreply, socket |> assign(restore_message: restore_text(result)) |> load("chiezo")}

  def handle_async(:restore, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, restore_message: restore_text({:error, :chiezo_unavailable}))}

  def handle_async(:test_push, {:ok, results}, socket) do
    {:noreply,
     assign(socket,
       push_testing: false,
       push_message: Subscriptions.result_text(results),
       push_devices: Subscriptions.list()
     )}
  end

  def handle_async(:test_push, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, push_testing: false, push_message: "送れませんでした。")}

  def handle_async(:pace, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, pace_message: pace_text({:error, :chiezo_unavailable}))}

  # 読めたときだけ「最後に取得」を進める（読めなかったときは前の時刻のまま）
  defp stamp(socket, {:ok, _overview}), do: assign(socket, checked_at: DateTime.utc_now())
  defp stamp(socket, _result), do: socket

  @impl true
  def handle_event("reload", _params, socket), do: {:noreply, load(socket, "chiezo")}

  def handle_event("reload_photos", _params, socket), do: {:noreply, load(socket, "photos")}

  # **保存してから送る。** 送れなくても保存は残る（次に「収集の設定を更新」を押した
  # ときにも、この間隔で組んで送られる）
  # Chiezo に残っている設定から戻す（`Chidori.SettingsRestore`）
  def handle_event("restore_settings", _params, socket) do
    case News.chiezo_base_url() do
      nil ->
        {:noreply, assign(socket, restore_message: "Chiezo の場所が設定されていません。")}

      base ->
        {:noreply,
         socket
         |> assign(restore_message: "Chiezo を読んでいます…")
         |> start_async(:restore, fn -> Chidori.SettingsRestore.run(base) end)}
    end
  end

  def handle_event("save_pace", %{"pace" => pace}, socket) do
    saved =
      for kind <- CollectPace.kinds(),
          value = pace[to_string(kind)],
          {minutes, ""} <- [Integer.parse(to_string(value))],
          do: CollectPace.put(kind, minutes)

    cond do
      Enum.any?(saved, &(&1 != :ok)) ->
        {:noreply, assign(socket, pace_message: "選べない間隔が含まれていました。")}

      base = News.chiezo_base_url() ->
        {:noreply,
         socket
         |> assign(pace_message: "保存しました。Chiezo に送っています…")
         |> start_async(:pace, fn -> CollectPace.apply(base) end)}

      true ->
        {:noreply,
         assign(socket,
           pace_message: "保存しました（Chiezo の場所が設定されていないので送っていません）。"
         )}
    end
  end

  # 選び直したところを覚える（送るまでは Chiezo に触らない）
  def handle_event("pick", %{"collection" => name} = params, socket) do
    {:noreply, update(socket, :picks, &Map.put(&1, name, form_picks(params)))}
  end

  # **収集ごとに送る。** 相手は選び直した巡回だけ、整理は切り替えたときだけ送る
  # （同じ値を送り直すと、押していない巡回まで「直した」ことになる）
  def handle_event("send_collection", %{"collection" => name} = params, socket) do
    with {:ok, overview} <- socket.assigns.overview,
         %{} = collection <- Enum.find(overview.collections, &(&1.name == name)),
         base when is_binary(base) <- News.chiezo_base_url() do
      picked = form_picks(params)

      {:noreply,
       socket
       |> update(:sent, &Map.put(&1, name, "送っています…"))
       |> start_async({:send, name}, fn -> send_collection(base, collection, picked) end)}
    else
      _ -> {:noreply, update(socket, :sent, &Map.put(&1, name, "送れませんでした（Chiezo が読めていません）。"))}
    end
  end

  # **収集を止める・動かす**（Chiezo の `POST /v1/collect/{name}/enabled`）。動かすのは Chiezo の
  # 管理画面で外部からの有効化を許可したときだけ通る（`Chidori.Chiezo.switch/3`）。終わったら表を読み直す
  def handle_event("switch_collection", %{"collection" => name, "enabled" => enabled}, socket) do
    case News.chiezo_base_url() do
      base when is_binary(base) ->
        on? = enabled == "true"

        {:noreply,
         socket
         |> update(:sent, &Map.put(&1, name, if(on?, do: "動かしています…", else: "止めています…")))
         |> start_async({:switch, name}, fn -> {on?, Chidori.Chiezo.switch(base, name, on?)} end)}

      _none ->
        {:noreply, update(socket, :sent, &Map.put(&1, name, "Chiezo の場所が決まっていません。"))}
    end
  end

  # **Chiezo の管理画面のボタンと同じ操作**（やり直す・一周をやり直す・未確認に戻す・
  # 区画を割り直す・取り込みを止める）。中身は Chiezo の REST（`Chidori.Chiezo.operate/3`）
  def handle_event("operate", %{"collection" => name, "op" => op} = params, socket) do
    with base when is_binary(base) <- News.chiezo_base_url(),
         {:ok, op} <- parse_op(op, params["sweep"]) do
      {:noreply,
       socket
       |> update(:sent, &Map.put(&1, name, "頼んでいます…"))
       |> start_async({:operate, name}, fn -> {op, Chidori.Chiezo.operate(base, name, op)} end)}
    else
      _ -> {:noreply, update(socket, :sent, &Map.put(&1, name, "頼めませんでした。"))}
    end
  end

  # **ワーカーを止める・動かす・起こす**（Chiezo の `POST /v1/ai/workers/{id}/…`）
  def handle_event("worker", %{"id" => id, "op" => op}, socket)
      when op in ["pause", "resume", "wake"] do
    case News.chiezo_base_url() do
      base when is_binary(base) ->
        {:noreply,
         socket
         |> update(:worker_sent, &Map.put(&1, id, "頼んでいます…"))
         |> start_async({:worker, id}, fn ->
           {op,
            case op do
              "pause" -> Chidori.Chiezo.pause_worker(base, id, true)
              "resume" -> Chidori.Chiezo.pause_worker(base, id, false)
              "wake" -> Chidori.Chiezo.wake_worker(base, id)
            end}
         end)}

      _none ->
        {:noreply, update(socket, :worker_sent, &Map.put(&1, id, "Chiezo の場所が決まっていません。"))}
    end
  end

  # **検索文の控え**。開いたときだけ読む（収集の数だけ毎回聞きに行かない）
  def handle_event("load_queries", %{"collection" => name}, socket) do
    case News.chiezo_base_url() do
      base when is_binary(base) ->
        {:noreply,
         socket
         |> update(:queries, &Map.put(&1, name, :loading))
         |> start_async({:queries, name}, fn -> Chidori.Chiezo.queries(base, name) end)}

      _none ->
        {:noreply, update(socket, :queries, &Map.put(&1, name, {:error, :chiezo_not_configured}))}
    end
  end

  # 検索文を 1 つ（`query` が空なら全部）消して、控えを読み直す
  def handle_event("forget_query", %{"collection" => name} = params, socket) do
    case News.chiezo_base_url() do
      base when is_binary(base) ->
        query = if params["query"] in [nil, ""], do: nil, else: params["query"]

        {:noreply,
         socket
         |> update(:queries, &Map.put(&1, name, :loading))
         |> start_async({:queries, name}, fn ->
           with :ok <- Chidori.Chiezo.forget_queries(base, name, query),
                do: Chidori.Chiezo.queries(base, name)
         end)}

      _none ->
        {:noreply, socket}
    end
  end

  # **Chidori が起こす回の時刻を直す**（要約の回は `Notify.Settings` の digest_at、
  # 映画の図への引き継ぎは `Relations.CarrySetting` の run_at、情報収集は
  # `Datasets.SurveySetting` の run_at）。
  # Chiezo には送らない
  def handle_event(
        "save_wake",
        %{"collection" => name, "kind" => kind, "times" => times} = params,
        socket
      ) do
    result =
      case kind do
        "digest" ->
          Chidori.Notify.Settings.put(name, %{"digest_at" => times})

        # 最新情報の映画を図へ引き継ぐ時刻と 1 回の数（`Chidori.Relations.CarrySetting`）
        "carry" ->
          Chidori.Relations.CarrySetting.put(%{"run_at" => times, "batch" => params["batch"]})

        # 情報収集を起こす時刻（収集ごと。`Chidori.Datasets.SurveySetting`）
        "survey" ->
          Chidori.Datasets.SurveySetting.put(name, %{"run_at" => times})

        _other ->
          {:error, :unknown}
      end

    message =
      case result do
        {:ok, _saved} -> "起こす時刻を保存しました。"
        {:error, %Ecto.Changeset{} = changeset} -> first_error(changeset)
        {:error, _reason} -> "起こす時刻を保存できませんでした。"
      end

    {:noreply,
     socket |> assign(sent: Map.put(socket.assigns.sent, name, message)) |> load("chiezo")}
  end

  # 書いたそばから覚える。覚えないと、描き直しの拍子に書きかけが消える
  def handle_event("edit_ntfy", %{"ntfy" => attrs}, socket) do
    {:noreply, assign(socket, ntfy_form: ntfy_form(attrs))}
  end

  def handle_event("save_ntfy", %{"ntfy" => attrs}, socket) do
    case Destination.put(attrs) do
      {:ok, _destination} ->
        {:noreply,
         socket
         |> assign(ntfy_form: ntfy_form())
         |> put_flash(:info, "ntfy の設定を保存しました。")}

      {:error, changeset} ->
        # 書いたものは消さない
        {:noreply,
         socket
         |> assign(ntfy_form: to_form(%{changeset | action: :validate}, as: :ntfy))
         |> put_flash(:error, "ntfy の設定を保存できませんでした: " <> first_error(changeset))}
    end
  end

  # この端末を登録する（`assets/js/web_push.js` が、ブラウザの作った宛先を渡してくる）。
  # **結果は返事で返す** —— 端末の側は、登録できたかで出す一言とボタンを変える
  def handle_event("push_subscribe", %{"subscription" => subscription} = params, socket)
      when is_map(subscription) do
    case Subscriptions.subscribe(subscription, params["user_agent"] || "") do
      {:ok, device} ->
        {:reply, %{ok: true},
         assign(socket,
           push_devices: Subscriptions.list(),
           push_message: "この端末（#{device.label}）を登録しました。"
         )}

      {:error, changeset} ->
        {:reply, %{ok: false},
         assign(socket, push_message: "この端末を登録できませんでした: " <> first_error(changeset))}
    end
  end

  # この端末で受け取るのをやめた（ブラウザの側はもう宛先を捨てている）
  def handle_event("push_unsubscribe", %{"endpoint" => endpoint}, socket)
      when is_binary(endpoint) do
    Subscriptions.delete_endpoint(endpoint)

    {:noreply,
     assign(socket,
       push_devices: Subscriptions.list(),
       push_message: "この端末では受け取らないようにしました。"
     )}
  end

  # この端末が登録してあるか（ブラウザが宛先を持っていても、一覧から外したものは未登録）
  def handle_event("push_check", %{"endpoint" => endpoint}, socket) do
    {:reply, %{registered: Enum.any?(socket.assigns.push_devices, &(&1.endpoint == endpoint))},
     socket}
  end

  def handle_event("remove_device", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(to_string(id)), do: Subscriptions.delete(id)

    {:noreply,
     socket
     |> assign(push_devices: Subscriptions.list(), push_message: "端末を外しました。")
     |> push_event("web_push:refresh", %{})}
  end

  # **全部の端末へ送って、結果を出す。** 登録しただけでは、届くかどうかは分からない
  # （通知を切っている・配信先が受け取らない）
  def handle_event("test_push", _params, socket) do
    {:noreply,
     socket
     |> assign(push_testing: true, push_message: "送っています…")
     |> start_async(:test_push, fn ->
       Subscriptions.deliver_all(
         "Chidori のテスト通知",
         "この端末に届いています。押すと設定の「通知」タブを開きます。",
         "/settings?tab=notify",
         tag: "test"
       )
     end)}
  end

  # 話題ごとに知らせるかを切り替える。**押したらすぐ保存する**（保存ボタンを押し忘れると、
  # チェックの見た目と実際がずれたまま残る）
  def handle_event("toggle_notify", %{"collection" => collection}, socket) do
    case Enum.find(socket.assigns.notify_topics, &(&1.collection == collection)) do
      nil ->
        {:noreply, socket}

      topic ->
        socket =
          case Settings.put(collection, %{"notify" => to_string(not topic.notify)}) do
            {:ok, _setting} ->
              word = if topic.notify, do: "知らせないようにしました", else: "知らせるようにしました"
              put_flash(socket, :info, "#{topic.name}を#{word}。")

            {:error, changeset} ->
              put_flash(socket, :error, "保存できませんでした: " <> first_error(changeset))
          end

        {:noreply, assign(socket, notify_topics: notify_topics())}
    end
  end

  defp first_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {_field, messages} -> messages end)
    |> List.first() || "書いた内容を確かめてください"
  end

  @doc "巡回の間隔の並び（ざっと見る → 整理。回る順）。"
  def pace_kinds, do: Enum.sort_by(CollectPace.kinds(), &if(&1 == :scan, do: 0, else: 1))

  @doc """
  その巡回を持つ収集の数と、そのうち動いているものの数（「Chidori に 5 本・動いている 3 本」）。
  **動いている**のは、収集も巡回も止まっておらず、自分の時計で回り、いま走れないわけの
  無いもの（依頼元が起こす回・一周して止まった回・前の回の一周待ちは数えない）。
  表を読めていなければ nil。
  """
  def pace_count({:ok, %{collections: collections}}, kind) do
    name = CollectPace.sweep_name(kind)

    sweeps =
      for collection <- collections,
          sweep <- collection.sweeps,
          sweep.name == name,
          do: {collection, sweep}

    running =
      Enum.count(sweeps, fn {collection, sweep} ->
        collection[:in_chiezo] != false and collection[:enabled] == true and
          sweep[:enabled] != false and not sweep[:by_caller] and sweep[:blocked] in [nil, ""]
      end)

    "Chidori に #{length(sweeps)} 本・動いている #{running} 本"
  end

  def pace_count(_overview, _kind), do: nil

  defp form_picks(params),
    do: %{"sweeps" => sweep_choices(params), "tidy" => params["tidy"] == "true"}

  @doc """
  1 つの収集に、選んだものを送ります。返すのは `[{巡回 | :all, :settings | :backend | :tidy, 結果}]`。

  **Chidori の画面にある収集は、その画面の「収集の設定を更新」と同じものを丸ごと送る**
  （`push`。依頼文を含む Chidori の今の定義に、選んだ相手を載せる）。整理を自動で
  回すかは先に Chidori に覚えさせる —— 丸ごと送る設定に、それが載る（`with_stops`）。

  **画面に無い収集**（Chiezo にだけ残っているもの）は定義を持たないので、**選び直した
  巡回の相手だけ**を送り、整理は切り替えたときだけ送る。
  """
  def send_collection(base, %{push: push} = collection, %{"sweeps" => sweeps, "tidy" => tidy})
      when is_function(push, 2) do
    tidies =
      for sweep <- collection.sweeps, tidy_sweep?(sweep), tidy != sweep.by_caller do
        result =
          case CollectPace.stop_tidy(collection.name, tidy, nil) do
            {:ok, :not_sent} -> :ok
            other -> other
          end

        {sweep.name, :tidy, result}
      end

    tidies ++ [{:all, :settings, push.(base, sweeps)}]
  end

  def send_collection(base, collection, %{"sweeps" => sweeps, "tidy" => tidy}) do
    backends =
      for sweep <- collection.sweeps,
          !sweep.mechanical,
          %{backend: backend} = choice <- [sweeps[sweep.name]],
          model = Map.get(choice, :model, sweep.pick_model),
          {backend, model} != {sweep.pick, sweep.pick_model} do
        # 相手を替えたら、前の相手のモデルは持ち越さない
        model = if backend != sweep.pick and model == sweep.pick_model, do: "", else: model

        {sweep.name, :backend,
         Chiezo.set_sweep_backend(base, collection.name, sweep.name, backend, model)}
      end

    tidies =
      for sweep <- collection.sweeps, tidy_sweep?(sweep), tidy != sweep.by_caller do
        {sweep.name, :tidy, CollectPace.stop_tidy(collection.name, tidy, base)}
      end

    backends ++ tidies
  end

  @doc false
  defp parse_op("redo", _sweep), do: {:ok, :redo}
  defp parse_op("requeue", _sweep), do: {:ok, :requeue}
  defp parse_op("repartition", _sweep), do: {:ok, :repartition}
  defp parse_op("stop", _sweep), do: {:ok, :stop}

  defp parse_op("restart", sweep) when is_binary(sweep) and sweep != "",
    do: {:ok, {:restart, sweep}}

  defp parse_op(_op, _sweep), do: :error

  def operate_text(:redo, :ok),
    do: "最後の 1 回を巻き戻して、もう一度走らせるよう頼みました（進み具合は「収集」の表で見られます）。"

  def operate_text({:restart, sweep}, :ok),
    do: "「#{sweep}」の一周をやり直します（区画の印を外しました。次の予定で先頭から回ります）。"

  def operate_text(:requeue, :ok),
    do: "全部を未確認に戻すよう頼みました（次に焼く回で効きます）。"

  def operate_text(:repartition, :ok),
    do: "区画の割り直しを始めました（AI は使いません。大きな収集では数分かかります）。"

  def operate_text(:stop, :ok), do: "走っている取り込みを止めるよう頼みました。"

  def operate_text(_op, {:error, {:chiezo_refused, _status, message}}) when is_binary(message),
    do: "Chiezo が断りました: #{message}"

  def operate_text(_op, {:error, _reason}), do: "頼めませんでした（Chiezo に届きませんでした）。"

  def worker_text("pause", :ok), do: "止めました（待ち行列は残ります。動かすと続きから流れます）。"
  def worker_text("resume", :ok), do: "動かしました。"
  def worker_text("wake", :ok), do: "起こしました（待っている先頭の 1 本を流します）。"

  def worker_text(_op, {:error, {:chiezo_refused, _status, message}}) when is_binary(message),
    do: "Chiezo が断りました: #{message}"

  def worker_text(_op, {:error, _reason}), do: "頼めませんでした（Chiezo に届きませんでした）。"

  def switch_text(true, :ok), do: "動かしました（Chiezo の時計で回り始めます）。"
  def switch_text(false, :ok), do: "止めました（時計では走りません。画面から押した 1 回は走ります）。"

  def switch_text(_on?, {:error, :not_allowed}),
    do: "動かせませんでした。Chiezo の管理画面の収集の面で「外部からの有効化を許可する」を押してください。"

  def switch_text(_on?, {:error, :not_ours}), do: "Chidori が依頼した収集ではないので、切り替えられません。"
  def switch_text(_on?, {:error, _reason}), do: "切り替えられませんでした（Chiezo に届きませんでした）。"

  @doc "収集ごとに送った結果の言い方。"
  def send_text([]), do: "変わったところはありませんでした。"

  def send_text(results) do
    case Enum.reject(results, fn {_sweep, _what, result} -> result == :ok end) do
      [] ->
        "送りました（" <> Enum.map_join(results, "・", &sent_what/1) <> "）。"

      failed ->
        "送れなかったもの: " <>
          Enum.map_join(failed, "・", fn {_s, _w, result} = one ->
            sent_what(one) <> failed_why(result)
          end)
    end
  end

  defp sent_what({_all, :settings, _result}), do: "依頼文と巡回の相手を含む設定"
  defp sent_what({sweep, :backend, _result}), do: "#{sweep}の相手"
  defp sent_what({sweep, :tidy, _result}), do: "#{sweep}を自動で回すか"

  defp failed_why({:error, reason}), do: "（" <> ChidoriWeb.Collect.reason_text(reason) <> "）"
  defp failed_why(_result), do: ""

  @doc "表の欄に出す選択（覚えているほうを先に見る）。"
  def picked_backend(picks, collection, sweep) do
    case get_in(picks, [collection, "sweeps", sweep.name]) do
      %{backend: backend} -> backend
      _ -> sweep.pick
    end
  end

  def picked_model(picks, collection, sweep) do
    case get_in(picks, [collection, "sweeps", sweep.name]) do
      %{model: model} -> model
      _ -> sweep.pick_model
    end
  end

  def picked_tidy(picks, collection, sweep) do
    case get_in(picks, [collection, "tidy"]) do
      nil -> sweep.by_caller
      tidy -> tidy
    end
  end

  @doc "整理の巡回か（自動で回すかを選ぶ口を出す）。"
  def tidy_sweep?(sweep), do: sweep.name == Chidori.SweepNames.tidy()

  @doc "Chiezo の設定から戻した結果の言い方。**変えたものだけ**並べる。"
  def restore_text({:ok, %{paces: [], stopped: [], resumed: [], min_pageviews: nil}}),
    do: "Chiezo の設定と同じでした（変えたものはありません）。"

  def restore_text({:ok, result}) do
    parts =
      Enum.map(result.paces, fn {kind, minutes} ->
        "#{CollectPace.sweep_name(kind)}を#{CollectPace.label(minutes)}ごとに"
      end) ++
        if(result.stopped == [],
          do: [],
          else: ["整理を自動で回さない: #{Enum.join(result.stopped, "・")}"]
        ) ++
        if(result.resumed == [],
          do: [],
          else: ["整理を自動で回す: #{Enum.join(result.resumed, "・")}"]
        ) ++
        if(result.min_pageviews,
          do: ["芸能人の図の知名度の下限を月 #{result.min_pageviews} 閲覧に"],
          else: []
        )

    "Chiezo の設定から戻しました（" <> Enum.join(parts, "、") <> "）。"
  end

  def restore_text({:error, _reason}), do: "Chiezo の収集の一覧を読めませんでした。"

  @doc "間隔を送った結果の言い方。"
  def pace_text({:ok, %{sent: sent, failed: []}}),
    do: "保存して、#{length(sent)} 本の巡回に送りました。"

  def pace_text({:ok, %{sent: sent, failed: failed}}) do
    names = Enum.map_join(failed, "、", fn {name, sweep, _reason} -> "#{name} / #{sweep}" end)
    "保存して、#{length(sent)} 本の巡回に送りました。送れなかったもの: #{names}"
  end

  def pace_text({:error, _reason}),
    do: "保存しました。Chiezo に送れませんでした（繋がらないかもしれません）。各画面の「収集の設定を更新」でも送れます。"

  @doc """
  日時を JST で短く（「9/28 09:53」。空なら —）。**表に何行も並ぶので年と「JST」は
  落とす**（見出しに JST と書く）—— 全部書くと欄が折り返して読めない。
  """
  def at(nil), do: "—"
  def at(""), do: "—"

  def at(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        jst = DateTime.add(dt, 9 * 3600, :second)

        "#{jst.month}/#{jst.day} " <>
          String.pad_leading("#{jst.hour}", 2, "0") <>
          ":" <> String.pad_leading("#{jst.minute}", 2, "0")

      _ ->
        value
    end
  end

  @doc "読めなかったときの一言。"
  def error_text({:error, :chiezo_not_configured}), do: "Chiezo の場所（CHIEZO_BASE_URL）が設定されていません。"
  def error_text({:error, :collect_disabled}), do: "Chiezo の収集が無効です。"
  def error_text(_error), do: "Chiezo から読めませんでした（繋がらないかもしれません）。"

  @doc "待ち行列を読めなかったときの一言。"
  def queue_error_text(_reason), do: "待ち行列を読めませんでした。"

  @doc "取得の結果の言い方（Chidori の列）。"
  def photo_result(:ok), do: "取れた"
  def photo_result(:missing), do: "無い"
  def photo_result(:retry), do: "Chiezo が取りに行けなかった（30 分休む）"
  def photo_result(other), do: to_string(other)

  @doc "写しの鍵の見せ方（表紙は ISBN、写真はファイル名）。"
  def photo_target("isbn:" <> isbn), do: "ISBN " <> isbn

  def photo_target(url) when is_binary(url),
    do: url |> String.split("/") |> List.last() |> URI.decode()

  @doc "Chiezo の依頼の控えの 1 行の絵の見せ方（ホストとファイル名）。"
  def chiezo_target(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) and is_binary(path) ->
        host <> " …/" <> (path |> String.split("/") |> List.last() |> URI.decode())

      _other ->
        url
    end
  end

  def chiezo_target(_url), do: ""

  @doc "Chiezo がいま休んでいる相手（`{相手, 期限}`。期限の過ぎたものは出さない）。"
  def resting_now(health, now \\ DateTime.utc_now()) do
    for {host, until} <- health["resting"] || %{},
        {:ok, at, _offset} <- [DateTime.from_iso8601(to_string(until))],
        DateTime.compare(at, now) == :gt,
        do: {host, until}
  end
end
