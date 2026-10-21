defmodule Chidori.Datasets.AnimeSeichiTest do
  @moduledoc """
  アニメ聖地（`Chidori.Datasets.AnimeSeichi`）。1 件は 1 作品 × 舞台の土地 1 つで、
  ピンは象徴的な場所に 1 本だけ。名簿は TV アニメと劇場アニメのうち日本の土地が舞台のものだけ。
  """
  use ExUnit.Case, async: true

  alias Chidori.Datasets.AnimeSeichi
  alias Chidori.SweepNames

  describe "名簿の引き方" do
    test "入口は年のカテゴリで、日本の土地が舞台の作品だけを採る" do
      spec = AnimeSeichi.extract()

      assert spec.source == "jawiki"
      # TV アニメと劇場アニメだけ（OVA・配信・漫画は入口に無い）
      assert spec.tag_suffix == "年のテレビアニメ,年のアニメ映画"

      [pair] = spec.tag_pairs
      setting = Regex.compile!(pair.with_pattern, "u")

      assert Regex.match?(setting, "鎌倉市を舞台としたアニメ作品")
      assert Regex.match?(setting, "埼玉県を舞台としたアニメ作品")
      assert Regex.match?(setting, "東京を舞台としたアニメ映画")
      assert Regex.match?(setting, "湘南を舞台としたアニメ作品")
      # 外国の市・土地でない舞台は入れない
      refute Regex.match?(setting, "ニューヨーク市を舞台としたアニメ作品")
      refute Regex.match?(setting, "高等学校を舞台としたアニメ作品")
      # Chiezo の正規表現は 200 字まで
      assert String.length(pair.with_pattern) <= 200
    end

    test "県はカテゴリの名前から、市区町村は地図辞典で読み、2 県なら県ごとに分ける" do
      spec = AnimeSeichi.extract()
      [_kind, place, city, unknown | _rest] = spec.tags

      assert place.map["東京"] == "東京都"
      assert place.map["埼玉県"] == "埼玉県"
      assert city.fallback == true
      assert city.area_of.source == "osm_japan"
      assert unknown.format == "地域:不明"
      assert spec.split == %{prefix: "地域:", title: "{title}（{value}）"}
    end

    test "形式は年のカテゴリから" do
      formats = for %{format: "形式:" <> kind} <- AnimeSeichi.extract().tags, do: kind
      assert formats == ["TVアニメ", "劇場アニメ"]
    end
  end

  describe "場所" do
    test "地図辞典に引き当て、当たらなければ住所の街区、最後に AI が地図で確かめた座標" do
      resolve = AnimeSeichi.resolve()

      assert resolve.clue == "spot"
      # 店舗辞典は使わない（公共の場所は地図辞典のほうが確か）
      assert Enum.map(resolve.sources, & &1.source) == ["osm_japan"]
      assert resolve.address.source == "address_jp"
      assert resolve.ai_fallback == %{tag: "出典:AI"}
      assert resolve.failed_tag == AnimeSeichi.unplaced_tag()
      assert resolve.failed_when_missing
    end
  end

  describe "巡回" do
    test "機械収集 → 情報収集の 2 本で、情報収集は 1 回 1 県・場所の決まらない県には戻る" do
      [roster, survey] = AnimeSeichi.sweeps()

      assert %{use_extract: true, only_new: true, once: true} = roster
      assert roster.name == SweepNames.machine()
      assert survey.name == SweepNames.survey()
      assert survey.after == SweepNames.machine()
      assert survey.partitions_per_run == 1
      assert survey.hold_tag == AnimeSeichi.unplaced_tag()
      refute Map.get(survey, :only_new)
    end

    test "区画は県と「不明」" do
      partition = AnimeSeichi.partition()

      assert partition.by == "tag"
      assert List.first(partition.values) == "東京都"
      assert List.last(partition.values) == "不明"
      assert length(partition.values) == 48
    end
  end

  describe "依頼文" do
    test "1 作品 1 土地・象徴的な場所（無ければ最寄駅）・作中の場所の説明・公表と考察の書き分け" do
      prompt = AnimeSeichi.survey_prompt()

      assert prompt =~ "1 件は 1 つのアニメ作品"
      assert prompt =~ "作品の顔になっている実在の場所"
      assert prompt =~ "決めきれなければ、舞台の最寄駅"
      assert prompt =~ "劇場版で舞台が別の土地なら、劇場版を別の 1 件"
      assert prompt =~ "その土地で作中に出てくる場所を 3〜8 か所"
      assert prompt =~ "ファンの"
      assert prompt =~ "考察で特定"
      assert prompt =~ "{current}"
      assert prompt =~ "{partition}"
      assert prompt =~ "この回に時間の制限はありません"
    end
  end

  describe "travel-log への書き出し" do
    @dataset %{key: "anime", key_prefix: ""}

    defp doc(extra, tags \\ ["アニメ聖地", "地域:神奈川県", "形式:TVアニメ", "裏付け:公式", "出典:OSM"]) do
      %{
        "doc_id" => 7,
        "title" => "見本の作品（神奈川県）",
        "body" => "海辺の町が舞台。作中に出てくる場所: 見本駅（毎回のオープニング）。",
        "tags" => tags,
        "extra" =>
          Map.merge(
            %{
              "lat" => 35.30,
              "lon" => 139.55,
              "pageviews_month" => 12_000,
              "url" => "https://ja.wikipedia.org/wiki/見本の作品",
              "spot" => %{"name" => "見本駅"},
              "spot_reason" => "オープニングに毎回出てくる駅"
            },
            extra
          )
      }
    end

    test "1 件を 1 行にする（名前の「（県名）」は落とす）" do
      row = AnimeSeichi.spot(doc(%{}), @dataset)

      assert row["name"] == "見本の作品"
      assert row["region"] == "神奈川県"
      assert row["series"] == "TVアニメ"
      assert row["rank"] == "B"
      assert row["categories"] == "公式が公表"
      assert row["description"] =~ "作中に出てくる場所: 見本駅"
      assert row["description"] =~ "ピン: 見本駅（オープニングに毎回出てくる駅）"
      assert row["description"] =~ "出典: [ja.wikipedia:見本の作品]"
      assert row["description"] =~ "座標: ピンの場所（OpenStreetMap）"
      assert row["key"] == "7"
    end

    test "場所の決まっていない作品は書き出さない" do
      assert AnimeSeichi.spot(doc(%{"lat" => nil, "lon" => nil}), @dataset) == nil
    end

    test "AI が地図で確かめた座標は、そう書く" do
      tags = ["アニメ聖地", "地域:神奈川県", "形式:劇場アニメ", "出典:AI"]
      row = AnimeSeichi.spot(doc(%{}, tags), @dataset)

      assert row["series"] == "劇場アニメ"
      assert row["description"] =~ "座標: ピンの場所（地図サービスで確かめた位置）"
    end
  end
end
