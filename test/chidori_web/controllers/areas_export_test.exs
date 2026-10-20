defmodule ChidoriWeb.AreasExportTest do
  @moduledoc """
  食事処の全範囲を 1 つの ZIP に書き出す口（`/datasets/areas/travel-log.zip`）。
  見ているのは、**範囲ごとの店が 1 つの `dining/` に入ること**と、
  **範囲が重なったところで同じ店が 2 件にならないこと**です。
  """

  use ChidoriWeb.ConnCase, async: false

  alias Chidori.Datasets.DiningAreas

  setup do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

    # 東京駅のあたりで重なった 2 つの範囲
    Chidori.Repo.insert!(%DiningAreas{
      id: 1,
      name: "広い",
      south: 35.6,
      west: 139.7,
      north: 35.75,
      east: 139.85
    })

    Chidori.Repo.insert!(%DiningAreas{
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
      "chidori_dining_1" => [shop.(10, "だるま食堂", 35.6812), shop.(11, "広いだけの店", 35.7200)],
      "chidori_dining_2" => [shop.(20, "だるま食堂", 35.6813)]
    }

    Chidori.HttpStub.stub(fn %{method: :get, url: url} ->
      cond do
        String.contains?(url, "/links") ->
          Chidori.HttpStub.ok(~s({"links":{}}))

        String.contains?(url, "include_removed") ->
          Chidori.HttpStub.ok(~s({"results":[],"total":0}))

        true ->
          [_, name] = Regex.run(~r{/v1/(chidori_dining_\d+)/filter}, url)
          results = docs[name]
          Chidori.HttpStub.ok(Jason.encode!(%{"results" => results, "total" => length(results)}))
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
    # ふだんは travel-log 側のシリーズの見た目を残してもらう
    assert Jason.decode!(files["dining/settings.json"])["keep_series_styles"] == true
  end

  test "?styles=replace のときだけ、シリーズの見た目も上書きさせる", %{conn: conn} do
    # 色の決め方を変えたあとに、既にあるシリーズの色まで入れ替えるための 1 回きりの道
    conn = get(conn, ~p"/datasets/areas/travel-log.zip?styles=replace")

    assert conn.status == 200
    {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
    files = Map.new(files, fn {name, body} -> {to_string(name), body} end)
    assert Jason.decode!(files["dining/settings.json"])["keep_series_styles"] == false
  end

  test "1 つの範囲の ZIP では、?styles=replace を付けてもシリーズの見た目を上書きさせない", %{conn: conn} do
    # travel-log の食事処は範囲で分かれていないので、1 つの範囲のシリーズだけで見た目を
    # 置き換えると、ほかの範囲の見た目が壊れる（上書きは全範囲の ZIP からだけ）
    conn = get(conn, ~p"/datasets/dining-1/travel-log.zip?styles=replace")

    assert conn.status == 200
    {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
    files = Map.new(files, fn {name, body} -> {to_string(name), body} end)

    settings =
      Enum.find_value(files, fn {name, body} ->
        String.ends_with?(name, "settings.json") && body
      end)

    assert Jason.decode!(settings)["keep_series_styles"] == true
  end
end
