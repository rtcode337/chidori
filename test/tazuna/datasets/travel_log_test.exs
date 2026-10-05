defmodule Tazuna.Datasets.TravelLogTest do
  use ExUnit.Case, async: true

  alias Tazuna.Datasets
  alias Tazuna.Datasets.TravelLog

  defp dataset, do: Tazuna.Datasets.Meals.definition()

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

    test "シリーズはジャンルの先頭、カテゴリは店の特徴" do
      # ジャンルの 2 つめ以降を回していた頃は、粗いジャンルの重複（寿司屋の「和食」）
      # ばかりで絞り込みの軸にならなかった
      row = TravelLog.row(doc(%{}), dataset())

      assert row["series"] == "和食"
      # 特徴が無くても、位置を確かめたかどうかは付く
      assert row["categories"] == "位置未確認"

      tags = ["食事処", "ジャンル:和食", "地域:東京都", "特徴:個室あり", "特徴:ゆっくりできる", "特徴:眺めがいい"]

      extra = %{
        "lat" => 35.6,
        "lon" => 139.7,
        "opening_hours" => "Mo-Fr 11:00-14:00; Sa 17:00-23:00"
      }

      row = TravelLog.row(doc(%{"tags" => tags, "extra" => extra}), dataset())

      # 語彙の並びで、語彙に無い語は落とす。営業時間から読めるものは機械で足す
      assert row["categories"] == "ランチ営業|深夜営業|ゆっくりできる|個室あり|位置未確認"
      assert row["description"] =~ "営業時間: Mo-Fr 11:00-14:00; Sa 17:00-23:00"
    end

    test "座標が固定された店には「位置確認済み」、それ以外には「位置未確認」が付く" do
      # travel-log から渡した位置確認が Chiezo まで届いたことを、取り込み直して確かめられる
      tags = ["食事処", "ジャンル:和食", "地域:東京都", "特徴:個室あり", Tazuna.Chiezo.locked_tag()]
      extra = %{"lat" => 35.6, "lon" => 139.7}
      row = TravelLog.row(doc(%{"tags" => tags, "extra" => extra}), dataset())

      assert row["categories"] == "個室あり|位置確認済み"

      # まだ確かめていない店を現地で見て回れるよう、未確認も絞り込めるようにする
      unchecked = List.delete(tags, Tazuna.Chiezo.locked_tag())
      row = TravelLog.row(doc(%{"tags" => unchecked, "extra" => extra}), dataset())
      assert row["categories"] == "個室あり|位置未確認"

      # AI に付けさせる語彙には入れない（確かめていない店に付けられないように）
      refute "位置確認済み" in Tazuna.Datasets.Meals.features()
      refute "位置未確認" in Tazuna.Datasets.Meals.features()
      assert Enum.take(Tazuna.Datasets.Meals.category_order(), -2) == ["位置確認済み", "位置未確認"]
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

  describe "exclude.txt" do
    defp removed(doc_id, after_review, tags \\ ["食事処", "_chiezo_removed"]) do
      doc(%{
        "doc_id" => doc_id,
        "tags" => tags,
        "extra" => %{"removed_reason" => "閉店", "removed_after_review" => after_review}
      })
    end

    test "目を通したあとで消えたものの key を、番号順に重複なく出す" do
      # 消えたものは spots.csv に載らないだけでは、travel-log に前の回で入ったぶんが消えない
      docs = [removed(300, true), removed(20, true), removed(300, true)]

      assert TravelLog.excluded_keys(docs, dataset()) == ["20", "300"]
    end

    test "最初の目通しで弾かれたもの・印の無いものは出さない" do
      # 一度も書き出されていないので、向こうに消すものが無い
      without_mark = doc(%{"doc_id" => 3, "tags" => ["食事処", "_chiezo_removed"], "extra" => %{}})

      assert TravelLog.excluded_keys([removed(1, false), without_mark], dataset()) == []
    end

    test "消えていないもの・収集の目印が無いものは出さない" do
      docs = [removed(1, true, ["食事処"]), removed(2, true, ["別の種類", "_chiezo_removed"])]

      assert TravelLog.excluded_keys(docs, dataset()) == []
    end

    test "1 行に 1 つの key で、注記の行は # で始める" do
      # travel-log は空行と # で始まる行を読み飛ばす
      assert TravelLog.exclude_txt(["20", "300"]) ==
               "# tazuna の収集で消えたスポット（閉店・重複など）の key\r\n20\r\n300\r\n"
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

    test "カテゴリの並びは語彙のまま渡し、シリーズには混ぜない" do
      rows = [%{"series" => "和食", "categories" => "ランチ営業"}]
      json = Jason.decode!(TravelLog.settings_json("meals", "食事処", rows, ["ランチ営業", "深夜営業"]))

      assert Enum.map(json["series"], & &1["series"]) == ["和食"]
      assert json["categories"] == ["ランチ営業", "深夜営業"]
    end

    test "キーと呼び名は、そのまま travel-log の種別になる" do
      settings = Jason.decode!(TravelLog.settings_json("meals", "食事処", []))

      assert settings["key"] == "meals"
      assert settings["label"] == "食事処"
      # ランクは A〜E が入るので使う
      assert settings["settings"]["rank_enabled"] == true

      # 見た目は travel-log 側で付けたものを残してもらう（範囲ごとに読み込むため）
      assert settings["keep_series_styles"] == true
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

  describe "範囲の収集の書き出し" do
    @area %{id: 3, name: "東京駅", south: 35.67, west: 139.75, north: 35.69, east: 139.78}

    test "スポットの key に範囲の番号を付ける（範囲どうしで key をぶつけない）" do
      doc = %{
        "doc_id" => 1234,
        "title" => "店",
        "tags" => ["食事処", "地域:神奈川県"],
        "extra" => %{"lat" => 35.681, "lon" => 139.767}
      }

      assert TravelLog.row(doc, Tazuna.Datasets.Meals.definition(@area))["key"] == "3-1234"
    end

    test "範囲の外の店は書き出さず、exclude.txt に回す（範囲を狭めたあと）" do
      # Chiezo は四角の外の文書を消さないので、狭めた範囲の外の店が収集に残る
      inside = %{"lat" => 35.681, "lng" => 139.767, "key" => "3-1"}
      outside = %{"lat" => 35.70, "lng" => 139.767, "key" => "3-2"}
      definition = Tazuna.Datasets.Meals.definition(@area)

      assert TravelLog.split_outside([inside, outside], definition) == {[inside], [outside]}
      # 範囲を持たない収集は全部が中
      assert TravelLog.split_outside([inside, outside], %{}) == {[inside, outside], []}
    end

    test "シリーズは語彙の順に固定する（読み込むたびに並びも色も入れ替わらない）" do
      rows = [%{"series" => "和食"}, %{"series" => "和食"}, %{"series" => "カレー"}]
      order = Tazuna.Datasets.Meals.genre_order()

      %{"series" => series} =
        Jason.decode!(TravelLog.settings_json("dining", "食事処", rows, nil, order))

      names = Enum.map(series, & &1["series"])

      # 店に無いジャンルも並ぶ（別の範囲にしか無いジャンルを落とさない）
      assert Enum.take(names, length(order)) == order
      # 語彙に無いジャンルは後ろに
      assert List.last(names) == "カレー"
    end
  end
end
