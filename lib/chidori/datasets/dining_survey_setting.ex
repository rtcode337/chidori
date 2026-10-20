defmodule Chidori.Datasets.DiningSurveySetting do
  @moduledoc """
  食事処の情報収集を起こす時計（`Chidori.Datasets.DiningSurvey`）の設定と、
  時計が最後に起こした記録（表 `dining_survey_settings`。1 行だけ）。

  **起こす時刻は Chidori ごとに決め、既定は空（起こさない）です。** 時計は Chidori の中に
  あるので、本番とテストの 2 つを立てていると、どちらも同じ回を起こします。時刻を書いた
  Chidori だけが起こす（映画の引き継ぎの時刻と同じ書き方。`Chidori.Notify.Setting.times_of/1`）。

  **記録も DB に持ちます。** 予定ごとに起こし終えた収集を持たないと、立ち上げ直したときに
  同じ予定でもう一度起こす（情報収集は重い相手で回すので、二重に起こすとそのぶん枠を使う）。
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Chidori.Notify.Setting
  alias Chidori.Repo

  schema "dining_survey_settings" do
    field(:run_at, :string, default: "")
    field(:slot_at, :utc_datetime)
    field(:done, {:array, :string}, default: [])
    field(:last_at, :utc_datetime)
    field(:last_result, :string)

    timestamps(type: :utc_datetime)
  end

  @doc "今の設定と記録（まだ無ければ既定の値）。"
  def get do
    Repo.one(__MODULE__) || %__MODULE__{}
  rescue
    # 表がまだ無い（マイグレーションの前）ときも画面は出す
    _error in [Postgrex.Error, DBConnection.ConnectionError, DBConnection.OwnershipError] ->
      %__MODULE__{}
  end

  @doc "起こす時刻（JST の `{時, 分}` を早い順に）。空なら起こさない。"
  def times(%__MODULE__{run_at: text}), do: Setting.times_of(text || "")

  @doc "時刻を書き換えます。**読めない時刻は断ります**。"
  def put(attrs) do
    get()
    |> cast(attrs, [:run_at])
    |> update_change(:run_at, &Setting.normalize_times/1)
    |> validate_change(:run_at, fn :run_at, text ->
      if Setting.bad_times(text) == [],
        do: [],
        else: [run_at: "時刻は 24 時間制で書いてください（例: 04:00,16:00）"]
    end)
    |> Repo.insert_or_update()
  end

  @doc """
  予定 `slot` で起こし終えた収集（`done`）と、その回の結果の一言を残します。
  予定が変われば、起こし終えた収集は数え直す。
  """
  def record(slot, done, result) do
    setting = get()
    before = if setting.slot_at == slot, do: setting.done || [], else: []

    setting
    |> change(
      slot_at: slot,
      done: Enum.uniq(before ++ done),
      last_at: DateTime.utc_now() |> DateTime.truncate(:second),
      last_result: result
    )
    |> Repo.insert_or_update()
  end
end
