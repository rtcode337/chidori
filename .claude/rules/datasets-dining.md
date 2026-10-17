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
  - "assets/js/gsi_tiles.js"
  - "priv/geo/**"
  - "test/chidori/datasets/**"
  - "test/chidori_web/controllers/**"
  - "test/support/area_fixture.ex"
---

# データ収集（技術書・Pi-hole・食事処）

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
  補足は区画ごとに分けて渡す。1 回 20 区画まで。「位置確認」「位置修正」の行は AI に渡さず Chiezo の locks で座標を固定する。
  人が閉店と報告した店は頼む直前に固定を外す（`Requests.release_closed/2`）
- travel-log への書き出しは `Chidori.Datasets.TravelLog`。travel-log に Chidori の決めごとを持たせず、向こうの形（`settings.json`・`spots.csv`・`exclude.txt`）に直す。
  key は `<範囲の番号>-<doc_id>`、シリーズの並びと色は Chidori の語彙の順で固定、説明には 1 件ごとに出典を添える（辞典ごとにライセンスが違う）。
  URL は Chiezo に確かめさせた結果で選ぶ（`Chidori.Datasets.ShopLinks`）
- 区画の地図: 白地図は手元（`priv/geo/japan_coast.json`。Natural Earth）、寄ると地理院タイル（見る人のブラウザが取る。参照元は送らない）。
  メルカトル。大きさは本当のまま描き、足りないぶんは画面 1px の縁で補う。押しただけでは走らせない
