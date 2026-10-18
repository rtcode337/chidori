---
paths:
  - "lib/chidori/datasets.ex"
  - "lib/chidori/datasets/**"
  - "lib/chidori/geo/**"
  - "lib/chidori_web/live/datasets_live*"
  - "lib/chidori_web/live/dining_areas_live*"
  - "lib/chidori_web/components/dining_tabs.ex"
  - "lib/chidori_web/controllers/datasets_controller.ex"
  - "lib/chidori_web/controllers/thumb_controller.ex"
  - "lib/chidori_web/components/partition_map.ex"
  - "assets/js/area_draw.js"
  - "assets/js/partition_map.js"
  - "lib/chidori_web/components/prefecture_map.ex"
  - "assets/js/prefecture_map.js"
  - "scripts/build_prefectures.py"
  - "assets/js/gsi_tiles.js"
  - "priv/geo/**"
  - "test/chidori/datasets/**"
  - "test/chidori_web/controllers/**"
  - "test/chidori_web/live/datasets_*"
  - "test/support/area_fixture.ex"
---

# データ収集（技術書・Pi-hole・ご当地グルメ・食事処）

詳しい説明・travel-log の項目との対応表・実測値は `docs/datasets.md`。

- 他のアプリで使うデータを集めさせる画面。溜まったものは見せない（例外は読む側のアプリを持たない技術書の本棚と Pi-hole）。
  対象は `Chidori.Datasets.defined/0` に 1 つ書けばタブも依頼も増える
- 技術書: 本ではなく勧めている記事を溜める（`chidori_book_posts`）。数は機械が数え、AI は数に触らない（畳む・分野・説明だけ）。
  検索文は回ごとに巡回の相手が考え、控えるのは Chiezo。調べ終えたものは調べ直さない（`{unreviewed}`）
- Pi-hole: 繋ぐのは Chiezo（接続先とパスワードは Chiezo 側）。Chidori は Pi-hole に直接つながらない
- 食事処: 範囲ごとに収集が 1 つ（`Chidori.Datasets.DiningAreas`・`chidori_dining_<番号>`。Chiezo に同じ名前が残っている番号は使わない）。
  データ収集のタブは「食事処」1 つで、範囲ごとのタブはその下の段（`ChidoriWeb.DiningTabs`。「全体」= `/datasets/areas` と範囲ごと）
- 名前と座標は AI に書かせない。名簿は 3 つの辞典（`jawiki`・`osm_japan`・`overture_japan`）を範囲の四角（`bbox`）で絞って引く。
  どの項目をどの辞典から採るかは決めてあり、順位を譲った辞典の値も空いたところを埋めるのに使う
- 区画は座標で割り、1 区画 20 件の目安（1 件ずつ確かめさせるため）。母集団は収集自身、矩形は範囲の四角
- 巡回は 名簿 → ざっと見る（一周したら止まる）→ 整理（ゆっくり回り続ける。割り込みと travel-log からの依頼もここ）
- 座標のずれは消す理由にしない。イートインできる店だけを集める。閉店は墓標で消し、理由を本文に書かせる
- travel-log からの依頼（`Chidori.Datasets.Requests`）は貼っても即座に頼まず控え（`pending_requests`）、区画ごとにまとめて整理の 1 回で頼む。
  区画が矩形でない対象（ご当地グルメ）は控えるときに区画の鍵を決めて残す（`partition_key`。対象の `request_partition/1`。
  名前の出てくる依頼は近くの同じ名前の料理の県、追加は座標の県）。前置きは対象が持っていればそれ（`request_preface/0`）。
  補足は区画ごとに分けて渡す。1 回 20 区画まで。「位置確認」「位置修正」の行は AI に渡さず Chiezo の locks で座標を固定する。
  人が閉店と報告した店は頼む直前に固定を外す（`Requests.release_closed/2`）
- travel-log への書き出しは `Chidori.Datasets.TravelLog`。行を自分で組む対象（`spot/2`。ご当地グルメ）は列（`csv_header/0`）も
  説明文もランクもその対象が決め、地図に置けない 1 件（座標が無い）の key は exclude.txt に入れる。travel-log に Chidori の決めごとを持たせず、向こうの形（`settings.json`・`spots.csv`・`exclude.txt`）に直す。
  key は食事処が `<範囲の番号>-<doc_id>`・ご当地グルメが `doc_id`、シリーズの並びと色は Chidori の語彙の順で固定、説明には 1 件ごとに出典を添える（辞典ごとにライセンスが違う）。
  URL は Chiezo に確かめさせた結果で選ぶ（`Chidori.Datasets.ShopLinks`）
- ご当地グルメ（`Chidori.Datasets.Gourmet`・`chidori_gourmet`。全国で 1 つ）: 1 件は料理（土産・駅弁・食材も）、ピンは確実に食べられる・買える代表店
  （本店 → とりわけ有名な店 → 行きやすい店。県の外でもよい。発祥店はタグ）。区画は県（`by=tag`・`values` に 47 県を東京都から JIS 順）。
  名簿は百科事典の「県の名前が付いた」食のカテゴリ（県の麺料理・県の土産菓子・北海道のご当地◯◯）を 47 県 × 括りで組み立てて機械で引き、
  県の農業は同じ県の食文化にも入っている記事だけ（Chiezo の抽出の `tag_pairs`。種類は食材）。
  店・会社・商品・作品の記事と米の品種（`イネの品種`）は `not_tag` で外す。全国・地方の括り、県の食文化・県の菓子は入れない（県が読めない／料理以外が混ざる）。
  一般名の食材（スダチ・ユズ）は地名の有無で分けず、ずば抜けた産地か県・市町村が売り出す名物だけを AI に残させ、地図に出す名前（「徳島のスダチ」）は `extra.display_name`（見出しは鍵なので変えない）
  2 県に入る記事は県ごとに分ける（`split`）。座標は AI に書かせず、AI が書いた代表店の手がかりを Chiezo が辞典に引き当てる（`resolve`）。
  提供の月と営業時間の書式は Chiezo が確かめる（`formats`）。AI に書かせる脇書きの鍵は 8 つ（Chiezo の上限 20 に収める）。
  代表店の状態は 3 つ: あり（座標がある）・まだ（`状態:代表店未定`。手がかりなしも Chiezo が付ける `failed_when_missing`）・
  なし（`状態:代表店なし` + `extra.no_shop` の理由。AI が `"shop": null` と一緒に返す。Chiezo の `none_tag` で未定が外れる）。
  なしは足止めに数えず、書き出さず、整理の ⑤ で日の経ったものから探し直す。終わったものは墓標（なしと混ぜない）。
  巡回は 機械収集 → 整理（機械の名簿の確認・代表店・空欄・見直し・未定が無い回だけ名簿に無い名産を数品足す）→ 情報収集（足すだけ・薄い切り口から。時計では整理の一周を待つ `after`）。どちらも 1 回 1 県。
  整理は代表店未定が残る県を見終わりにしない（`hold_tag`。1 品も減らなければ Chiezo が次へ進める）
  ランクは裏付けと提供店の数から書き出すときに機械で決める（AI に段階を決めさせない）。終わったものは墓標、代表店の閉店は選び直し。
  画面は区画の地図の代わりに県の地図と県ごとの数（料理・代表店あり・代表店まだ（うち引き当てできず）・代表店なし）だけを出し、地図の県か表の「選ぶ」で県を選んで 1 回頼める。
  「AI が見たか」（未確認）は出さない（代表店がまだでも 0 になり紛らわしい）
- 県の地図（`ChidoriWeb.PrefectureMap`・`Chidori.Datasets.Map.prefectures/1`）: 県の境界は手元（`priv/geo/japan_prefectures.json`。Natural Earth の admin-1、
  `scripts/build_prefectures.py` で境目を共有したまま間引く）。範囲を描く地図と同じ枠・メルカトル。塗りは代表店ありの割合の 5 段、引き当てできずは別の印、凡例と
  県名・数の `title` を添える（色だけに頼らない）。離れた島も本当の位置と大きさ（小さい県は拡大か表から）。地図は数が届いたときに 1 回組み、
  選んだ県は上に重ねる 1 本（選び直しで境目を送り直さない）。並びは 地図 → 選んだ県 → 表。押しただけでは走らせない
- 区画の地図: 白地図は手元（`priv/geo/japan_coast.json`。Natural Earth）、寄ると地理院タイル（見る人のブラウザが取る。参照元は送らない）。
  メルカトル。大きさは本当のまま描き、足りないぶんは画面 1px の縁で補う。押しただけでは走らせない
