defmodule Tazuna.Datasets.SurveyPlans do
  @moduledoc """
  整理の起点と時刻の読み書き。**持っていない収集には空のもの**を返します
  （画面はそのままフォームに載せる）。
  """

  alias Tazuna.Datasets.SurveyPlan
  alias Tazuna.Repo

  def get(collection) when is_binary(collection) do
    Repo.get_by(SurveyPlan, collection: collection) || %SurveyPlan{collection: collection}
  end

  @doc """
  起点を決めます。**決めた時刻も一緒に控えます** —— それより前に見た区画は
  「まだ見ていない」ものとして扱い、新しい起点から回り直すためです。
  """
  def put_place(collection, %{name: name, lat: lat, lon: lon}) do
    update(collection, %{
      "place" => name,
      "lat" => lat,
      "lon" => lon,
      "place_set_at" => DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  @doc "頼む時刻を書き換えます（空にすれば自分からは回らない）。"
  def put_times(collection, text), do: update(collection, %{"run_at" => text || ""})

  @doc """
  頼んだことを控えます。**走らせる前に控えます**（要約と同じ理由 —— 空くのを
  待っている最中に同じ回の時刻がもう一度来て、二重に起こさないため）。
  控えるのは予定の時刻です。
  """
  def mark_run(collection, %DateTime{} = at),
    do: update(collection, %{"last_run_at" => DateTime.truncate(at, :second)})

  @doc "どう終わったかを控えます（画面に出すため）。"
  def mark_result(collection, text) when is_binary(text),
    do: update(collection, %{"last_result" => text})

  defp update(collection, attrs) do
    collection
    |> get()
    |> SurveyPlan.changeset(Map.put(attrs, "collection", collection))
    |> Repo.insert_or_update()
  end
end
