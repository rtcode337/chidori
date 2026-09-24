defmodule Tazuna.Datasets do
  @moduledoc """
  データ収集の対象（「データ収集」の画面のタブ）。

  **対象は tazuna の機能で、利用者のデータではありません。** 最新情報の「話題」や
  関連図の「人物」「画家」と同じ立ち位置で、集め方も引く先も対象ごとに違う ——
  だから**定義はコードに置きます**（`defined/0`）。足すときはここへ 1 つ書けば、
  タブも依頼も増えます。

  **ここに置くのは、どの対象でも同じ手順だけ**です（読む・送る・割り込む）。
  何を集めるかの指定と依頼文は対象の側（`Tazuna.Datasets.Meals` など）が持ちます。

  **tazuna は収集の設定を覚えません。** 正は Chiezo が持っているもので、画面は
  それを読んで見せているだけ —— 写しを置くと、どちらが本物か言えなくなります。
  """

  alias Tazuna.Chiezo
  alias Tazuna.Datasets.Books
  alias Tazuna.Datasets.Meals

  @doc """
  tazuna が持っている収集の対象。**この並びがタブの並び**。
  """
  def defined, do: [Meals.definition(), Books.definition()]

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
  断られるので、それだけだと tazuna 側で依頼文や区画を直しても永遠に届きません。
  """
  def push(%{module: module, collection: name}, choices \\ %{}) do
    attrs = module.attrs(choices)

    with {:ok, base} <- base_url(),
         {:ok, existing} <- Chiezo.collection(base, name) do
      if existing, do: Chiezo.patch(base, name, attrs), else: Chiezo.request(base, attrs)
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
      Chiezo.focus(base, name, note, [], sweep, key)
    end
  end

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
      Chiezo.run(base, name, Keyword.merge(opts, partitions: [key]))
    end
  end

  @doc """
  頼みごとを 1 回だけ走らせます（割り込み）。**専用の巡回は置きません** ——
  頼むのは同じ仕事なので、設定も依頼文も整理の回のものでよいためです。
  """
  def focus(%{collection: name, survey_sweep: sweep}, note) do
    with {:ok, base} <- base_url() do
      Chiezo.focus(base, name, note, [], sweep)
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
