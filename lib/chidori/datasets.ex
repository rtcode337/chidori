defmodule Chidori.Datasets do
  @moduledoc """
  データ収集の対象（「データ収集」の画面のタブ）。

  **対象は Chidori の機能で、利用者のデータではありません。** 最新情報の「話題」や
  関連図の「人物」「画家」と同じ立ち位置で、集め方も引く先も対象ごとに違う ——
  だから**定義はコードに置きます**（`defined/0`）。足すときはここへ 1 つ書けば、
  タブも依頼も増えます。

  **ここに置くのは、どの対象でも同じ手順だけ**です（読む・送る・割り込む）。
  何を集めるかの指定と依頼文は対象の側（`Chidori.Datasets.Dining` など）が持ちます。

  **Chidori は収集の設定を覚えません。** 正は Chiezo が持っているもので、画面は
  それを読んで見せているだけ —— 写しを置くと、どちらが本物か言えなくなります。
  """

  alias Chidori.Chiezo
  alias Chidori.Datasets.Books
  alias Chidori.Datasets.DiningAreas
  alias Chidori.Datasets.Dining
  alias Chidori.Datasets.Gourmet
  alias Chidori.Datasets.Pihole

  @doc """
  Chidori が持っている収集の対象。タブはこの順に並ぶが、前に出すもの（技術書・食事処・
  ご当地グルメ）は `tabs/1` が決める。

  **食事処は範囲ごとに 1 つ**（`Chidori.Datasets.DiningAreas`。画面で地図に四角を描いて
  足す）。日本全体を 1 つで回していた頃は、費用がかさみ抜け漏れも多すぎた。

  **ご当地グルメは全国で 1 つ**（`Chidori.Datasets.Gourmet`。区画が県なので、範囲で分ける
  理由が無い）。
  """
  def defined,
    do: [
      Books.definition(),
      Pihole.definition(),
      Chidori.Datasets.Recipes.definition(),
      Gourmet.definition(),
      Chidori.Datasets.AnimeSeichi.definition()
      | Enum.map(DiningAreas.list(), &Dining.definition/1)
    ]

  @doc """
  対象の関数を呼びます。**範囲を持つ対象（食事処）は、範囲を最後の引数に足して呼ぶ**
  —— 名簿・区画・起点・依頼の中身が範囲で変わるため。範囲を持たない対象はそのまま。
  """
  def call(%{module: module} = dataset, fun, args \\ []) do
    case dataset[:area] do
      nil -> apply(module, fun, args)
      area -> apply(module, fun, args ++ [area])
    end
  end

  # タブの並びで前に出すもの（`:dining` は範囲ごとの食事処をまとめた 1 つのタブ）。
  # ここに無いものは、その後ろに定義の順で並ぶ
  @tab_order ["books", :dining, "gourmet"]

  @doc """
  データ収集のタブの並び。範囲を持たない対象と、食事処をまとめた `:dining` の並び
  （範囲ごとのタブは下の段。`ChidoriWeb.DiningTabs`）。**前に出すものは `@tab_order`**、
  残りは定義の順。
  """
  def tabs(datasets \\ defined()) do
    plain = Enum.reject(datasets, & &1[:area])
    all = plain ++ [:dining]
    key = fn tab -> if tab == :dining, do: :dining, else: tab.key end
    first = for k <- @tab_order, tab = Enum.find(all, &(key.(&1) == k)), do: tab

    first ++ Enum.reject(all, &(&1 in first))
  end

  @doc "対象の一覧（定義の順）。"
  def list, do: defined()

  @doc "1 つぶん。定義に無い鍵なら nil。"
  def get(key) when is_binary(key), do: Enum.find(defined(), &(&1.key == key))
  def get(_key), do: nil

  @doc """
  開く対象。**知らない鍵は先頭に倒します** —— 手で URL を書き換えられても
  画面が壊れないように（`?view=` はそのまま人が触れるところ）。
  """
  def valid_key(key) when is_binary(key) do
    if get(key), do: key, else: default_key()
  end

  def valid_key(_key), do: default_key()

  @doc "最初に開く対象。"
  def default_key, do: defined() |> List.first() |> Map.fetch!(:key)

  @doc """
  Chiezo に置いてある収集の状態。**まだ依頼していなければ `{:ok, nil}`**（失敗ではない）。

  区画の一覧もここで一緒に取ります —— どこがまだ見られていないかは、
  そこにしか無いためです。
  """
  def read(%{collection: name}) do
    with {:ok, base} <- base_url() do
      Chiezo.collection(base, name)
    end
  end

  @doc """
  依頼を送ります。**まだ無ければ作り、あれば設定を送り直します**。

  作られるのは**止まった状態**なので、押しただけで AI が動くことはありません
  （動かすかは Chiezo の管理画面で決めます）。**走らせもしません** ——
  走らせると、定時の巡回がその回ぶん先送りになります。

  **既にある収集には送り直しが要ります。** 作るときの `POST` は「もうある」で
  断られるので、それだけだと Chidori 側で依頼文や区画を直しても永遠に届きません。
  """
  def push(%{collection: name} = dataset, choices \\ %{}) do
    with {:ok, base} <- base_url(),
         {:ok, existing} <- Chiezo.collection(base, name) do
      attrs = outgoing(dataset, choices)
      if existing, do: Chiezo.patch(base, name, attrs), else: Chiezo.request(base, attrs)
    end
  end

  @doc """
  `push/2` が送る設定。**収集の画面（`/collect`）の表で、Chiezo の今の設定と突き合わせるのにも
  使う** —— 送るものと比べるものを別々に組むと、片方だけ直る。
  """
  def outgoing(dataset, choices \\ %{}), do: call(dataset, :attrs, [choices])

  @doc """
  範囲を変えたあとで、**範囲で決まるところだけを Chiezo へ送り、機械収集から
  走らせ直します**（範囲を持つ対象だけ）。

  送るのは説明・名簿の指定・区画だけ（`shape`）。巡回まで送り直すと、画面で選んだ
  相手が既定に戻る。区画の四角が変わると Chiezo は次の回に新しい範囲で割り直し、
  前の範囲に収まる区画には見終わった印を引き継ぐ。広げたところだけが「まだ」になる
  ので、一周して止まっていたざっと見るもそこだけを見に動き出す。

  返すのは次のどれか:

  - `:ok` —— 送って、機械収集を頼んだ
  - `{:ok, :not_requested}` —— まだ収集が無い（作るときに新しい範囲が載る）
  - `{:error, {:not_run, 理由}}` —— 送れたが、機械収集を頼めなかった（止まっているなど）
  - `{:error, 理由}` —— 送れなかった
  """
  def reshape(%{collection: name, area: area, module: module} = dataset) when not is_nil(area) do
    with {:ok, base} <- base_url(),
         {:ok, existing} <- Chiezo.collection(base, name) do
      if existing do
        with :ok <- Chiezo.patch(base, name, call(dataset, :shape)) do
          # 範囲を変えたのは人なので、止めている収集でも走らせる（`Chiezo.by_hand/1`）
          case Chiezo.by_hand(fn -> Chiezo.run(base, name, sweep: module.roster_sweep_name()) end) do
            :ok -> :ok
            {:error, reason} -> {:error, {:not_run, reason}}
          end
        end
      else
        {:ok, :not_requested}
      end
    end
  end

  @doc """
  「この区画を先に調べて」を Chiezo へ割り込ませます。

  **定時の巡回の進み具合にも次の予定にも触りません。** 区画を名指しするので、
  その区画には印が付きます —— 先に見てほしいと頼んだのだから、巡回が同じところを
  もう一度見る必要はありません。
  """
  def focus_partition(%{collection: name, survey_sweep: sweep}, key, note) do
    with {:ok, base} <- base_url() do
      # 人が押した 1 回（止めている収集でも走らせる。`Chiezo.by_hand/1`）
      Chiezo.by_hand(fn -> Chiezo.focus(base, name, note, [], sweep, key) end)
    end
  end

  @doc """
  この収集から作る収集（本棚など）を用意します —— **無ければ作り、
  あれば設定を送り直します**。**走らせはしません**（止めた状態で作られます）。

  `choices` は巡回ごとに選んだ相手（親の収集の「収集の設定を更新」と同じ形）。
  """
  def push_derived(dataset, choices \\ %{})

  def push_derived(%{derived: derived}, choices) when not is_nil(derived) do
    with {:ok, base} <- base_url(), do: derived.setup(base, choices)
  end

  def push_derived(_dataset, _choices), do: {:error, :not_requested}

  @doc """
  この収集から作る収集の状態。**まだ依頼していなければ `{:ok, nil}`**（`read/1` と同じ）。
  """
  def read_derived(%{derived: derived}) when not is_nil(derived),
    do: read(%{collection: derived.collection()})

  def read_derived(_dataset), do: {:ok, nil}

  @doc """
  この収集から作る収集に**溜まっているもの**（本棚の本など）。並べる口を持つ
  対象だけ（`list/1`）。持たなければ `{:ok, nil}`。
  """
  def shelf(%{derived: derived}) when not is_nil(derived) do
    Code.ensure_loaded(derived)

    if function_exported?(derived, :list, 1) do
      with {:ok, base} <- base_url(), do: derived.list(base)
    else
      {:ok, nil}
    end
  end

  # **自分に溜まったものを一覧で出す対象**（Pi-hole のドメイン）。本棚と同じ口で読み、
  # 同じ覚え書きに置く
  def shelf(%{listing: listing}) when not is_nil(listing) do
    with {:ok, base} <- base_url(), do: listing.list(base)
  end

  # **溜まったものを読む画面を持つ対象**（レシピ集）。同じ口で読み、同じ覚え書きに置く
  def shelf(%{reading: reading}) when not is_nil(reading) do
    with {:ok, base} <- base_url(), do: reading.list(base)
  end

  def shelf(_dataset), do: {:ok, nil}

  @doc """
  他のアプリが読む対象か（ご当地グルメ・アニメ聖地・食事処。読むのは travel-log）。Chidori で読むものを
  持たない対象がこれ。収集の画面では「他アプリ用」の段（`/collect/apps`）に分けて置く。
  """
  def for_other_app?(dataset), do: not listed?(dataset)

  @doc "その対象の収集の画面の道（他アプリ用は `/collect/apps`、Chidori で読むものは `/collect/datasets`）。"
  def collect_path(dataset),
    do: if(for_other_app?(dataset), do: "/collect/apps", else: "/collect/datasets")

  @doc """
  データ収集の読む画面（`/datasets`）で読む対象か（Pi-hole・レシピ集）。**本棚（技術書）は
  トップページの「技術書」の枠で読む**ので、ここには並べない（収集の画面のデータ収集には並ぶ）。
  """
  def read_on_datasets?(dataset), do: listed?(dataset) and is_nil(dataset[:derived])

  @doc "その対象を読む画面の道（本棚はトップページの枠、ほかはデータ収集の読む画面）。"
  def read_path(%{derived: derived}) when not is_nil(derived), do: "/?panel=books"
  def read_path(dataset), do: "/datasets?view=#{dataset.key}"

  @doc "データ収集の読む画面で最初に開く対象。"
  def default_read_key, do: defined() |> Enum.find(&read_on_datasets?/1) |> Map.fetch!(:key)

  @doc "一覧を持つ対象か（本棚、自分に溜まったものの一覧、または読む画面）。"
  def listed?(dataset),
    do:
      not is_nil(dataset[:derived]) or not is_nil(dataset[:listing]) or
        not is_nil(dataset[:reading])

  @doc """
  選んだ区画を、選んだ巡回で **1 回走らせます**（Chiezo の「選んだ区画で 1 回
  走らせる」と同じ形）。

  **割り込みとは別物です。** あちらは進み具合にも区画の印にも触らないので、
  押しても画面が何も変わらず「何が起きたのか分からない」になります ——
  こちらは**ふつうの回として走る**ので、印が付き、次に読み直せば結果が見えます。

  相手は `backend`（＋ `model`）か `worker` のどちらか。書かなければ巡回の設定のまま。
  """
  def run_partition(%{collection: name}, key, opts \\ []) do
    with {:ok, base} <- base_url() do
      # 人が押した 1 回（止めている収集でも走らせる。`Chiezo.by_hand/1`）
      Chiezo.by_hand(fn -> Chiezo.run(base, name, Keyword.merge(opts, partitions: [key])) end)
    end
  end

  @doc """
  頼みごとを 1 回だけ走らせます（割り込み）。**専用の巡回は置きません** ——
  頼むのは同じ仕事なので、設定も依頼文も整理の回のものでよいためです。
  """
  def focus(%{collection: name, survey_sweep: sweep}, note) do
    with {:ok, base} <- base_url() do
      Chiezo.by_hand(fn -> Chiezo.focus(base, name, note, [], sweep) end)
    end
  end

  @doc """
  空いている欄を埋める 1 回を頼みます（食事処。頼みごとは `Dining.fill_request/3`）。
  **割り込みとして、店を名指しして走らせます** —— 区画を名指ししないので、情報収集の
  進み具合にも区画の印にも触りません。相手は `choice`（`backend:` と `model:`、または
  `worker:`）で、その回だけ選べます。書かなければ情報収集の巡回の設定のまま。
  """
  def fill_blanks(
        %{collection: name, survey_sweep: sweep},
        %{note: note, titles: titles, prompt: prompt},
        choice \\ []
      ) do
    with {:ok, base} <- base_url() do
      # 人が押した 1 回（止めている収集でも走らせる。`Chiezo.by_hand/1`）
      Chiezo.by_hand(fn ->
        Chiezo.focus(base, name, note, titles, sweep, nil, prompt, choice)
      end)
    end
  end

  @doc """
  Chiezo で頼める相手の一覧。引けなければ空（**選べないだけで、画面は出ます**）。
  """
  def backends do
    case base_url() do
      {:ok, base} -> Chiezo.backends(base)
      _unavailable -> []
    end
  end

  @doc """
  Chiezo のルートURL。**未設定ならこの画面は何もできません**（押す前に分かるように、
  理由として返します）。
  """
  def base_url do
    case Chiezo.base_url() do
      nil -> {:error, :chiezo_not_configured}
      base -> {:ok, base}
    end
  end
end
