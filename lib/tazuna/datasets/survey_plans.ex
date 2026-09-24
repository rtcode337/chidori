defmodule Tazuna.Datasets.SurveyPlans do
  @moduledoc """
  起点と情報収集の時刻の読み書き。**持っていない収集には空のもの**を返します
  （画面はそのままフォームに載せる）。
  """

  alias Tazuna.Datasets.SurveyPlan
  alias Tazuna.Repo

  @doc """
  その収集の起点と時刻。`default`（`%{name, lat, lon}`）を渡すと、**起点を決めて
  いなければそれを入れて返します**（保存はしない。決めた時刻も空のまま）。
  """
  def get(collection, default \\ nil) when is_binary(collection) do
    plan = Repo.get_by(SurveyPlan, collection: collection) || %SurveyPlan{collection: collection}

    case default do
      %{name: name, lat: lat, lon: lon} ->
        if SurveyPlan.placed?(plan), do: plan, else: %{plan | place: name, lat: lat, lon: lon}

      _none ->
        plan
    end
  end

  @doc """
  起点を決めます。**決めた時刻も一緒に控えます**（画面に「いつ決めたか」を出す）。
  Chiezo へ送るのは `Tazuna.Datasets.put_origin/2` の仕事です。
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
