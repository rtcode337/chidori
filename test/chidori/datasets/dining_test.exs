defmodule Chidori.Datasets.DiningTest do
  use ExUnit.Case, async: true

  alias Chidori.Chiezo
  alias Chidori.Datasets.Dining

  @area %{id: 3, name: "東京駅", south: 35.67, west: 139.75, north: 35.69, east: 139.78}

  # 範囲の収集の依頼文（ざっと見ると整理）
  defp prompts, do: [Dining.check_prompt(), Dining.tidy_prompt()]

  describe "名簿の引き方" do
    setup do
      specs = Dining.extract(@area)
      %{specs: specs, by_source: Map.new(specs, &{&1.source, &1})}
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
      # 営業時間は朝食営業・ランチ営業・深夜営業を機械で読み取るのに使う
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

    test "閉店で消すときは、同じ店の片割れも見るよう頼む" do
      # 同じ店が辞典に 2 件入っていて、片方だけ閉店で消えることがある。判断は AI に任せる
      for prompt <- prompts(), do: assert(prompt =~ "片割れ")
    end

    test "足す前に営業しているかを確かめさせる" do
      # 閉店した店の記事や口コミの頁は何年も残る
      for prompt <- prompts(), do: assert(prompt =~ "いまも営業しているか")
    end

    test "読まないものは運ばない", %{by_source: by_source} do
      # 脇書きは毎回の素材に丸ごと乗る —— 読まないものを運ぶと、そのぶん焼きが遅くなる
      # （実測で confidence と locality だけで 9.8 MB）
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

      assert Enum.sort(Dining.source_tags()) ==
               Enum.sort(["出典:Wikipedia", "出典:OSM", "出典:Overture"])
    end
  end

  describe "区画" do
    test "座標で割り、母集団は書かない" do
      # **自分自身を割っているときだけ Chiezo が割り直す** —— 座標が直れば
      # 区画もそれに追随してほしい
      spec = Dining.partition([35.68, 139.765], @area)

      assert spec.by == "geo"
      refute Map.has_key?(spec, :source)
    end

    test "始める点は、範囲の四角の中にある" do
      # 書かないと南西の隅から広がる。外に置いても並ぶだけは並ぶが、
      # 「範囲のどこから広げるか」を言えなくなる
      [south, west, north, east] = Dining.shape(@area).partition.bbox
      [lat, lon] = Dining.shape(@area).partition.origin

      assert south < lat and lat < north
      assert west < lon and lon < east
    end

    test "1 区画は、AI が 1 回で返せるぶんに収まる" do
      # **入り口より出口が先に効く。** この回は残す店ぜんぶにタグと紹介文を
      # 付けさせるので、区画の件数がそのまま返る件数になる。
      # 実測（Antigravity に 150 件ぶんを返させた）: 150 件が切れずに全部返り、
      # 47,685 文字・2 分 50 秒。1 件あたり約 318 文字・約 1.1 秒
      target = Dining.area_partition_target()
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
    setup do: %{sweeps: Dining.sweeps(@area)}

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

    test "1 回の取り込みは、次の予定に追いつかれない", %{sweeps: sweeps} do
      # **日数は希望**で、実際の速さは区画の数と Chiezo の上限で決まる ——
      # こちらで確かめられるのは「1 回が長すぎないか」のほう。区画ごとに AI を
      # 1 回、直列に呼ぶ（実測で 1 件 1.1 秒）ので、追いつかれると走りっぱなしになる。
      # 上限まで見た回でも収まっているかで見る
      per_run_cap = 5

      for sweep <- sweeps, Map.get(sweep, :cover_days) do
        minutes = per_run_cap * Dining.area_partition_target() * 1.1 / 60

        assert minutes < sweep.interval_minutes,
               "#{sweep.name} は 1 回に #{round(minutes)} 分かかり、" <>
                 "#{sweep.interval_minutes} 分後の次の予定に追いつかれます"
      end
    end
  end

  describe "依頼の中身" do
    test "網羅で頼む" do
      # 古いものが要らなくなることはない —— 期限で落とすと地図に穴が開く
      assert Dining.attrs(%{}, @area).kind == "stock"

      # 店の URL を Chiezo に確かめさせる（書き出すときに開けないものを落とす）
      assert Dining.attrs(%{}, @area).links
    end

    test "巡回の依頼文は、送るときに実物へ入れ替わる" do
      tidy = Enum.find(Dining.attrs(%{}, @area).sweeps, &(&1.name == "整理"))

      assert is_binary(tidy.prompt)
      assert tidy.prompt =~ "足りない店"
    end

    test "画面で選んだ相手を巡回に載せる" do
      attrs = Dining.attrs(%{"整理" => %{backend: "antigravity", model: nil}}, @area)
      tidy = Enum.find(attrs.sweeps, &(&1.name == "整理"))

      assert tidy.backend == "antigravity"
      # 渡していない項目で、巡回が元から持っているものを潰さない
      refute Map.has_key?(tidy, :model)
    end

    test "「Chiezo の既定にまかせる」は落とさない" do
      # 空文字は意思表示で、落とすと一度決めた相手を外せなくなる
      attrs = Dining.attrs(%{"ざっと見る" => %{backend: ""}}, @area)

      assert Enum.find(attrs.sweeps, &(&1.name == "ざっと見る")).backend == ""
    end
  end

  describe "依頼文" do
    test "消すのは墓標で、理由を書かせる" do
      # 消したものは名前が並ぶだけなので、理由が無いと消し間違いに気づけない
      for prompt <- prompts() do
        assert prompt =~ Chiezo.tombstone_tag()
        assert prompt =~ "理由"
      end
    end

    test "返す形のところにも、消し方を書く" do
      # 仕事の並びの中に 1 行あるだけでは守られなかった（実測で、墓標だけが付いて
      # 理由が 1 件も書かれず、座標違いで消えた店を戻す判断ができなかった）
      for prompt <- prompts() do
        assert prompt =~ "消す 1 件は、形が 1 つ違います"
        assert prompt =~ "body に消す理由を 1 行"
        assert prompt =~ "理由の無い墓標は、あとから誰にも直せません"
      end
    end

    test "出典の URL は、開いて確かめたものだけを書かせる" do
      # 口コミサイトの店の番号を推し量って書き、別の店の頁や開けない頁になっていた
      for prompt <- prompts() do
        assert prompt =~ "実際に開いて、その店の頁だと"
        assert prompt =~ "店の番号を推し量って書かないでください"
        assert prompt =~ "https で"
        # url を書かないだけでは前の値が残る
        assert prompt =~ "`extra.url` に `null` を書いて"
      end
    end

    test "確かめられなかった座標は触らせない" do
      # 当てずっぽうで座標を書くと、正しかったものが落ちる
      assert Dining.check_prompt() =~ "確かめられなかった座標は触らない"
    end

    test "座標が違うのは、消す理由にしない" do
      # 住所がこの範囲の外を指していても、消すと名簿から消えたままどの区画にも
      # 戻ってこない。直せば次の回から本来の区画に並ぶ
      # （実測で、座標と住所が食い違う店が墓標で消されていた）
      for prompt <- prompts() do
        assert prompt =~ "消す理由ではありません"
        assert prompt =~ "消さずに正しい緯度・経度へ直してください"
      end
    end

    test "人が確かめた位置の店は、座標を直させない" do
      for prompt <- prompts() do
        assert prompt =~ ~s(tags に "#{Chiezo.locked_tag()}" が付いた店は、人が現地で確かめた位置です)
      end
    end

    test "「本来の区画へ移す」ために消させない" do
      # 移す手立ては座標を直すことだけ。消すと、移った先の回はその店を知らず、
      # 墓標が機械の名簿からの復帰も止める
      # （実測で 2 件、「本来の区画へ移動」と書いて消されていた）
      for prompt <- prompts() do
        assert prompt =~ "「本来の区画へ移す」ために消すのも同じです"
      end
    end

    test "集めるのはイートインできる店だけ" do
      # travel-log は「食べに行く先」の地図で、買って帰る店は行き先にならない。
      # 書いていなかった頃は、同じ持ち帰り専門店が回によって残ったり消えたりした
      for prompt <- prompts() do
        assert prompt =~ "その場で食べられるかで分けてください"
        assert prompt =~ "持ち帰りもやっている店は残してください"
      end
    end

    test "1 件に潰れた別々の店は、分けさせる" do
      # 名簿は見出しで同じものかを決めているので、同名の別店が 1 件になる
      # （実測で、百科事典の東京の店と、地図辞典の別の県の同名店が
      #  1 件に潰れ、本文と座標が別の店のものになっていた）
      assert Dining.check_prompt() =~ "1 件に別々の店が混ざっていたら"
      assert Dining.check_prompt() =~ "新しい見出しで"
    end

    test "足すものには必ず座標を入れさせる" do
      # 座標の無いものはどの区画にも入らず、次に見たときには「まだ無い」と見える
      for prompt <- prompts() do
        assert prompt =~ "足すものには必ず座標を"
        assert prompt =~ "lat"
      end
    end

    test "travel-log が読むタグを、どちらの回にも同じ形で書く" do
      # 書き分けると、回によって別の形が返ってくる
      for prompt <- prompts() do
        assert prompt =~ Dining.kind_tag()
        assert prompt =~ Dining.genre_tag()
        assert prompt =~ Dining.area_tag()
        assert prompt =~ Dining.rank_tag()
        assert prompt =~ Dining.feature_tag()
      end
    end

    test "特徴は語彙から選ばせ、確かめられたものだけ付けさせる" do
      # 表記が割れると travel-log の絞り込みが効かない。付いた印は「そうだ」と読まれる
      for prompt <- prompts() do
        for feature <- Dining.features(), do: assert(prompt =~ feature)
        assert prompt =~ "新しい語は作らない"
        assert prompt =~ "確かめられたものだけ"
      end
    end

    test "地域の空いているものを、どちらの回でも必ず埋めさせる" do
      # 名簿の元の店舗辞典は日本では都道府県がほとんど空で、そのままだと
      # travel-log は地図に置けない（region が必須）
      for prompt <- prompts() do
        assert prompt =~ "必ず埋めて"
        assert prompt =~ "都道府県"
      end
    end

    test "いま付いているタグを消させない" do
      # 返した内容で丸ごと置き換わるので、書かなかったタグは消える
      for prompt <- prompts(), do: assert(prompt =~ "そのまま残してください")
    end

    test "同じ店が 2 つに分かれていたら、まとめさせる" do
      # 辞典ごとに名前の書き方が違うので機械では畳めない
      # （実測で、同じ範囲の地図辞典と店舗辞典で名前が一致するのは 3%）
      for prompt <- prompts() do
        assert prompt =~ "同じ店が 2 つに分かれていないか"
        # **どちらを残すかを決めさせない。** 回ごとに違う値が残ると、
        # 直したはずの座標が次の回で元へ戻る
        assert prompt =~ "座標は \"出典:OSM\""
        assert prompt =~ "説明は \"出典:Wikipedia\""
      end
    end

    test "出典の印は AI に触らせない" do
      # 機械が付けたもの。足させると、辞典に載っていない店にも印が付く
      for prompt <- prompts(), do: assert(prompt =~ "足したり消したりしないでください")
    end
  end

  test "travel-log に渡す項目が、画面に出せる形で並ぶ" do
    # ここに書いていない項目は向こうで空欄になるので、気づけるようにする
    rows = Dining.fields()

    assert Enum.all?(rows, &match?(%{field: _, stored: _, who: _}, &1))
    assert Enum.any?(rows, &(&1.field =~ "座標"))
    assert Enum.any?(rows, &(&1.field =~ "ランク"))
  end

  describe "範囲ごとの収集" do
    test "収集の名前は範囲ごと" do
      assert Dining.collection(@area) == "chidori_dining_3"
      assert Dining.definition(@area).collection == "chidori_dining_3"
    end

    test "3 つの辞典を範囲の四角で絞る" do
      specs = Dining.extract(@area)

      assert Enum.map(specs, & &1.source) == ["jawiki", "osm_japan", "overture_japan"]
      for spec <- specs, do: assert(spec.bbox == [35.67, 139.75, 35.69, 139.78])
    end

    test "区画は範囲の四角を、細かく割る" do
      partition = Dining.partition([35.68, 139.765], @area)

      assert partition.bbox == [35.67, 139.75, 35.69, 139.78]
      assert partition.target == Dining.area_partition_target()
    end

    test "起点の既定は範囲の真ん中" do
      origin = Dining.default_origin(@area)

      assert {origin.lat, origin.lon} == {35.68, 139.765}
    end

    test "依頼の中身も範囲のもの" do
      attrs = Dining.attrs(%{}, @area)

      assert attrs.name == "chidori_dining_3"
      assert attrs.partition.bbox == [35.67, 139.75, 35.69, 139.78]
      assert Enum.all?(attrs.extract, &(&1.bbox == [35.67, 139.75, 35.69, 139.78]))
    end

    test "ざっと見るで早めに一周し、そのあとは整理がゆっくり回る" do
      sweeps = Dining.sweeps(@area)

      assert Enum.map(sweeps, & &1.name) == ["機械収集", "ざっと見る", "整理"]
      scan = Enum.find(sweeps, &(&1.name == "ざっと見る"))
      tidy = Enum.find(sweeps, &(&1.name == "整理"))

      assert scan.after == "機械収集"
      assert scan.one_lap
      assert tidy.after == "ざっと見る"
      # 閉店も開店も続くので、整理は一周しても止めない
      refute Map.get(tidy, :one_lap)
      # 整理のほうが遅い（AI の枠の節約）
      assert tidy.interval_minutes > scan.interval_minutes
      assert tidy.cover_days > scan.cover_days
      # ざっと見るは収集の依頼文、整理は自分の依頼文
      refute Map.has_key?(scan, :prompt)
      assert tidy.prompt == :tidy
    end

    test "割り込みも travel-log からの依頼も整理が引き受ける" do
      definition = Dining.definition(@area)

      assert definition.survey_sweep == "整理"
      assert definition.request_sweep == "整理"
      assert definition.partition_sweeps == ["ざっと見る", "整理"]
    end

    test "ざっと見るは、1 件ずつ営業を確かめさせ、足りない店も足させる" do
      prompt = Dining.check_prompt()

      assert prompt =~ "1 件ずつ確かめる"
      assert prompt =~ "web で確かめて"
      assert prompt =~ "見つからないだけでは消さないで"
      assert prompt =~ "足りない店を足す"
      assert prompt =~ "足すものには必ず座標を入れて"
      assert prompt =~ "not_reviewed"

      # 申告するのは時間切れの店だけ。情報が見つからなかった店は見たうえで残す
      # （申告すると地図に出ないまま、次の回も同じく見つからずに残り続ける）
      assert prompt =~ "時間切れで手を付けられなかった店だけ"
      assert prompt =~ "情報も閉店の情報も見つからなかった店は、申告しないで"
      assert Dining.attrs(%{}, @area).prompt == prompt
    end

    test "どの依頼文にも、隣の区画にある店を見せて足させない" do
      # 区画の中しか見せないと、密集した地区では境目の向こうの店を足し直す
      for prompt <- prompts() do
        assert prompt =~ "{nearby}"
        assert prompt =~ "隣の区画にある店"
      end
    end

    test "営業日と営業時間を、確かめられた店だけ OSM の書き方で埋めさせる" do
      # 朝食営業・ランチ営業・深夜営業の印は、この書き方から機械で読み取る（`OpeningHours`）
      for prompt <- [Dining.tidy_prompt(), Dining.check_prompt()] do
        assert prompt =~ "extra.opening_hours"
        assert prompt =~ "確かめられたときだけ"
        assert prompt =~ "Mo-Fr 11:00-14:30,17:30-22:00; Sa,Su,PH 11:00-21:00; We off"
      end

      assert Chidori.Datasets.OpeningHours.features("Mo-Fr 11:00-14:30,17:30-22:00; We off") ==
               [:lunch]
    end

    test "整理は、報告・まだ目を通していない店・足りない店を先にし、見直しは残りの時間で" do
      prompt = Dining.tidy_prompt()
      order = fn needle -> prompt |> :binary.match(needle) |> elem(0) end

      # travel-log からの報告が第一
      assert order.("1. 地図を使っている人からの報告") < order.("2. まだ目を通していない店")
      assert order.("2. まだ目を通していない店") < order.("3. 足りない店を足す")
      assert order.("3. 足りない店を足す") < order.("4. 埋まっていない情報がある店")

      # 空いている欄（とくに営業時間）を埋めるのは、足りない店の次・見直しの前
      assert order.("4. 埋まっていない情報がある店") < order.("5. 時間が残っていたら")
      assert prompt =~ "営業日と営業時間（`extra.opening_hours`）が無い店"
      assert prompt =~ Chidori.Chiezo.unreviewed_tag()
      # 閉店の取りこぼしは多いので、見直しもやめない
      assert prompt =~ "とくに閉店です"
      # 一度確かめた店を申告させない（区画が毎回先頭に戻ってくる）
      assert prompt =~ "見直せなかった店は申告しないで"
      # 範囲の外の店は隣の区画にいるので挙げない
      assert prompt =~ "足すのは範囲の中の店だけ"
      # 探し方・見直し方を具体的に書く（漠然と頼むと最小限で終える）
      assert prompt =~ "その町名・丁目の飲食店の一覧"
      assert prompt =~ "「閉店」「閉業」「移転」の表示が無いか"
      # 何を調べたかを残させる（あとで確かめられるように）
      assert prompt =~ "`checked`"

      attrs = Dining.attrs(%{}, @area)
      assert Enum.find(attrs.sweeps, &(&1.name == "整理")).prompt == prompt
      assert Dining.prompts(@area) == [{"ざっと見る", Dining.check_prompt()}, {"整理", prompt}]
    end

    test "範囲で決まるところだけを取り出せる（範囲を直したときに送る）" do
      shape = Dining.shape(@area)

      assert Map.keys(shape) |> Enum.sort() == [:description, :extract, :partition]
      assert shape.partition.bbox == [35.67, 139.75, 35.69, 139.78]
      assert shape.description =~ "東京駅"
    end

    test "travel-log へは範囲によらず同じ種別に書き出し、key に範囲の番号を付ける" do
      definition = Dining.definition(@area)

      assert definition.export_key == "dining"
      assert definition.key_prefix == "3-"
    end
  end
end
