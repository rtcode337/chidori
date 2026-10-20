defmodule Chidori.Datasets.DiningAreas do
  @moduledoc """
  食事処を集める範囲。**範囲 1 つにつき Chiezo の収集が 1 つ**です
  （`Chidori.Datasets.Dining.definition/1`）。

  **離れた場所は別の範囲にします。** 1 つの四角で 2 か所を囲むと、あいだの
  見たくない土地まで区画になって AI が回る。

  範囲は画面で地図に四角を描いて決めます（`ChidoriWeb.DiningAreasLive`）。
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Chidori.Repo

  schema "dining_areas" do
    field(:name, :string)
    field(:south, :float)
    field(:west, :float)
    field(:north, :float)
    field(:east, :float)
    # 情報収集が 1 回に回る区画の数（`set_survey_per_run/2`）
    field(:survey_per_run, :integer, default: 1)

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

  # 情報収集が 1 回に回る区画の数として選べるもの（Chiezo の天井は 5）
  @survey_per_run_choices 1..5

  @doc "情報収集が 1 回に回る区画の数として選べるもの。"
  def survey_per_run_choices, do: Enum.to_list(@survey_per_run_choices)

  @doc """
  情報収集が 1 回に回る区画の数を書き換えます。**重い相手で回すので、区画の数から自動で
  決めさせず、範囲ごとに人が決める**（区画の多い範囲ほど 1 回が重くなっていた）。
  """
  def set_survey_per_run(area, value) do
    area
    |> cast(%{survey_per_run: value}, [:survey_per_run])
    |> validate_inclusion(:survey_per_run, Enum.to_list(@survey_per_run_choices))
    |> Repo.update()
  end

  @doc "1 つの範囲。無ければ nil。"
  def get(id), do: Repo.get(__MODULE__, id)

  @doc "四角（`[南, 西, 北, 東]`。Chiezo の順）。"
  def bbox(%{south: south, west: west, north: north, east: east}), do: [south, west, north, east]

  @doc "真ん中（区画を広げる起点に使う）。"
  def center(%{south: south, west: west, north: north, east: east}),
    do: {(south + north) / 2, (west + east) / 2}

  @doc "範囲の広さの上限（度）。"
  def max_span, do: @max_span

  @doc """
  範囲を作ります。`{:ok, 範囲}` か `{:error, changeset}`。

  **番号は空いているいちばん小さいもの**（範囲の番号は Chiezo の収集の名前
  `chidori_dining_<番号>` になる）。通し番号に任せると、消した範囲の番号が欠けた
  まま残る。**Chiezo に同じ名前の収集が残っている番号は使わない** —— 範囲を外しても
  Chiezo の収集は消さないので、使うと前の範囲の店を引き継ぐ。別の場所で動かしている
  Chidori が作った範囲の収集とも、これでぶつからない。

  Chiezo をつないでいるのに収集の一覧を読めなければ作らない（番号が決められない）。
  `chiezo_names` は Chiezo の収集の名前を返す関数（テストで差し替える）。
  """
  def create(attrs, chiezo_names \\ &chiezo_collection_names/0) do
    changeset = changeset(%__MODULE__{}, attrs)

    with true <- changeset.valid?,
         {:ok, names} <- chiezo_names.() do
      changeset
      |> put_change(:id, free_number(names))
      |> Repo.insert()
    else
      false ->
        {:error, %{changeset | action: :insert}}

      {:error, _reason} ->
        {:error,
         changeset
         |> add_error(:id, "を決められません（Chiezo の収集の一覧を読めませんでした）")
         |> Map.put(:action, :insert)}
    end
  end

  @doc """
  空いているいちばん小さい番号。手元の範囲と、Chiezo に残っている範囲の収集
  （`names` のうち `chidori_dining_<番号>` の形のもの）の両方が使っていないもの。
  """
  def free_number(names) do
    prefix = Chidori.Datasets.Dining.area_collection_prefix()

    remote =
      for name <- names,
          String.starts_with?(name, prefix),
          {n, ""} <- [Integer.parse(String.replace_prefix(name, prefix, ""))],
          do: n

    used = MapSet.new(Repo.all(from(a in __MODULE__, select: a.id)) ++ remote)
    Enum.find(Stream.iterate(1, &(&1 + 1)), &(not MapSet.member?(used, &1)))
  end

  # Chiezo をつないでいなければ、Chiezo に収集は無い（手元の範囲だけで決める）
  defp chiezo_collection_names do
    case Chidori.Datasets.base_url() do
      {:error, :chiezo_not_configured} ->
        {:ok, []}

      {:ok, base} ->
        with {:ok, collections} <- Chidori.Chiezo.collections(base) do
          {:ok, for(%{"name" => name} <- collections, is_binary(name), do: name)}
        end
    end
  end

  @doc """
  Chiezo に残っている範囲の収集から、手元に無い範囲を読み戻し、**四角が違う範囲は
  Chiezo の四角に合わせます**。
  `{:ok, %{restored: 戻した範囲, updated: 四角を合わせた範囲, skipped: 戻せなかった収集の名前}}`
  か `{:error, 理由}`。

  **四角を合わせるのは、Chiezo の画面で区画の範囲を直したとき向け**です。手元が古いままだと、
  設定ページで「定義が違う」と出続け、「収集の設定を更新」を押すと狭いほうへ戻してしまう。
  名前は手元のまま（説明は Chidori が書いたものなので、Chiezo 側で変わる理由が無い）。

  **範囲の正本は手元の表ですが、同じ中身が Chiezo の収集にも載っています** ——
  番号は収集の名前（`chidori_dining_<番号>`）、四角は区画の指定（`partition.bbox`）、
  名前は説明（`shape/1` が書く「（〈名前〉の食事処 / travel-log 向け）」）。
  別の場所で Chidori を動かし直したとき、描き直さずに同じ収集へつなぎ直せる。

  **Chiezo へは何も送りません。** 収集はもう在るので、送ると画面で選んだ相手が
  既定に戻る（`Chidori.Datasets.Dining.shape/1` の注）。

  `collections` は Chiezo の収集の一覧を返す関数（テストで差し替える）。
  """
  def restore(collections \\ &chiezo_collections/0) do
    with {:ok, collections} <- collections.() do
      local = Map.new(Repo.all(__MODULE__), &{&1.id, &1})
      prefix = Chidori.Datasets.Dining.area_collection_prefix()

      candidates =
        for %{"name" => name} = collection when is_binary(name) <- collections,
            String.starts_with?(name, prefix),
            {id, ""} <- [Integer.parse(String.replace_prefix(name, prefix, ""))],
            do: {id, name, collection}

      result =
        candidates
        |> Enum.sort()
        |> Enum.reduce(%{restored: [], updated: [], skipped: []}, fn {id, name, collection},
                                                                     acc ->
          case sync_one(Map.get(local, id), id, collection) do
            {:restored, area} -> Map.update!(acc, :restored, &[area | &1])
            {:updated, area} -> Map.update!(acc, :updated, &[area | &1])
            :same -> acc
            {:error, _reason} -> Map.update!(acc, :skipped, &[name | &1])
          end
        end)

      {:ok, Map.new(result, fn {key, list} -> {key, Enum.reverse(list)} end)}
    end
  end

  defp sync_one(nil, id, collection) do
    with {:ok, area} <- restore_one(id, collection), do: {:restored, area}
  end

  defp sync_one(%__MODULE__{} = area, _id, collection) do
    case get_in(collection, ["partition", "bbox"]) do
      [south, west, north, east] = box ->
        if bbox(area) == box do
          :same
        else
          with {:ok, area} <-
                 __MODULE__.update(area, %{south: south, west: west, north: north, east: east}),
               do: {:updated, area}
        end

      _other ->
        {:error, :unreadable}
    end
  end

  defp restore_one(id, collection) do
    with {:ok, name} <- area_name(collection["description"]),
         [south, west, north, east] <- get_in(collection, ["partition", "bbox"]) do
      %__MODULE__{}
      |> changeset(%{name: name, south: south, west: west, north: north, east: east})
      |> put_change(:id, id)
      |> Repo.insert()
    else
      _other -> {:error, :unreadable}
    end
  end

  # 説明から範囲の名前を読む（`Chidori.Datasets.Dining.shape/1` が書く形）
  defp area_name(description) when is_binary(description) do
    case Regex.run(~r/（(.+)の食事処 \/ travel-log 向け）/u, description) do
      [_, name] -> {:ok, name}
      nil -> {:error, :unreadable}
    end
  end

  defp area_name(_description), do: {:error, :unreadable}

  defp chiezo_collections do
    case Chidori.Datasets.base_url() do
      {:ok, base} -> Chidori.Chiezo.collections(base)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  範囲を直します（名前と四角）。`{:ok, 範囲}` か `{:error, changeset}`。

  **Chiezo へ送るのは呼ぶ側**（`Chidori.Datasets.reshape/1`）。四角が変わったかは
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
    # 同じ番号を同時に 2 つ作ろうとしたとき（空き番号を選ぶのは挿入の手前なので）
    |> unique_constraint(:id, name: :dining_areas_pkey, message: "が重なりました。もう一度作ってください")
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
