---
paths:
  - "lib/chidori/relations.ex"
  - "lib/chidori/relations/**"
  - "lib/chidori/artwork.ex"
  - "lib/chidori_web/live/relations_live*"
  - "lib/chidori_web/controllers/face_controller.ex"
  - "lib/chidori_web/components/fullscreen_button.ex"
  - "assets/js/relation_map.js"
  - "assets/js/pan_zoom.js"
  - "test/chidori/relations/**"
  - "test/chidori/relations_test.exs"
  - "test/chidori/artwork_test.exs"
---

# 関連図

詳しい説明と理由（実測値つき）は `docs/relations.md`。

- 画家の図（収集は網羅）と芸能人の図（`Chidori.Relations.People`・収集 `chidori_people`）は同じ仕組み。図の読み方の違いは
  `Graph.from_docs/2` に渡す仕様に寄せてあり、画家の図はその既定
- 名簿・年代・様式は AI に書かせない。Chidori が条件を言葉で書き、Chiezo が抽出の指定にして jawiki から機械的に引く。
  指定を書けなかったときは収集を作らず、理由を画面に出す。名簿は `tag_suffix`（「〜の画家」）で指し、地域も年代も絞らない
- 丸の大きさは jawiki の月次ページビュー（`extra.pageviews_month`。機械が写す事実）。AI が直すのは別の鍵の倍率（`extra.fame_scale`）。同じ鍵を書き換えさせない
- 誰を見るかは AI に選ばせない。Chiezo が区画（地域 × 生年。1 年より細かく割らない）を割って渡す。区画の所属は Chiezo と同じ規則で
  `Chidori.Relations.Partitions` が割り出す
- 巡回は 名簿（一度きり）→ ざっと（年代と地域を最優先。一周したら止まる）→ 調査。割り込みは調査の回に頼む
- 図の構造は Chiezo に持ち込まない（1 画家 = 1 文書 + タグ `画家`・`様式:`・`年代:`・`影響元:<名前>:<説明>`）
- 図を開くたびに Chiezo へ聞きに行かない（最後に取得した時刻を出し、取り直すかは読む人が決める）。設定は開いたときに読む
- 芸能人: 夫婦が最優先。公表されている関係だけ、未成年の家族と記事の無い家族は書かせない。グループは名簿に入れず枠で描く。
  顔写真は Commons のものだけを 1 人 1 回、横 120px の縮小版を Chiezo に作らせ（`Chiezo.thumb_of/2`。Wikimedia へは出ない）、
  DB（`face_thumbs`）に写して `/faces/:id` から配る。
  押すと Commons のファイルのページ（出典とライセンス）へのリンクを出す
- 映画（`Chidori.Relations.Films`・収集 `chidori_films`）: 札は作品だけ。名簿・監督・公開年・国は分類から機械で
  （「〜の監督映画」の `tag_suffix` と主な賞の受賞作の `tag`、知名度で下を切る）、主演だけ AI（`verify_tags` で実在の記事に限る）。
  同じ監督と同じ主演は、どちらも公開年順に隣どうしを結ぶ線（`edge_rules` の `shared`。種類 `:director` と `:costar` で色を分ける）。
  監督の枠は使わない（枠は 1 つの高さにしか置けず、縦の公開年が崩れた）。横は国の帯（`@country_bands`。合作は先に当たる帯）。
  受賞作は知名度の下限を免除する（Chiezo の `min_extra_unless_tag`）。主演の名前は芸能人の図へ飛ぶ（`?view=people&focus=<名前>`）。
  芸能人の名簿は海外の俳優も（「〜の男優」「〜の女優」の `tag_suffix`）
- 映画の図には新しい作品も引き継ぐ（`Chidori.Relations.FilmCarry`）。最新情報の映画のうち見た記録を付けたものと注目度が高く公開済みのもの、
  図の画面の「見た映画を足す」で書いたものを、図の収集への割り込みで AI に足させる（Chidori の時計が決めた時刻に。画面からは押した 1 回で）。
  引き継いだ作品は元の見出しを `記録:<見出し>` で持つ。済んだかは図の作品の見出しと `記録:` の両方で数える
  （図の札に直接付けた記録も同じ置き場に入るため。図の作品を 500 件ずつページを送って読む）。全部は入れない（最新情報は年に数百本）。
  頼む順は見た作品（見た日の新しい順）→ 注目度の高い作品（公開日の新しい順）。頼めた回数を作品ごとに数え（`attempts`）、
  3 回頼んでも載らない作品は時計から外す（枠の頭を占め続けないように）。画面からは「いま頼む」（時計と同じ並びで上から
  1 回の数まで。押した 1 回なので止めた収集でも走り、時計の記録は動かさない）と、外した作品の「この作品を頼む」で頼める。
  時刻（JST。既定は空 = その Chidori からは頼まない。本番とテストの二重を避けるため）・1 回の数と、前回いつ何を頼んで
  どうなったかは表 `film_carry_settings`（`Chidori.Relations.CarrySetting`）。時刻は設定ページの「Chiezo 収集」の表の
  映画の図の行（`CollectOverview.chidori_rows/1`。Chiezo へは送らない行）で直す。過ぎて 30 分までの回を拾い、
  済まなかった回は次の予定まで試し直す。時計の回は画面から足した 1 回と別に数える（`clock_at`）。
  映画の図には前回と次の予定を出し、待っている作品は押したときだけ Chiezo に聞く。
  同じ作品の二重足しを避けるため、図の見出しの前方一致と全文検索で似た作品を名指しして見せる
- 映画の図の見た記録は最新情報の映画と同じ置き場（`movies`）。札の記録は札の名前か `記録:` の見出しで引く（`Films.marks_by_node/2`）。
  図に載っていない記録は「まだ図に無い」として出す
- 代表作の説明と絵は Chiezo の jawiki から引く（`Chidori.Artwork`。絵は Chiezo に縮小版を作らせ `/thumbs/…` から出す。
  Commons 以外は出さない。結果は 1 日覚える）
- 見た記録は `chidori_data` に 1 ノード 1 件（`Chidori.Relations.Marks`）。収集には書かない
- 札は 2 回押して開く。1 回目は札・線・線の先を立たせ（`picked`。名前で持つ。`pick_of/2`）、2 回目で詳細。余白で戻す（`unpick`）
- 図の操作は `assets/js/pan_zoom.js` を関連図・トピックの網・区画の地図・県の地図で共有する。拡大は `viewBox` を動かす（CSS の transform で引き伸ばさない）。
  図ごとの事情だけを `relation_map.js` に足す
