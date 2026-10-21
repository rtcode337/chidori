defmodule Chidori.DatasetsTabsTest do
  @moduledoc """
  データ収集のタブの並び（`Chidori.Datasets.tabs/1`）。前に出すのは技術書・食事処・ご当地グルメで、
  残りは定義の順。食事処は範囲がいくつあってもタブ 1 つ。
  """

  use ExUnit.Case, async: true

  alias Chidori.Datasets

  test "技術書・食事処・ご当地グルメを前に、残りを定義の順に並べる（食事処の範囲はまとめて 1 つ）" do
    datasets = [
      %{key: "books"},
      %{key: "pihole"},
      %{key: "recipes"},
      %{key: "gourmet"},
      %{key: "anime"},
      %{key: "dining_1", area: %{}},
      %{key: "dining_2", area: %{}}
    ]

    keys = Enum.map(Datasets.tabs(datasets), &if(&1 == :dining, do: :dining, else: &1.key))
    assert keys == ["books", :dining, "gourmet", "pihole", "recipes", "anime"]
  end
end
