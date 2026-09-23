defmodule Tazuna.Datasets.TravelLogTest do
  use ExUnit.Case, async: true

  alias Tazuna.Datasets
  alias Tazuna.Datasets.TravelLog

  defp dataset, do: Datasets.get("meals")

  defp doc(overrides) do
    Map.merge(
      %{
        "doc_id" => 12_345,
        "title" => "だるま食堂",
        "tags" => ["食事処", "出典:OSM", "ジャンル:和食", "ジャンル:定食", "地域:東京都", "ランク:C"],
        "extra" => %{
          "lat" => 35.681,
          "lon" => 139.767,
          "website" => "https://example.test/daruma"
        },
        "opening" => "所在地: 東京都 千代田区\n昔ながらの定食屋。"
      },
      overrides
    )
  end

  describe "1 件をスポットの行にする" do
    test "タグと脇書きから、travel-log の列を埋める" do
      row = TravelLog.row(doc(%{}), dataset())

      assert row["name"] == "だるま食堂"
      assert row["lat"] == 35.681
      assert row["lng"] == 139.767
      assert row["region"] == "東京都"
      assert row["rank"] == "C"
    end

    test "シリーズはジャンルの先頭、残りはカテゴリへ回す" do
      # 地図の見た目を決めるのは 1 つだけ。残りは絞り込みに使えるほうが無駄がない
      row = TravelLog.row(doc(%{}), dataset())

      assert row["series"] == "和食"
      assert row["categories"] == "定食"
    end

    test "鍵は Chiezo の doc_id" do
      # 焼き直しても引き継がれる番号。名前を鍵にすると、AI が表記を直した回で
      # 別のスポットが増える
      assert TravelLog.row(doc(%{}), dataset())["key"] == "12345"
    end

    test "説明文には、どの辞典から来たかを必ず書く" do
      # 辞典ごとにライセンスが違うので、渡した先で切り分けられないと外しようがない
      description = TravelLog.row(doc(%{}), dataset())["description"]

      assert description =~ "OpenStreetMap"
      assert description =~ "昔ながらの定食屋。"
      assert description =~ "https://example.test/daruma"
    end

    test "地域が無いものは書き出さない" do
      # travel-log は地域が必須で、空のままでは地図に置けない
      without_area = doc(%{"tags" => ["食事処", "ジャンル:和食"]})

      assert TravelLog.row(without_area, dataset()) == nil
    end

    test "座標が無いものは書き出さない" do
      assert TravelLog.row(doc(%{"extra" => %{}}), dataset()) == nil
    end

    test "見出しに付いた重複よけの番号は落とす" do
      # 地図に出るのは名前なので、機械の都合は見せない
      assert TravelLog.row(doc(%{"title" => "A&W (node:5884951586)"}), dataset())["name"] ==
               "A&W"

      assert TravelLog.row(doc(%{"title" => "ほっともっと (454627)"}), dataset())["name"] ==
               "ほっともっと"
    end

    test "名前の一部の丸かっこは残す" do
      # `サンプル食堂 (SAMPLE)` のような別名は名前の一部。一律に外すと別の店に見える
      assert TravelLog.row(doc(%{"title" => "サンプル食堂 (SAMPLE)"}), dataset())["name"] ==
               "サンプル食堂 (SAMPLE)"
    end
  end

  describe "CSV" do
    test "改行は CRLF で、区切りを含む値はくくる" do
      csv = TravelLog.csv([TravelLog.row(doc(%{}), dataset())])

      assert String.starts_with?(
               csv,
               "name,lat,lng,region,rank,series,categories,description,key"
             )

      assert String.contains?(csv, "\r\n")
      # 説明文は改行を含むので引用符でくくられる
      assert String.contains?(csv, ~s("所在地: 東京都))
    end

    test "引用符は 2 つ重ねて書く" do
      row = TravelLog.row(doc(%{"title" => ~s(すし"処")}), dataset())

      assert String.contains?(TravelLog.csv([row]), ~s("すし""処"))
    end
  end

  describe "settings.json" do
    test "シリーズは出てきた数の多い順に並び、色が付く" do
      # 並び順がそのまま絞り込みの並びとピンの色の並びになる。色を付けないと
      # travel-log 側で全部が同じ灰色のピンになり、地図で見分けられない
      rows = [
        %{"series" => "和食", "categories" => ""},
        %{"series" => "カフェ", "categories" => ""},
        %{"series" => "和食", "categories" => ""}
      ]

      %{"series" => series} = Jason.decode!(TravelLog.settings_json("meals", "食事処", rows))

      assert Enum.map(series, & &1["series"]) == ["和食", "カフェ"]
      assert Enum.all?(series, &String.starts_with?(&1["color"], "#"))
      assert Enum.map(series, & &1["label"]) == ["和食", "カフ"]
    end

    test "キーと呼び名は、そのまま travel-log の種別になる" do
      settings = Jason.decode!(TravelLog.settings_json("meals", "食事処", []))

      assert settings["key"] == "meals"
      assert settings["label"] == "食事処"
      # ランクは A〜E が入るので使う
      assert settings["settings"]["rank_enabled"] == true
    end
  end

  describe "書き出せる対象か" do
    test "スポットにできる収集だけ" do
      # 技術ニュースのように地図に載らない収集もある
      assert TravelLog.exportable?(dataset())
      refute TravelLog.exportable?(%{module: Enum})
      refute TravelLog.exportable?(%{})
    end
  end
end
