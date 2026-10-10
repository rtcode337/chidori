defmodule Chidori.Relations do
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

  alias Chidori.Chiezo
  alias Chidori.Http
  alias Chidori.Relations.Graph
  alias Chidori.Relations.Partitions
  alias Chidori.Relations.People

  # 図を描く面の大きさ。サンプルの座標もこの中に収めてある
  @canvas_width 980
  @canvas_height 560

  # 図の上下に空ける余白。**重なる UI のぶん** —— 探す欄と道具は図の上に、
  # 操作の案内は下に重ねてある（`.relation-find` / `.relation-tools` /
  # `.relation-hint`）。余白が無いと、いちばん上と下のノードがその下に隠れ、
  # **引きずっても拡大しても出てこない**（重なっているものは一緒に動かない）
  @canvas_margin 90

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
  @user_agent "chidori"

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

  # ざっと全体を拾う巡回（1 回に見る区画数は Chiezo が区画の数と一周の日数から
  # 計算するので、画家が増えても一周の日数は変わらない）。
  # **一周の日数で決める**のは、AI の呼び出し回数がそこから逆算されるため ——
  # 1 万人を 7 日で回ると 1 日 32 回になる。
  # **間隔を延ばすときは一周の日数も同じだけ延ばす** —— 間隔だけ延ばすと、
  # 1 回に見る区画が増えるだけで、1 日に呼ぶ回数は変わらない（枠の減りが釣り合わ
  # なかったので 1 時間 → 2 時間にした）。400 区画を 2 時間ごとに 6 区画ずつで 6 日
  # **間隔は設定ページから変えられる**（`Chidori.CollectPace`。既定 2 時間）。
  # 日数は既定の間隔のときのもので、間隔を変えたら同じ比で伸びる
  @rough_days_at_default 6
  # **区画ごとに仕上げる回。** 整理と同じ間隔で、何区画かまとめて見る ——
  # 1 時間ごとだと、走っている時間のほうが長くなる。400 区画なら 1 回 5 区画で、
  # 40 日ほどで一周する。1 日 1 区画にしていた頃は一周に 400 日かかっていた
  # (手入れの回が一周しないなら、区画で割っている意味が無い)。
  # **一周の日数で決める**ので、区画が増えても 1 回あたりが自動で増える。
  # 間隔を 6 時間 → 12 時間に延ばしたときに一周も 21 日 → 42 日に延ばした
  # （延ばさないと 1 回の区画が倍になり、使う枠が減らない）
  # 間隔は整理と同じ（設定ページから変えられる）。日数は既定の間隔のときのもの
  @survey_days_at_default 42

  # 名簿を機械で取り込み直す巡回。**週 1 で足りる** —— Wikipedia のカテゴリが
  # 増える速さはその程度で、AI を呼ばないぶん頻度を上げても得るものが無い
  @roster_minutes 10_080

  # **2 本に分ける理由。** 進み方も、頼む相手も、1 回に食べる量も違う ——
  # ざっとは影響関係の空欄を埋めて回り、じっくりは既に入っているものを疑う。
  # 1 本の間隔では両方は表せない
  # **3 本目は時計を持たない。** 画家のモーダルから頼む「この画家を詳しく調べて」は
  # 割り込みとして走るので、**頼む相手を定時のものと別に決めておける**必要がある ——
  # あれは人が待っている場面で、ざっとの相手をそのまま使う理由が無い
  # **漏れ探しは分けない。** 足すだけの 1 本（`only_new`）を置いていた頃は、
  # 同じ区画を何度も渡して何度も同じものを読ませていた —— 仕上げの回が
  # 「探して・磨いて・消す」をまとめて持つ。
  # **仕事は 3 つに分ける。** 名簿を作る → 区画の材料を埋める → 区画ごとに仕上げる。
  # 順番に意味があるので、後のものは前のものが一周するまで走らない（`after`）——
  # 年代の分からない人が 3 割いる状態で漏れを探させても、その人たちは別の区画に
  # いるだけなので、「この区画に無い」を理由に既にいる画家を挙げて終わる
  @sweeps [
    # **名簿の取り込み。** AI を呼ばず、抽出の指定を走らせるだけの回。
    # **一度きり** —— 元の Wikipedia が変わらない限り何度やっても同じで、
    # その 1 回ぶんの取り込みが無駄になる。取り込み直したら押して走らせる
    %{
      name: Chidori.SweepNames.machine(),
      interval_minutes: @roster_minutes,
      use_extract: true,
      only_new: true,
      once: true
    },
    # **区画の材料を埋める回。** 年代と地域が入っていないと区画が決まらないので、
    # そこが最優先。ついでに説明・代表作・様式も埋め、明らかに画家でない人は消す。
    # **一周したら止まる** —— 行き渡れば用が済む回で、止めないと 2 周目 3 周目が
    # 回り続け、同じことを何度も聞くために枠を使う。そのあとの手入れは調査が引き継ぐ
    %{
      name: Chidori.SweepNames.scan(),
      interval_minutes: Chidori.SweepNames.scan_minutes(),
      cover_days: Chidori.CollectPace.days(:scan, @rough_days_at_default),
      after: "機械収集",
      one_lap: true
    },
    # **区画ごとに仕上げる回。** 漏れを探し、内容を磨き、要らないものを消す。
    # 3 本に分けていた頃は、同じ区画を 3 回渡して 3 回とも同じものを読ませていた。
    # **割り込みもここへ頼む**（時計を持たない 1 本は置かない）
    %{
      name: Chidori.SweepNames.tidy(),
      interval_minutes: Chidori.SweepNames.tidy_minutes(),
      cover_days: Chidori.CollectPace.days(:tidy, @survey_days_at_default),
      prompt: :survey,
      after: "ざっと見る"
    }
  ]

  # 割り込みを頼む先の巡回。**専用の 1 本は置かない**（同じ仕事を頼むので）
  @survey_sweep Chidori.SweepNames.tidy()
  # **未レビューの人が残る区画を、先にざっと見てもらう**ときの巡回。
  # 整理（漏れ探しと磨き）を頼むより軽く、AI が目を通した印もこれで付く
  @rough_sweep "ざっと見る"
  # 区画への割り込みで名指しできる巡回
  @partition_sweeps [@survey_sweep, @rough_sweep]

  # Chiezo に名簿を持たせて育てる図。**並びが関連図のタブとトップの枠の並び**
  @chiezo_views ["painters", "people"]

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
      title: "芸能人のつながり",
      eyebrow: "COUPLES & FAMILY",
      # **これは手書きの表示例**。Chiezo（や AI）から読めたものに差し替わるまで、
      # 図は描かない —— 本物と見分けが付かない図が出ると、何を見ているのか分からない
      sample?: true,
      description: "芸能人の夫婦・家族とグループを、上から下へ年代順にたどれます。",
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
  Chidori が持っている設定を Chiezo へ送り、読み直します。

  **走らせません。** 定時の巡回は Chiezo が回すもので、こちらから割り込んで
  走らせると、その回のぶん予定が先送りになる（押した人にはそれが見えない）。
  """
  def collect_now(key, choices \\ %{}) when is_binary(key) and is_map(choices) do
    GenServer.cast(__MODULE__, {:collect, valid_key(key), choices})
  end

  @doc """
  **名簿の知名度の下限を変えて、名簿を引き直します**（芸能人の図。`Relations.Settings`）。

  Chiezo には抽出の指定だけを送り（巡回の相手などは触らない）、名簿を引く回
  （機械収集）を 1 回走らせます。**足すだけ**の回なので、下限を上げても名簿からは
  消えません（広げる向きのつまみ）。結果は `{:reroster, key, result}` で知らせます。
  """
  def reroster(key, min_pageviews) when key == "people" and is_integer(min_pageviews) do
    with {:ok, _setting} <- Chidori.Relations.Settings.put_min_pageviews(key, min_pageviews),
         base when is_binary(base) <- chiezo_base_url() do
      Task.Supervisor.start_child(Chidori.TaskSupervisor, fn ->
        name = collection_of(key)

        result =
          with :ok <- Chiezo.patch(base, name, %{extract: People.extract(min_pageviews)}) do
            Chiezo.by_hand(fn -> Chiezo.run(base, name, sweep: Chidori.SweepNames.machine()) end)
          end

        Phoenix.PubSub.broadcast(Chidori.PubSub, topic(key), {:reroster, key, result})
      end)

      :ok
    else
      nil -> {:error, :chiezo_not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  **この画家を詳しく調べて**、を Chiezo へ割り込ませます。

  定時の巡回とは別の道なので、進み具合にも次の予定にも触りません。
  """
  def focus_painter(key, name, note) when is_binary(key) and is_binary(name) do
    GenServer.cast(__MODULE__, {:focus, valid_key(key), name, note})
  end

  @doc """
  **この区画を先に見て**、を Chiezo へ割り込ませます。

  区画を名指しするので、**その区画には印が付きます** —— 先に見てほしいと頼んだ
  のだから、巡回が同じところをもう一度見る必要はありません。

  `sweep` はどの巡回として走らせるか。整理（漏れ探しと磨き）か、ざっと見る
  （未レビューの人に目を通して空欄を埋める）のどちらか。それ以外は整理に倒します。
  """
  def focus_partition(key, partition, note, sweep \\ @survey_sweep)
      when is_binary(key) and is_binary(partition) do
    sweep = if sweep in @partition_sweeps, do: sweep, else: @survey_sweep
    GenServer.cast(__MODULE__, {:focus_partition, valid_key(key), partition, note, sweep})
  end

  @doc """
  **この画家の区画を先にざっと見て**、を Chiezo へ割り込ませます。

  区画は押したときに割り出します（区画の一覧は設定なので、図を開いただけでは
  読んでいない）。届き具合は `partition_focus_id/1` の名前で追えます。
  """
  def focus_painter_partition(key, name, tags) when is_binary(key) and is_binary(name) do
    GenServer.cast(__MODULE__, {:focus_painter_partition, valid_key(key), name, tags || []})
  end

  @doc "画家の区画への割り込みを、届き具合の上で見分ける名前。"
  def partition_focus_id(name), do: "#{name} の区画"

  @doc "区画への割り込みで名指しできる巡回（整理・ざっと見る）。"
  def survey_sweep, do: @survey_sweep
  def rough_sweep, do: @rough_sweep

  @doc """
  Chiezo に溜まっているものを読み直します。**依頼も収集もしません**。

  画面を開いたときに呼びます —— Chiezo の側は Chidori と関係なく進むので、
  開くたびに取り直さないと、いつまでも表示例のままになります。
  溜め先を持たない図（人物）では何もしません。
  """
  def refresh(key) when is_binary(key) do
    GenServer.cast(__MODULE__, {:refresh, valid_key(key)})
  end

  def keys, do: Map.keys(@views)

  @doc """
  トップページに並べられる図（`{キー, 見出し}`）。**Chiezo から読む図だけ**
  —— 手書きの表示例しか無い図を並べても、読むものが無い。
  """
  def views, do: Enum.map(@chiezo_views, &{&1, @views[&1].title})

  @doc "Chiezo に名簿を持たせて育てる図か（画家・芸能人）。"
  def chiezo_view?(key), do: key in @chiezo_views

  @doc "その図の収集の名前。"
  def collection_of("people"), do: People.collection()
  def collection_of(_key), do: painters_collection()

  @doc "その図の、Chiezo に送る設定（関連図の画面の「収集の設定を更新」と同じもの）。"
  def attrs_of("people", choices), do: People.attrs(choices)
  def attrs_of(_key, choices), do: painters_attrs(choices)

  @doc "その図の、依頼文（ざっと見る回の文。画面の設定欄に出す）。"
  def prompt_of("people"), do: People.prompt()
  def prompt_of(_key), do: painters_prompt()

  # 図の読み方（`Graph.from_docs/2`）
  defp graph_spec("people"), do: People.graph_spec()
  defp graph_spec(_key), do: Graph.painters_spec()

  # 区画を割り出すタグの頭（`Partitions.locator/3`）
  defp partition_tags("people"), do: {People.category_tag(), Graph.years_tag()}
  defp partition_tags(_key), do: {Graph.region_tag(), Graph.years_tag()}

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
    Phoenix.PubSub.subscribe(Chidori.PubSub, topic(valid_key(key)))
  end

  @doc """
  種類を切り替えたときに使います。外さないと、見ていない側の収集結果でも
  画面が書き換わります。
  """
  def unsubscribe(key) when is_binary(key) do
    Phoenix.PubSub.unsubscribe(Chidori.PubSub, topic(valid_key(key)))
  end

  @doc """
  設定に関係なく確かめられるよう、鍵の丸めは公開しておく。

  **知らない鍵は画家に倒します**（最初に開く図でもあります）—— Chiezo に溜めて
  育てているのはこちらで、人物の図はまだその場で AI に聞く形のためです。
  """
  def valid_key(key) when key in ["people", "painters"], do: key
  def valid_key(_key), do: "painters"

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
  def handle_cast({:refresh, key}, state) when key in @chiezo_views do
    if state.statuses[key] == :loading do
      {:noreply, state}
    else
      fallback = Map.fetch!(state.relations, key)
      base_url = chiezo_base_url()

      if base_url do
        task =
          Task.Supervisor.async_nolink(Chidori.TaskSupervisor, fn ->
            fetch_view(key, base_url, fallback)
          end)

        check_busy(key)

        state =
          state
          |> put_in([:statuses, key], :loading)
          |> put_in([:tasks, task.ref], key)

        {:noreply, broadcast(state, key)}
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

        Task.Supervisor.start_child(Chidori.TaskSupervisor, fn ->
          send(me, {:focus_done, key, painter, ask_focus(base_url, painter, note, key)})
        end)

        {:noreply, broadcast(put_in(state.focus[key], %{painter: painter, state: :sending}), key)}
    end
  end

  def handle_cast({:focus_partition, key, partition, note, sweep}, state) do
    case chiezo_base_url() do
      nil ->
        {:noreply,
         broadcast(focused(state, key, partition, {:error, :chiezo_not_configured}), key)}

      base_url ->
        me = self()

        Task.Supervisor.start_child(Chidori.TaskSupervisor, fn ->
          send(
            me,
            {:focus_done, key, partition, ask_partition(base_url, partition, note, sweep, key)}
          )
        end)

        {:noreply,
         broadcast(put_in(state.focus[key], %{painter: partition, state: :sending}), key)}
    end
  end

  def handle_cast({:focus_painter_partition, key, name, tags}, state) do
    id = partition_focus_id(name)

    case chiezo_base_url() do
      nil ->
        {:noreply, broadcast(focused(state, key, id, {:error, :chiezo_not_configured}), key)}

      base_url ->
        me = self()

        Task.Supervisor.start_child(Chidori.TaskSupervisor, fn ->
          send(me, {:focus_done, key, id, ask_painter_partition(base_url, name, tags, key)})
        end)

        {:noreply, broadcast(put_in(state.focus[key], %{painter: id, state: :sending}), key)}
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
          Task.Supervisor.async_nolink(Chidori.TaskSupervisor, fn ->
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

  # 区画を割り出してから頼んだもの。**どの区画に頼んだかも残す**（押した人が知りたい）
  defp focused(state, key, painter, {:ok, partition}),
    do: put_in(state.focus[key], %{painter: painter, state: :sent, partition: partition})

  defp focused(state, key, painter, {:error, reason}),
    do: put_in(state.focus[key], %{painter: painter, state: :failed, reason: reason})

  # 確かめるのは別のプロセス。GenServer を HTTP で止めない
  defp check_busy(key) do
    parent = self()

    if base_url = chiezo_base_url() do
      Task.Supervisor.start_child(Chidori.TaskSupervisor, fn ->
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
    Phoenix.PubSub.broadcast(Chidori.PubSub, topic(key), {:relation_updated, public(state, key)})
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
  画家の図を溜めておく Chiezo の収集の名前。`CHIDORI_PAINTERS_COLLECTION` で変えられます。

  **網羅の収集**として置きます。図は流れではなく一枚もので、
  作り直すたびに全体が入れ替わるのが正しい振る舞いだからです。
  """
  def painters_collection do
    case System.get_env("CHIDORI_PAINTERS_COLLECTION", "") |> String.trim() do
      "" -> "chidori_painters"
      name -> name
    end
  end

  # 画家は **Chiezo に溜まったものを読む**。集めて整理するのは Chiezo の役目で、
  # Chidori は図の形に読み直して見せるだけ。1 画家 1 文書の普通のソースなので、
  # ノードとエッジという読み方を与えるのはこちら側（`Relations.Graph`）。
  #
  # 引き方は `filter`（タグでの一括抽出）。図は流れではなく**一枚もの**なので、
  # 新しい順に何件かではなく全部が要る。
  # 「収集」を押したとき。**まだ無ければ依頼し、その場で 1 回集めさせて**読み直す
  defp fetch_relation(key, fallback, choices) when key in @chiezo_views do
    case chiezo_base_url() do
      nil -> {:error, :chiezo_not_configured}
      base_url -> push_view(key, base_url, fallback, choices)
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
  def fetch_painters(base_url, fallback), do: fetch_view("painters", base_url, fallback)

  @doc "Chiezo に溜まっている図（画家・芸能人）を読みます。**読むだけ**（`fetch_painters/2`）。"
  def fetch_view(key, base_url, fallback) do
    # **収集の設定は読まない。** 図に要るのは溜まった文書だけで、設定（巡回・区画・
    # 依頼文）は画面の設定欄を開いたときに読む（`settings/1`）。一緒に読んでいた頃は、
    # 図を開くたびに 400 区画ぶんの台帳まで運んでいた。
    # **読めなかったときだけ設定を見る** —— 「収集が無い」のか「まだ溜まっていない」
    # のかで、押した人が次にすることが違う
    spec = graph_spec(key)

    case collected_docs(base_url, collection_of(key), spec.kind_tag) do
      {:error, :nothing_collected} ->
        collection = collection_or_nil(base_url, key)
        {:error, {nothing_reason(collection), collection}}

      {:error, reason} ->
        {:error, reason}

      {:ok, docs} ->
        graph = Graph.from_docs(docs, spec)

        if graph.nodes == [] do
          collection = collection_or_nil(base_url, key)
          {:error, {nothing_reason(collection), collection}}
        else
          # 丸の大きさは知名度で決める。**AI に有名かどうかを判断させない** ——
          # jawiki の月次ページビューのほうが客観的で、実行のたびに揺れない。
          # **その値は収集の中に入っている**（集める回が長期記憶から写す）ので、
          # ここで外へ引きに行かない
          {:ok,
           fallback
           |> Map.merge(%{graph | nodes: graph.nodes |> Graph.sized() |> with_faces()})
           |> Map.put(:collection, nil)
           |> Map.put(:sample?, false)}
        end
    end
  end

  # 顔写真の写しがある人に、配る道を付ける（無い人は取りに行く列に並ぶ。
  # `Chidori.Relations.Faces`）。記事の画像を運んでいない図（画家）は何もしない
  defp with_faces(nodes) do
    case for(node <- nodes, url = node[:image], is_binary(url), do: url) do
      [] ->
        nodes

      urls ->
        faces = Chidori.Relations.Faces.faces(urls)

        Enum.map(nodes, fn node ->
          case faces[node[:image]] do
            nil -> node
            path -> Map.put(node, :face, path)
          end
        end)
    end
  end

  defp collection_or_nil(base_url, key) do
    case Chiezo.collection(base_url, collection_of(key)) do
      {:ok, found} -> found
      {:error, _reason} -> nil
    end
  end

  @doc """
  設定欄に出すもの（収集の設定と、頼める相手の一覧）を Chiezo から読みます。

  **画面の設定欄を開いたときだけ呼びます。** 図を開くたびに読んでいた頃は、
  見もしない設定のために待たされていました。`nodes` を渡すと、区画ごとの
  未レビューの人数も数えます（区画の一覧と突き合わせるので、ここで一緒に）。
  """
  def settings(key, nodes \\ []) do
    case chiezo_base_url() do
      nil ->
        {:error, :chiezo_not_configured}

      base_url ->
        # 2 つは別の問い合わせなので並べて待つ
        backends = Task.async(fn -> Chiezo.backends(base_url) end)
        collection = if chiezo_view?(key), do: collection_or_nil(base_url, key)

        {:ok,
         %{
           collection: collection,
           backends: Task.await(backends, 30_000),
           partition_unreviewed: unreviewed_by_partition(collection, nodes, key)
         }}
    end
  end

  @doc """
  区画ごとの、AI がまだ目を通していない人の数（`%{鍵 => 人数}`）。
  区画の所属は Chiezo と同じ規則で割り出します（`Partitions`）。
  """
  def unreviewed_by_partition(collection, nodes, key \\ "painters")

  def unreviewed_by_partition(%{partitions: [_ | _] = partitions}, nodes, key) do
    {prefix, value} = partition_tags(key)
    find = Partitions.locator(partitions, prefix, value)

    nodes
    |> Enum.filter(& &1[:unreviewed?])
    |> Enum.map(&find.(&1[:tags] || [], &1.name))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  def unreviewed_by_partition(_collection, _nodes, _key), do: %{}

  @doc """
  Chiezo に収集を依頼して、そのまま読み直します。

  作られるのは**止まった状態**なので、押しただけで AI が動くことはありません。
  動かすかは Chiezo 側で決めます。
  """
  def request_painters(base_url, fallback) do
    with :ok <- ensure_collection(base_url, "painters") do
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
  def push_painters(base_url, fallback, choices \\ %{}),
    do: push_view("painters", base_url, fallback, choices)

  @doc "依頼したうえで読み直します（画家・芸能人。`push_painters/3`）。"
  def push_view(key, base_url, fallback, choices \\ %{}) do
    name = collection_of(key)

    with {:ok, existing} <- ensure_collection_once(base_url, key) do
      # **既にある収集には設定を送り直す。** 作るときの `POST` は「もうある」で
      # 断られるので、それだけだと Chidori 側で指示文や区画を直しても永遠に届かない
      # （画面には Chiezo の中身が出るので、直したはずのものが出ないことになる）。
      # **走らせはしない** —— 走らせると定時の巡回がその回ぶん先送りになる
      #
      # **断られたら黙って済ませない。** 読み直しは成功するので、結果だけ見ていると
      # 「押したのに何も変わらない」としか映らない（送れていないことに気づけない）
      pushed =
        if existing do
          progress(key, :pushing)
          Chiezo.patch(base_url, name, attrs_of(key, choices))
        else
          :ok
        end

      case {pushed, reading(key, fetch_view(key, base_url, fallback))} do
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
  def ask_partition(base_url, partition, note, sweep \\ @survey_sweep, key \\ "painters") do
    # **区画を名指しした割り込み。** その区画に印が付くので、巡回が同じところを
    # もう一度見ることはない —— 「ここを先に見てほしい」を頼む口
    # 画面から押した 1 回（止めている収集でも走らせる。`Chiezo.by_hand/1`）
    Chiezo.by_hand(fn ->
      Chiezo.focus(base_url, collection_of(key), note, [], sweep, partition)
    end)
  end

  @doc """
  その画家の区画を割り出して、ざっと見るの回として割り込ませます。
  成功すれば `{:ok, 区画の鍵}`。
  """
  def ask_painter_partition(base_url, name, tags, key \\ "painters") do
    {prefix, value} = partition_tags(key)

    with %{partitions: [_ | _] = partitions} <-
           collection_or_nil(base_url, key) || :no_partitions,
         find = Partitions.locator(partitions, prefix, value),
         partition when is_binary(partition) <- find.(tags, name) || :no_partition,
         :ok <-
           ask_partition(base_url, partition, rough_note(partition, key), @rough_sweep, key) do
      {:ok, partition}
    else
      :no_partitions -> {:error, :no_partitions}
      :no_partition -> {:error, :no_partition}
      %{} -> {:error, :no_partitions}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "ざっと見るの割り込みの指示文。**必ず区画の名前で始めます**。"
  def rough_note(partition, key \\ "painters"),
    do:
      "#{partition} の区画を先にざっと見てください。まだ目を通していない#{if key == "people", do: "人", else: "画家"}が残っています。"

  def ask_focus(base_url, name, note, key \\ "painters") do
    # **調査の回に頼む。** 割り込み専用の巡回は置いていない —— 同じ仕事
    # （漏れ探し・磨き・削除）を頼むのだから、設定も依頼文もそこのものでよい
    case Chiezo.by_hand(fn ->
           Chiezo.focus(base_url, collection_of(key), note, [name], @survey_sweep)
         end) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reading(key, result) do
    progress(key, :reading)
    result
  end

  # **押しても数分は Chiezo 側に何も出ない**（先に AI へ指定を書かせるため）。
  # どこで待っているのかが分からないと、押せていないのと区別が付かない
  defp progress(key, step) do
    if pid = Process.whereis(__MODULE__), do: send(pid, {:progress, key, step})
    :ok
  end

  # すでにあるなら何もしない。**作るときだけ指定を書かせる**ので、
  # 押すたびに書かせに行かないよう、先に有無を確かめる
  # 戻り値の真偽は「もとからあったか」。作った直後かどうかで、このあと
  # 指定を書かせに行くかが変わる
  defp ensure_collection_once(base_url, key) do
    progress(key, :checking)

    case Chiezo.collection(base_url, collection_of(key)) do
      {:ok, nil} ->
        with :ok <- ensure_collection(base_url, key), do: {:ok, false}

      {:ok, _found} ->
        {:ok, true}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # **図の構造は Chiezo に持ち込まない。** 1 画家 1 文書の普通の文書として書かせ、
  # 属性と関係はタグに載せる（読み方を与えるのは Chidori 側 = `Relations.Graph`）。
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
    入っていません**。活動した国や地域が分かるなら "#{Graph.region_tag()}:フランス" の形で
    書いてください。

    #{years_rule("")}

    そのうえで、できる範囲で埋めてください —— **影響関係**と**代表作**、
    読んで分かる説明です。**絵で知られていない人（俳優・作家・漫画家）が混ざっていたら、
    墓標で消して構いません**（tags に "#{Chiezo.tombstone_tag()}" を入れ、body に消す理由を1行書く）。

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
    引けないところです。**知られている絵から順に 3 つまで**書いてください。
    日本語版 Wikipedia に記事がある絵はその記事名で、**記事の無い絵も入れて
    構いません**（一般に通っている日本語の題名で。画面は、記事の無い絵を画像検索へ
    つなぎます）。**1 つも思い当たらない画家は空のままで構いません** ——
    無理に埋めると、その画家の絵でないものが代表作として並びます。

    **図の丸の大きさは、日本語版 Wikipedia の読まれ方で決まります。**
    実態と大きく食い違う画家だけ、`extra` に "#{Graph.fame_scale_key()}" を書いて
    直してください（倍率。書かなければ 1.0）。**ほとんどの人には要りません。**
    - 海外では高名だが日本語版はあまり読まれない → 2.0 〜 5.0
    - 最近の話題で一時的に読まれているだけ → 0.2 〜 0.5

    "#{Graph.views_key()}" のほうは機械が入れた事実なので、書き換えないでください。

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
      - "#{Graph.work_tag()}:<その絵の題名。例: 印象・日の出>"。
        **知られている順に 3 つまで**（多い画家ほど、代表作を 1 つに決められません）。
        日本語版 Wikipedia に記事があればその記事名に、無ければ一般に通っている
        日本語の題名にしてください（画面は記事から絵を出し、記事が無ければ画像検索へ
        つなぎます）。確かなものが 1 つも無ければ、この行は書かなくて構いません
      - "影響元:<影響を受けた画家名>:<何を受けたか>"
        **何を受けたかは 1〜2 文で具体的に**（40〜80 字ほど。例: 「師事して明暗法と
        劇的な構図を学び、宗教画の群像表現を受け継いだ」）。**「影響を受けた」
        「色彩」だけのような一語では書かないでください** —— 線を押した人が読む
        説明はこれだけです。**タグの区切りの「:」は本文に使わないでください**。
        影響を受けた画家ごとに 1 つ。**その人の「#{Graph.related_tag()}」タグに
        挙がっている画家から選んでください** —— あれは名簿にいる相手だけが載っているので、
        そこから選べば必ず図に線が出ます。名簿にいない相手への線は出ません。
      年代や様式が明らかに違うときだけ、そのタグを直してください（年代が数の形で
      ないときは、上の形に直してください）。

    重複していたら、まとめた先を返して、元のほうは墓標で消してください。
    **絵で知られていない人（俳優・作家など）が混ざっていたら、同じく墓標で消してください。**
    名簿は Wikipedia のカテゴリから機械的に作っているので、絵も描く別の職業の人が
    入ってしまいます。そこの見分けは、あなたにしかできません。

    **墓標には、なぜ消すのかを body に1行書いてください。** 消した人は名前が
    並ぶだけなので、理由が無いと消し間違いに気づけません。
    """
  end

  # 年代のタグの書き方。**ざっと見る回と整理の回で同じ文を渡す** —— 整理の回にだけ
  # 無かった頃、足した人に「21世紀」と書かれ、21 年生まれとしていちばん古い帯へ
  # 入ったうえ、そこで「範囲に合わない」と消された
  defp years_rule(indent) do
    tag = Graph.years_tag()

    [
      ~s(**「#{tag}」は必ず西暦の数で、"#{tag}:生年-没年" の形にしてください**),
      ~s(（例: "#{tag}:1840-1926"）。**区画は、このタグで最初に出てくる数（生年）で),
      "決まります** —— 「18世紀」と書くと 18 年として読まれ、「江戸時代」は数が無いので",
      "年代不明の置き場に落ちます。",
      ~s(- 存命の人は没年を空けます（"#{tag}:1948-"）),
      "- 生年が分からなければ、**分かる手掛かりから推し量った年に「頃」を付けて**",
      ~s(  ください（"#{tag}:1720頃-1790"。活動した時期や世紀からでも構いません）),
      ~s(- どうしても推し量れず没年だけ分かるときは "#{tag}:不詳-1518"),
      "- **「18世紀」「江戸時代」のような書き方がいま付いていたら、この形に直してください**"
    ]
    |> Enum.join("\n" <> indent)
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

    **範囲に合わない人が混ざっていることがあります。** 区画は年代と地域のタグで
    機械的に決まるので、タグが間違っている人・年代が西暦の数になっていない人
    （「21世紀」は 21 年として読まれ、いちばん古い帯に入ります）は、別の区画に
    入ってしまいます。**そういう人は消さずに、年代と地域のタグを直して返して
    ください** —— 直せば次の回から正しい区画へ移ります。
    下の「消したもの」に、範囲に合わないことだけを理由に消えている人がいたら、
    それは消し間違いです。書いてある手順で戻し、同じくタグを直してください。

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
    **絵で知られていない人は墓標で消してください**（tags に "#{Chiezo.tombstone_tag()}" を入れ、
    body に消す理由を1行書く）。消した人は一覧に名前と理由が並ぶだけなので、
    理由が無いと消し間違いに気づけません。
    表記の揺れで同じ人が 2 つに分かれていたら、**残すほうに中身をまとめて返し、
    消すほうに墓標を付けて**ください。
    **墓標を付けるのは、絵で知られていない人と重複の 2 つだけです。** 範囲に
    合わない、年代や地域が分からない、は消す理由になりません（タグを直すか、
    分からなければ触らずに残してください）。

    **図の丸の大きさは、日本語版 Wikipedia の読まれ方で決まります。**
    実態と大きく食い違う画家だけ、`extra` に "#{Graph.fame_scale_key()}" を書いて
    直してください（倍率。書かなければ 1.0）。**ほとんどの人には要りません。**
    - 海外では高名だが日本語版はあまり読まれない → 2.0 〜 5.0
    - 最近の話題で一時的に読まれているだけ → 0.2 〜 0.5

    "#{Graph.views_key()}" のほうは機械が入れた事実なので、書き換えないでください。

    **触った人だけ返してください。** 触れなかった人はそのまま残ります。
    **いま付いているタグは、直すもの以外そのまま残してください** ——
    返した内容で丸ごと置き換わるので、書かなかったタグは消えます。

    足す人・直す人の形は次のとおりです。
    - title: 画家名（**日本語版 Wikipedia の記事名にそろえる**）
    - body: その画家が何をした人かと、影響関係の要点
    - url: 日本語版 Wikipedia のその画家の記事の URL
    - tags:
      - "#{Graph.kind_tag()}"
      - "#{Graph.years_tag()}:<1840-1926 のような生没年>"（**区画がこれで決まります**）。
        #{years_rule("    ")}
      - "#{Graph.region_tag()}:<フランス / 日本 のような国や地域>"（**同じく区画の材料**）
      - "#{Graph.style_tag()}:<様式名>"（当てはまる数だけ並べてよい）
      - "#{Graph.work_tag()}:<代表作の題名>"（知られている順に 3 つまで。
        日本語版 Wikipedia に記事があればその記事名、無ければ一般に通っている日本語の
        題名 —— 記事の無い絵は、画面が画像検索へつなぎます）
      - "#{Graph.influence_tag()}:<影響を受けた画家名>:<何を受けたか>"
        （**1〜2 文で具体的に**。40〜80 字ほど。「色彩」のような一語では書かない。
        本文に「:」は使わない）。**その人の「#{Graph.related_tag()}」タグに挙がっている画家から選んでください**
        —— あれは名簿にいる相手だけが載っているので、そこから選べば必ず図に線が出ます
      - "#{Graph.related_tag()}" のタグは**そのまま残してください**（消すと線が消えます）
    """
  end

  # まだ無ければ依頼する。**止まった状態で作られる**ので、これで AI が動き出す
  # ことはない（動かすかは Chiezo 側で決める）。すでにあれば何もしない
  defp ensure_collection(base_url, key) do
    progress(key, :requesting)
    Chiezo.request(base_url, attrs_of(key, %{}))
  end

  @doc """
  名簿の引き方（Chiezo の「抽出の指定」）。**Chidori が持ちます**。

  かつては依頼文を渡して AI に書き起こさせ、書けたものを Chiezo が持っていました。
  やめた理由は、**中身が図の軸そのもの**だからです —— 年代は縦軸、地域は横軸、
  様式は色で、どれも `Chidori.Relations.Graph` が読む語彙。向こうに預けると、
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
      tags:
        [
          %{const: Graph.kind_tag()}
        ] ++
          years_rules() ++
          [
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
          ],
      # **知名度は長期記憶から写す。** 月次ページビュー（bot 除外）は jawiki の記事に
      # 入っているので、図を出すたびに 1 人ずつ引き直す理由が無い ——
      # 引いていた頃は画家の数だけ往復していた（初回で 9,000 回以上）
      extra: ["pageviews_month"]
    }
  end

  # 年代の世紀の手掛かりを当てる範囲(紀元後 1 世紀から 21 世紀まで)
  @centuries 1..21

  @doc """
  年代のタグを作る規則。**区画を切るのに使う形(「生年-没年」の数)にそろえる**。

  Chiezo の区画は、年代のタグから**最初に出てくる数**を取って区切ります
  （図の縦軸も同じ読み方）。「18世紀」と書くと 18 年として読まれ、
  「江戸時代」は数が無いので「年代不明」の置き場に落ちます。

  **手掛かりの確かな順に並べ、当たったところで止める**（`fallback`）——
  並べただけでは当たった全部が足され、年代のタグが何本も付きます。

  1. 生年と没年の両方 → `1840-1926`
  2. 生年だけ(存命か、没年のカテゴリが無い) → `1948-`
  3. 没年だけ(生年不詳) → `不詳-1518`。区画は没年で決まる(生年が分からないので、
     どこかに入れるほうを取る)
  4. 世紀だけ(生没年不詳) → `1700頃-1800頃`。世紀の頭を生年の目安にする。
     2 つの世紀に当たる人は、カテゴリの並びで先に当たったほうを採る
  """
  def years_rules do
    tag = Graph.years_tag()

    [
      %{patterns: ["^(\\d{3,4})年生$", "^(\\d{3,4})年没$"], format: "#{tag}:{1}-{2}"},
      %{pattern: "^(\\d{3,4})年生$", format: "#{tag}:{1}-", fallback: true},
      %{pattern: "^(\\d{3,4})年没$", format: "#{tag}:不詳-{1}", fallback: true},
      # **世紀は 1 つの規則で、値の表で読み替える**（`map`）。世紀ごとに規則を
      # 並べると Chiezo の上限（読み替えは 20 個まで）を超えて、設定の更新が断られた
      %{
        pattern: "^(\\d{1,2})世紀.+の(?:女性)?画家$",
        format: "#{tag}:{1}",
        fallback: true,
        map: Map.new(@centuries, &{"#{&1}", "#{(&1 - 1) * 100}頃-#{&1 * 100}頃"})
      }
    ]
  end

  defp nothing_reason(nil), do: :collection_missing
  defp nothing_reason(_collection), do: :nothing_collected

  @doc """
  画家の収集に送る設定（関連図の画面の「収集の設定を更新」と同じもの）。
  `choices` は巡回ごとに選んだ相手。
  """
  def painters_attrs(choices \\ %{}), do: base_attrs(painters_collection(), choices)

  defp base_attrs(name, choices) do
    %{
      name: name,
      description: "Chidori の関連図（画家の影響と時代）",
      prompt: painters_prompt(),
      interval_minutes: Chidori.SweepNames.scan_minutes(),
      partition: @partition,
      sweeps: with_choices(@sweeps, choices),
      # **名簿の引き方も送る。** ここが Chidori 側にあるので、直したいときに直せる
      extract: painters_extract(),
      # **網羅。** ある括りの全部が対象で、増減はしても古いものが要らなくなることは
      # ない —— 期限で落とすと穴が開く
      kind: "stock",
      # **実在しない見出しを指すタグは、Chiezo が焼く前に落とす。** 関連の相手は
      # 名簿にいる人でなければ線にならないので、記事の無い名前は落とす。
      # **代表作は照らさない。** 作品が単独の記事を持つことは少なく、照らしていた頃は
      # AI が目を通した画家の 9 割で代表作が落ちていた（3,637 人中 322 人しか残らない）。
      # 絵が見つからない作品は、画面が画像検索へのリンクにする
      verify_tags: [
        %{prefix: Graph.related_tag(), source: "jawiki"}
      ],
      requested_by: "chidori"
    }
  end

  # 画面で選んだ相手を巡回に載せる。**Chidori は覚えない** —— 正は Chiezo が持って
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
  # **未レビューのものも読む**（`include_removed`）。読み口の既定は AI がまだ目を
  # 通していないものを外すが、それだと名簿の 6 割が図から消え、どこが残って
  # いるのかも分からなくなる。**消えたものも一緒に届く**ので、図にする側で落とす
  # （`Graph`）。
  # **溜まっているぶんは全部読む。** かつては先頭 200 件だけを読んでいたが、
  # あれは「超えた分は有名な順に落ちる」という前提で置いた上限で、その前提が
  # 成り立っていなかった —— 収集ソースには rank_score が入らないので、Chiezo の
  # `ORDER BY rank_score DESC, title` は title のタイブレークだけが効き、返るのは
  # 名前順の先頭 200 人になる（実測では、有名な画家が 1 人も入らなかった）。
  defp collected_docs(base_url, name, kind_tag) do
    collect_pages(base_url, name, kind_tag, 0, [])
  end

  defp collect_pages(_base_url, _name, _kind_tag, offset, acc)
       when offset >= @page_size * @max_pages,
       do: {:ok, acc}

  defp collect_pages(base_url, name, kind_tag, offset, acc) do
    url =
      base_url <>
        "/v1/" <>
        name <>
        "/filter?limit=#{@page_size}&offset=#{offset}&fields=title,body,tags,extra,updated_at" <>
        "&include_removed=true&tag=" <>
        URI.encode_www_form(kind_tag)

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
              else: collect_pages(base_url, name, kind_tag, offset + @page_size, acc)

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
  def canvas_height(_count, "painters"), do: @canvas_height + 2 * @canvas_margin
  def canvas_height(count, _key), do: max(@canvas_height, 200 * rows(count)) + 2 * @canvas_margin

  @doc "図の上下に空ける余白。**重なる UI のぶん**。"
  def canvas_margin, do: @canvas_margin

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
        # 上下 2 段に振って重なりを避ける。**どちらの段も余白の内側**に置く
        y: @canvas_margin + if(rem(index, 2) == 0, do: 190, else: 350)
      })
    end)
  end

  def layout_nodes(nodes, _key) do
    count = length(nodes)
    columns = columns(count)
    cell_width = @canvas_width / columns

    # **余白の内側に段を割る。** 面ぜんたいで割ると、いちばん上と下の段が
    # 重なっている UI の下へ入る
    cell_height = (canvas_height(count, "people") - 2 * @canvas_margin) / rows(count)

    Enum.with_index(nodes, fn node, index ->
      Map.merge(node, %{
        x: cell_width * (rem(index, columns) + 0.5),
        y: @canvas_margin + cell_height * (div(index, columns) + 0.5)
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
