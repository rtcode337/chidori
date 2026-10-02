defmodule Tazuna.Datasets.MealAreas do
  @moduledoc """
  食事処を集める範囲。**範囲 1 つにつき Chiezo の収集が 1 つ**です
  （`Tazuna.Datasets.Meals.definition/1`）。

  **離れた場所は別の範囲にします。** 1 つの四角で 2 か所を囲むと、あいだの
  見たくない土地まで区画になって AI が回る。

  範囲は画面で地図に四角を描いて決めます（`TazunaWeb.MealAreasLive`）。
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Tazuna.Repo

  schema "meal_areas" do
    field(:name, :string)
    field(:south, :float)
    field(:west, :float)
    field(:north, :float)
    field(:east, :float)

    timestamps(type: :utc_datetime)
  end

  # 1 つの範囲の広さの上限（度）。**広すぎる範囲は日本全体と同じことになる** ——
  # 区画が増えて一周のめどが立たなくなる。0.5 度はおよそ 45〜55 km 四方
  @max_span 0.5

  @doc "範囲の一覧（作った順）。読めなければ空。"
  def list do
    __MODULE__ |> order_by(:id) |> Repo.all()
  rescue
    _error -> []
  end

  @doc "1 つの範囲。無ければ nil。"
  def get(id), do: Repo.get(__MODULE__, id)

  @doc "四角（`[南, 西, 北, 東]`。Chiezo の順）。"
  def bbox(%{south: south, west: west, north: north, east: east}), do: [south, west, north, east]

  @doc "真ん中（起点の既定に使う）。"
  def center(%{south: south, west: west, north: north, east: east}),
    do: {(south + north) / 2, (west + east) / 2}

  @doc "範囲の広さの上限（度）。"
  def max_span, do: @max_span

  @doc """
  範囲を作ります。`{:ok, 範囲}` か `{:error, changeset}`。
  """
  def create(attrs), do: %__MODULE__{} |> changeset(attrs) |> Repo.insert()

  @doc """
  範囲を直します（名前と四角）。`{:ok, 範囲}` か `{:error, changeset}`。

  **Chiezo へ送るのは呼ぶ側**（`Tazuna.Datasets.reshape/1`）。四角が変わったかは
  `box_changed?/2` で見る —— 名前を直しただけで機械収集から走らせ直すことはない。
  """
  def update(%__MODULE__{} = area, attrs), do: area |> changeset(attrs) |> Repo.update()

  @doc "四角が変わったか。"
  def box_changed?(before, changed), do: bbox(before) != bbox(changed)

  @doc """
  範囲を外します。**Chiezo の収集は消しません** —— 溜めたものを消すかは Chiezo の
  画面で決める（取り消せないため）。
  """
  def delete(%__MODULE__{} = area), do: Repo.delete(area)

  def changeset(area, attrs) do
    area
    |> cast(attrs, [:name, :south, :west, :north, :east])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :south, :west, :north, :east],
      message: "を入れてください"
    )
    |> validate_length(:name, max: 20)
    |> validate_number(:south, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:north, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:west, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> validate_number(:east, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> validate_box()
    |> unique_constraint(:name, message: "はもう使われています")
  end

  defp validate_box(changeset) do
    south = get_field(changeset, :south)
    west = get_field(changeset, :west)
    north = get_field(changeset, :north)
    east = get_field(changeset, :east)

    cond do
      Enum.any?([south, west, north, east], &is_nil/1) ->
        changeset

      not (south < north and west < east) ->
        add_error(changeset, :north, "は南より北、西より東にしてください")

      north - south > @max_span or east - west > @max_span ->
        add_error(changeset, :north, "範囲が広すぎます（縦横とも #{@max_span} 度まで）")

      true ->
        changeset
    end
  end
end
