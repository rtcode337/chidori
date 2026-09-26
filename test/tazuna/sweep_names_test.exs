defmodule Tazuna.SweepNamesTest do
  @moduledoc """
  巡回の名前は `Tazuna.SweepNames` の語彙から選ぶ。**収集ごとに新しい名前を作らない**
  —— 同じ仕事の回が別の名前で並ぶと、画面でも変更履歴でも同じ仕事だと読めない。
  """

  use ExUnit.Case, async: true

  alias Tazuna.SweepNames

  defp names_of(sweeps), do: Enum.map(sweeps, &(&1[:name] || &1["name"]))

  test "どの収集の巡回も、語彙の名前だけを使う" do
    topics = Tazuna.Topics.defined()

    all =
      Enum.flat_map(topics, fn topic ->
        topic |> Map.put(:interests, ["LLM"]) |> Tazuna.News.sweeps() |> names_of()
      end) ++
        Enum.flat_map(topics, &(Tazuna.Themes.sweeps(&1) |> names_of())) ++
        names_of(Tazuna.Datasets.Books.sweeps()) ++
        names_of(Tazuna.Datasets.Bookshelf.sweeps()) ++
        names_of(Tazuna.Datasets.Meals.sweeps())

    for name <- Enum.uniq(all) do
      assert name in SweepNames.all(), "語彙に無い巡回の名前: #{name}"
    end
  end
end
