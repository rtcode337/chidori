defmodule Chidori.Relations.Settings do
  @moduledoc """
  関連図ごとの設定（表 `relation_settings`）。いまは**名簿の知名度の下限**だけです。

  芸能人の図はカテゴリだけで 3 万人に届くので、Wikipedia の月の閲覧数で切ってから
  AI に回します。**落ち着いたら下げて広げる**ためのつまみで、Chiezo に送る設定
  （`Chidori.Relations.People.extract/1`）に載ります。図の画面からも設定画面からも
  送るので、どこから送っても同じ値になるよう Chidori に持ちます。
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Chidori.Repo

  # 始めの下限。**約 3,000 人**になる（俳優・歌手・タレント・お笑い芸人の合計。実測）
  @default_min_pageviews 10_000

  # 画面で選べる下限（広げる向き）
  @choices [30_000, 10_000, 5_000, 3_000, 1_000]

  schema "relation_settings" do
    field(:view, :string)
    field(:min_pageviews, :integer)

    timestamps(type: :utc_datetime)
  end

  @doc "選べる下限。"
  def choices, do: @choices

  @doc "始めの下限。"
  def default_min_pageviews, do: @default_min_pageviews

  @doc "その図の名簿の知名度の下限（月の閲覧数）。"
  def min_pageviews(view) do
    case Repo.get_by(__MODULE__, view: view) do
      %{min_pageviews: value} -> value
      nil -> @default_min_pageviews
    end
  rescue
    # 表がまだ無い（マイグレーションの前）ときも図は出す
    _error in [Postgrex.Error, DBConnection.ConnectionError, DBConnection.OwnershipError] ->
      @default_min_pageviews
  end

  @doc "下限を書き換えます。"
  def put_min_pageviews(view, value) when is_integer(value) and value > 0 do
    (Repo.get_by(__MODULE__, view: view) || %__MODULE__{view: view})
    |> cast(%{min_pageviews: value}, [:min_pageviews])
    |> validate_number(:min_pageviews, greater_than: 0)
    |> Repo.insert_or_update()
  end
end
