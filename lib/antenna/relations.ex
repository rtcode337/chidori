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

  # 1 回に取れる件数。**Chiezo の filter の上限**で、これを超えると 422 になる。
  # 溜まっているぶんは全部読むので、足りない分は offset で継ぐ
  @page_size 500

  # 頁を継ぐ回数の上限。**際限なく回らないための止め木**であって、ここで絞る意図は無い
  # （@page_size と掛けた数が実質の上限になる）。無限に回ると、向こうの応答が
  # 壊れたときに終われなくなる
  @max_pages 40
  @user_agent "antenna/0.1 (+https://github.com/rtcode337/antenna)"

  # 回る先の割り方。**見出しの順に 25 人ずつ**で、300 区画ほどになる
  # （日本語版 Wikipedia の「〜の画家」は 323 カテゴリ・のべ 14,735 記事）。
  #
  # **1 回の答えが長くなりすぎない大きさにする。** 50 人ずつで聞いていた頃、AI の
  # 答えがモデルの出力上限に当たって途中で切れた（実測: 7,948 文字目で JSON が壊れた）。
  # 上限を上げる手は無い —— Chiezo もブリッジも出力を切っておらず、切っているのは
  # モデル自身で、しかも打ち切られたことは応答から見分けられない。
  # **区画を半分にすれば 1 回の答えも半分**になる。一周の日数は `cover_days` から
  # 計算されるので変わらない（同じ量を、細かく分けて聞くだけ）。
  #
  # 意味のある集まり（生年の 10 年刻み、様式）で割るほうが「この範囲で漏れている画家は
  # 誰か」を問えるのだが、**そちらは半分近くが区画から漏れる** —— 生没年のカテゴリを
  # 持たない画家が 42%、様式に至っては 94% いる（本番の 2,999 人で実測）。
  # ここでの狙いは**全員を一度は見ること**なので、全員が必ずどこかに入る見出し順を採る。
  # 「この 25 人を詳しくして」は、集まりに意味が無くても答えられる問い。
  #
  # **区画は「地域 × 生年」で切る。** 辞書順で切っていた頃は「Kage〜おおやちき」の
  # ような塊になり、同じ区画に入った 2 人に何の関係も無かった —— 影響関係も漏れも
  # 見つけようがない。地域と世代で切れば、流派と世代のまとまりになる。
  #
  # **1 年より細かくは割らない**（Chiezo 側の約束）。「フランスの 1660 年生まれ」を
  # 2 つに分けると、その区画に全員が並ばなくなり、漏れを問えなくなる。
  # 人の少ない地域は年の幅が自然に広がる（実測で 400 区画・中央値 25 人）。
  #
  # **名簿の漏れは 2 か所から埋める。** カテゴリで取れるものは抽出の指定
  # （`painters_extract_request`）のほうが決定的なので、そちらを直して引き直す。
  # **カテゴリでは取れないもの**（記事はあるのにカテゴリが無い人、日本語版に記事が
  # 無い人）は機械では拾いようがないので、巡回のプロンプトで AI に足させる。
  # 狙い撃ちで調べさせたいときは割り込み（`POST /v1/collect/<name>/focus`）。
  @partition %{by: "band", prefix: Graph.region_tag(), value: Graph.years_tag(), target: 25}

  # ざっと全体を拾う巡回。6 時間ごとに 14 日で一周する（1 回に見る区画数は
  # Chiezo が区画の数から計算するので、画家が増えても一周の日数は変わらない）。
  # **一周の日数で決める**のは、AI の呼び出し回数がそこから逆算されるため ——
  # 1 万人を 7 日で回ると 1 日 32 回になる
  # **一周を数日で終える。** 400 区画を 1 時間ごとに 6 区画ずつで 2〜3 日
  @rough_minutes 60
  @rough_days 3
  # 少数をじっくり調べる巡回。1 日 1 区画を、考える量を上げて見直す
  @deep_minutes 1440
  # 名簿を機械で取り込み直す巡回。**週 1 で足りる** —— Wikipedia のカテゴリが
  # 増える速さはその程度で、AI を呼ばないぶん頻度を上げても得るものが無い
  @roster_minutes 10_080

  # **2 本に分ける理由。** 進み方も、頼む相手も、1 回に食べる量も違う ——
  # ざっとは影響関係の空欄を埋めて回り、じっくりは既に入っているものを疑う。
  # 1 本の間隔では両方は表せない
  # **3 本目は時計を持たない。** 画家のモーダルから頼む「この画家を詳しく調べて」は
  # 割り込みとして走るので、**頼む相手を定時のものと別に決めておける**必要がある ——
  # あれは人が待っている場面で、ざっとの相手をそのまま使う理由が無い
  # **4 本目は「漏れ探し」。** 足すだけの回（`only_new`）で、既にいる画家には
  # 触らない —— 見せられるのはその区画のぶんだけなので、AI には「もう居るか」が
  # 分からない（別の括りに入っていることも、タグが間違っていることもある）。
  # 触らせると、既にいる有名な画家が薄い内容で上書きされ、タグごと落ちる。
  # **依頼文も巡回ごとに分ける** —— 埋める・見直して消す・漏れを足すは別の仕事で、
  # 1 つの文で全部を頼むと、どの回も同じ薄さになる
  # **仕事は 3 つに分ける。** 名簿を作る → 区画の材料を埋める → 区画ごとに仕上げる。
  # 順番に意味があるので、後のものは前のものが一周するまで走らない（`after`）——
  # 年代の分からない人が 3 割いる状態で漏れを探させても、その人たちは別の区画に
  # いるだけなので、「この区画に無い」を理由に既にいる画家を挙げて終わる
  @sweeps [
    # **名簿の取り込み。** AI を呼ばず、抽出の指定を走らせるだけの回。
    # **一度きり** —— 元の Wikipedia が変わらない限り何度やっても同じで、
    # その 1 回ぶんの取り込みが無駄になる。取り込み直したら押して走らせる
    %{name: "名簿", interval_minutes: @roster_minutes, use_extract: true, only_new: true, once: true},
    # **区画の材料を埋める回。** 年代と地域が入っていないと区画が決まらないので、
    # そこが最優先。ついでに説明・代表作・様式も埋め、明らかに画家でない人は消す。
    # **一周を数日で終える速さ**にしてある（1 時間ごと・1 回 6 区画で 2〜3 日）
    %{name: "ざっと", interval_minutes: @rough_minutes, cover_days: @rough_days, after: "名簿"},
    # **区画ごとに仕上げる回。** 漏れを探し、内容を磨き、要らないものを消す。
    # 3 本に分けていた頃は、同じ区画を 3 回渡して 3 回とも同じものを読ませていた。
    # **割り込みもここへ頼む**（時計を持たない 1 本は置かない）
    %{
      name: "調査",
      interval_minutes: @deep_minutes,
      partitions_per_run: 1,
      effort: "high",
      prompt: :survey,
      after: "ざっと"
    }
  ]

  # 割り込みを頼む先の巡回。**専用の 1 本は置かない**（同じ仕事を頼むので）
  @survey_sweep "調査"

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
      # **これは手書きの表示例**。Chiezo（や AI）から読めたものに差し替わるまで、
      # 図は描かない —— 本物と見分けが付かない図が出ると、何を見ているのか分からない
      sample?: true,
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
      sample?: true,
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

  @doc """
  antenna が持っている設定を Chiezo へ送り、読み直します。

  **走らせません。** 定時の巡回は Chiezo が回すもので、こちらから割り込んで
  走らせると、その回のぶん予定が先送りになる（押した人にはそれが見えない）。
  """
  def collect_now(key, choices \\ %{}) when is_binary(key) and is_map(choices) do
    GenServer.cast(__MODULE__, {:collect, valid_key(key), choices})
  end

  @doc """
  **この画家を詳しく調べて**、を Chiezo へ割り込ませます。

  定時の巡回とは別の道なので、進み具合にも次の予定にも触りません。
  """
  def focus_painter(key, name, note) when is_binary(key) and is_binary(name) do
    GenServer.cast(__MODULE__, {:focus, valid_key(key), name, note})
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
  Chiezo で頼める相手の一覧（画面の選択肢に使う）。

  **図を読むのとは別に引きます。** 図の読み直しは開くたびに走るので、そこへ混ぜると
  「溜まったものを読む」以外の問い合わせが増える —— 何を読んでいるのかが辿りにくい。

  引けなければ空。**選べないだけで、図は出ます**。
  """
  def ai_backends do
    case chiezo_base_url() do
      nil -> []
      base_url -> Chiezo.backends(base_url)
    end
  end

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
      # Chiezo 側で取り込みが走っているか。**ボタンは止めない** —— 押しても
      # 送るだけ（走らせはしない）ので、取り込み中でも困らない
      busy: %{},
      # 割り込み（この画家を詳しく調べて）の届き具合。**断られたら知らせる** ——
      # 取り込み中の Chiezo は受け付けないので、黙って捨てると「頼んだのに何も
      # 起きない」だけが残る
      focus: %{},
      # 押して送っている最中か。**開いたときの読み直しと区別する** ——
      # 一緒にすると、読むだけのときに「送っています」と出てボタンも押せなくなる
      pushing: %{},
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
  def handle_cast({:focus, key, painter, note}, state) do
    case chiezo_base_url() do
      nil ->
        {:noreply, broadcast(focused(state, key, painter, {:error, :chiezo_not_configured}), key)}

      base_url ->
        # **待たせない。** 割り込みは Chiezo 側で数分かかるので、押した合図だけ返す。
        # **ただし断られたら知らせる** —— 取り込みが走っている間は Chiezo が受け付けない
        # ので、黙って捨てると「頼んだのに何も起きない」だけが残る（実際にそうなった）
        me = self()

        Task.Supervisor.start_child(Antenna.TaskSupervisor, fn ->
          send(me, {:focus_done, key, painter, ask_focus(base_url, painter, note)})
        end)

        {:noreply, broadcast(put_in(state.focus[key], %{painter: painter, state: :sending}), key)}
    end
  end

  def handle_cast({:collect, key, choices}, state) do
    cond do
      # **送っている最中だけ止める。** 読み直しの最中も止めていたが、あれのせいで
      # 押下が黙って捨てられていた —— 8,000 件の読み直しは数十秒かかり、そのあいだ
      # ボタンは押せるのに何も起きない（画面には何も出ないので、設定が送られていない
      # ことに気づきようがない）。送るのは読み直しとは別の往復なので、重なって困らない
      state.pushing[key] ->
        {:noreply, state}

      throttled?(state, key) ->
        {:noreply, broadcast(put_in(state.reasons[key], :too_soon), key)}

      true ->
        fallback = Map.fetch!(state.relations, key)

        task =
          Task.Supervisor.async_nolink(Antenna.TaskSupervisor, fn ->
            fetch_relation(key, fallback, choices)
          end)

        check_busy(key)

        state =
          state
          |> put_in([:statuses, key], :loading)
          |> put_in([:reasons, key], nil)
          |> put_in([:tasks, task.ref], key)
          |> put_in([:pushing, key], true)
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
          # 終わったら「送っている」も「いまどこ」も畳む(残すと押せないままになる)
          |> put_in([:pushing, key], false)
          |> put_in([:step, key], nil)
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
          # **落ちたときも必ず戻す。** 戻さないと「送っています」のまま固まり、
          # ボタンが二度と押せなくなる
          |> put_in([:pushing, key], false)
          |> put_in([:step, key], nil)
          |> apply_result(key, {:error, :collection_crashed})

        {:noreply, broadcast(state, key)}

      :error ->
        {:noreply, state}
    end
  end

  # 走っている途中から届く「いま何をしているか」。そのまま画面へ流す
  # 割り込みの結果が返ってきた（待っていたのはタスクの側）
  def handle_info({:focus_done, key, painter, result}, state),
    do: {:noreply, broadcast(focused(state, key, painter, result), key)}

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

  # 割り込みの結果。**成否どちらも残す** —— 押した人が知りたいのは「届いたか」で、
  # 届かなかったときこそ知らせる必要がある
  defp focused(state, key, painter, :ok),
    do: put_in(state.focus[key], %{painter: painter, state: :sent})

  defp focused(state, key, painter, {:error, reason}),
    do: put_in(state.focus[key], %{painter: painter, state: :failed, reason: reason})

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

  # 収集そのものが無いとき。**状態を添えようがない**ので、理由だけを持って表示例へ戻す
  defp apply_step(state, key, {:error, {reason, nil}}) do
    state
    |> put_in([:relations, key], Map.put(Map.fetch!(@views, key), :collection, nil))
    |> put_in([:statuses, key], :unavailable)
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
    |> Map.put(:focus, Map.get(state.focus, key))
    # **押して送っている最中かどうか。** 開いたときの読み直しと区別する ——
    # 読むだけのときに「送っています」と出すのは嘘で、しかもボタンが押せなくなる
    |> Map.put(:pushing, Map.get(state.pushing, key, false))
    |> Map.put(:step, Map.get(state.step, key))
    |> Map.put(:reason, Map.get(state.reasons, key))
  end

  @doc """
  画家の図を溜めておく Chiezo の収集の名前。`ANTENNA_PAINTERS_COLLECTION` で変えられます。

  **網羅の収集**として置きます。図は流れではなく一枚もので、
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
  defp fetch_relation("painters", fallback, choices) do
    case chiezo_base_url() do
      nil -> {:error, :chiezo_not_configured}
      base_url -> push_painters(base_url, fallback, choices)
    end
  end

  defp fetch_relation(key, fallback, _choices) do
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
        {:error, {nothing_reason(collection), collection}}

      {:error, reason} ->
        {:error, reason}

      {:ok, docs} ->
        graph = Graph.from_docs(docs)

        if graph.nodes == [] do
          {:error, {nothing_reason(collection), collection}}
        else
          # 丸の大きさは知名度で決める。**AI に有名かどうかを判断させない** ——
          # jawiki の月次ページビューのほうが客観的で、実行のたびに揺れない
          fame = Fame.for_articles(base_url, Enum.map(graph.nodes, & &1.article))
          sized = Graph.sized(graph.nodes, fame)

          {:ok,
           fallback
           |> Map.merge(%{graph | nodes: sized})
           |> Map.put(:collection, collection)
           |> Map.put(:sample?, false)}
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
  def push_painters(base_url, fallback, choices \\ %{}) do
    name = painters_collection()

    with {:ok, existing} <- ensure_collection_once(base_url, name) do
      # **既にある収集には設定を送り直す。** 作るときの `POST` は「もうある」で
      # 断られるので、それだけだと antenna 側で指示文や区画を直しても永遠に届かない
      # （画面には Chiezo の中身が出るので、直したはずのものが出ないことになる）。
      # **走らせはしない** —— 走らせると定時の巡回がその回ぶん先送りになる
      #
      # **断られたら黙って済ませない。** 読み直しは成功するので、結果だけ見ていると
      # 「押したのに何も変わらない」としか映らない（送れていないことに気づけない）
      pushed =
        if existing do
          progress(:pushing)
          Chiezo.patch(base_url, name, base_attrs(name, choices))
        else
          :ok
        end

      case {pushed, reading(fetch_painters(base_url, fallback))} do
        {:ok, read} -> read
        {{:error, reason}, {:ok, relation}} -> {:ok, relation, reason}
        {{:error, reason}, _unreadable} -> {:error, reason}
      end
    end
  end

  @doc """
  この画家を詳しく調べてほしい、を Chiezo へ割り込ませます。

  **区画ではなく名指しで渡します** —— 区画を渡すだけでは、直してほしい 1 人が
  差し込みに載る保証がありません。
  """
  def ask_focus(base_url, name, note) do
    # **調査の回に頼む。** 割り込み専用の巡回は置いていない —— 同じ仕事
    # （漏れ探し・磨き・削除）を頼むのだから、設定も依頼文もそこのものでよい
    case Chiezo.focus(base_url, painters_collection(), note, [name], @survey_sweep) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
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


  # **図の構造は Chiezo に持ち込まない。** 1 画家 1 文書の普通の文書として書かせ、
  # 属性と関係はタグに載せる（読み方を与えるのは antenna 側 = `Relations.Graph`）。
  def painters_prompt do
    """
    画家の関連図を育ててください。

    **今回見る範囲**
    {partition}

    **この範囲の画家が、下にすべて並んでいます。** 誰を見るか選ぶ必要はありません ——
    並んでいる人を順に詳しくしてください。**範囲の外の画家は返さないでください**
    （その人たちは別の回に回ってきます）。

    {current}

    **まず「#{Graph.years_tag()}」と「#{Graph.region_tag()}」を埋めてください。**
    ここがいちばん急ぎます —— **この 2 つで区画が決まる**ので、空のままだと
    その人は「年代不明」の置き場に入り、同じ時代・同じ地域の画家と一緒に
    見てもらえません（実測で 3 割の人が年代を持っていません）。

    どちらも Wikipedia のカテゴリから機械的に入れていますが、**カテゴリの無い人には
    入っていません**。生没年が分かるなら "#{Graph.years_tag()}:1840-1926" の形で、
    活動した国や地域が分かるなら "#{Graph.region_tag()}:フランス" の形で書いてください。

    そのうえで、できる範囲で埋めてください —— **影響関係**と**代表作**、
    読んで分かる説明です。**絵で知られていない人（俳優・作家・漫画家）が混ざっていたら、
    墓標で消して構いません**（tags に "削除" を入れて返す）。

    **関連の線はもう引いてあります。** 記事どうしが相互にリンクしている組を
    機械的に「#{Graph.related_tag()}」のタグにしてあるので、図はすでにつながっています。
    あなたの仕事は、そのうち**実際に影響関係があるものを「影響元」に書き換える**こと ——
    誰が誰から何を受けたのかは、リンクの有無からは分かりません。
    関連のタグはそのまま残してください（消すと線が消えます）。

    **様式は入っている人と入っていない人がいます。** カテゴリに「〜派の画家」がある人
    だけ機械的に入っており、ゴッホやピカソのようにカテゴリを持たない人は空のままです。
    空の人には様式のタグを足してください。

    **1 人に複数の様式を付けて構いません。** 時期で作風が変わった画家を 1 つに
    決めると、どれを選んでも間違いになります（ピカソは青の時代もキュビスムも
    新古典主義も本当です）。当てはまるものを全部書いてください。

    **代表作は誰にも入っていません。** 名簿にあるのは名前と年代だけで、機械では
    引けないところです。**知られている絵から順に 3 つまで**、日本語版 Wikipedia に
    記事がある絵を書いてください（記事の無い絵は図から辿れないので、入れなくて
    構いません）。**1 つも思い当たらない画家は空のままで構いません** ——
    無理に埋めると、その画家の絵でないものが代表作として並びます。

    **変えない人を返す必要はありません。** 触れなかった人はそのまま残ります。
    調べても影響関係が分からなかった人は、飛ばして構いません。

    1 人につき 1 件で、次の形にしてください。
    - title: 画家名（**上に並んでいる人は、その表記をそのまま使う**。変えると別人に
      なります。足す人は日本語版 Wikipedia の記事名にそろえてください）
    - body: その画家が何をした人かと、影響関係の要点
    - url: 日本語版 Wikipedia のその画家の記事の URL
    - tags: **その人にいま付いているタグをすべて残したうえで**、次を足してください
      - "様式:<ロマン主義 / 印象派 / キュビスム のような様式名>"。**当てはまる様式の数だけ
        並べてよい**（時期で作風が変わった画家は 1 つに決められません）
      - "#{Graph.work_tag()}:<日本語版 Wikipedia にあるその絵の記事名。例: 印象・日の出>"。
        **知られている順に 3 つまで**（多い画家ほど、代表作を 1 つに決められません）。
        **記事があるものだけ挙げてください** —— 画面はこの名前で日本語版 Wikipedia を
        引いて絵を出すので、記事の無い作品名を書くと、その枠はずっと空のままになります。
        確かなものが 1 つも無ければ、この行は書かなくて構いません
      - "影響元:<影響を受けた画家名>:<何を受けたかを10文字ほどで>"
        影響を受けた画家ごとに 1 つ。**その人の「#{Graph.related_tag()}」タグに
        挙がっている画家から選んでください** —— あれは名簿にいる相手だけが載っているので、
        そこから選べば必ず図に線が出ます。名簿にいない相手への線は出ません。
      年代や様式が明らかに違うときだけ、そのタグを直してください。

    重複していたら、まとめた先を返して、元のほうは墓標で消してください。
    **絵で知られていない人（俳優・作家など）が混ざっていたら、同じく墓標で消してください。**
    名簿は Wikipedia のカテゴリから機械的に作っているので、絵も描く別の職業の人が
    入ってしまいます。そこの見分けは、あなたにしかできません。
    """
  end

  @doc """
  区画ごとに仕上げる回の依頼文。**漏れを探し、内容を磨き、要らないものを消す**。

  3 本に分けていた頃は、同じ区画を 3 回渡して 3 回とも同じ人たちを読ませていました。
  読む材料が同じなら、仕事も一度に頼むほうが安く、判断も揃います。

  **割り込みもここへ来ます**（区画を名指しすることも、画家を名指しすることもある）。
  """
  def painters_survey_prompt do
    """
    画家の関連図を、**この区画ぶんだけ仕上げてください**。

    **今回見る範囲**
    {partition}

    {current}

    **上に並んでいるのが、この範囲の全員です。** 範囲は「地域」と「生年」で
    区切ってあるので、その地域・その年代の画家は漏れなく上に出ています。

    やってほしいことは 3 つです。

    **1. 漏れを足す。** 上に無くて、この範囲（同じ地域・同じ年代）に入る画家が
    いれば足してください。抜けるのは、日本語版 Wikipedia に記事はあるが
    「〜の画家」のカテゴリが付いていない人、日本語版に記事が無い人、別の表記で
    載っている人です。**思い当たらなければ足さなくて構いません** ——
    既にいる人を挙げ直しても名簿は変わらず、AI の枠だけが減ります。

    **2. 内容を磨く。** 上に並んでいる人で、説明・様式・代表作・影響元が
    空のものを埋めてください。入っているものが明らかに違うときだけ直します。
    **確かめられなかったものは触らないでください** —— 疑わしいから消す、を
    やると、正しかったものまで落ちます。

    **3. 要らないものを消す。** 名簿は日本語版 Wikipedia のカテゴリから機械的に
    作っているので、絵で知られていない人（俳優・作家・漫画家）が混ざります。
    **絵で知られていない人は墓標で消してください**（tags に "削除" を入れて返す）。
    表記の揺れで同じ人が 2 つに分かれていたら、**残すほうに中身をまとめて返し、
    消すほうに墓標を付けて**ください。

    **触った人だけ返してください。** 触れなかった人はそのまま残ります。
    **いま付いているタグは、直すもの以外そのまま残してください** ——
    返した内容で丸ごと置き換わるので、書かなかったタグは消えます。

    足す人・直す人の形は次のとおりです。
    - title: 画家名（**日本語版 Wikipedia の記事名にそろえる**）
    - body: その画家が何をした人かと、影響関係の要点
    - url: 日本語版 Wikipedia のその画家の記事の URL
    - tags:
      - "#{Graph.kind_tag()}"
      - "#{Graph.years_tag()}:<1840-1926 のような生没年>"（**区画がこれで決まります**）
      - "#{Graph.region_tag()}:<フランス / 日本 のような国や地域>"（**同じく区画の材料**）
      - "#{Graph.style_tag()}:<様式名>"（当てはまる数だけ並べてよい）
      - "#{Graph.work_tag()}:<代表作の記事名>"（知られている順に 3 つまで。
        **日本語版 Wikipedia に記事があるものだけ** —— 画面はこの名前で引いて絵を
        出すので、記事の無い作品名を書くと、その枠はずっと空のままになります）
      - "#{Graph.influence_tag()}:<影響を受けた画家名>:<何を受けたかを10文字ほどで>"
        **その人の「#{Graph.related_tag()}」タグに挙がっている画家から選んでください**
        —— あれは名簿にいる相手だけが載っているので、そこから選べば必ず図に線が出ます
      - "#{Graph.related_tag()}" のタグは**そのまま残してください**（消すと線が消えます）
    """
  end

  # まだ無ければ依頼する。**止まった状態で作られる**ので、これで AI が動き出す
  # ことはない（動かすかは Chiezo 側で決める）。すでにあれば何もしない
  defp ensure_collection(base_url, name) do
    progress(:requesting)
    Chiezo.request(base_url, base_attrs(name))
  end

  @doc """
  名簿の引き方（Chiezo の「抽出の指定」）。**antenna が持ちます**。

  かつては依頼文を渡して AI に書き起こさせ、書けたものを Chiezo が持っていました。
  やめた理由は、**中身が図の軸そのもの**だからです —— 年代は縦軸、地域は横軸、
  様式は色で、どれも `Antenna.Relations.Graph` が読む語彙。向こうに預けると、
  読む側と引く側が別々に動いて静かにズレます（実際、末尾を「〜の画家」から広げても
  地域を作る規則が古いままで、入ってきた画家が全員「その他」に落ちる形になっていた）。

  ここに置けば、直したいときに直せます（「収集の設定を更新」で届く）。
  **Chiezo の画面で手で直したものは、押すと上書きされます** ——
  指示文・区画・巡回と同じ契約です。
  """
  def painters_extract do
    %{
      source: "jawiki",
      # **呼び方は 1 つではありません。** 「の画家」だけを書いていたせいで
      # 「〜の女性画家」が丸ごと落ちていた（44 カテゴリ・1,877 記事。草間彌生もそこ）
      tag_suffix: "の画家,の女性画家",
      # 族をなさない 2 つ。どちらも日本の画家のカテゴリで、合わせて 1,589 記事
      tag: "洋画家,日本画家",
      # **カテゴリは持ち主の職業を選びません。** 絵も描く俳優や作家が入っていて、
      # 人気の順に取るとそちらが先に並ぶ
      not_tag: "俳優,小説家,児童文学作家",
      body: "opening",
      url: "https://ja.wikipedia.org/wiki/{title}",
      tags: [
        %{const: Graph.kind_tag()},
        # 生年と没年の両方があるときだけ作る（半端な年代は軸として読めない）
        %{
          patterns: ["^(\\d{3,4})年生$", "^(\\d{3,4})年没$"],
          format: "#{Graph.years_tag()}:{1}-{2}"
        },
        # **「〜の女性画家」にも当てる。** 当てないと、広げた末尾で入ってきた画家に
        # 地域も様式も付かず、横軸の「その他」に落ちる
        %{pattern: "^(.+?)派の(?:女性)?画家$", format: "#{Graph.style_tag()}:{1}派"},
        %{
          pattern: "^\\d{1,2}世紀(.+?)の(?:女性)?画家$",
          format: "#{Graph.region_tag()}:{1}"
        },
        %{
          pattern:
            "^(江戸|明治|大正|昭和|平成|令和|室町|安土桃山|鎌倉|平安|南北朝|飛鳥|奈良)" <>
              "時代の(?:女性)?画家$",
          format: "#{Graph.region_tag()}:日本"
        },
        %{
          pattern: "^(オランダ)黄金時代の(?:女性)?画家$",
          format: "#{Graph.region_tag()}:{1}"
        },
        # 族をなさない 2 つは、名前そのものが「日本の画家」を意味している
        %{pattern: "^(?:洋画家|日本画家)$", format: "#{Graph.region_tag()}:日本"},
        # 代表作は「〈その画家〉の作品」のカテゴリから、人気の順に 3 つまで
        %{from_tag: "{title}の作品", format: "#{Graph.work_tag()}:{1}", take: 3},
        # 相互リンクだけを線にする（片側だと有名どうしが軒並み繋がって毛玉になる）
        %{linked: "mutual", format: "#{Graph.related_tag()}:{1}"}
      ]
    }
  end

  defp nothing_reason(nil), do: :collection_missing
  defp nothing_reason(_collection), do: :nothing_collected

  defp base_attrs(name, choices \\ %{}) do
    %{
      name: name,
      description: "antenna の関連図（画家の影響と時代）",
      prompt: painters_prompt(),
      interval_minutes: @rough_minutes,
      partition: @partition,
      sweeps: with_choices(@sweeps, choices),
      # **名簿の引き方も送る。** ここが antenna 側にあるので、直したいときに直せる
      extract: painters_extract(),
      # **網羅。** ある括りの全部が対象で、増減はしても古いものが要らなくなることは
      # ない —— 期限で落とすと穴が開く
      kind: "stock",
      # **実在しない見出しを指すタグは、Chiezo が焼く前に落とす。** AI は代表作を
      # 挙げられても、それが記事として存在するかは知らない —— 図は「タグがある =
      # 押せば何か出る」として印を付けるので、混ざっていると押しても何も出ない印が
      # 並ぶ。**画面で取り繕わず、データの側で揃える**
      verify_tags: [
        %{prefix: Graph.work_tag(), source: "jawiki"},
        %{prefix: Graph.related_tag(), source: "jawiki"}
      ],
      requested_by: "antenna"
    }
  end

  # 画面で選んだ相手を巡回に載せる。**antenna は覚えない** —— 正は Chiezo が持って
  # いるもので、画面はそれを読んで見せているだけ。覚えると二重に持つことになり、
  # Chiezo 側で直したときにどちらが正か言えなくなる
  defp with_choices(sweeps, choices) do
    for sweep <- Enum.map(sweeps, &resolve_prompt/1) do
      case Map.get(choices, sweep.name) do
        nil ->
          sweep

        # **空文字は落とさない。** あれは「Chiezo の既定にまかせる」を選んだという
        # 意思表示で、落とすと一度決めた相手を外せなくなる（Chiezo 側が空を
        # 「指定しない」に倒す）
        picked ->
          Map.merge(sweep, Map.reject(picked, fn {_k, v} -> is_nil(v) end))
      end
    end
  end

  # 巡回ごとの依頼文。**定義の中では名前で置いてある** —— 依頼文は数十行あるので、
  # 巡回の一覧に直に書くと、どの巡回がどんな設定かが読めなくなる
  defp resolve_prompt(%{prompt: :survey} = sweep), do: %{sweep | prompt: painters_survey_prompt()}

  defp resolve_prompt(sweep), do: sweep

  # 溜まっているものを全部引く。**まだ焼かれていなければソースごと無い**ので、
  # 404 は「まだ何も入っていない」として扱う（繋がらないのとは別）
  # **溜まっているぶんは全部読む。** かつては先頭 200 件だけを読んでいたが、
  # あれは「超えた分は有名な順に落ちる」という前提で置いた上限で、その前提が
  # 成り立っていなかった —— 収集ソースには rank_score が入らないので、Chiezo の
  # `ORDER BY rank_score DESC, title` は title のタイブレークだけが効き、返るのは
  # 名前順の先頭 200 人になる（実測では、有名な画家が 1 人も入らなかった）。
  defp collected_docs(base_url, name) do
    collect_pages(base_url, name, 0, [])
  end

  defp collect_pages(_base_url, _name, offset, acc) when offset >= @page_size * @max_pages,
    do: {:ok, acc}

  defp collect_pages(base_url, name, offset, acc) do
    url =
      base_url <>
        "/v1/" <>
        name <>
        "/filter?limit=#{@page_size}&offset=#{offset}&fields=title,body,tags,extra,updated_at&tag=" <>
        URI.encode_www_form(Graph.kind_tag())

    case Http.get(url,
           headers: [{"user-agent", @user_agent}],
           timeout: @read_timeout,
           connect_timeout: @connect_timeout
         ) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          # `filter` が返すのは `results`（`recent` の `docs` とは別の名前）
          {:ok, %{"results" => docs}} when is_list(docs) ->
            acc = acc ++ docs

            # 満杯で返ってきた頁の次だけ継ぐ。**足りない頁で止める**ので、
            # total を信じて回数を決めるより、途中で件数が変わっても破綻しない
            if length(docs) < @page_size,
              do: {:ok, acc},
              else: collect_pages(base_url, name, offset + @page_size, acc)

          _ ->
            {:error, :chiezo_unexpected_body}
        end

      # まだ焼かれていなければソースごと無い。1 頁目で出たときだけ「空」とみなす
      {:ok, %{status: 404}} when acc == [] ->
        {:error, :nothing_collected}

      {:ok, %{status: 404}} ->
        {:ok, acc}

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  defp chiezo_base_url, do: Chiezo.base_url()

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
        | sample?: false,
          nodes: laid_out,
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
