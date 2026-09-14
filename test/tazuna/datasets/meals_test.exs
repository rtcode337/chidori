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
      for key <- ~w(lat lon address website phone) do
        assert key in by_source["osm_japan"].extra
      end

      assert "confidence" in by_source["overture_japan"].extra
      # 知名度はここにしか無い（ランクを AI が決める材料になる）
      assert "pageviews_month" in by_source["jawiki"].extra
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

    test "1 区画は、1 回に差し込めるぶんに収まる" do
      # 超えると差し込みが切られ、「この範囲の全部が並んでいる」という
      # 漏れ探しの前提が崩れる。**枠は 2 つあり、厳しいほうが効く**（Chiezo の
      # MAX_MATERIAL_DOCS と MAX_MATERIAL_CHARS）
      target = Meals.partition().target

      assert target <= 300

      # **育ったあとの姿で見る。** 機械で引いた直後は 1 行 83 文字だが、AI が説明を
      # 書いたあとは 249 文字になる（本文 200 文字 + タグ 5 つ）——
      # 「件数に収まっているから大丈夫」は、育つ前の姿しか見ていない
      assert target * 249 <= 80_000

      # 区画は割り直される前に少しあふれるので、件数の上限には寄せきらない
      assert target < 300
    end
  end

  describe "巡回" do
    setup do: %{sweeps: Meals.sweeps()}

    test "名簿 → ざっと → じっくりの順に待つ", %{sweeps: sweeps} do
      # 座標の直っていない状態で「この区画に足りないもの」を問うても、
      # その店は別の区画に居るだけなので、既にあるものを挙げて終わる
      assert Enum.map(sweeps, & &1.name) == ["名簿", "ざっと", "じっくり"]
      assert Enum.find(sweeps, &(&1.name == "ざっと")).after == "名簿"
      assert Enum.find(sweeps, &(&1.name == "じっくり")).after == "ざっと"
    end

    test "名簿の回は機械で引き、足すだけ", %{sweeps: sweeps} do
      # 足すだけにしないと、AI が肉付けしたぶんを、名前と住所しか持たない名簿で上書きする
      roster = Enum.find(sweeps, &(&1.name == "名簿"))

      assert roster.use_extract
      assert roster.only_new
      assert roster.once
    end

    test "ざっとは一周したら止まる", %{sweeps: sweeps} do
      # 座標と閉店を一度ずつ見れば用が済む回。止めないと 2 周目が同じことを聞く
      assert Enum.find(sweeps, &(&1.name == "ざっと")).one_lap
    end

    test "じっくりは一周の日数で決める", %{sweeps: sweeps} do
      # 区画が増えても 1 回あたりを Chiezo が計算し直す（区画数を手で追わなくてよい）
      survey = Enum.find(sweeps, &(&1.name == "じっくり"))

      assert survey.cover_days > 0
      assert survey.prompt == :survey
    end

    test "一周の日数は、届く数を書く", %{sweeps: sweeps} do
      # Chiezo は 1 回に見る区画を 20 までに抑える（区画ごとに AI を 1 回、直列に
      # 呼ぶため）。**届かない日数を書くと、その日数では回りきらないのに画面には
      # 書いた日数が出る**
      partitions = 2_080
      per_run_cap = 20

      for sweep <- sweeps, days = Map.get(sweep, :cover_days), days do
        runs = days * 24 * 60 / sweep.interval_minutes

        assert ceil(partitions / runs) <= per_run_cap,
               "#{sweep.name} は #{days} 日では回りきりません"
      end
    end
  end

  describe "依頼の中身" do
    test "網羅で頼む" do
      # 古いものが要らなくなることはない —— 期限で落とすと地図に穴が開く
      assert Meals.attrs().kind == "stock"
    end

    test "巡回の依頼文は、送るときに実物へ入れ替わる" do
      survey = Enum.find(Meals.attrs().sweeps, &(&1.name == "じっくり"))

      assert is_binary(survey.prompt)
      assert survey.prompt =~ "足りない店"
    end

    test "画面で選んだ相手を巡回に載せる" do
      attrs = Meals.attrs(%{"じっくり" => %{backend: "antigravity", model: nil}})
      survey = Enum.find(attrs.sweeps, &(&1.name == "じっくり"))

      assert survey.backend == "antigravity"
      # 渡していない項目で、巡回が元から持っているものを潰さない
      refute Map.has_key?(survey, :model)
    end

    test "「Chiezo の既定にまかせる」は落とさない" do
      # 空文字は意思表示で、落とすと一度決めた相手を外せなくなる
      attrs = Meals.attrs(%{"ざっと" => %{backend: ""}})

      assert Enum.find(attrs.sweeps, &(&1.name == "ざっと")).backend == ""
    end
  end

  describe "依頼文" do
    test "消すのは墓標で、理由を書かせる" do
      # 消したものは名前が並ぶだけなので、理由が無いと消し間違いに気づけない
      assert Meals.scan_prompt() =~ Chiezo.tombstone_tag()
      assert Meals.scan_prompt() =~ "理由"
    end

    test "確かめられなかったものは触らせない" do
      # 疑わしいから消す・当てずっぽうで座標を書く、をやると正しかったものが落ちる
      assert Meals.scan_prompt() =~ "確かめられなかったものは触らないでください"
      assert Meals.survey_prompt() =~ "確かめられなかったものは触らないでください"
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
end
