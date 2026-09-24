defmodule Tazuna.Datasets.SurveyPlan do
  @moduledoc """
  収集 1 つぶんの「どこから広げるか・情報収集をいつ頼むか」。**利用者が決めることだけ**を持ちます。

  起点（地名と座標）は Chiezo の収集の起点にも送り、ざっと見るも情報収集もそこから
  **放射状に**区画を回ります。区画を選ぶのは Chiezo です（`Tazuna.Datasets.Survey`）。
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Tazuna.Notify.Setting

  schema "survey_plans" do
    field(:collection, :string)
    field(:place, :string, default: "")
    field(:lat, :float)
    field(:lon, :float)
    field(:place_set_at, :utc_datetime)
    field(:run_at, :string, default: "")
    field(:last_run_at, :utc_datetime)
    field(:last_result, :string, default: "")

    timestamps(type: :utc_datetime)
  end

  @fields ~w(collection place lat lon place_set_at run_at last_run_at last_result)a

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, @fields)
    |> validate_required([:collection])
    |> update_change(:place, &String.trim/1)
    |> validate_length(:place, max: 200)
    |> validate_number(:lat, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:lon, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    # 時刻の書き方は要約と同じ（「03:00,15:00」。0300 や 3 も読める）
    |> update_change(:run_at, &Setting.normalize_times/1)
    |> validate_change(:run_at, fn :run_at, text ->
      if Setting.bad_times(text) == [],
        do: [],
        else: [run_at: "時刻は 24 時間制で書いてください（例: 03:00,15:00）"]
    end)
    |> unique_constraint(:collection)
  end

  @doc "頼む時刻（JST の `{時, 分}` を早い順に）。空なら自分からは回らない。"
  def times(%__MODULE__{run_at: text}), do: Setting.times_of(text || "")

  @doc "起点が決まっているか。"
  def placed?(%__MODULE__{lat: lat, lon: lon}), do: is_number(lat) and is_number(lon)
end
