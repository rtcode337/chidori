defmodule Tazuna.CollectPace do
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
  """

  import Ecto.Changeset

  alias Tazuna.Chiezo
  alias Tazuna.Repo
  alias Tazuna.SweepNames

  defmodule Setting do
    @moduledoc false
    use Ecto.Schema

    schema "collect_paces" do
      field(:kind, :string)
      field(:minutes, :integer)

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

  @doc "保存してある間隔を読み込みます（起動時）。**読めなければ既定のまま**。"
  def load_all do
    for %Setting{kind: kind, minutes: minutes} <- Repo.all(Setting),
        kind in Enum.map(kinds(), &to_string/1) do
      :persistent_term.put({__MODULE__, String.to_existing_atom(kind)}, minutes)
    end

    :ok
  rescue
    _error -> :ok
  end

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
  いまの間隔を Chiezo に送ります。**tazuna が頼んだ収集のうち、その名前の巡回を
  持つものだけ**に送ります（時計を持たない巡回には送らない）。

  返すのは `%{sent: [{収集, 巡回}], failed: [{収集, 巡回, 理由}]}`。
  1 つ断られても残りは送ります（止めてある収集もあるので、全部通るとは限らない）。
  """
  def apply(base) do
    with {:ok, collections} <- Chiezo.collections(base) do
      results =
        for collection <- collections,
            Tazuna.CollectOverview.ours?(collection),
            sweep <- collection["sweeps"] || [],
            sweep["on_demand"] != true,
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
