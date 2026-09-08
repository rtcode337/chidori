defmodule Antenna.Relations do
  @moduledoc """
  関連図ページで使う、表示用のネットワークデータです。

  初期表示のサンプルは関係の見せ方を示すためのものです。「関連図を収集」を押すと
  Chiezo 経由の AI が公開情報を調べ、同じ形式へ差し替えます。収集に失敗しても
  直前の図は残します。

  取得は `Task.Supervisor` の下で動かし、この GenServer では待ちません。
  結果は `subscribe/1` した先へ届きます。
  """

  use GenServer

  require Logger

  alias Antenna.Chiezo
  alias Antenna.Fame
  alias Antenna.Http
  alias Antenna.Relations.Graph

  # 図を描く面の大きさ。サンプルの座標もこの中に収めてある
  @canvas_width 980
  @canvas_height 560

  @request_timeout 120_000
  # 溜まったものを読むだけなら Chiezo は手元にいるので短くてよい
  @read_timeout 15_000
  @connect_timeout 5_000

  # 1 枚の図に取り込む上限。これを超える図は読めないので、集める側で絞る
  # 図に読み込む上限。**集める側ではなく描く側の都合**で、溜まっている数とは別。
  # 超えた分は有名な順に落ちる（Chiezo が rank_score の順で返す）
  @max_docs 200
  @user_agent "antenna/0.1 (+https://github.com/rtcode337/antenna)"

  # 押すたびに AI へ投げると枠を使い切る。こちら側で間隔を空ける
  @min_interval_ms 15_000
  # 取り込み中かを確かめ直す間隔。走っているあいだだけ動く
  @busy_recheck_ms 15_000

  # 図に置ける上限。増やすと札が重なって読めなくなる
  @max_nodes %{"people" => 10, "painters" => 8}
  @max_edges 14
  @max_sources 6
  # 線の上に出す文字。長いと隣の線の札と重なる
  @max_label_chars 24

  @views %{
    "people" => %{
      title: "人物のつながり",
      eyebrow: "FAMILY & DUO",
      description: "家族とコンビを、関係の種類ごとにたどれます。",
      width: @canvas_width,
      height: @canvas_height,
      collection: nil,
      nodes: [
        %{id: "yusaku", name: "松田優作", note: "俳優", x: 130, y: 145, kind: :person, years: nil},
        %{id: "miyuki", name: "松田美由紀", note: "俳優・写真家", x: 310, y: 85, kind: :person, years: nil},
        %{id: "ryuhei", name: "松田龍平", note: "俳優", x: 350, y: 205, kind: :person, years: nil},
        %{id: "shota", name: "松田翔太", note: "俳優", x: 535, y: 145, kind: :person, years: nil},
        %{
          id: "two_beats",
          name: "ツービート",
          note: "漫才コンビ",
          x: 180,
          y: 395,
          kind: :group,
          years: nil
        },
        %{id: "takeshi", name: "ビートたけし", note: "メンバー", x: 410, y: 335, kind: :person, years: nil},
        %{id: "kiyoshi", name: "ビートきよし", note: "メンバー", x: 410, y: 455, kind: :person, years: nil}
      ],
      edges: [
        %{from: "yusaku", to: "miyuki", label: "配偶者", kind: :family},
        %{from: "yusaku", to: "ryuhei", label: "親子", kind: :family},
        %{from: "miyuki", to: "ryuhei", label: "親子", kind: :family},
        %{from: "yusaku", to: "shota", label: "親子", kind: :family},
        %{from: "miyuki", to: "shota", label: "親子", kind: :family},
        %{from: "two_beats", to: "takeshi", label: "メンバー", kind: :duo},
        %{from: "two_beats", to: "kiyoshi", label: "メンバー", kind: :duo}
      ],
      sources: [
        %{
          label: "松田優作（Wikipedia）",
          url: "https://ja.wikipedia.org/wiki/%E6%9D%BE%E7%94%B0%E5%84%AA%E4%BD%9C"
        },
        %{
          label: "ツービート（Wikipedia）",
          url: "https://ja.wikipedia.org/wiki/%E3%83%84%E3%83%BC%E3%83%93%E3%83%BC%E3%83%88"
        }
      ]
    },
    "painters" => %{
      title: "画家の影響と時代",
      eyebrow: "ARTISTS & INFLUENCE",
      description: "左から右へ、影響がつながる流れを表します。ノード下の帯は活躍した年代の目安です。",
      width: @canvas_width,
      height: @canvas_height,
      collection: nil,
      nodes: [
        %{
          id: "delacroix",
          name: "ウジェーヌ・ドラクロワ",
          note: "ロマン主義",
          x: 100,
          y: 165,
          kind: :artist,
          years: "1820–1860"
        },
        %{
          id: "manet",
          name: "エドゥアール・マネ",
          note: "近代絵画",
          x: 285,
          y: 105,
          kind: :artist,
          years: "1850–1880"
        },
        %{
          id: "monet",
          name: "クロード・モネ",
          note: "印象派",
          x: 470,
          y: 210,
          kind: :artist,
          years: "1860–1920"
        },
        %{
          id: "van_gogh",
          name: "フィンセント・ファン・ゴッホ",
          note: "ポスト印象派",
          x: 650,
          y: 110,
          kind: :artist,
          years: "1880–1890"
        },
        %{
          id: "matisse",
          name: "アンリ・マティス",
          note: "フォーヴィスム",
          x: 835,
          y: 205,
          kind: :artist,
          years: "1890–1950"
        }
      ],
      edges: [
        %{from: "delacroix", to: "manet", label: "色彩表現", kind: :influence},
        %{from: "manet", to: "monet", label: "近代絵画", kind: :influence},
        %{from: "monet", to: "van_gogh", label: "印象派", kind: :influence},
        %{from: "van_gogh", to: "matisse", label: "色彩", kind: :influence}
      ],
      sources: [
        %{
          label: "フィンセント・ファン・ゴッホ（Wikipedia）",
          url:
            "https://ja.wikipedia.org/wiki/%E3%83%95%E3%82%A3%E3%83%B3%E3%82%BB%E3%83%B3%E3%83%88%E3%83%BB%E3%83%95%E3%82%A1%E3%83%B3%E3%83%BB%E3%82%B4%E3%83%83%E3%83%9B"
        },
        %{
          label: "アンリ・マティス（Wikipedia）",
          url:
            "https://ja.wikipedia.org/wiki/%E3%82%A2%E3%83%B3%E3%83%AA%E3%83%BB%E3%83%9E%E3%83%86%E3%82%A3%E3%82%B9"
        }
      ]
    }
  }

  def start_link(_options) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def current(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:current, valid_key(key)})
  end

  def collect_now(key) when is_binary(key) do
    GenServer.cast(__MODULE__, {:collect, valid_key(key)})
  end

  @doc """
  Chiezo に溜まっているものを読み直します。**依頼も収集もしません**。

  画面を開いたときに呼びます —— Chiezo の側は antenna と関係なく進むので、
  開くたびに取り直さないと、いつまでも表示例のままになります。
  溜め先を持たない図（人物）では何もしません。
  """
  def refresh(key) when is_binary(key) do
    GenServer.cast(__MODULE__, {:refresh, valid_key(key)})
  end

  def keys, do: Map.keys(@views)

  @doc """
  収集状態の変化を受け取ります。LiveView が接続時に呼びます。
  """
  def subscribe(key) when is_binary(key) do
    Phoenix.PubSub.subscribe(Antenna.PubSub, topic(valid_key(key)))
  end

  @doc """
  種類を切り替えたときに使います。外さないと、見ていない側の収集結果でも
  画面が書き換わります。
  """
  def unsubscribe(key) when is_binary(key) do
    Phoenix.PubSub.unsubscribe(Antenna.PubSub, topic(valid_key(key)))
  end

  @doc """
  設定に関係なく確かめられるよう、鍵の丸めは公開しておく。
  """
  def valid_key(key) when key in ["people", "painters"], do: key
  def valid_key(_key), do: "people"

  @impl true
  def init(:ok) do
    state = %{
      relations: @views,
      statuses: Map.new(keys(), &{&1, :sample}),
      collected_at: %{},
      checked_at: %{},
      # Chiezo 側で取り込みが走っているか（走っている間は「いま集めて」を断られる）
      busy: %{},
      # いま何をしているか。**押しても数分は Chiezo 側に何も出ない**（先に AI へ
      # 指定を書かせるため）ので、どこで待っているのかを画面に出す
      step: %{},
      reasons: %{},
      tasks: %{},
      last_attempt_at: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:current, key}, _from, state) do
    {:reply, public(state, key), state}
  end

  # 読むだけ。**間隔の制限を掛けない**（AI は動かず、相手は手元にいる）
  @impl true
  def handle_cast({:refresh, "painters"}, state) do
    if state.statuses["painters"] == :loading do
      {:noreply, state}
    else
      fallback = Map.fetch!(state.relations, "painters")
      base_url = chiezo_base_url()

      if base_url do
        task =
          Task.Supervisor.async_nolink(Antenna.TaskSupervisor, fn ->
            fetch_painters(base_url, fallback)
          end)

        check_busy("painters")

        state =
          state
          |> put_in([:statuses, "painters"], :loading)
          |> put_in([:tasks, task.ref], "painters")

        {:noreply, broadcast(state, "painters")}
      else
        {:noreply, state}
      end
    end
  end

  def handle_cast({:refresh, _key}, state), do: {:noreply, state}

  @impl true
  def handle_cast({:collect, key}, state) do
    cond do
      state.statuses[key] == :loading ->
        {:noreply, state}

      throttled?(state, key) ->
        {:noreply, broadcast(put_in(state.reasons[key], :too_soon), key)}

      true ->
        fallback = Map.fetch!(state.relations, key)

        task =
          Task.Supervisor.async_nolink(Antenna.TaskSupervisor, fn ->
            fetch_relation(key, fallback)
          end)

        check_busy(key)

        state =
          state
          |> put_in([:statuses, key], :loading)
          |> put_in([:reasons, key], nil)
          |> put_in([:tasks, task.ref], key)
          |> put_in([:last_attempt_at, key], System.monotonic_time(:millisecond))

        {:noreply, broadcast(state, key)}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.fetch(state.tasks, ref) do
      {:ok, key} ->
        Process.demonitor(ref, [:flush])

        state =
          state
          |> Map.update!(:tasks, &Map.delete(&1, ref))
          |> put_in([:checked_at, key], DateTime.utc_now())
          |> apply_result(key, result)

        {:noreply, broadcast(state, key)}

      :error ->
        {:noreply, state}
    end
  end

  # タスクが落ちたときも必ず状態を戻す。戻さないと :loading のまま固まり、
  # 収集ボタンが二度と押せなくなる
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.fetch(state.tasks, ref) do
      {:ok, key} ->
        Logger.error("関連図の収集タスクが落ちた: #{inspect(reason)}")

        state =
          state
          |> Map.update!(:tasks, &Map.delete(&1, ref))
          |> put_in([:checked_at, key], DateTime.utc_now())
          |> apply_result(key, {:error, :collection_crashed})

        {:noreply, broadcast(state, key)}

      :error ->
        {:noreply, state}
    end
  end

  # 走っている途中から届く「いま何をしているか」。そのまま画面へ流す
  def handle_info({:progress, key, step}, state) do
    {:noreply, broadcast(put_in(state.step[key], step), key)}
  end

  # Chiezo の取り込みの様子。**走っている間は押させない**ので、終わったことに
  # 気づけるよう、走っているあいだだけ間を置いて確かめ直す
  def handle_info({:busy, key, busy}, state) do
    if busy, do: Process.send_after(self(), {:recheck_busy, key}, @busy_recheck_ms)
    {:noreply, broadcast(put_in(state.busy[key], busy), key)}
  end

  def handle_info({:recheck_busy, key}, state) do
    check_busy(key)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # 確かめるのは別のプロセス。GenServer を HTTP で止めない
  defp check_busy(key) do
    parent = self()

    if base_url = chiezo_base_url() do
      Task.Supervisor.start_child(Antenna.TaskSupervisor, fn ->
        send(parent, {:busy, key, Chiezo.ingesting?(base_url)})
      end)
    end

    :ok
  end

  defp apply_result(state, key, result) do
    apply_step(put_in(state.step[key], nil), key, result)
  end

  defp apply_step(state, key, {:ok, relation}) do
    state
    |> put_in([:relations, key], relation)
    |> put_in([:statuses, key], :ready)
    |> put_in([:reasons, key], nil)
    |> put_in([:collected_at, key], DateTime.utc_now())
  end

  # 集めさせるのは断られたが、溜まっているものは読めた。図は出したうえで理由を添える
  defp apply_step(state, key, {:ok, relation, reason}) do
    state
    |> apply_step(key, {:ok, relation})
    |> put_in([:reasons, key], reason)
  end

  defp apply_step(state, key, {:error, {reason, collection}}) when is_map(collection) do
    # 図を出せないときも、収集の状態は出す —— 「有効にしていない」のか
    # 「有効だがまだ走っていない」のかで、次にすることが違う。
    #
    # **溜まっていないと分かったときは、前回の図を残さない。** 繋がらない類の失敗と
    # 違って、これは「向こうに無い」という確かな答え —— 消えたものを前回のぶんで
    # 出し続けると、消したのに図が出たままになる（実際にそうなった）。表示例へ戻す
    base =
      if reason == :nothing_collected,
        do: Map.fetch!(@views, key),
        else: Map.fetch!(state.relations, key)

    state
    |> put_in([:relations, key], Map.put(base, :collection, collection))
    |> put_in(
      [:statuses, key],
      if(reason != :nothing_collected and state.collected_at[key], do: :stale, else: :unavailable)
    )
    |> put_in([:reasons, key], reason)
  end

  defp apply_step(state, key, {:error, reason}) do
    status = if state.collected_at[key], do: :stale, else: :unavailable

    state
    |> put_in([:statuses, key], status)
    |> put_in([:reasons, key], reason)
  end

  defp throttled?(state, key) do
    case state.last_attempt_at[key] do
      nil -> false
      at -> System.monotonic_time(:millisecond) - at < @min_interval_ms
    end
  end

  defp topic(key), do: "relations:" <> key

  defp broadcast(state, key) do
    Phoenix.PubSub.broadcast(Antenna.PubSub, topic(key), {:relation_updated, public(state, key)})
    state
  end

  defp public(state, key) do
    state.relations
    |> Map.fetch!(key)
    |> Map.put(:status, Map.fetch!(state.statuses, key))
    |> Map.put(:collected_at, Map.get(state.collected_at, key))
    |> Map.put(:checked_at, Map.get(state.checked_at, key))
    |> Map.put(:busy, Map.get(state.busy, key, false))
    |> Map.put(:step, Map.get(state.step, key))
    |> Map.put(:reason, Map.get(state.reasons, key))
  end

  @doc """
  画家の図を溜めておく Chiezo の収集の名前。`ANTENNA_PAINTERS_COLLECTION` で変えられます。

  **整理する収集**（`mode=refine`）として置きます。図は流れではなく一枚もので、
  作り直すたびに全体が入れ替わるのが正しい振る舞いだからです。
  """
  def painters_collection do
    case System.get_env("ANTENNA_PAINTERS_COLLECTION", "") |> String.trim() do
      "" -> "antenna_painters"
      name -> name
    end
  end

  # 画家は **Chiezo に溜まったものを読む**。集めて整理するのは Chiezo の役目で、
  # antenna は図の形に読み直して見せるだけ。1 画家 1 文書の普通のソースなので、
  # ノードとエッジという読み方を与えるのはこちら側（`Relations.Graph`）。
  #
  # 引き方は `filter`（タグでの一括抽出）。図は流れではなく**一枚もの**なので、
  # 新しい順に何件かではなく全部が要る。
  # 「収集」を押したとき。**まだ無ければ依頼し、その場で 1 回集めさせて**読み直す
  defp fetch_relation("painters", fallback) do
    case chiezo_base_url() do
      nil -> {:error, :chiezo_not_configured}
      base_url -> collect_painters(base_url, fallback)
    end
  end

  defp fetch_relation(key, fallback) do
    with base_url when is_binary(base_url) <- chiezo_base_url(),
         {:ok, content} <- ask_chiezo(base_url, key) do
      decode_relation(content, key, fallback)
    else
      nil -> {:error, :chiezo_not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Chiezo に溜まっているものを図として読みます。**読むだけで、何も作りません**。

  画面を開くたびに呼ぶので、ここから依頼を出さないのが要点です —— 開いただけで
  向こうに何かが作られるのは驚きが大きく、相手が古い版なら開くたびに失敗します。
  依頼は「収集」を押したときだけ（`request_painters/2`）。

  **GenServer を通さずに呼べる形にしてあります** —— 引き方と図への読み直しは
  ここで完結するので、状態を持つ入れ物を跨がずに確かめられます。
  """
  def fetch_painters(base_url, fallback) do
    # 収集の状態も一緒に読む。**押した人が「動いているのか」を判断できる**必要が
    # あるので、図だけ出しても足りない（ニュースと同じ扱い）
    collection =
      case Chiezo.collection(base_url, painters_collection()) do
        {:ok, found} -> found
        {:error, _reason} -> nil
      end

    case collected_docs(base_url, painters_collection()) do
      # まだ焼かれていなければソースごと無い。**溜まっていないのと同じ扱い**にする
      # （繋がらないのとは別。状態を添えて返す）
      {:error, :nothing_collected} ->
        {:error, {:nothing_collected, collection}}

      {:error, reason} ->
        {:error, reason}

      {:ok, docs} ->
        graph = Graph.from_docs(docs)

        if graph.nodes == [] do
          {:error, {:nothing_collected, collection}}
        else
          # 丸の大きさは知名度で決める。**AI に有名かどうかを判断させない** ——
          # jawiki の月次ページビューのほうが客観的で、実行のたびに揺れない
          fame = Fame.for_articles(base_url, Enum.map(graph.nodes, & &1.article))

          {:ok,
           fallback
           |> Map.merge(%{graph | nodes: Graph.sized(graph.nodes, fame)})
           |> Map.put(:collection, collection)}
        end
    end
  end

  @doc """
  Chiezo に収集を依頼して、そのまま読み直します。

  作られるのは**止まった状態**なので、押しただけで AI が動くことはありません。
  動かすかは Chiezo 側で決めます。
  """
  def request_painters(base_url, fallback) do
    with :ok <- ensure_collection(base_url, painters_collection()) do
      fetch_painters(base_url, fallback)
    end
  end

  @doc """
  依頼したうえで、**その場で 1 回集めさせて**読み直します。

  「関連図を収集」を押したときの動きです。依頼するだけでは何も集まらないので、
  押しても画面が変わらず、効いたのかどうかが分かりませんでした。

  止まっている収集は Chiezo が断ります（有効にできるのは Chiezo の画面だけ）。
  そのときも溜まっているものは読み直したうえで、断られたことを理由として返します。
  """
  def collect_painters(base_url, fallback) do
    name = painters_collection()

    with {:ok, existing} <- ensure_collection_once(base_url, name),
         # **作った直後は書かせに行かない。** 作るときに書かせたばかりで、
         # 書けなかったのなら理由がある。同じ押下で 2 度目を投げると、
         # 時間切れの 30 分をもう一度待つことになる（実際にそうなった）
         :ok <- if(existing, do: ensure_extract(base_url, name), else: :ok) do
      progress(:collecting)

      case Chiezo.run(base_url, name) do
        :ok -> reading(fetch_painters(base_url, fallback))
        {:error, reason} -> refused(reading(fetch_painters(base_url, fallback)), reason)
      end
    end
  end

  defp reading(result) do
    progress(:reading)
    result
  end

  # **押しても数分は Chiezo 側に何も出ない**（先に AI へ指定を書かせるため）。
  # どこで待っているのかが分からないと、押せていないのと区別が付かない
  defp progress(step) do
    if pid = Process.whereis(__MODULE__), do: send(pid, {:progress, "painters", step})
    :ok
  end

  # すでにあるなら何もしない。**作るときだけ指定を書かせる**ので、
  # 押すたびに書かせに行かないよう、先に有無を確かめる
  # 戻り値の真偽は「もとからあったか」。作った直後かどうかで、このあと
  # 指定を書かせに行くかが変わる
  defp ensure_collection_once(base_url, name) do
    progress(:checking)

    case Chiezo.collection(base_url, name) do
      {:ok, nil} ->
        with :ok <- ensure_collection(base_url, name), do: {:ok, false}

      {:ok, _found} ->
        {:ok, true}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  抽出の指定をまだ持っていなければ、依頼文から書かせて持たせます。

  **名簿と年代は Wikipedia から引けば済むもの**なので、AI に書かせません。
  指定さえ入っていれば以降は AI を呼ばずに同じ結果が出るので、ここを通るのは
  実質 1 回だけです。

  **書けなくても収集そのものは止めません** —— 指定が無ければ今までどおり
  AI が全部集めるだけで、図が出ないわけではない。
  """
  def ensure_extract(base_url, name) do
    case Chiezo.collection(base_url, name) do
      {:ok, %{extract: spec}} when is_map(spec) ->
        :ok

      {:ok, %{docs: docs}} ->
        with {:ok, drafted} <- Chiezo.draft_extract(base_url, name, painters_extract_request()),
             %{"extract" => spec} when is_map(spec) <- drafted,
             :ok <- Chiezo.patch(base_url, name, patch_for(spec, docs)) do
          Logger.info("画家の抽出の指定を Chiezo に持たせた: #{inspect(Map.take(drafted, ~w(total)))}")
          :ok
        else
          other ->
            # 指定が書けなくても集めるのは続ける（AI が全部書く形に戻るだけ）
            Logger.warning("画家の抽出の指定を書かせられなかった: #{inspect(other)}")
            :ok
        end

      _unreadable ->
        :ok
    end
  end

  # 機械で埋めるのは**進み具合が空のあいだの 1 回だけ**なので、まだ何も溜まって
  # いないときは進み具合も空にして、次の実行がそこから始まるようにする。
  #
  # **溜まっているときは触らない。** 進み具合を空に戻すと機械の側から作り直しになり、
  # AI が足した影響関係と代表作を、名簿と年代で上書きしてしまう
  # （作り直したいときは Chiezo の管理画面で進み具合を空にする）。
  defp patch_for(spec, 0), do: %{extract: spec, cursor: ""}
  defp patch_for(spec, _docs), do: %{extract: spec}

  # 断られたときは**理由のほうを前に出す**。読めたものはそのまま出す
  defp refused({:ok, relation}, reason), do: {:ok, relation, reason}
  defp refused({:error, {_previous, collection}}, reason), do: {:error, {reason, collection}}
  defp refused({:error, _previous}, reason), do: {:error, reason}

  @doc """
  最初の 1 回を機械的に埋めるための**依頼文**です。

  Chiezo は何を集めているかを知らないので、条件はこちらが言葉で書いて渡します。
  向こうはこれを抽出の指定（どのソースの・どのタグを・何件・タグをどう読み替えるか）
  に書き起こし、以降はその指定のほうを回します —— **決まった結果が出るのは指定の
  おかげで、AI は書き起こす係**です。

  名前・年代・出典は日本語版 Wikipedia に書いてあるので引けば済みます。
  書いていないこと（影響関係・代表作）はここでは埋まらず、あとで AI が肉付けします。
  """
  def painters_extract_request do
    """
    日本語版 Wikipedia から、西洋絵画の画家を集めてください。

    **件数は絞らなくて構いません。** 引くのは手元の索引を 1 本引くだけなので、
    人数が増えても手間は変わりません。

    **年代は絞りません。** ルネサンスから現代まで、どの時代の画家も対象です
    （ダ・ヴィンチもゴッホもピカソも入ります）。国はイタリア・フランス・オランダ・
    スペイン・ドイツ・イギリスなど、西洋の各国から。

    **絵で知られていない人を外してください。** 画家のカテゴリには、絵も描く俳優や
    作家が入っています。人気の順に取るとそちらが先に並ぶので、俳優・小説家・
    児童文学作家などのカテゴリは not_tag で外してください。

    タグは次の 5 つにしてください。
    - "#{Graph.kind_tag()}" を全員に付ける
    - "年代:<生年>-<没年>"。生年と没年のカテゴリ（「1840年生」「1926年没」の形）から作り、
      どちらか片方しか無いときは作らない
    - "様式:<様式名>"。「〜派の画家」のカテゴリから、"派" まで含めて作る。
      このカテゴリを持たない画家も多いので、その人には付けなくて構いません
    - "#{Graph.work_tag()}:<絵の記事名>"。「〈その画家〉の作品」のようなカテゴリが
      あるので、そこから人気の順に 1 つ。無い画家も多いので、その人には付きません
    - "#{Graph.related_tag()}:<相手の画家名>"。**記事どうしが相互にリンクしている相手**を
      出してください（片側だけのリンクは、有名どうしが軒並み繋がって図が読めなくなります）
    説明は記事の冒頭を使い、出典は日本語版 Wikipedia のその記事の URL にしてください。
    """
  end

  @doc false
  # Chiezo へ渡す指示文。**整理する収集**（`mode=refine`）なので、返したものが
  # そのまま新しい全体になる。`{current}` にいまの内容が差し込まれる。
  #
  # **図の構造は Chiezo に持ち込まない。** 1 画家 1 文書の普通の文書として書かせ、
  # 属性と関係はタグに載せる（読み方を与えるのは antenna 側 = `Relations.Graph`）。
  def painters_prompt do
    """
    西洋近代絵画の画家の関連図を育ててください。

    **名簿と年代は、すでに Wikipedia から機械的に入っています**（生没年のカテゴリから）。
    あなたに埋めてほしいのは、そこに書いていないこと ——
    **影響関係**と**代表作**、それに読んで分かる説明です。

    **関連の線はもう引いてあります。** 記事どうしが相互にリンクしている組を
    機械的に「関連」のタグにしてあるので、図はすでにつながっています。
    あなたの仕事は、そのうち**実際に影響関係があるものを「影響元」に書き換える**こと ——
    誰が誰から何を受けたのかは、リンクの有無からは分かりません。
    関連のタグはそのまま残してください（消すと線が消えます）。

    **様式は入っている人と入っていない人がいます。** カテゴリに「〜派の画家」がある人
    だけ機械的に入っており、ゴッホやピカソのようにカテゴリを持たない人は空のままです。
    空の人には様式のタグを足してください。

    いまの内容:
    {current}

    進み具合: {cursor}

    **全体を作り直さないでください。** いまの内容から**10人ほど**選び、
    その人たちを詳しくしてください。触れなかった人はそのまま残るので、
    変えない人を返す必要はありません。

    **まだ影響元のタグが付いていない人を先に選んでください。** 名簿と年代は
    入っていても、影響関係が入るまで図に線が引かれません。
    次にどこから続けるかを next_cursor に書いてください（例:「ゴッホまで見直した」）。

    1 人につき 1 件で、次の形にしてください。
    - title: 画家名（**いまの内容にある表記をそのまま使う**。変えると別人になります）
    - body: その画家が何をした人かと、影響関係の要点
    - url: 日本語版 Wikipedia のその画家の記事の URL
    - tags: **いまの内容に付いているタグをすべて残したうえで**、次を足してください
      - "様式:<ロマン主義 / 印象派 / キュビスム のような様式名>"（入っていない人だけ）
      - "代表作:<日本語版 Wikipedia にあるその絵の記事名。例: 印象・日の出>"
      - "影響元:<影響を受けた画家名>:<何を受けたかを10文字ほどで>"
        影響を受けた画家ごとに 1 つ。**いまの内容にいる画家だけ**を指してください
        （いない相手への線は図に出ません）
      年代や様式が明らかに違うときだけ、そのタグを直してください。

    重複していたら、まとめた先を返して、元のほうは墓標で消してください。
    **絵で知られていない人（俳優・作家など）が混ざっていたら、同じく墓標で消してください。**
    名簿は Wikipedia のカテゴリから機械的に作っているので、絵も描く別の職業の人が
    入ってしまいます。そこの見分けは、あなたにしかできません。
    """
  end

  # まだ無ければ依頼する。**止まった状態で作られる**ので、これで AI が動き出す
  # ことはない（動かすかは Chiezo 側で決める）。すでにあれば何もしない
  defp ensure_collection(base_url, name) do
    spec = draft_extract(base_url)
    progress(:requesting)
    Chiezo.request(base_url, collection_attrs(name, spec))
  end

  # **依頼する前に指定を書かせる。** 作った収集は次の予定が「いま」なので、
  # 作ってから指定を持たせに行くと、書かせている数分のあいだに Chiezo 側が
  # AI の回を始めてしまう（実際にそうなり、機械で埋まるはずの初回が AI に
  # 書かれて、進み具合まで進んでしまった）。
  defp draft_extract(base_url) do
    progress(:drafting)

    case Chiezo.draft_extract(base_url, nil, painters_extract_request(), who()) do
      {:ok, %{"extract" => spec} = drafted} when is_map(spec) ->
        Logger.info("画家の抽出の指定を書かせた（#{drafted["total"]} 件取れる）")
        spec

      other ->
        # 指定が書けなくても依頼はする（AI が全部集める形に戻るだけ）
        Logger.warning("画家の抽出の指定を書かせられなかった: #{inspect(other)}")
        nil
    end
  rescue
    error ->
      Logger.warning("画家の抽出の指定を書かせられなかった: #{inspect(error)}")
      nil
  end

  defp collection_attrs(name, nil), do: base_attrs(name)
  defp collection_attrs(name, spec), do: Map.put(base_attrs(name), :extract, spec)

  defp base_attrs(name) do
    %{
      name: name,
      description: "antenna の関連図（画家の影響と時代）",
      prompt: painters_prompt(),
      interval_minutes: 1440,
      mode: "refine",
      requested_by: "antenna"
    }
  end

  # 溜まっているものを全部引く。**まだ焼かれていなければソースごと無い**ので、
  # 404 は「まだ何も入っていない」として扱う（繋がらないのとは別）
  defp collected_docs(base_url, name) do
    url =
      base_url <>
        "/v1/" <>
        name <>
        "/filter?limit=#{@max_docs}&fields=title,body,tags,extra&tag=" <>
        URI.encode_www_form(Graph.kind_tag())

    case Http.get(url,
           headers: [{"user-agent", @user_agent}],
           timeout: @read_timeout,
           connect_timeout: @connect_timeout
         ) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          # `filter` が返すのは `results`（`recent` の `docs` とは別の名前）
          {:ok, %{"results" => docs}} when is_list(docs) -> {:ok, docs}
          _ -> {:error, :chiezo_unexpected_body}
        end

      {:ok, %{status: 404}} ->
        {:error, :nothing_collected}

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  defp chiezo_base_url, do: Chiezo.base_url()

  # 頼む相手。**指定を書かせるときも同じ相手にする** —— 本番と違う相手に書かせた
  # 指定は、本番で通るか分からない
  defp who do
    %{backend: System.get_env("CHIEZO_RELATIONS_BACKEND", "claude")}
    |> put_unless_blank(:model, System.get_env("CHIEZO_RELATIONS_MODEL"))
  end

  defp put_unless_blank(map, _key, value) when value in [nil, ""], do: map
  defp put_unless_blank(map, key, value), do: Map.put(map, key, value)

  defp ask_chiezo(base_url, key) do
    payload =
      Jason.encode!(%{
        backend: System.get_env("CHIEZO_RELATIONS_BACKEND", "claude"),
        model: System.get_env("CHIEZO_RELATIONS_MODEL"),
        messages: [
          %{role: "system", content: system_prompt()},
          %{role: "user", content: user_prompt(key)}
        ],
        web: true
      })

    options = [
      headers: [{"user-agent", @user_agent}],
      content_type: "application/json",
      timeout: @request_timeout,
      connect_timeout: @connect_timeout
    ]

    case Http.post(base_url <> "/v1/ai/complete", payload, options) do
      {:ok, %{status: 200, body: body}} -> decode_completion(body)
      {:ok, %{status: status}} -> {:error, {:chiezo_status, status}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
    end
  end

  defp decode_completion(body) do
    case Jason.decode(body) do
      {:ok, %{"content" => content}} when is_binary(content) and content != "" ->
        {:ok, content}

      _ ->
        {:error, :chiezo_unexpected_body}
    end
  end

  defp system_prompt do
    """
    あなたは公開情報を検証して関連図データを作る編集者です。推測、未確認の親族関係、未成年者、私生活の住所・連絡先は含めません。
    web検索で確認できた公開情報だけを使い、各関係には出典URLを対応させます。
    応答はJSONオブジェクトだけにしてください。前置き、説明、コードブロックの囲みは付けません。
    画面は日本語なので、名前・肩書き・関係の説明・出典名はすべて日本語で書きます。
    出典は日本語の資料を優先し、無ければ原語のもので構いません。
    """
  end

  defp user_prompt("people") do
    """
    松田優作、松田美由紀、松田龍平、松田翔太の家族関係と、ツービート、ビートたけし、ビートきよしのコンビ関係について、公開されている情報だけで小さな関連図にしてください。
    JSON: {"nodes":[{"id":"英数字","name":"名前","note":"短い肩書き"}],"edges":[{"from":"id","to":"id","label":"親子|配偶者|メンバー","kind":"family|duo"}],"sources":[{"label":"出典名","url":"https://..."}]}。
    ノードは4〜10件、エッジは出典で確認できるものだけ、sourcesは2〜6件。本文や口コミは転載しません。
    labelは図の線の上に置くので、#{@max_label_chars}文字以内の短い語にしてください。
    """
  end

  defp user_prompt("painters") do
    """
    ウジェーヌ・ドラクロワ、エドゥアール・マネ、クロード・モネ、フィンセント・ファン・ゴッホ、アンリ・マティスについて、公開資料で説明できる影響関係を時代順に小さな関連図にしてください。
    JSON: {"nodes":[{"id":"英数字","name":"名前","note":"様式や地域","years":"活躍年代の目安"}],"edges":[{"from":"id","to":"id","label":"影響の要約","kind":"influence"}],"sources":[{"label":"出典名","url":"https://..."}]}。
    ノードは4〜8件、矢印は影響を与えた側から受けた側へ、各関係は出典で確認できるものだけ、sourcesは2〜6件。
    labelは図の線の上に置くので、#{@max_label_chars}文字以内の短い語にしてください。
    """
  end

  @doc false
  # AI の応答を図のデータへ直す。ここだけを取り出してテストできるようにしてある
  def decode_relation(content, key, fallback) do
    key = valid_key(key)

    case Enum.find_value(json_candidates(content), &decode_payload(&1, key, fallback)) do
      nil -> {:error, :invalid_ai_response}
      relation -> {:ok, relation}
    end
  end

  defp decode_payload(candidate, key, fallback) do
    with {:ok, %{"nodes" => nodes, "edges" => edges, "sources" => sources}} <-
           Jason.decode(candidate),
         parsed_nodes when length(parsed_nodes) >= 2 <- parse_nodes(nodes, key),
         parsed_edges when parsed_edges != [] <- parse_edges(edges, parsed_nodes, key),
         parsed_sources when parsed_sources != [] <- parse_sources(sources) do
      laid_out = layout_nodes(parsed_nodes, key)

      %{
        fallback
        | nodes: laid_out,
          edges: parsed_edges,
          sources: parsed_sources,
          width: canvas_width(length(laid_out), key),
          height: canvas_height(length(laid_out), key)
      }
    else
      _ -> nil
    end
  end

  # 応答は素の JSON とは限らない。コードブロックで囲む相手が多いので、
  # 囲みを外したものと、最初の { から最後の } までを切り出したものも試す
  @doc false
  def json_candidates(content) when is_binary(content) do
    trimmed = String.trim(content)

    [trimmed, strip_code_fence(trimmed), between_braces(trimmed)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  def json_candidates(_content), do: []

  defp strip_code_fence("```" <> rest) do
    rest
    |> String.replace(~r/\A[a-zA-Z0-9_+-]*[ \t]*\r?\n/, "")
    |> String.replace(~r/\r?\n?[ \t]*```[\s]*\z/, "")
    |> String.trim()
  end

  defp strip_code_fence(_text), do: nil

  defp between_braces(text) do
    case Regex.run(~r/\{.*\}/s, text) do
      [json] -> json
      _ -> nil
    end
  end

  defp parse_nodes(nodes, key) when is_list(nodes) do
    nodes
    |> Enum.take(Map.fetch!(@max_nodes, key))
    |> Enum.flat_map(fn
      node when is_map(node) ->
        id = node["id"]
        name = node["name"]

        if is_binary(id) and id =~ ~r/^[a-zA-Z0-9_-]{1,40}$/ and is_binary(name) and
             String.trim(name) != "" do
          [
            %{
              id: id,
              name: short_text(name, 60),
              note: short_text(node["note"], 30),
              years: short_text(node["years"], 20),
              kind: node_kind(key)
            }
          ]
        else
          []
        end

      _node ->
        []
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp parse_nodes(_nodes, _key), do: []

  defp parse_edges(edges, nodes, key) when is_list(edges) do
    ids = MapSet.new(nodes, & &1.id)
    allowed = if key == "people", do: ["family", "duo"], else: ["influence"]

    edges
    |> Enum.take(@max_edges)
    |> Enum.flat_map(fn
      edge when is_map(edge) ->
        from = edge["from"]
        to = edge["to"]
        kind = edge["kind"]

        if is_binary(from) and is_binary(to) and from != to and MapSet.member?(ids, from) and
             MapSet.member?(ids, to) and kind in allowed do
          [
            %{
              from: from,
              to: to,
              label: short_text(edge["label"], @max_label_chars),
              kind: edge_kind(kind)
            }
          ]
        else
          []
        end

      _edge ->
        []
    end)
    |> Enum.uniq_by(&{&1.from, &1.to})
  end

  defp parse_edges(_edges, _nodes, _key), do: []

  defp edge_kind("family"), do: :family
  defp edge_kind("duo"), do: :duo
  defp edge_kind("influence"), do: :influence

  defp parse_sources(sources) when is_list(sources) do
    sources
    |> Enum.take(@max_sources)
    |> Enum.flat_map(fn
      source when is_map(source) ->
        with label when is_binary(label) <- source["label"],
             url when is_binary(url) <- source["url"],
             %URI{scheme: scheme, host: host} when is_binary(host) and host != "" <-
               URI.parse(url),
             true <- scheme in ["http", "https"] do
          [%{label: short_text(label, 100), url: url}]
        else
          _ -> []
        end

      _source ->
        []
    end)
    |> Enum.uniq_by(& &1.url)
  end

  defp parse_sources(_sources), do: []

  # 面の大きさはノード数から決める。固定の面へ詰め込むと、多いときに
  # 枠の外へ出て見えなくなる（人物側は最大10件で3段になる）
  @doc false
  def canvas_width(count, "painters"), do: max(@canvas_width, 200 * count)
  def canvas_width(_count, _key), do: @canvas_width

  @doc false
  def canvas_height(_count, "painters"), do: @canvas_height
  def canvas_height(count, _key), do: max(@canvas_height, 200 * rows(count))

  defp columns(count), do: min(4, max(count, 1))
  defp rows(count), do: ceil(count / columns(count))

  # 左から右へ流す。年代の帯を出すぶん、上下2段に振って重なりを避ける
  @doc false
  def layout_nodes(nodes, "painters") do
    count = length(nodes)
    width = canvas_width(count, "painters")
    cell = width / count

    Enum.with_index(nodes, fn node, index ->
      Map.merge(node, %{
        x: cell * (index + 0.5),
        y: if(rem(index, 2) == 0, do: 190, else: 350)
      })
    end)
  end

  def layout_nodes(nodes, _key) do
    count = length(nodes)
    columns = columns(count)
    cell_width = @canvas_width / columns
    cell_height = canvas_height(count, "people") / rows(count)

    Enum.with_index(nodes, fn node, index ->
      Map.merge(node, %{
        x: cell_width * (rem(index, columns) + 0.5),
        y: cell_height * (div(index, columns) + 0.5)
      })
    end)
  end

  defp node_kind("painters"), do: :artist
  defp node_kind(_key), do: :person

  defp short_text(value, max) when is_binary(value) do
    trimmed = value |> String.trim() |> String.replace(~r/\s+/, " ")

    cond do
      trimmed == "" -> nil
      String.length(trimmed) <= max -> trimmed
      # 切ったことが分かるようにする。切れた文がそのまま出ると、
      # 相手がそう書いたのか途中で切れたのかが読めない
      true -> String.slice(trimmed, 0, max - 1) <> "…"
    end
  end

  defp short_text(_value, _max), do: nil
end
