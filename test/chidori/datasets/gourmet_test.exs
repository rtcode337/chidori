defmodule Chidori.Datasets.GourmetTest do
  @moduledoc """
  ご当地グルメの収集の定義（区画・名簿・引き当て・書式・巡回・依頼文）と、
  travel-log への行の組み方。
  """

  use ExUnit.Case, async: true

  alias Chidori.Datasets
  alias Chidori.Datasets.Gourmet
  alias Chidori.SweepNames

  describe "区画は 47 県" do
    test "東京都から JIS の番号順に回り、北海道に戻って千葉県で一周する" do
      order = Gourmet.prefecture_order()

      assert length(order) == 47
      assert length(Enum.uniq(order)) == 47
      assert Enum.take(order, 3) == ["東京都", "神奈川県", "新潟県"]
      # 沖縄県（47）のあと北海道（1）へ
      assert Enum.slice(order, 34, 2) == ["沖縄県", "北海道"]
      assert List.last(order) == "千葉県"
    end

    test "タグで割り、並べた値がそのまま区画になる（まだ 1 件も無い県も区画にする）" do
      partition = Gourmet.partition()

      assert partition.by == "tag"
      assert partition.prefix == "地域:"
      assert partition.values == Gourmet.prefecture_order()
      assert Gourmet.partition_key("福井県") == "地域:福井県"
      assert Gourmet.prefecture_of_key("地域:福井県") == "福井県"
      # 語彙に無い値（表記を崩したもの）は県として読まない
      assert Gourmet.prefecture_of_key("地域:東京") == nil
      assert Gourmet.prefecture_of_key("種類:菓子") == nil
    end
  end

  describe "名簿は県の名前が付いた食のカテゴリから機械で" do
    test "県の麺料理・県の土産菓子・北海道のご当地ラーメンなどを 47 県ぶん組み立てる" do
      tags = String.split(Gourmet.extract().tag, ",")

      assert "福井県の麺料理" in tags
      assert "沖縄県の土産菓子" in tags
      assert "北海道のご当地ラーメン" in tags
      assert "北海道の駅弁" in tags
      assert "神奈川県の農業" in tags
      # 店の括り（県の飲食店）も 47 県ぶん
      assert "東京都の飲食店" in tags
      # 組で入れる全国の括り（県の食文化にも入っている記事だけ）
      assert "日本の郷土料理" in tags
      assert "日本の水産加工品" in tags
      assert length(tags) == 47 * 9 + length(Gourmet.national_categories())

      # 県が読めない括り・どこにでもある料理が混ざる括り・食べもの以外を抱える括りは入れない
      for wide <- ~w(ご当地グルメ 関東地方のご当地ラーメン 東北地方の駅弁 東京都の食文化 京都府の菓子) do
        refute wide in tags
      end
    end

    test "全国の括りは、どこかの県の食文化にも入っている記事だけ（県は食文化から読む）" do
      extract = Gourmet.extract()
      [_farm, %{pattern: pattern, with_pattern: partner}] = extract.tag_pairs
      pattern = Regex.compile!(pattern, "u")
      partner = Regex.compile!(partner, "u")

      for national <- ~w(日本の郷土料理 日本の水産加工品 日本の鍋料理 日本の発酵食品 農山漁村の郷土料理百選) do
        assert Regex.match?(pattern, national)
      end

      # 県の括りは組を要らない（全国の括りの組に当たらない）
      refute Regex.match?(pattern, "秋田県の麺料理")
      refute Regex.match?(pattern, "日本の郷土料理の一覧")
      assert Regex.match?(partner, "秋田県の食文化")
      refute Regex.match?(partner, "秋田市の食文化")

      # 県は県の括りが先。決まらなかった記事だけ食文化から、当たった県ごとに読む
      [_kind, region, culture | _rest] = extract.tags
      assert culture.fallback == "all"
      assert culture.format == region.format
      assert culture.map == region.map
      assert [_, "宮崎県"] = Regex.run(Regex.compile!(culture.pattern, "u"), "宮崎県の食文化")

      # 全国の括りは外す括りと重ならない
      excluded = String.split(extract.not_tag, ",")
      for national <- Gourmet.national_categories(), do: refute(national in excluded)
    end

    test "農業の括りは、同じ県の食文化にも入っている記事だけ（米の品種は外す）" do
      extract = Gourmet.extract()
      assert [%{pattern: pattern, with: "{1}の食文化"}, _national] = extract.tag_pairs
      assert [_, "群馬県"] = Regex.run(Regex.compile!(pattern, "u"), "群馬県の農業")
      # 県は農業の括りからも読む
      [_kind, region | _rest] = extract.tags
      assert [_, "群馬県"] = Regex.run(Regex.compile!(region.pattern, "u"), "群馬県の農業")

      # 県の飲食店は組を要らない（tag_pairs のどの pattern にも当たらない）
      refute Regex.match?(Regex.compile!(pattern, "u"), "群馬県の飲食店")
      assert "イネの品種" in String.split(extract.not_tag, ",")
      assert Gourmet.tidy_prompt() =~ "米の品種"
    end

    test "会社・メーカー・商品・作品・店でないもの・閉じた店・一覧の記事は外す" do
      excluded = String.split(Gourmet.extract().not_tag, ",")

      for company <- ~w(日本の製菓業者 東京都の製菓業者 日本の食品メーカー 日本の製麺業者 日本の即席麺メーカー
                        インスタントラーメンの商品名 日本のファストフード店 ナイトクラブ
                        かつて存在した日本の外食事業者 かつて存在した東京都の企業 北海道の一覧) do
        assert company in excluded
      end

      # 閉じた施設のカテゴリは名前に空白を含む（カンマで区切るので、そのまま渡る）
      assert "神奈川県の商業施設 (廃止)" in excluded
    end

    test "店の記事は外さず、店の 1 件として入れる（店と会社が混ざる括りも整理が分ける）" do
      excluded = String.split(Gourmet.extract().not_tag, ",")

      for shop <- ~w(ラーメン店 餃子店 洋菓子店 和菓子の店舗・メーカー 日本の外食事業者 東京都の飲食店) do
        refute shop in excluded
      end

      [_kind, region, _culture, shop | _kinds] = Gourmet.extract().tags
      assert shop.format == Gourmet.shop_tag()
      pattern = Regex.compile!(shop.pattern, "u")

      for category <- ~w(ラーメン店 和菓子の店舗・メーカー うどん・蕎麦屋 東京都の飲食店) do
        assert Regex.match?(pattern, category)
      end

      # 料理のカテゴリには当たらない（「鰻料理」は うなぎパイ にも付くので店の印にしない）
      for category <- ~w(東京都の麺料理 静岡県の土産菓子 鰻料理 日本の飲食店) do
        refute Regex.match?(pattern, category)
      end

      # 県は県の飲食店からも読む
      assert [_, "東京都"] = Regex.run(Regex.compile!(region.pattern, "u"), "東京都の飲食店")

      # Chiezo の pattern は 200 文字まで
      for %{pattern: pattern} <- Gourmet.extract().tags, do: assert(String.length(pattern) <= 200)
    end

    test "名簿の括りと外す括りが重ならない（県の飲食店を外したまま入れようとしない）" do
      extract = Gourmet.extract()
      wanted = MapSet.new(String.split(extract.tag, ","))
      excluded = MapSet.new(String.split(extract.not_tag, ","))

      assert MapSet.disjoint?(wanted, excluded)
    end

    test "県はカテゴリの名前から読み、47 県の名前のときだけ作る" do
      [_kind, region | _rest] = Gourmet.extract().tags
      pattern = Regex.compile!(region.pattern, "u")

      assert [_, "福井県"] = Regex.run(pattern, "福井県の麺料理")
      assert [_, "京都府"] = Regex.run(pattern, "京都府の土産菓子")
      assert [_, "北海道"] = Regex.run(pattern, "北海道のご当地カレー")
      # 食文化からは読まない（名簿に入れていない括り）
      assert Regex.run(pattern, "東京都の食文化") == nil
      # 「日本の…」は表に無いので作らない
      assert map_size(region.map) == 47
      refute Map.has_key?(region.map, "日本")
      assert region.format == "地域:{1}"
    end

    test "2 つの県に入っている記事は県ごとの 1 件に分ける" do
      assert Gourmet.extract().split == %{prefix: "地域:", title: "{title}（{value}）"}
    end

    test "種類は細かい括りから 1 つだけ（2 つ目からは前が作っていれば作らない）" do
      [_kind, _region, _culture, _shop | rules] = Gourmet.extract().tags

      # Chiezo の読み替えは 1 本の指定に 20 個まで
      assert length(rules) + 4 <= 20
      assert hd(rules)[:fallback] == nil
      assert Enum.all?(tl(rules), &(&1.fallback == true))

      # 表の規則（`map`）は捕まえたカテゴリの名前を表で引く（Chiezo と同じ読み方）
      first_kind = fn categories ->
        Enum.find_value(rules, fn rule ->
          pattern = Regex.compile!(rule.pattern, "u")

          Enum.find_value(categories, fn category ->
            case Regex.run(pattern, category) do
              nil -> nil
              [_ | _] when not is_map_key(rule, :map) -> rule.format
              [_, name | _] -> if kind = rule.map[name], do: "種類:" <> kind
            end
          end)
        end)
      end

      assert first_kind.(["北海道のご当地ラーメン", "北海道の麺料理"]) == "種類:ラーメン"
      assert first_kind.(["北海道の駅弁", "北海道の土産菓子"]) == "種類:駅弁"
      assert first_kind.(["香川県の麺料理", "ご当地うどん"]) == "種類:うどん"
      assert first_kind.(["岩手県の麺料理"]) == "種類:麺類"
      assert first_kind.(["群馬県の農業", "群馬県の食文化"]) == "種類:食材"
      # 麺料理にも入っていれば、そちらが先
      assert first_kind.(["長野県の麺料理", "長野県の農業"]) == "種類:麺類"
      assert first_kind.(["三重県の土産菓子"]) == "種類:菓子"

      # 店は店の種類が先（ラーメン店で県の麺料理に入っている店は「麺類」ではない）
      assert first_kind.(["ラーメン店", "東京都の麺料理"]) == "種類:ラーメン"
      assert first_kind.(["和菓子の店舗・メーカー", "東京都の土産菓子"]) == "種類:菓子"
      assert first_kind.(["料亭", "京都府の飲食店"]) == "種類:和食"
      assert first_kind.(["日本の喫茶店", "神奈川県の飲食店"]) == "種類:飲み物"
      assert first_kind.(["寿司屋", "石川県の飲食店"]) == "種類:寿司・ごはん"
      assert first_kind.(["お好み焼店"]) == "種類:粉もの"
      # 店の種類が読めない店は AI に任せる
      assert first_kind.(["東京都の飲食店"]) == nil

      # 全国の括りは読める 2 つだけ（県の括りが先）。郷土料理・発酵食品は AI に任せる
      assert first_kind.(["日本の鍋料理", "秋田県の食文化"]) == "種類:鍋・汁物"
      assert first_kind.(["日本の水産加工品", "東京都の食文化"]) == "種類:魚介料理"
      assert first_kind.(["日本の郷土料理", "日本の水産加工品"]) == "種類:魚介料理"
      assert first_kind.(["日本の郷土料理", "宮崎県の食文化"]) == nil
      assert first_kind.(["日本の発酵食品", "福井県の食文化"]) == nil
      assert first_kind.(["日本の鍋料理", "山梨県の麺料理"]) == "種類:麺類"

      for rule <- rules do
        kinds = if rule[:map], do: Map.values(rule.map), else: [rule.format]
        for kind <- kinds, do: assert(String.replace_prefix(kind, "種類:", "") in Gourmet.kinds())
      end
    end
  end

  describe "代表店は辞典から引き当てる" do
    test "AI の座標は捨て、地図辞典を先に照らし、営業時間は辞典の値が先" do
      resolve = Gourmet.resolve()

      assert resolve.clue == "shop"
      assert Enum.map(resolve.sources, & &1.source) == ["osm_japan", "overture_japan"]
      assert resolve.area_tag == "地域:"
      assert resolve.failed_tag == Gourmet.unplaced_tag()

      # 手がかりがまだ無い料理も代表店未定に数え、代表店なしの料理は数えない
      assert resolve.failed_when_missing == true
      assert resolve.none_tag == Gourmet.no_shop_tag()
      refute Gourmet.no_shop_tag() == Gourmet.unplaced_tag()
      assert resolve.to_extra == %{opening_hours: "opening_hours"}
      assert resolve.ai_coords == false

      # 店の辞典に無い店は、AI が確かめた住所から街区の代表点を引く（最後の段）
      assert resolve.address == %{source: "address_jp", tag: "出典:位置参照情報"}
    end

    test "提供の月と営業時間の書式は Chiezo に確かめさせる" do
      assert Gourmet.formats() == %{available_months: "months", opening_hours: "opening_hours"}
    end
  end

  describe "巡回" do
    test "機械収集・ざっと見る・整理・情報収集の 4 本をこの順に並べ、名前は SweepNames から選ぶ" do
      sweeps = Gourmet.sweeps()
      names = Enum.map(sweeps, & &1.name)

      # 名簿の確かめと代表店決め（ざっと見る・整理）が先で、料理を足す（情報収集）のはその後
      assert names == [
               SweepNames.machine(),
               SweepNames.scan(),
               SweepNames.tidy(),
               SweepNames.survey()
             ]

      assert Enum.all?(names, &(&1 in SweepNames.all()))

      [roster, scan, tidy, survey] = sweeps

      # ざっと見るは名簿を待ち、2 時間おきの間隔で一周したら止まる。代表店未定が残る県には戻る
      assert %{after: "機械収集", one_lap: true, partitions_per_run: 1} = scan
      assert scan.interval_minutes == SweepNames.scan_minutes()
      assert scan.hold_tag == Gourmet.unplaced_tag()
      assert %{use_extract: true, only_new: true} = roster
      # 1 回に 1 県
      assert %{partitions_per_run: 1} = survey
      assert %{partitions_per_run: 1} = tidy
      # 情報収集は足すだけ（並んでいる料理を薄い中身で上書きしない）
      assert %{only_new: true} = survey
      refute Map.get(tidy, :only_new)

      # 整理と情報収集は、ざっと見るが見終えた県から回る（一周は待たない。名簿に混ざったものを
      # 外してから見直す・足す）
      assert %{after: "ざっと見る", after_each: true} = survey
      assert %{after: "ざっと見る", after_each: true} = tidy

      # 整理は代表店未定が残る県を見終わりにしない（情報収集は足止めしない）
      assert Map.get(tidy, :hold_tag) == Gourmet.unplaced_tag()
      refute Map.has_key?(survey, :hold_tag)
    end

    test "送る中身に、名簿・区画・引き当て・書式・各巡回の依頼文が入る" do
      attrs = Gourmet.attrs(%{})

      assert attrs.name == "chidori_gourmet"
      assert attrs.extract == Gourmet.extract()
      assert attrs.partition == Gourmet.partition()
      assert attrs.resolve == Gourmet.resolve()
      assert attrs.formats == Gourmet.formats()
      assert attrs.locked_doubt_tag == "終了の可能性あり"

      # 空欄を埋める段のために、空いている脇書きを一覧の 1 行に添えてもらう
      assert attrs.show_blanks == ["shop_reason", "opening_hours"]
      assert Gourmet.scan_prompt() =~ "〔空: shop_reason, opening_hours〕"
      assert Gourmet.tidy_prompt() =~ "〔空: shop_reason, opening_hours〕"

      prompts = Map.new(attrs.sweeps, &{&1.name, &1[:prompt]})
      assert prompts[SweepNames.survey()] == Gourmet.survey_prompt()
      assert prompts[SweepNames.tidy()] == Gourmet.tidy_prompt()
      assert prompts[SweepNames.scan()] == Gourmet.scan_prompt()
    end

    test "ざっと見るは整理の名簿の確認・代表店・空欄の段だけを、同じ文で頼む" do
      scan = Gourmet.scan_prompt()
      tidy = Gourmet.tidy_prompt()

      assert scan =~ "**1. 名簿から機械で入った料理を確かめる。**"
      assert scan =~ "**2. 代表店の決まっていない料理に、代表店を決める。**"
      assert scan =~ "**3. 空いている項目を埋める。**"
      # 見直し・名産を足す・報告に答えるのは整理だけ
      refute scan =~ "日の経った料理を見直す。**"
      refute scan =~ "名簿に無い名産を足す。**"
      refute scan =~ "報告に答える"
      assert tidy =~ "**2. 名簿から機械で入った料理を確かめる。**"
      assert tidy =~ "**5. 時間が残っていたら"
      assert scan =~ "{current}"
      # 段の中身は同じ文（片方が直したものをもう片方が戻さない）
      assert scan =~ "**料理は 1 回に 20 品まで**"
      assert scan =~ "**1 回に 30 件まで**"
      # 空欄の段を飛ばさせない（全部でなくて構わない、とは書かない）
      assert scan =~ "**3 もこの回の主な仕事です。飛ばさないでください。**"
      refute scan =~ "3 は全部でなくて構いません"
    end

    test "画面で選んだ相手を巡回に載せる" do
      attrs = Gourmet.attrs(%{"整理" => %{backend: "codex", model: nil}})
      tidy = Enum.find(attrs.sweeps, &(&1.name == "整理"))

      assert tidy.backend == "codex"
      refute Map.has_key?(tidy, :model)
    end

    test "データ収集の対象に 1 つ並ぶ（技術書・Pi-hole・レシピのあと）" do
      keys = Enum.map(Datasets.defined(), & &1.key)

      assert Enum.take(keys, 4) == ["books", "pihole", "recipes", "gourmet"]
      assert %{collection: "chidori_gourmet", prefectures: true} = Datasets.get("gourmet")
      assert Chidori.Datasets.TravelLog.exportable?(Datasets.get("gourmet"))
    end
  end

  describe "依頼文" do
    test "情報収集は、並んでいるものを見て薄い切り口から探し、何を試したかを残させる" do
      prompt = Gourmet.survey_prompt()

      for needle <- ["{partition}", "{current}", "{now}", "少ない切り口から", "checked", "chiezo の MCP"] do
        assert prompt =~ needle
      end
    end

    test "整理は、機械の名簿を確かめ、代表店を決め、空欄を埋め、古いものから確かめ直す" do
      prompt = Gourmet.tidy_prompt()

      for needle <- [
            Chidori.Chiezo.unreviewed_tag(),
            Gourmet.unplaced_tag(),
            "引き当てられなかった",
            "20 品まで",
            "この県の店は全部片付けて",
            # 辞典の見出しを先に引かせる（記事名と見出しの書き方が違うと引き当てに落ちる）
            "手がかりを書く前に引いてください",
            "checked_on",
            Chidori.Chiezo.tombstone_tag(),
            "collect_partition",
            # 探しても見つからなければ代表店なしの印と理由（終わったものは墓標）
            Gourmet.no_shop_tag(),
            "extra.no_shop",
            "料理そのものが終わった証拠",
            # 手の空いた回は名簿に無い名産を数品足す（並んでいる見出しでは返さない）
            "名簿に無い名産",
            "上に並んでいる料理の見出しでは返さないでください",
            # 一般名の食材は、ずば抜けた産地か名物として売り出しているときだけ。名前は土地を頭に
            "一般名の食材",
            "extra.display_name"
          ] do
        assert prompt =~ needle
      end
    end

    test "一般名の食材の決まりは、どちらの依頼文にも 1 回ずつ書く" do
      for prompt <- [Gourmet.survey_prompt(), Gourmet.tidy_prompt(), Gourmet.scan_prompt()] do
        assert prompt =~ "ずば抜けた産地"
        assert prompt =~ "徳島のスダチ"
        assert length(String.split(prompt, "ずば抜けた産地")) == 2
      end
    end

    test "地図に出す名前は extra.display_name を先に使い、無ければ見出しから作る" do
      doc = fn extra ->
        %{
          "doc_id" => 1,
          "title" => "スダチ",
          "tags" => ["ご当地グルメ", "地域:徳島県", "種類:食材"],
          "extra" => Map.merge(%{"lat" => 34.07, "lon" => 134.55}, extra)
        }
      end

      assert %{"name" => "徳島のスダチ"} =
               Gourmet.spot(doc.(%{"display_name" => "徳島のスダチ"}), Gourmet.definition())

      assert %{"name" => "スダチ"} = Gourmet.spot(doc.(%{}), Gourmet.definition())
    end

    test "代表店の選び方・発祥店・時期・終わったもの・出典・残さない情報源を、どちらの依頼文にも書く" do
      for prompt <- [Gourmet.survey_prompt(), Gourmet.tidy_prompt(), Gourmet.scan_prompt()] do
        assert prompt =~ "代表店:本店"
        assert prompt =~ "代表店:有名店"
        assert prompt =~ "代表店:行きやすい店"
        assert prompt =~ ~s("発祥店")
        assert prompt =~ "available_months"
        assert prompt =~ "終わったもの"
        assert prompt =~ "extra.sources"
        assert prompt =~ "Google マップや食べログ"
        assert prompt =~ "座標（lat / lon）は書かないでください"

        # 料理の県の外でもよい・発祥を争う料理は県ごと（利用者の決めごと）
        assert prompt =~ "県の外でもかまいません"
        assert prompt =~ "県ごとに 1 件ずつ"
      end
    end

    test "AI に書かせる脇書きの鍵は 10 こで、Chiezo の上限（20）に収まる" do
      ai_keys =
        ~w(shop available_months season_note opening_hours municipality sources checked_on no_shop display_name shop_reason)

      # 機械が運ぶ鍵（座標と出典）と Chiezo の印（消した理由・見直した印・疑いの印など）
      machine_keys =
        ~w(lat lon url ai_keys removed_reason removed_at removed_after_review doubt_reason doubt_at)

      assert length(ai_keys ++ machine_keys) <= 20

      assert length(ai_keys) == 10

      for prompt <- [Gourmet.survey_prompt(), Gourmet.tidy_prompt(), Gourmet.scan_prompt()],
          key <- ai_keys,
          do: assert(prompt =~ "extra.#{key}")
    end

    test "代表店の理由は、確かめた事実だけを extra.shop_reason に 1 行（評点や感想は書かせない）" do
      for prompt <- [Gourmet.survey_prompt(), Gourmet.tidy_prompt(), Gourmet.scan_prompt()] do
        assert prompt =~ "その店を選んだ理由を `extra.shop_reason` に 1 行で"
        assert prompt =~ "確かめた頁に書いてある事実だけ"
        assert prompt =~ "口コミの評点や「美味しい」「人気」のような感想は"
        assert length(String.split(prompt, "その店を選んだ理由を `extra.shop_reason` に 1 行で")) == 2
      end
    end
  end

  describe "travel-log の行" do
    defp doc(overrides) do
      Map.merge(
        %{
          "doc_id" => 77,
          "title" => "ソースカツ丼（福井県）",
          "tags" => [
            "ご当地グルメ",
            "地域:福井県",
            "種類:丼もの",
            "代表店:本店",
            "発祥店",
            "裏付け:県",
            "提供店:多数",
            "出典:OSM"
          ],
          "extra" => %{
            "lat" => 36.0613,
            "lon" => 136.2229,
            "shop" => %{"name" => "サンプル軒総本店", "address" => "福井県福井市中央1丁目"},
            "available_months" => "11-3",
            "season_note" => "冬季のみ",
            "opening_hours" => "Mo-Fr 11:00-20:00; We off",
            "url" =>
              "https://ja.wikipedia.org/wiki/%E3%82%BD%E3%83%BC%E3%82%B9%E3%82%AB%E3%83%84%E4%B8%BC",
            "sources" => ["https://example.com/fukui-gourmet", "javascript:alert(1)"]
          }
        },
        overrides
      )
    end

    defp dataset, do: Gourmet.definition()

    test "名前は料理、座標は代表店、地域は料理の県、シリーズは料理の種類" do
      row = Gourmet.spot(doc(%{}), dataset())

      # 県ごとに分けた 1 件の「（県名）」は落とす
      assert row["name"] == "ソースカツ丼"
      assert row["lat"] == 36.0613
      assert row["lng"] == 136.2229
      assert row["region"] == "福井県"
      assert row["series"] == "丼もの"
      assert row["key"] == "77"
    end

    test "カテゴリは発祥店・代表店の決まり・季節限定・裏付けの順" do
      row = Gourmet.spot(doc(%{}), dataset())

      assert row["categories"] == "発祥店|本店|季節限定|県の紹介"
    end

    test "説明は代表店と選んだ理由・時期・営業時間・出典・座標の出どころ" do
      description = Gourmet.spot(doc(%{}), dataset())["description"]

      assert description =~ "代表店: サンプル軒総本店（本店・発祥の店）／福井県福井市中央1丁目"
      assert description =~ "提供の時期: 11〜3月（冬季のみ）"
      assert description =~ "営業時間: "

      # 百科事典は travel-log の決まりの書き方で、ほかは URL のまま。http/https 以外は落とす
      assert description =~ "出典: [ja.wikipedia:ソースカツ丼] https://example.com/fukui-gourmet"
      refute description =~ "javascript"
      assert description =~ "座標: 代表店の位置（OpenStreetMap）"
    end

    test "住所から引いた座標は、出典と整備年を添えて街区の代表点と書く" do
      row =
        Gourmet.spot(
          doc(%{
            "tags" => ["ご当地グルメ", "地域:福井県", "種類:丼もの", "出典:位置参照情報"],
            "extra" => %{
              "lat" => 36.0613,
              "lon" => 136.2229,
              "shop" => %{"name" => "見本食堂", "address" => "福井県福井市中央一丁目1", "version" => "24.0a"}
            }
          }),
          dataset()
        )

      assert row["description"] =~
               "座標: 代表店の住所の街区（街区レベル位置参照情報 国土交通省 令和7年度を加工）"

      refute row["description"] =~ "代表店の位置"
    end

    test "選定理由は裏付けのタグから機械で 1 行（語ごとに読める言い回し・無ければ出さない）" do
      line = fn backings ->
        tags = ["ご当地グルメ", "地域:福井県"] ++ Enum.map(backings, &"裏付け:#{&1}")

        Gourmet.description(tags, %{})
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "選定理由: "))
      end

      assert line.(["国"]) == "選定理由: 国（農林水産省など）が名物として紹介"
      assert line.(["県"]) == "選定理由: 県や県の観光協会が名物として紹介"
      assert line.(["市区町村"]) == "選定理由: 市区町村や地元の観光協会が名物として紹介"
      assert line.(["商標"]) == "選定理由: 地域団体商標に登録"
      assert line.(["大会"]) == "選定理由: ご当地グルメの大会に出展・受賞"

      # 紹介している先はまとめて 1 つの「が名物として紹介」に、並びは語彙の順（付いた順ではない）
      assert line.(["大会", "県", "国", "商標"]) ==
               "選定理由: 国（農林水産省など）・県や県の観光協会が名物として紹介、" <>
                 "地域団体商標に登録、ご当地グルメの大会に出展・受賞"

      # 裏付けの無い 1 件・語彙に無い値には出さない
      assert line.([]) == nil
      assert line.(["口コミ"]) == nil

      # 説明の先頭に出る
      assert Gourmet.spot(doc(%{}), dataset())["description"]
             |> String.starts_with?("選定理由: 県や県の観光協会が名物として紹介\n代表店: ")
    end

    test "代表店の理由は代表店の行のすぐ後ろに（書いていなければ出さない）" do
      extra = Map.put(doc(%{})["extra"], "shop_reason", "1950 年創業の発祥の店で、いまも本店で出している")
      lines = String.split(Gourmet.spot(doc(%{"extra" => extra}), dataset())["description"], "\n")
      at = Enum.find_index(lines, &String.starts_with?(&1, "代表店: "))

      assert Enum.at(lines, at + 1) == "代表店の理由: 1950 年創業の発祥の店で、いまも本店で出している"
      refute Gourmet.spot(doc(%{}), dataset())["description"] =~ "代表店の理由"

      # 代表店の名前が無ければ理由だけを出さない
      no_shop = Map.put(extra, "shop", nil)
      refute Gourmet.description([], no_shop) =~ "理由"
    end

    test "提供の時期と営業時間は CSV の 2 列にそのまま出す" do
      row = Gourmet.spot(doc(%{}), dataset())

      assert row["available_months"] == "11-3"
      assert row["opening_hours"] == "Mo-Fr 11:00-20:00; We off"

      csv = Chidori.Datasets.TravelLog.csv([row], Gourmet.csv_header())

      assert csv =~
               "name,lat,lng,region,rank,series,categories,description,available_months,opening_hours,key\r\n"

      assert csv =~ ",11-3,Mo-Fr 11:00-20:00; We off,77\r\n"
    end

    test "代表店が引き当たっていない料理（座標が無い）は行にしない" do
      extra = Map.drop(doc(%{})["extra"], ["lat", "lon"])

      assert Gourmet.spot(doc(%{"extra" => extra}), dataset()) == nil
      # 県が語彙に無いものも
      assert Gourmet.spot(doc(%{"tags" => ["ご当地グルメ", "地域:福井"]}), dataset()) == nil
    end

    test "ランクは裏付けと提供店の数から機械で決める" do
      assert Gourmet.rank(["裏付け:国", "提供店:多数"]) == "A"
      assert Gourmet.rank(["裏付け:商標", "提供店:多数"]) == "A"
      # 国の裏付けでも、提供店が多数でなければ A にしない（A を絞る）
      assert Gourmet.rank(["裏付け:国", "提供店:数軒"]) == "B"
      assert Gourmet.rank(["裏付け:県"]) == "B"
      assert Gourmet.rank(["裏付け:市区町村", "提供店:1"]) == "C"
      assert Gourmet.rank(["提供店:数軒"]) == "D"
      assert Gourmet.rank(["提供店:1"]) == "E"
      assert Gourmet.rank([]) == "E"
    end

    test "百科事典の閲覧数でも段を上げる（高いほうを採る）" do
      assert Gourmet.rank([], %{"pageviews_month" => 2500}) == "A"
      assert Gourmet.rank([], %{"pageviews_month" => 800}) == "B"
      assert Gourmet.rank([], %{"pageviews_month" => 150}) == "C"
      # 記事があるだけで D
      assert Gourmet.rank([], %{"pageviews_month" => 3}) == "D"
      # 裏付けのほうが高ければそちら
      assert Gourmet.rank(["裏付け:県"], %{"pageviews_month" => 150}) == "B"
      # 食材は閲覧数では C まで
      assert Gourmet.rank(["種類:食材"], %{"pageviews_month" => 9000}) == "C"

      assert Gourmet.rank(["種類:食材", "裏付け:国", "提供店:多数"], %{"pageviews_month" => 9000}) ==
               "A"
    end

    test "記事の無い 1 件だけ AI の見立てを B まで使う" do
      assert Gourmet.rank(["ランク:C"]) == "C"
      assert Gourmet.rank(["ランク:A"]) == "B"
      # 記事があれば AI の見立ては読まない
      assert Gourmet.rank(["ランク:A"], %{"pageviews_month" => 30}) == "D"
      # 知らない段は読まない
      assert Gourmet.rank(["ランク:S"]) == "E"
    end

    test "名前から見分けの補足を落とす" do
      assert Gourmet.dish_name("チェルシー (菓子)", "北海道") == "チェルシー"
      assert Gourmet.dish_name("イタリアン (新潟)（福島県）", "福島県") == "イタリアン"
      assert Gourmet.dish_name("大間のマグロ", "青森県") == "大間のマグロ"
    end

    test "月の並びを日本語に" do
      assert Gourmet.months_text("11-3") == "11〜3月"
      assert Gourmet.months_text("6,7,8") == "6月・7月・8月"
      assert Gourmet.months_text("12-2,7") == "12〜2月・7月"
      assert Gourmet.months_text("冬") == ""
    end
  end

  describe "店の 1 件" do
    defp shop_doc(overrides \\ %{}) do
      Map.merge(
        %{
          "doc_id" => 88,
          "title" => "サンプル亭 (ラーメン店)",
          "tags" => [
            "ご当地グルメ",
            "地域:東京都",
            "区分:店",
            "種類:ラーメン",
            "代表店:本店",
            "発祥店",
            "提供店:数軒",
            "出典:OSM"
          ],
          "extra" => %{
            "lat" => 35.6812,
            "lon" => 139.7671,
            "shop" => %{"name" => "サンプル亭 本店", "address" => "東京都千代田区丸の内1丁目"}
          }
        },
        overrides
      )
    end

    test "見出しは店名のまま（見分けの補足は落とす）、ピンはその店（本店）" do
      row = Gourmet.spot(shop_doc(), Gourmet.definition())

      assert row["name"] == "サンプル亭"
      assert row["lat"] == 35.6812
      assert row["series"] == "ラーメン"
      assert Gourmet.shop?(shop_doc())
      refute Gourmet.shop?(%{"tags" => ["ご当地グルメ", "地域:東京都"]})
    end

    test "travel-log では「名店」のカテゴリで料理と見分ける（代表店の「有名店」とは別の語）" do
      row = Gourmet.spot(shop_doc(), Gourmet.definition())

      assert row["categories"] == "名店|発祥店|本店"
      assert hd(Gourmet.category_order()) == "名店"
      assert "有名店" in Gourmet.category_order()
      assert length(Enum.uniq(Gourmet.category_order())) == length(Gourmet.category_order())
    end

    test "説明は「代表店」ではなく「店」でその店自身を書く" do
      description = Gourmet.spot(shop_doc(), Gourmet.definition())["description"]

      assert description =~ "店: サンプル亭 本店（本店・発祥の店）／東京都千代田区丸の内1丁目"
      refute description =~ "代表店:"
    end

    test "店の 1 件の理由は「選んだ理由」で、店の行のすぐ後ろに" do
      extra = Map.put(shop_doc()["extra"], "shop_reason", "県の観光協会が名物の店として紹介している本店")

      description =
        Gourmet.spot(shop_doc(%{"extra" => extra}), Gourmet.definition())["description"]

      assert description =~
               "店: サンプル亭 本店（本店・発祥の店）／東京都千代田区丸の内1丁目\n" <>
                 "選んだ理由: 県の観光協会が名物の店として紹介している本店"

      refute description =~ "代表店の理由"
    end

    test "料理の発祥の店として知られる店の 1 件は、地図に料理名で出す（説明の店の行は店名のまま）" do
      shop = %{
        "doc_id" => 89,
        "title" => "サンプル洋食店",
        "tags" => ["ご当地グルメ", "地域:東京都", "区分:店", "種類:洋食・中華", "代表店:本店", "発祥店", "提供店:1"],
        "extra" => %{
          "lat" => 35.67,
          "lon" => 139.76,
          "display_name" => "カツカレー",
          "shop" => %{"name" => "サンプル洋食店", "address" => "東京都中央区銀座1丁目"}
        }
      }

      row = Gourmet.spot(shop, Gourmet.definition())

      assert row["name"] == "カツカレー"
      assert row["categories"] =~ "名店|発祥店"
      assert row["description"] =~ "店: サンプル洋食店（本店・発祥の店）／東京都中央区銀座1丁目"
    end

    test "どちらの依頼文にも、発祥の店の 1 件の名前の決まりを 1 回ずつ書く（料理の 1 件があれば重なりの決まり）" do
      for prompt <- [Gourmet.survey_prompt(), Gourmet.tidy_prompt(), Gourmet.scan_prompt()] do
        assert prompt =~ "料理の発祥の店として知られる店"
        assert prompt =~ "`extra.display_name` に**その料理の名前**"
        assert prompt =~ "名前は**料理名そのまま**"
        assert prompt =~ "店のある土地を頭に付けて"
        assert prompt =~ "この決まりではなく次の「料理と店の重なり」に従って"
        assert length(String.split(prompt, "料理の発祥の店として知られる店**（")) == 2
      end
    end

    test "種類の語彙は店のぶん（和食・洋食・中華）を足しても 20 を超えない" do
      kinds = Gourmet.kinds()

      assert "和食" in kinds
      assert "洋食・中華" in kinds
      assert length(kinds) <= 20
      assert List.last(kinds) == "その他"
    end

    test "どちらの依頼文にも、店の 1 件の決まりと料理との重なりの決め方を 1 回ずつ書く" do
      for prompt <- [Gourmet.survey_prompt(), Gourmet.tidy_prompt(), Gourmet.scan_prompt()] do
        assert prompt =~ ~s(tags に "区分:店")
        assert prompt =~ "地元でも知られていない店"
        assert prompt =~ "本店（発祥の店）が決まらないチェーン"
        assert prompt =~ "全国チェーンそのもの"
        assert prompt =~ "閉店した店"
        assert prompt =~ "その店自身"
        # 同じ店にピンを 2 本立てない（系統の料理と発祥の店）
        assert prompt =~ "同じ店にピンが 2 本立たないように"
        assert prompt =~ "の 1 件にまとめた（代表店・発祥店）"
        assert length(String.split(prompt, "同じ店にピンが 2 本立たないように")) == 2

        # 重なりではいつも料理を残す（提供店が 1 軒でも）。店を残して料理をまとめる向きは無い
        assert prompt =~ "残すのはいつも料理です"
        assert prompt =~ "消す前に、料理の 1 件が上に生きていることを確かめてください"
        refute prompt =~ "なら**店を残し**"
        refute prompt =~ "<店>の 1 件にまとめた"
      end
    end

    test "情報収集は記事の無い店を足しすぎない（1 回 2 軒まで・公的な紹介があるものだけ）" do
      prompt = Gourmet.survey_prompt()

      assert prompt =~ "1 回 2 軒まで"
      assert prompt =~ "県・市区町村・観光協会がその土地の名物の店として紹介している"
    end

    test "整理は店の印を確かめ、2 県に分かれた店は本店の県の 1 件にまとめる" do
      prompt = Gourmet.tidy_prompt()

      assert prompt =~ "看板の菓子・料理そのものの記事"
      assert prompt =~ "本店のある県の 1 件だけを残し"
      assert prompt =~ "店の 1 件は、その店の閉店が終わり"
    end

    test "travel-log からの閉店の報告は、店の 1 件なら墓標" do
      assert Gourmet.request_preface() =~ "現地から閉店の報告"
    end
  end

  describe "料理と店が同じ店を指すときは、書き出すときに片方だけ" do
    # 代表店が辞典の記録に引き当たった 1 件（`identity` は Chiezo が運ぶ元の記録の鍵）
    defp resolved(id, title, tags, shop) do
      %{
        "doc_id" => id,
        "title" => title,
        "tags" => ["ご当地グルメ", "地域:神奈川県", "種類:ラーメン"] ++ tags,
        "extra" => %{
          "lat" => 35.45,
          "lon" => 139.6,
          "shop" => Map.merge(%{"name" => "サンプル家", "resolved_at" => "2026-10-01T00:00:00Z"}, shop)
        }
      }
    end

    @node %{"identity" => ["osm_japan:osm_type=node;osm_id=1", "overture_japan:overture_id=a"]}

    defp kept(docs) do
      docs
      |> Enum.map(&{&1, Gourmet.spot(&1, Gourmet.definition())})
      |> Gourmet.without_same_shop()
      |> Enum.reject(fn {_doc, row} -> is_nil(row) end)
      |> Enum.map(fn {doc, _row} -> doc["title"] end)
    end

    test "提供店が数軒以上の料理は料理を残し、店を落とす" do
      dish = resolved(1, "サンプル系ラーメン", ["提供店:多数"], @node)
      shop = resolved(2, "サンプル家", ["区分:店", "提供店:1"], @node)

      assert kept([dish, shop]) == ["サンプル系ラーメン"]

      assert kept([shop, resolved(1, "サンプル系ラーメン", ["提供店:数軒"], @node)]) ==
               ["サンプル系ラーメン"]
    end

    test "提供店が 1 軒か印の無い料理でも、料理を残して店を落とす（いつも料理）" do
      shop = resolved(2, "サンプル家", ["区分:店"], @node)

      assert kept([resolved(1, "サンプル麺", ["提供店:1"], @node), shop]) == ["サンプル麺"]
      assert kept([shop, resolved(1, "サンプル麺", ["提供店:1"], @node)]) == ["サンプル麺"]
      assert kept([resolved(1, "サンプル麺", [], @node), shop]) == ["サンプル麺"]
    end

    test "同じ記録とみなすのは元の記録の鍵が 1 つでも重なるとき（どちらかの辞典で当たればよい）" do
      dish = resolved(1, "サンプル麺", [], %{"identity" => ["overture_japan:overture_id=a"]})
      shop = resolved(2, "サンプル家", ["区分:店"], @node)

      assert kept([dish, shop]) == ["サンプル麺"]
    end

    test "記録が違えば、名前が同じでも両方残す" do
      dish = resolved(1, "サンプル麺", [], %{"identity" => ["osm_japan:osm_type=node;osm_id=1"]})
      shop = resolved(2, "サンプル家", ["区分:店"], %{"identity" => ["osm_japan:osm_type=way;osm_id=1"]})

      assert kept([dish, shop]) == ["サンプル麺", "サンプル家"]
    end

    test "元の記録の鍵が無い引き当ては、辞典の見出し（ref）で比べる" do
      ref = %{"ref" => "osm_japan:サンプル家"}
      shop = resolved(2, "サンプル家", ["区分:店"], ref)

      assert kept([resolved(1, "サンプル麺", [], ref), shop]) == ["サンプル麺"]

      assert kept([resolved(1, "サンプル麺", [], %{"ref" => "osm_japan:サンプル家 (2)"}), shop]) ==
               ["サンプル麺", "サンプル家"]
    end

    test "引き当てられていない手がかりや、料理どうし・店どうしは突き合わせない" do
      shop = resolved(2, "サンプル家", ["区分:店"], @node)
      unresolved = resolved(1, "サンプル麺", [], Map.put(@node, "unresolved", "候補なし"))

      assert kept([unresolved, shop]) == ["サンプル麺", "サンプル家"]
      assert kept([resolved(1, "甲", [], @node), resolved(3, "乙", [], @node)]) == ["甲", "乙"]
    end

    test "同じ店にいる料理はいくつあっても全部残し、店だけを落とす" do
      many = resolved(1, "サンプル系ラーメン", ["提供店:多数"], @node)
      one = resolved(3, "サンプル家の限定麺", ["提供店:1"], @node)
      shop = resolved(2, "サンプル家", ["区分:店"], @node)

      assert kept([many, one, shop]) == ["サンプル系ラーメン", "サンプル家の限定麺"]
    end
  end
end
