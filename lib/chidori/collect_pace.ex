defmodule Chidori.CollectPace do
  @moduledoc """
  巡回の間隔。**どの収集にも共通の速さ**を、設定ページ（「Chiezo 収集」）から変えます。

  | 種類 | 巡回 | 既定 |
  |---|---|---|
  | `:tidy` | 整理（どの収集も） | 12 時間 |
  | `:scan` | ざっと見る（関連図・食事処） | 2 時間 |

  **枠の減り方と回復の速さを釣り合わせるためのつまみ**です。整理はほぼ 1 つの相手が
  引き受けていて、6 時間ごとにしていた頃は、その 7 日枠が回復より速く減った。
  どこまで延ばせばよいかは枠の減り方で決まり、その減り方は相手や集めるものの量で
  変わるので、コードに書かずに画面から変えられるようにしてある。

  **区画を回る巡回は、一周の日数も同じ比で伸ばします**（`days/2`）。Chiezo は
  一周の日数から 1 回に見る区画の数を逆算するので、間隔だけ延ばすと 1 回の区画が
  増えるだけで、呼ぶ回数（使う枠）が変わらない。

  **値は起動時と保存時に読み込んで持ちます**（`:persistent_term`）。巡回を組むたびに
  DB を引かないためで、**読み込んでいなければ既定の間隔**を返します。

  **保存したら Chiezo にも送ります**（`apply/1`）。送るのは巡回の間隔だけで、
  画面で選んだ相手や依頼文には触りません（Chiezo の `PATCH …/sweeps/{sweep}`）。

  ## 整理を自動で回さない収集

  **AI の枠を節約したい収集は、整理だけを自動で回さないようにできます**
  （`stop_tidy/3`）。巡回は消さずに Chiezo の時計だけを外す（`by_caller`）ので、
  割り込みや travel-log からの依頼の行き先としては今までどおり走ります。

  **選んだものは Chidori が覚えて、収集の設定を送るたびに載せ直します**
  （`with_stops/2`。`Chidori.Chiezo.request/2` と `patch/3` が通す）—— 各画面の
  「収集の設定を更新」は巡回を並びごと送るので、載せないと時計が戻る。
  """

  import Ecto.Changeset

  alias Chidori.Chiezo
  alias Chidori.Repo
  alias Chidori.SweepNames

  defmodule Setting do
    @moduledoc false
    use Ecto.Schema

    schema "collect_paces" do
      field(:kind, :string)
      field(:minutes, :integer)

      timestamps(type: :utc_datetime)
    end
  end

  defmodule TidyStop do
    @moduledoc false
    use Ecto.Schema

    schema "tidy_stops" do
      field(:collection, :string)

      timestamps(type: :utc_datetime)
    end
  end

  # 選べる間隔（分）。**自由入力にしない** —— 3 時間半のような半端な値は、
  # 待ち行列を読むときに「何がどの間隔で回っているか」を読みにくくする
  @kinds [
    tidy: %{default: 720, choices: [360, 480, 720, 1440, 2880]},
    scan: %{default: 120, choices: [60, 120, 180, 240, 360, 720]}
  ]

  @doc "変えられる種類（並びが画面の並び）。"
  def kinds, do: Keyword.keys(@kinds)

  @doc "その種類の巡回の名前（Chiezo の巡回の名前と同じ）。"
  def sweep_name(:tidy), do: SweepNames.tidy()
  def sweep_name(:scan), do: SweepNames.scan()

  @doc "既定の間隔（分）。"
  def default(kind), do: @kinds[kind].default

  @doc "選べる間隔（分）。"
  def choices(kind), do: @kinds[kind].choices

  @doc "いまの間隔（分）。読み込んでいなければ既定。"
  def minutes(kind) when kind in [:tidy, :scan],
    do: :persistent_term.get({__MODULE__, kind}, default(kind))

  @doc """
  一周の日数。**既定の間隔のときの日数を渡すと、いまの間隔に合わせて伸ばします**
  （1 回に見る区画の数を変えないため）。
  """
  def days(kind, days_at_default) do
    max(round(days_at_default * minutes(kind) / default(kind)), 1)
  end

  @doc """
  保存してある間隔と、整理を自動で回さない収集を読み込みます（起動時）。
  **読めなければ既定のまま**。
  """
  def load_all do
    for %Setting{kind: kind, minutes: minutes} <- Repo.all(Setting),
        kind in Enum.map(kinds(), &to_string/1) do
      :persistent_term.put({__MODULE__, String.to_existing_atom(kind)}, minutes)
    end

    stops = TidyStop |> Repo.all() |> MapSet.new(& &1.collection)
    :persistent_term.put({__MODULE__, :tidy_stops}, stops)
    :ok
  rescue
    _error -> :ok
  end

  @doc "整理を自動で回さない収集か。読み込んでいなければ「回す」。"
  def tidy_stopped?(collection), do: MapSet.member?(tidy_stops(), collection)

  defp tidy_stops, do: :persistent_term.get({__MODULE__, :tidy_stops}, MapSet.new())

  @doc """
  整理を自動で回すか決めます（`stop?` が true で回さない）。**保存してから Chiezo へ
  送ります**（`base` が nil なら保存だけ）。

  返すのは `:ok`、`{:ok, :not_sent}`（保存したが送れなかった。次に「収集の設定を
  更新」を押せば載る）、`{:error, 理由}`（保存できなかった）。
  """
  def stop_tidy(collection, stop?, base) when is_binary(collection) and is_boolean(stop?) do
    with :ok <- save_stop(collection, stop?) do
      case base && Chiezo.set_sweep_by_caller(base, collection, SweepNames.tidy(), stop?) do
        :ok -> :ok
        # 整理を持たない収集・まだ作っていない収集は、送る先が無いだけ
        {:error, :not_found} -> :ok
        _not_sent -> {:ok, :not_sent}
      end
    end
  end

  defp save_stop(collection, true) do
    %TidyStop{collection: collection}
    |> Ecto.Changeset.change()
    |> Repo.insert(on_conflict: :nothing, conflict_target: :collection)
    |> case do
      {:ok, _row} ->
        :persistent_term.put({__MODULE__, :tidy_stops}, MapSet.put(tidy_stops(), collection))
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp save_stop(collection, false) do
    import Ecto.Query
    Repo.delete_all(from(t in TidyStop, where: t.collection == ^collection))
    :persistent_term.put({__MODULE__, :tidy_stops}, MapSet.delete(tidy_stops(), collection))
    :ok
  end

  @doc """
  送る設定に、整理を自動で回さないことを載せます（`by_caller: true`）。巡回を
  持たない設定や、止めていない収集はそのまま返します。
  """
  def with_stops(collection, %{} = attrs) do
    key = if Map.has_key?(attrs, :sweeps), do: :sweeps, else: "sweeps"

    case Map.get(attrs, key) do
      sweeps when is_list(sweeps) and is_binary(collection) ->
        if tidy_stopped?(collection),
          do: Map.put(attrs, key, Enum.map(sweeps, &stop_if_tidy/1)),
          else: attrs

      _none ->
        attrs
    end
  end

  def with_stops(_collection, attrs), do: attrs

  defp stop_if_tidy(%{} = sweep) do
    name = sweep[:name] || sweep["name"]
    key = if Map.has_key?(sweep, "name"), do: "by_caller", else: :by_caller
    if name == SweepNames.tidy(), do: Map.put(sweep, key, true), else: sweep
  end

  defp stop_if_tidy(sweep), do: sweep

  @doc """
  間隔を保存します。**選べる値のほかは断ります**（`{:error, :not_a_choice}`）。
  """
  def put(kind, minutes) when is_integer(minutes) do
    if minutes in choices(kind) do
      row = Repo.get_by(Setting, kind: to_string(kind)) || %Setting{kind: to_string(kind)}

      with {:ok, _saved} <-
             row
             |> cast(%{minutes: minutes}, [:minutes])
             |> Repo.insert_or_update() do
        :persistent_term.put({__MODULE__, kind}, minutes)
        :ok
      end
    else
      {:error, :not_a_choice}
    end
  end

  @doc """
  いまの間隔を Chiezo に送ります。**Chidori が頼んだ収集のうち、その名前の巡回を
  持つものだけ**に送ります（時計を持たない巡回には送らない）。

  返すのは `%{sent: [{収集, 巡回}], failed: [{収集, 巡回, 理由}]}`。
  1 つ断られても残りは送ります（止めてある収集もあるので、全部通るとは限らない）。
  """
  def apply(base) do
    with {:ok, collections} <- Chiezo.collections(base) do
      results =
        for collection <- collections,
            Chidori.CollectOverview.ours?(collection),
            sweep <- collection["sweeps"] || [],
            sweep["on_demand"] != true,
            # 時計を外した巡回（整理を自動で回さない収集など）には、間隔を送っても断られる
            sweep["by_caller"] != true,
            kind <- kinds(),
            sweep["name"] == sweep_name(kind) do
          name = collection["name"]

          case Chiezo.set_sweep_clock(base, name, sweep["name"], minutes(kind)) do
            :ok -> {:sent, {name, sweep["name"]}}
            {:error, reason} -> {:failed, {name, sweep["name"], reason}}
          end
        end

      {:ok,
       %{
         sent: for({:sent, one} <- results, do: one),
         failed: for({:failed, one} <- results, do: one)
       }}
    end
  end

  @doc "間隔の言い方（「12 時間」「2 日」「30 分」）。"
  def label(minutes) when rem(minutes, 1440) == 0, do: "#{div(minutes, 1440)} 日"
  def label(minutes) when rem(minutes, 60) == 0, do: "#{div(minutes, 60)} 時間"
  def label(minutes), do: "#{minutes} 分"
end
