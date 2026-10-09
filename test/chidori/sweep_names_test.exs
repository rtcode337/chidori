defmodule Chidori.SweepNamesTest do
  @moduledoc """
  巡回の名前は `Chidori.SweepNames` の語彙から選ぶ。**収集ごとに新しい名前を作らない**
  —— 同じ仕事の回が別の名前で並ぶと、画面でも変更履歴でも同じ仕事だと読めない。
  """

  use ExUnit.Case, async: true

  alias Chidori.SweepNames

  defp names_of(sweeps), do: Enum.map(sweeps, &(&1[:name] || &1["name"]))

  test "どの収集の巡回も、語彙の名前だけを使う" do
    topics = Chidori.Topics.defined()

    all =
      Enum.flat_map(topics, fn topic ->
        topic |> Map.put(:interests, ["LLM"]) |> Chidori.News.sweeps() |> names_of()
      end) ++
        Enum.flat_map(topics, &(Chidori.Themes.sweeps(&1) |> names_of())) ++
        names_of(Chidori.Datasets.Books.sweeps()) ++
        names_of(Chidori.Datasets.Bookshelf.sweeps()) ++
        names_of(Chidori.Datasets.Dining.sweeps(%{id: 1}))

    for name <- Enum.uniq(all) do
      assert name in SweepNames.all(), "語彙に無い巡回の名前: #{name}"
    end
  end
end
