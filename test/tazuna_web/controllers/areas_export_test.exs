defmodule TazunaWeb.AreasExportTest do
  @moduledoc """
  食事処の全範囲を 1 つの ZIP に書き出す口（`/datasets/areas/travel-log.zip`）。
  見ているのは、**範囲ごとの店が 1 つの `dining/` に入ること**と、
  **範囲が重なったところで同じ店が 2 件にならないこと**です。
  """

  use TazunaWeb.ConnCase, async: false

  alias Tazuna.Datasets.MealAreas

  setup do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

    # 東京駅のあたりで重なった 2 つの範囲
    Tazuna.Repo.insert!(%MealAreas{
      id: 1,
      name: "広い",
      south: 35.6,
      west: 139.7,
      north: 35.75,
      east: 139.85
    })

    Tazuna.Repo.insert!(%MealAreas{
      id: 2,
      name: "狭い",
      south: 35.67,
      west: 139.75,
      north: 35.69,
      east: 139.78
    })

    shop = fn doc_id, title, lat ->
      %{
        "doc_id" => doc_id,
        "title" => title,
        "tags" => ["食事処", "出典:OSM", "ジャンル:和食", "地域:東京都"],
        "extra" => %{"lat" => lat, "lon" => 139.767},
        "opening" => "所在地: 東京都\n定食屋。"
      }
    end

    docs = %{
      # 重なったところの同じ店が、両方の収集に 1 件ずつ居る
      "tazuna_dining_1" => [shop.(10, "だるま食堂", 35.6812), shop.(11, "広いだけの店", 35.7200)],
      "tazuna_dining_2" => [shop.(20, "だるま食堂", 35.6813)]
    }

    Tazuna.HttpStub.stub(fn %{method: :get, url: url} ->
      cond do
        String.contains?(url, "/links") ->
          Tazuna.HttpStub.ok(~s({"links":{}}))

        String.contains?(url, "include_removed") ->
          Tazuna.HttpStub.ok(~s({"results":[],"total":0}))

        true ->
          [_, name] = Regex.run(~r{/v1/(tazuna_dining_\d+)/filter}, url)
          results = docs[name]
          Tazuna.HttpStub.ok(Jason.encode!(%{"results" => results, "total" => length(results)}))
      end
    end)

    :ok
  end

  test "全範囲の店を 1 つの dining/ に入れ、重なったところの同じ店は 1 件にする", %{conn: conn} do
    conn = get(conn, ~p"/datasets/areas/travel-log.zip")

    assert conn.status == 200
    {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
    files = Map.new(files, fn {name, body} -> {to_string(name), body} end)

    csv = files["dining/spots.csv"]
    assert csv =~ "広いだけの店"
    # 先に作った範囲（1）のものだけが残り、もう片方は exclude.txt へ
    assert length(Regex.scan(~r/だるま食堂/u, csv)) == 1
    assert csv =~ ",1-10\r\n"
    assert files["dining/excluded_candidates/exclude.txt"] =~ "2-20"
    assert Map.has_key?(files, "dining/settings.json")
  end
end
