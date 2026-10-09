defmodule Tazuna.ChiezoPlacesTest do
  @moduledoc """
  地名で探す（`Tazuna.Chiezo.places/2`。区画の地図と、範囲を描く地図が使う）。

  **「〇〇駅」は「駅」を外した語でも探し、駅を先に並べる。** 地図辞典（OSM）は駅名に
  「駅」を付けない決まりで、本物の東京駅は「東京」として入っている —— 「東京駅」で
  引けたのは、名前に「駅」の付いた別のもの（日光の模型）だった。
  """

  use ExUnit.Case, async: false

  alias Tazuna.Chiezo
  alias Tazuna.HttpStub

  @base "http://chiezo.test"

  # 見出し → 地物
  @docs %{
    "東京駅" => %{"area" => "栃木県", "feature" => "tourism=artwork", "lat" => 36.8, "lon" => 139.7},
    "東京" => %{"area" => "東京都", "feature" => "railway=station", "lat" => 35.681, "lon" => 139.767},
    "東京都" => %{"area" => "東京都", "feature" => "place=state", "lat" => 35.68, "lon" => 139.69}
  }

  setup do
    HttpStub.stub(fn %{url: url} ->
      %{path: path, query: query} = URI.parse(url)
      params = URI.decode_query(query || "")

      cond do
        String.ends_with?(path, "/search") ->
          titles =
            case params["q"] do
              "東京駅" -> ["東京駅"]
              "東京" -> ["東京", "東京都"]
              _other -> []
            end

          HttpStub.ok(Jason.encode!(%{"results" => Enum.map(titles, &%{"title" => &1})}))

        String.ends_with?(path, "/doc") ->
          title = params["title"]
          HttpStub.ok(Jason.encode!(%{"title" => title, "extra" => @docs[title]}))
      end
    end)

    :ok
  end

  test "「〇〇駅」で探すと、本物の駅が先に来る" do
    {:ok, [first | rest]} = Chiezo.places(@base, "東京駅")

    assert {first.name, first.area, first.feature} == {"東京", "東京都", "railway=station"}

    # 名前に「駅」の付いた別のものも、後ろに残す（それを探していることもある）
    assert Enum.any?(rest, &(&1.feature == "tourism=artwork"))
  end

  test "「駅」を外した語で引いたものは、駅だけを残す（区や都は並べない）" do
    {:ok, places} = Chiezo.places(@base, "東京駅")

    refute Enum.any?(places, &(&1.feature == "place=state"))
  end

  test "「駅」で終わらない語は、そのまま探す" do
    {:ok, places} = Chiezo.places(@base, "東京")

    assert Enum.map(places, & &1.feature) == ["railway=station", "place=state"]
  end
end
