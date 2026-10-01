defmodule Tazuna.Datasets.MealsTest do
  use ExUnit.Case, async: true

  alias Tazuna.Chiezo
  alias Tazuna.Datasets.Meals

  describe "名簿の引き方" do
    setup do
      %{specs: Meals.extract(), by_source: Map.new(Meals.extract(), &{&1.source, &1})}
    end

    test "3 つの辞典から引く", %{specs: specs} do
      # ひとつの辞典では要る項目が揃わない（紹介文があるのは百科事典だけ、
      # 座標がいちばん確かなのは地図辞典、件数がいちばん多いのは店舗辞典）
      assert Enum.map(specs, & &1.source) == ["jawiki", "osm_japan", "overture_japan"]
    end

    test "座標は地図辞典が勝つ", %{by_source: by_source} do
      # 現地を歩いた人が置いた点。**譲る側にも書かせない** ——
      # 百科事典が座標で勝つと、地図辞典の値が入らない
      assert "extra" in by_source["osm_japan"].provides
      refute "extra" in by_source["jawiki"].provides
    end

    test "説明は百科事典が勝つ", %{by_source: by_source} do
      # 読み物になっている紹介文があるのはここだけ。地図辞典の本文は定型
      assert "body" in by_source["jawiki"].provides
      refute "body" in by_source["osm_japan"].provides
    end

    test "店舗辞典は何も勝ちにいかない", %{by_source: by_source} do
      # 件数はいちばん多いが、値の確かさは上の 2 つに劣る
      assert by_source["overture_japan"].provides == []
    end

    test "順位を譲った辞典も、座標は運ぶ", %{by_source: by_source} do
      # **譲ることと捨てることは別。** 地図に載っていない 1 軒の座標は百科事典に
      # しか無く、捨てるとその 1 軒はどの区画にも入らず AI から永遠に見えなくなる
      assert "lat" in by_source["jawiki"].extra
      assert "lon" in by_source["jawiki"].extra
    end

    test "どの辞典にも件数を書かない", %{specs: specs} do
      # **網羅の収集なので、機械で引けるものを取りこぼさない** —— 取りこぼすと、
      # そのぶんを巡回が区画ごとに探し直すことになり、機械で済む仕事を AI に払わせる。
      # 地図辞典では実害も出る：飲食店にどれも同じ点しか付かないので、件数を書くと
      # 並びが見出し順になり、名前が先に来るものだけが残る
      for spec <- specs, do: refute(Map.has_key?(spec, :limit))
    end

    test "チェーンは名簿ごと落とす", %{by_source: by_source} do
      # どこにでもある店は地図の邪魔になる（残すかは AI ではなくここで決める）
      assert by_source["overture_japan"].not_tag =~ "fast_food_restaurant"
      assert by_source["overture_japan"].not_tag =~ "burger_restaurant"
      assert by_source["jawiki"].not_tag =~ "チェーン"
    end

    test "travel-log が読む事実は、元の 1 件からそのまま運ぶ", %{by_source: by_source} do
      # 読む側が 1 件ずつ辞典を引き直さずに済むように
      # 営業時間はランチ営業・深夜営業を機械で読み取るのに使う
      for key <- ~w(lat lon address website phone opening_hours) do
        assert key in by_source["osm_japan"].extra
      end

      # 知名度はここにしか無い（ランクを AI が決める材料になる）
      assert "pageviews_month" in by_source["jawiki"].extra
    end

    test "地図の辞典は、元の地物を名指す鍵も運ぶ", %{by_source: by_source} do
      # **見出しは取り込み直すと変わりうる**（同じ名前の地物の見分けの札）。見出しだけで
      # 突き合わせていると、閉店で消した店が新しい見出しで戻ってくる
      assert by_source["osm_japan"].identity == ~w(osm_type osm_id)
      assert by_source["overture_japan"].identity == ~w(overture_id)
      # 百科事典の見出しは記事名なので、札が付け直されることはない
      refute Map.has_key?(by_source["jawiki"], :identity)
    end

    test "ラーメン屋は新しい版の語彙でも麺類になる", %{by_source: by_source} do
      # 2026-09 の版で noodles_restaurant が無くなり、ramen_restaurant に入った
      assert by_source["overture_japan"].tag =~ "ramen_restaurant"

      assert Enum.any?(
               by_source["overture_japan"].tags,
               &(&1[:pattern] == "^ramen_restaurant$" and &1[:format] =~ "麺類")
             )
    end

    test "閉店の片割れを確かめてもらう" do
      # 同じ店が辞典に 2 件入っていて、片方だけ閉店で消えることがある
      assert Meals.definition().closed_twins == true
      assert Meals.scan_prompt() =~ "片割れ"
      assert Meals.survey_prompt() =~ "片割れ"
    end

    test "足す前に営業しているかを確かめさせる" do
      # 閉店した店の記事や口コミの頁は何年も残る
      assert Meals.survey_prompt() =~ "いまも営業しているか"
    end

    test "読まないものは運ばない" do
      # 脇書きは毎回の素材に丸ごと乗る —— 読まないものを運ぶと、そのぶん焼きが遅くなる
      # （実測で confidence と locality だけで 9.8 MB）
      by_source = Map.new(Meals.extract(), &{&1.source, &1})

      refute "confidence" in by_source["overture_japan"].extra
      refute "locality" in by_source["overture_japan"].extra
      refute "wikidata" in by_source["osm_japan"].extra
    end

    test "ジャンルの読み替えは、細かいものが先", %{by_source: by_source} do
      # 1 軒に何段階かのカテゴリが同時に付いている（寿司屋には「寿司」と「和食」）。
      # 読み替えは書いた順にタグを作り、travel-log は先頭をシリーズに使うので、
      # 粗いほうが先にあると地図がどの店も同じ一語で埋まる
      formats = for %{format: format} <- by_source["overture_japan"].tags, do: format

      assert Enum.find_index(formats, &(&1 =~ "寿司")) <
               Enum.find_index(formats, &(&1 =~ "和食"))
    end

    test "地域は百科事典のカテゴリから機械で決まる", %{by_source: by_source} do
      # 「の飲食店」で終わるカテゴリには「2021年開業の飲食店」のような年のものが
      # 混ざっていて、そのまま採ると「地域:2021年開業」ができる
      rule = Enum.find(by_source["jawiki"].tags, &(&1[:format] == "地域:{1}"))

      assert Regex.match?(Regex.compile!(rule.pattern), "東京都の飲食店")
      assert Regex.match?(Regex.compile!(rule.pattern), "北海道の飲食店")
      refute Regex.match?(Regex.compile!(rule.pattern), "2021年開業の飲食店")
    end

    test "1 件の目印は、どの辞典から来たものにも付く", %{specs: specs} do
      # travel-log はこのタグで 1 件を拾う
      for spec <- specs, do: assert(%{const: "食事処"} in spec.tags)
    end

    test "どの辞典から来たかが 1 件に残る", %{by_source: by_source} do
      # **同じ店が 2 つに分かれたとき、どちらの座標を残すかはここで決まる** ——
      # 機械では畳めない（実測で名前が一致するのは 3%）ので、AI がこれを見て決める
      for {source, tag} <- [
            {"jawiki", "出典:Wikipedia"},
            {"osm_japan", "出典:OSM"},
            {"overture_japan", "出典:Overture"}
          ] do
        assert %{const: tag} in by_source[source].tags
      end

      assert Enum.sort(Meals.source_tags()) ==
               Enum.sort(["出典:Wikipedia", "出典:OSM", "出典:Overture"])
    end
  end

  describe "区画" do
    test "座標で割り、母集団は書かない" do
      # **自分自身を割っているときだけ Chiezo が割り直す** —— 座標が直れば
      # 区画もそれに追随してほしい
      spec = Meals.partition()

      assert spec.by == "geo"
      refute Map.has_key?(spec, :source)
    end

    test "日本全体を矩形で持つ" do
      # 点から矩形を作ると、まだ 1 軒も入っていない範囲が対象から落ち、
      # 「ここに足りない店はないか」を永遠に問えない
      [south, west, north, east] = Meals.partition().bbox

      assert south < north
      assert west < east
      assert south < 24.0 and north > 45.0
    end

    test "東京駅から広げる" do
      # **書かないと南西の隅から北上する** —— 矩形の鍵は角から並ぶので、
      # 日本の地図では八重山が最初になる。一周に何十日もかかる台帳では、
      # 店の多いところに着くのが何か月も先になってしまう
      [lat, lon] = Meals.partition().origin

      assert_in_delta lat, 35.681, 0.01
      assert_in_delta lon, 139.767, 0.01
    end

    test "始める点は、対象の矩形の中にある" do
      # 外に置いても並ぶだけは並ぶが、「日本のどこから広げるか」を言えなくなる
      [south, west, north, east] = Meals.partition().bbox
      [lat, lon] = Meals.partition().origin

      assert south < lat and lat < north
      assert west < lon and lon < east
    end

    test "1 区画は、AI が 1 回で返せるぶんに収まる" do
      # **入り口より出口が先に効く。** この回は残す店ぜんぶにタグと紹介文を
      # 付けさせるので、区画の件数がそのまま返る件数になる。
      # 実測（Antigravity に 150 件ぶんを返させた）: 150 件が切れずに全部返り、
      # 47,685 文字・2 分 50 秒。1 件あたり約 318 文字・約 1.1 秒
      target = Meals.partition().target
      measured_items = 150
      bridge_seconds = 840

      assert target <= measured_items
      assert target * 1.1 < bridge_seconds

      # 差し込みの枠（Chiezo の MAX_MATERIAL_DOCS / MAX_MATERIAL_CHARS）にも収まる。
      # **育ったあとの姿で見る** —— 機械で引いた直後は 1 行 83 文字だが、
      # AI が説明を書いたあとは 249 文字になる
      assert target <= 300
      assert target * 249 <= 80_000
    end
  end

  describe "巡回" do
    setup do: %{sweeps: Meals.sweeps()}

    test "どちらの回も名簿を待つ", %{sweeps: sweeps} do
      # 名簿が無ければ区画に何も並ばず、空の一覧に「この範囲の全部です」と言う形になる。
      # **じっくりはざっとの一周を待たない** —— 起点のまわりから回すので、
      # 全国のざっとが一周するのを待っていては、見たいところにいつまでも着かない
      assert Enum.map(sweeps, & &1.name) == ["機械収集", "ざっと見る", "情報収集"]
      assert Enum.find(sweeps, &(&1.name == "ざっと見る")).after == "機械収集"
      assert Enum.find(sweeps, &(&1.name == "情報収集")).after == "機械収集"
    end

    test "じっくりは Chiezo の時計では走らず、tazuna が起こす", %{sweeps: sweeps} do
      # 1 区画に 6〜14 分かかる仕事なので、全国を順に回すと一周に何か月もかかる。
      # 起点と時刻は利用者が決め、tazuna が名指しで起こす
      survey = Enum.find(sweeps, &(&1.name == "情報収集"))

      assert survey.enabled == false
      refute Map.get(survey, :by_hand)
      assert Meals.definition().survey_plan_sweep == "情報収集"

      # **間隔は持たない**（時刻は tazuna が決める）。1 回に見る数は直に渡す
      refute Map.has_key?(survey, :interval_minutes)
      refute Map.has_key?(survey, :cover_days)
      assert survey.partitions_per_run == 5
    end

    test "割り込みはざっとが引き受ける" do
      # じっくりは tazuna が決めた時刻にしか走らないので、その場で頼む先はざっと
      assert Meals.definition().survey_sweep == "ざっと見る"
    end

    test "名簿の回は機械で引き、足すだけ", %{sweeps: sweeps} do
      # 足すだけにしないと、AI が肉付けしたぶんを、名前と住所しか持たない名簿で上書きする
      roster = Enum.find(sweeps, &(&1.name == "機械収集"))

      assert roster.use_extract
      assert roster.only_new
      assert roster.once
    end

    test "ざっとは一周したら止まる", %{sweeps: sweeps} do
      # 座標と閉店を一度ずつ見れば用が済む回。止めないと 2 周目が同じことを聞く
      assert Enum.find(sweeps, &(&1.name == "ざっと見る")).one_lap
    end

    test "情報収集は自分の依頼文を持つ", %{sweeps: sweeps} do
      survey = Enum.find(sweeps, &(&1.name == "情報収集"))
      assert survey.prompt == :survey
    end

    test "1 回の取り込みは、次の予定に追いつかれない", %{sweeps: sweeps} do
      # **日数は希望**で、実際の速さは区画の数と Chiezo の上限で決まる ——
      # こちらで確かめられるのは「1 回が長すぎないか」のほう。区画ごとに AI を
      # 1 回、直列に呼ぶ（実測で 1 件 1.1 秒）ので、追いつかれると走りっぱなしになる。
      # 上限まで見た回でも収まっているかで見る
      per_run_cap = 5

      for sweep <- sweeps, Map.get(sweep, :cover_days) do
        minutes = per_run_cap * Meals.partition().target * 1.1 / 60

        assert minutes < sweep.interval_minutes,
               "#{sweep.name} は 1 回に #{round(minutes)} 分かかり、" <>
                 "#{sweep.interval_minutes} 分後の次の予定に追いつかれます"
      end
    end
  end

  describe "依頼の中身" do
    test "網羅で頼む" do
      # 古いものが要らなくなることはない —— 期限で落とすと地図に穴が開く
      assert Meals.attrs().kind == "stock"
    end

    test "巡回の依頼文は、送るときに実物へ入れ替わる" do
      survey = Enum.find(Meals.attrs().sweeps, &(&1.name == "情報収集"))

      assert is_binary(survey.prompt)
      assert survey.prompt =~ "足りない店"
    end

    test "画面で選んだ相手を巡回に載せる" do
      attrs = Meals.attrs(%{"情報収集" => %{backend: "antigravity", model: nil}})
      survey = Enum.find(attrs.sweeps, &(&1.name == "情報収集"))

      assert survey.backend == "antigravity"
      # 渡していない項目で、巡回が元から持っているものを潰さない
      refute Map.has_key?(survey, :model)
    end

    test "「Chiezo の既定にまかせる」は落とさない" do
      # 空文字は意思表示で、落とすと一度決めた相手を外せなくなる
      attrs = Meals.attrs(%{"ざっと見る" => %{backend: ""}})

      assert Enum.find(attrs.sweeps, &(&1.name == "ざっと見る")).backend == ""
    end
  end

  describe "依頼文" do
    test "消すのは墓標で、理由を書かせる" do
      # 消したものは名前が並ぶだけなので、理由が無いと消し間違いに気づけない
      assert Meals.scan_prompt() =~ Chiezo.tombstone_tag()
      assert Meals.scan_prompt() =~ "理由"
    end

    test "返す形のところにも、消し方を書く" do
      # 仕事の並びの中に 1 行あるだけでは守られなかった（実測で、墓標だけが付いて
      # 理由が 1 件も書かれず、座標違いで消えた店を戻す判断ができなかった）
      for prompt <- [Meals.scan_prompt(), Meals.survey_prompt()] do
        assert prompt =~ "消す 1 件は、形が 1 つ違います"
        assert prompt =~ "body に消す理由を 1 行"
        assert prompt =~ "理由の無い墓標は、あとから誰にも直せません"
      end
    end

    test "確かめられなかったものは触らせない" do
      # 疑わしいから消す・当てずっぽうで座標を書く、をやると正しかったものが落ちる
      assert Meals.scan_prompt() =~ "確かめられなかったものは触らないでください"
      assert Meals.survey_prompt() =~ "確かめられなかったものは触らないでください"
    end

    test "じっくりは、足すのが主な仕事" do
      # 名簿の元は地図辞典なので、新しい店・小さい店・地図に載っていない店は
      # 入っていない。そこを埋めるのがこの層の値打ちで、磨くだけなら機械でもできる
      assert Meals.survey_prompt() =~ "1 つめが主な仕事"
      assert Meals.survey_prompt() =~ "足りない店を足す"
    end

    test "座標が違うのは、消す理由にしない" do
      # 住所がこの範囲の外を指していても、消すと名簿から消えたままどの区画にも
      # 戻ってこない。直せば次の回から本来の区画に並ぶ
      # （実測で、座標と住所が食い違う店が墓標で消されていた）
      for prompt <- [Meals.scan_prompt(), Meals.survey_prompt()] do
        assert prompt =~ "消す理由ではありません"
        assert prompt =~ "消さずに正しい緯度・経度へ直してください"
      end
    end

    test "「本来の区画へ移す」ために消させない" do
      # 移す手立ては座標を直すことだけ。消すと、移った先の回はその店を知らず、
      # 墓標が機械の名簿からの復帰も止める
      # （実測で 2 件、「本来の区画へ移動」と書いて消されていた）
      for prompt <- [Meals.scan_prompt(), Meals.survey_prompt()] do
        assert prompt =~ "「本来の区画へ移す」ために消すのも同じです"
      end
    end

    test "集めるのはイートインできる店だけ" do
      # travel-log は「食べに行く先」の地図で、買って帰る店は行き先にならない。
      # 書いていなかった頃は、同じ持ち帰り専門店が回によって残ったり消えたりした
      for prompt <- [Meals.scan_prompt(), Meals.survey_prompt()] do
        assert prompt =~ "その場で食べられるかで分けてください"
        assert prompt =~ "持ち帰りもやっている店は残してください"
      end
    end

    test "1 件に潰れた別々の店は、分けさせる" do
      # 名簿は見出しで同じものかを決めているので、同名の別店が 1 件になる
      # （実測で、百科事典の「東京の洋食店」（東京・上野）と地図辞典の熊本の同名店が
      #  1 件に潰れ、本文は東京・座標は熊本になっていた）
      assert Meals.survey_prompt() =~ "1 件に別々の店が混ざっていたら"
      assert Meals.survey_prompt() =~ "見出しで"
    end

    test "足すものには必ず座標を入れさせる" do
      # 座標の無いものはどの区画にも入らず、次に見たときには「まだ無い」と見える
      assert Meals.survey_prompt() =~ "座標"
      assert Meals.survey_prompt() =~ "lat"
    end

    test "travel-log が読むタグを、どちらの回にも同じ形で書く" do
      # 書き分けると、回によって別の形が返ってくる
      for prompt <- [Meals.scan_prompt(), Meals.survey_prompt()] do
        assert prompt =~ Meals.kind_tag()
        assert prompt =~ Meals.genre_tag()
        assert prompt =~ Meals.area_tag()
        assert prompt =~ Meals.rank_tag()
        assert prompt =~ Meals.feature_tag()
      end
    end

    test "特徴は語彙から選ばせ、確かめられたものだけ付けさせる" do
      # 表記が割れると travel-log の絞り込みが効かない。付いた印は「そうだ」と読まれる
      for prompt <- [Meals.scan_prompt(), Meals.survey_prompt()] do
        for feature <- Meals.features(), do: assert(prompt =~ feature)
        assert prompt =~ "新しい語は作らない"
        assert prompt =~ "確かめられたものだけ"
      end
    end

    test "地域の空いているものを、どちらの回でも必ず埋めさせる" do
      # 名簿の元の店舗辞典は日本では都道府県がほとんど空で、そのままだと
      # travel-log は地図に置けない（region が必須）
      for prompt <- [Meals.scan_prompt(), Meals.survey_prompt()] do
        assert prompt =~ "必ず埋めて"
        assert prompt =~ "都道府県"
      end
    end

    test "いま付いているタグを消させない" do
      # 返した内容で丸ごと置き換わるので、書かなかったタグは消える
      assert Meals.scan_prompt() =~ "そのまま残してください"
    end

    test "同じ店が 2 つに分かれていたら、まとめさせる" do
      # 辞典ごとに名前の書き方が違うので機械では畳めない
      # （実測で、同じ範囲の地図辞典と店舗辞典で名前が一致するのは 3%）
      for prompt <- [Meals.scan_prompt(), Meals.survey_prompt()] do
        assert prompt =~ "1 つにまとめて" or prompt =~ "まとめて返し"
        # **どちらを残すかを決めさせない。** 回ごとに違う値が残ると、
        # 直したはずの座標が次の回で元へ戻る
        assert prompt =~ "座標は \"出典:OSM\""
        assert prompt =~ "説明は \"出典:Wikipedia\""
      end
    end

    test "出典の印は AI に触らせない" do
      # 機械が付けたもの。足させると、辞典に載っていない店にも印が付く
      assert Meals.scan_prompt() =~ "足したり消したりしないでください"
    end
  end

  test "溜め先の名前は環境変数で変えられる" do
    System.put_env("TAZUNA_MEALS_COLLECTION", "meals_test")
    on_exit(fn -> System.delete_env("TAZUNA_MEALS_COLLECTION") end)

    assert Meals.collection() == "meals_test"
  end

  test "travel-log に渡す項目が、画面に出せる形で並ぶ" do
    # ここに書いていない項目は向こうで空欄になるので、気づけるようにする
    rows = Meals.fields()

    assert Enum.all?(rows, &match?(%{field: _, stored: _, who: _}, &1))
    assert Enum.any?(rows, &(&1.field =~ "座標"))
    assert Enum.any?(rows, &(&1.field =~ "ランク"))
  end

  describe "範囲ごとの収集" do
    @area %{id: 3, name: "東京駅", south: 35.67, west: 139.75, north: 35.69, east: 139.78}

    test "収集の名前は範囲ごと" do
      assert Meals.collection(@area) == "tazuna_dining_3"
      assert Meals.definition(@area).collection == "tazuna_dining_3"
    end

    test "3 つの辞典を範囲の四角で絞る" do
      specs = Meals.extract(@area)

      assert Enum.map(specs, & &1.source) == ["jawiki", "osm_japan", "overture_japan"]
      for spec <- specs, do: assert(spec.bbox == [35.67, 139.75, 35.69, 139.78])
    end

    test "全国版が残っていれば、AI が直した中身を最初の辞典として引き継ぐ" do
      [carry | _rest] = Meals.extract(Map.put(@area, :carry, true))

      assert carry.source == Meals.carry_from()
      assert carry.bbox == [35.67, 139.75, 35.69, 139.78]
      # 中身で勝つ（辞典の定型の本文より、AI が書いた説明を採る）
      assert "body" in carry.provides
      assert carry.body == "body"
    end

    test "区画は範囲の四角を、全国より細かく割る" do
      partition = Meals.partition([35.68, 139.765], @area)

      assert partition.bbox == [35.67, 139.75, 35.69, 139.78]
      assert partition.target < Meals.partition().target
    end

    test "起点の既定は範囲の真ん中" do
      origin = Meals.default_origin(@area)

      assert {origin.lat, origin.lon} == {35.68, 139.765}
    end

    test "依頼の中身も範囲のもの" do
      attrs = Meals.attrs(%{}, @area)

      assert attrs.name == "tazuna_dining_3"
      assert attrs.partition.bbox == [35.67, 139.75, 35.69, 139.78]
      assert Enum.all?(attrs.extract, &(&1.bbox == [35.67, 139.75, 35.69, 139.78]))
    end

    test "travel-log へは範囲によらず同じ種別に書き出し、key に範囲の番号を付ける" do
      definition = Meals.definition(@area)

      assert definition.export_key == "dining"
      assert definition.key_prefix == "3-"
      # 全国版とは別の種別
      refute definition.export_key == Meals.definition().key
    end
  end
end
