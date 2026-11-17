defmodule Chidori.Datasets.SurveySetting do
  @moduledoc """
  情報収集・漏れ探しを起こす時計（`Chidori.Datasets.SurveyClock`）の設定と、
  時計が最後に起こした記録（表 `dining_survey_settings`。**収集と巡回の組ごとに 1 行**。
  表の名前は食事処の情報収集だけが使っていた頃のまま）。

  **時刻は収集と巡回の組ごとに決めます。** 1 回十分ほどかかる回なので、全部を同じ時刻に
  起こすと組の数だけ並び、取り込みをその間ずっと占める（6 つで 1 時間）。巡回を省いたときは
  情報収集の行を読み書きする。

  **起こす時刻は Chidori ごとに決め、既定は空（起こさない）です。** 時計は Chidori の中に
  あるので、本番とテストの 2 つを立てていると、どちらも同じ回を起こします。時刻を書いた
  Chidori だけが起こす（映画の引き継ぎの時刻と同じ書き方。`Chidori.Notify.Setting.times_of/1`）。

  **記録も DB に持ちます。** 受け持った予定と起こせたかを持たないと、立ち上げ直したときに
  同じ予定でもう一度起こす（重い相手で回すので、二重に起こすとそのぶん枠を使う）。
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Chidori.Notify.Setting
  alias Chidori.Repo
  alias Chidori.SweepNames

  schema "dining_survey_settings" do
    field(:collection, :string, default: "")
    # 起こす巡回の名前（`Chidori.SweepNames`。今ある行は情報収集）
    field(:sweep, :string, default: "情報収集")
    field(:run_at, :string, default: "")
    # 時計が最後に受け持った予定の時刻と、その予定で起こせたか
    field(:slot_at, :utc_datetime)
    field(:slot_ok, :boolean, default: false)
    field(:last_at, :utc_datetime)
    field(:last_result, :string)

    timestamps(type: :utc_datetime)
  end

  @doc "その収集（Chiezo の収集の名前）の巡回の設定と記録（まだ無ければ既定の値）。"
  def get(collection, sweep \\ SweepNames.survey()) do
    Repo.one(from(s in __MODULE__, where: s.collection == ^collection and s.sweep == ^sweep)) ||
      %__MODULE__{collection: collection, sweep: sweep}
  rescue
    # 表がまだ無い（マイグレーションの前）ときも画面は出す
    _error in [Postgrex.Error, DBConnection.ConnectionError, DBConnection.OwnershipError] ->
      %__MODULE__{collection: collection, sweep: sweep}
  end

  @doc "起こす時刻（JST の `{時, 分}` を早い順に）。空なら起こさない。"
  def times(%__MODULE__{run_at: text}), do: Setting.times_of(text || "")

  @doc "その収集の巡回の時刻を書き換えます。**読めない時刻は断ります**。"
  def put(collection, sweep \\ SweepNames.survey(), attrs) do
    collection
    |> get(sweep)
    |> cast(attrs, [:run_at])
    |> update_change(:run_at, &Setting.normalize_times/1)
    |> validate_change(:run_at, fn :run_at, text ->
      if Setting.bad_times(text) == [],
        do: [],
        else: [run_at: "時刻は 24 時間制で書いてください（例: 04:00,16:00）"]
    end)
    |> Repo.insert_or_update()
  end

  @doc "予定 `slot` で起こしに行った結果を残します（`ok?` は起こせたか・止めてあったか）。"
  def record(collection, sweep \\ SweepNames.survey(), slot, ok?, result) do
    collection
    |> get(sweep)
    |> change(
      slot_at: slot,
      slot_ok: ok?,
      last_at: DateTime.utc_now() |> DateTime.truncate(:second),
      last_result: result
    )
    |> Repo.insert_or_update()
  end
end
