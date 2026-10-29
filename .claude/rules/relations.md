---
paths:
  - "lib/chidori_web/components/seen_films.ex"
  - "test/chidori_web/live/seen_films_test.exs"
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

- 関連図はどれも頭のメニューの「趣味」に並べる（`Relations.hobby?/1`・`Chidori.Hobbies`）。画家の図は「芸術家」、芸能人の図は「芸能人」（レシピの後ろ）のタブ、映画の図は映画のタブの中（最新と四角い札で切り替える。`DiningTabs.movie_tabs/1`）。頭のメニューと収集の画面の頭の段に「関連図」は無い。画面と道（`/relations?view=…`）はそのまま。対象なしで開いたら芸術家の図
- **図を見る画面（`/relations`）と収集の画面（`/collect/relations`）は同じ `RelationsLive`**（`@collect_mode`）。収集の設定・名簿の広さ・区画・消えたもの・依頼文・
  映画の「最新情報からの引き継ぎ」は収集の画面。詳細の「区画を先に見て」「詳しく調べて」は図を見る画面に残す（見ている 1 件から頼む口）。「見た映画を足す」は映画のタブの中の「見た映画」（`ChidoriWeb.SeenFilms`）

- 画家の図（収集は網羅）と芸能人の図（`Chidori.Relations.People`・収集 `chidori_people`）は同じ仕組み。図の読み方の違いは
  `Graph.from_docs/2` に渡す仕様に寄せてあり、画家の図はその既定
- 名簿・年代・様式は AI に書かせない。Chidori が条件を言葉で書き、Chiezo が抽出の指定にして jawiki から機械的に引く。
  指定を書けなかったときは収集を作らず、理由を画面に出す。名簿は `tag_suffix`（「〜の画家」）で指し、地域も年代も絞らない
- 丸の大きさは jawiki の月次ページビュー（`extra.pageviews_month`。機械が写す事実）。Chiezo が控えている月の中央値 `extra.pageviews_median` があれば先に使う（`Graph` の `views_in`。名簿の `extra` に運ばせる。その月の値は新作につられた旧作の閲覧で振られた）。AI が直すのは別の鍵の倍率（`extra.fame_scale`）。同じ鍵を書き換えさせない
- 原作の記事の作品（`記事:`）は、映画化されていれば AI に消させない（`Films.source_work_keep_rule/0`。ざっと見る回と整理の回。消すのは映画の記事が目録に別にあるときと、劇場公開の映画が無いときだけ。「映画ではないもの」を消す決まりだけだった頃は 61 本消された）
- 探す欄は順位でも探せる（「10位」「#10」。`search/2`・`rank_query`。その順位から下を順位の順に。数字だけは題名として探す）
- 札の下の年の行に大きさの順位を添える（「2014 · 10 位」。`fame_ranks/1`。図の全部の札の中で数え、絞った図でも変えない。同じ数なら同じ順位）
- 詳細の主演の下に「知名度」（札の大きさの順位 / 全体の数・閲覧数相当・決め方。`fame_rank/2`・`fame_rank_row`・`Films.size_basis/1`。主演の無い札はタグの最後）
- 詳細の「この〜の区画を見る」は収集の画面の区画の表へ飛び（`/collect/relations?view=…&partition_of=<名前>`）、その 1 件のタグを Chiezo から引いて区画を割り出し（`Relations.partition_key/4`・`target_partition/3`）、表を開いてその行を目立たせて画面の真ん中へ寄せる（`chidori:reveal`）
- 誰を見るかは AI に選ばせない。Chiezo が区画（地域 × 生年。1 年より細かく割らない）を割って渡す。区画の所属は Chiezo と同じ規則で
  `Chidori.Relations.Partitions` が割り出す
- 巡回は 名簿（一度きり）→ ざっと（年代と地域を最優先。一周したら止まる）→ 調査。割り込みは調査の回に頼む
- 図の構造は Chiezo に持ち込まない（1 画家 = 1 文書 + タグ `画家`・`様式:`・`年代:`・`影響元:<名前>:<説明>`）
- 図を開くたびに Chiezo へ聞きに行かない（最後に取得した時刻を出し、取り直すかは読む人が決める）。例外は映画の図で、開くたびに取り、取得の行を出さない（`refresh_on_open?/1`）。設定は収集の画面を開いたときに読む（設定の枠は開け閉めしない）。収集の画面には図を取り直す口を出さない（図を描かない。区画の未レビューの数だけは区画の表の横で取り直す）。収集の画面の設定欄の下に最近の回（`ChidoriWeb.RecentRuns`。趣味の収集の画面と共通）。図の見出しはいつも定義から（`Relations.public/2`）
- 芸能人: 夫婦が最優先。公表されている関係だけ、未成年の家族と記事の無い家族は書かせない。グループは名簿に入れず、同じ `グループ:` の人どうしを線で結ぶ（`shared`。枠は縦の年代を崩すので使わない）。
  線の色は夫婦が赤・家族が橙・グループと映画の監督が青。
  顔写真は Commons のものだけを 1 人 1 回、横 120px の縮小版を Chiezo に作らせ（`Chiezo.thumb_of/2`。Wikimedia へは出ない）、
  DB（`face_thumbs`）に写して `/faces/:id` から配る（Chiezo が Wikipedia のオフライン版から返したら（`Chiezo.thumb_from/2` の `offline`）1 分待たずに 1 秒で次を頼む。レシピ集の写真と技術書の表紙 `covers/1` もここで取る。幅は呼ぶ側が決める `faces/2`）。
  押すと Commons のファイルのページ（出典とライセンス）へのリンクを出す
- 映画（`Chidori.Relations.Films`・収集 `chidori_movie_catalog`）: 札は作品だけ。名簿・監督・公開年・国・ジャンルは分類から機械で
  （国は分類の頭を `@countries` の表で引く（`map`。主な国の外も「ほかの国」の帯）、分類に国が無い作品は AI に製作国を足させる（`machine_rule`）。ジャンルは分類の中の語を `@genres` の表で読み替え、国もジャンルも Chiezo の `fill` で既にいる作品にも渡す。札の 2 行目は国・ジャンル 3 つまで = `graph_spec` の `note_prefix`）
  （「〜の監督映画」と公開年の分類「〇〇年の映画」「〇〇年のアニメ映画」の `tag_suffix`（監督の分類が記事に無い有名作が漏れた）と主な賞の受賞作の `tag`（日本アカデミー賞最優秀外国作品賞も）、知名度で下を切る。下限は月 3,000 のまま —— 上げても入った作品は消えず、入り口ごとに食い違うだけ）、主演だけ AI（`verify_tags` で実在の記事に限る）。
  同じ監督と同じ主演は、どちらも公開年順に隣どうしを結ぶ線（`edge_rules` の `shared`。種類 `:director` と `:costar` で色を分ける）。
  監督の枠は使わない（枠は 1 つの高さにしか置けず、縦の公開年が崩れた）。縦は上が新しい（`newest_first`。置き終えた図を `Graph` が上下に裏返す。目盛りも）。横は国の帯（`@country_bands`。合作は先に当たる帯）。
  受賞作は知名度の下限を免除する（Chiezo の `min_extra_unless_tag`）。Wikipedia の相互リンクの線（`関連:`）は映画の図では引かない（`graph_spec` の `related: false`）。作品の詳細の主演・監督の名前は、詳細を閉じてその人の作品の鎖を立たせる（`pick_person` → `picked_edge` に `{:chain, {頭, 名前}}`・`pick_of/2`）。同じ監督・同じ主演の線の詳細はその人（jawiki の冒頭・芸能人の図で探す `?view=people&focus=`（札が無ければ名前で探した形 `apply_pending_focus`）・図にある作品（押すと `focus_film`）。`edge_people/3`）。名簿が原作（小説・漫画など）の記事を指す作品は、名簿を引くときに記事の 1 文目の主語から機械で `記事:<原作の種類>`（小説・漫画・ライトノベル・アニメ・ドラマ・ゲーム）を付け（Chiezo の読み替えの `on: "lead"`・`map`・`fill`。`Films.source_work_pattern/0`。分類では見分けない —— 映画の記事にも小説版・漫画版の分類が付く）、閲覧数を小説は 5 割・ほかは 2 割に割り引く（小説は映画で知られることが多く、漫画などは原作やアニメの人気で読まれる）。閲覧数の当てにならない作品（原作の記事・引き継いだ・足した作品）は AI の話題度（`extra.fame_level`。1〜10・閲覧数相当は基準から話題度が 4 下がるごとに 10 分の 1 `fame_views/2`（10 分の話題度の大きさにしていた頃は、漫画の実写作品が大きすぎた）。整理の回（`記事:` と `記録:` の作品だけ）と引き継ぎの回が書く `fame_rule`。映画だけの記事の作品には使わない）を先に使い、閲覧数の無い作品はまず Chiezo の jawiki の記事の閲覧数（`Relations` の `wiki_views/2`。半日覚える。記事の 1 文目も引き、原作の記事なら同じ率で割り引く `Films.source_kind_of/1` —— 引き継いだ作品の記事名は原作の記事への転送のことが多い。1 文目の取り出しは Chiezo の `lead_sentence` と揃える `Films.lead_sentence/1`）、記事も無ければ注目度で控えめに（基準に対して高 4 割・中 3 割・引き継いだ・足した作品 2 割の大きさ。最大にしない。`Films.with_new_film_views/3`・引き継ぎの依頼文で `注目度:` タグを写させる）。札の絵は Chiezo の `thumb` を記事の画像より先に使い（`with_faces`）、ポスターと上映時間（`extra.runtime_minutes`）は整理の回に探させる（`show_blanks: ["thumb", "runtime_minutes", "fame_level"]`）。主演の名前は芸能人の図へ飛ぶ（`?view=people&focus=<名前>`）。
  芸能人の名簿は海外の俳優も（「〜の男優」「〜の女優」の `tag_suffix`）
- 映画の図には新しい作品も引き継ぐ（`Chidori.Relations.FilmCarry`）。最新情報の映画のうち見た記録を付けたものと注目度が高く公開済みのもの、
  見た映画のページ（`ChidoriWeb.SeenFilms`）の「見た映画を足す」で書いたものを、図の収集への割り込みで AI に足させる（Chidori の時計が決めた時刻に。画面からは押した 1 回で）。
  引き継いだ作品は元の見出しを `記録:<見出し>` で持つ。済んだかは図の作品の見出しと `記録:` の両方で数える
  （図の札に直接付けた記録も同じ置き場に入るため。図の作品を 500 件ずつページを送って読む）。全部は入れない（最新情報は年に数百本）。
  頼む順は見た作品（見た日の新しい順）→ 注目度の高い作品（公開日の新しい順）。頼めた回数を作品ごとに数え（`attempts`）、
  3 回頼んでも載らない作品は時計から外す（枠の頭を占め続けないように）。画面からは「いま頼む」（時計と同じ並びで上から
  1 回の数まで。押した 1 回なので止めた収集でも走り、時計の記録は動かさない）と、外した作品の「この作品を頼む」で頼める。
  時刻（JST。既定は空 = その Chidori からは頼まない。本番とテストの二重を避けるため）・1 回の数と、前回いつ何を頼んで
  どうなったかは表 `film_carry_settings`（`Chidori.Relations.CarrySetting`）。時刻は収集の画面（`/collect`）の表の
  映画の図の行（`CollectOverview.chidori_rows/1`。Chiezo へは送らない行）で直す。過ぎて 30 分までの回を拾い、
  済まなかった回は次の予定まで試し直す。時計の回は画面から足した 1 回と別に数える（`clock_at`）。
  映画の図には前回と次の予定を出し、待っている作品は押したときだけ Chiezo に聞く。
  同じ作品の二重足しを避けるため、図の見出しの前方一致と全文検索で似た作品を名指しして見せる
- 映画の図の見た記録は最新情報の映画と同じ置き場（`movies`）。札の記録は札の名前か `記録:` の見出しで引く（`Films.marks_by_node/2`）。
  新しく書くときは `記録:` の元の見出しで書く（`Films.mark_key/2`。最新情報の画面はその見出しでしか引かない）。札の名前で書かれてしまった記録は、
  図を読み込んだときに元の見出しへ移す（`Films.align_marks/1`。元の見出しに既にあれば動かさない）
- 代表作の説明と絵は Chiezo の jawiki から引く（`Chidori.Artwork`。絵は Chiezo に縮小版を作らせ `/thumbs/…` から出す。
  Commons 以外は出さない。結果は 1 日覚える）
- 見た記録は `chidori_data` に 1 ノード 1 件（`Chidori.Relations.Marks`）。見た印を付けた（見た日を変えた）時刻を脇書き `detail.seen_at` に残し、見た映画のページは同じ日なら記録した新しい順（時刻の無い前の記録は記録の番号の順。`SeenFilms.seen/1`）。探す欄の隣の「見た作品」は見た印のある記録だけ（`seen_options/2`）。収集には書かない。
  印のある札は橙の枠（`marked`）、「見た」の印のある札は札の右上に上の縁から垂らした黄色いしおり（`is-seen`・`seen?/2`・`flag_path/1`。名前はそのぶん左へ寄せる `name_x/2`）、図の下に見た数（`seen_count/2`）と「見ていない作品だけにする」（`unseen_only`。映画の図は隠した状態で開く `unseen_by_default?/2`、`focus` を指して開いたときは隠さない。探して選んだ作品・押した札は隠さない `revealed_names/2`。いまは見られない印（`Mark.unavailable_on`。記録の `detail` に持つ）の作品も一緒に隠す（`unavailable_shown` で出す。札の詳細で付け外し、図の下に畳んだ一覧 `unavailable_rows/2`。「サブスクを探す」は `Films.subscription_search_url/1`）。`Graph.without/2` で除いて置き直し、共通項の鎖は残った札でつなぎ直す。ほかの絞り込みと重ねられる）
- 映画の図は表示する作品を知名度で絞れる（`fame_floor`。すべて / 3,000 / 1 万 / 3 万。開いたときは 1 万 `default_fame_floor/1`。札の大きさと同じ閲覧数で比べ、見た記録・印のある作品・選んだ作品は残す `below_floor/3`。引き継いだ作品も特別扱いしない。小説以外の原作の記事の作品は話題度が付くまで外す `Films.unrated_source_work?/1`）。見ていない作品だけと一緒に 1 度で外して置き直す（`shown/2` → `hidden_names`）。置き直しは全体の図と同じ置き方を名指しする（`Graph.without(.., layout: :full)`。読ませる置き方 `fitted_columns` はいちばん長い作品名に合わせて列を決め、数十本でも縦に並ぶだけになった。名指ししない絞り込みは 150 本までなら読ませる置き方 `@fitted_max`）。公開から間もない作品は閲覧数を割り引く（`Films` の `@recency_shares`・`settled/2`。今年 3 割〜3 年前 8 割）
- 札は 2 回押して開く。1 回目は札・線・線の先を立たせ（`picked`。名前で持つ。`pick_of/2`）、共通項の線（`shared`。線は `value` と、同じ 2 本が共にする共通項の全部 `values` を持つ）は鎖ごと立たせる。立たせた札（`pick.near`）は小さくても重なっても描き、押した札をいちばん先に置く（`drawn_nodes/3`。描くのはいちばん上 `paint_order/2` —— 鎖の相手は重なっても描くので、下に置くと 2 回目の押し込みを相手に取られた）。線も 2 回押して開く。1 回目はその線と両端（共通項の線ならその鎖だけ）を立たせる（`picked_edge`。`pick_of(relation, {from, to, kind})`。札は選ばない）。2 回目で詳細。余白で戻す（`unpick`）。線の当たり判定（`.edge-target`）は画面の px で太さを決める（`vector-effect: non-scaling-stroke`。22px、指で触る画面は 34px）。札の外側でも縁から 14px（マウスは 4px）以内の押し込みは札を押したことにする（`relation_map.js` の `nodeNear`。線は札の真ん中へ入るので、太い当たり判定が小さな札の 2 回目の押し込みを横取りしていた）
- 図の読み込み中の印（`statuses` の `:loading`）は、その図を読むタスクがもう無いか 5 分を過ぎていれば残った印とみなして読み直す（`stale_loading?/2`。コードの読み直しでタスクの終わりを取りこぼし、古い図を出し続けたため）
- 道具の段（`.relation-bar` = 探す欄・見た作品・拡大縮小）は、普段は図の外（器の中の上）に置き、全画面（器の `is-full`。`pan_zoom.js` の `markFull`）では図の上に重ねる。縦横比は図の svg が持つ（`canvas_style/2`）ので、倍率と位置は器ではなく svg で測る（`measureSvg`）。全画面では高さか幅の大きいほうに合わせて画面いっぱいに描き（`fillOnFullscreen` → `fill`）、図の端は道具の段・下端の帯の名前・（狭い画面で右に縦に並べた）ボタンのぶん空ける（`insets`。端まで寄せてもその内側に止まる）。帯の名前（横軸）は下端に留め、全画面では下の案内を出さない。図の外の押し込みは図の操作にしない（`tapped` は svg の中だけ）
- 図の操作は `assets/js/pan_zoom.js` を関連図・トピックの網・区画の地図・県の地図で共有する。拡大は `viewBox` を動かす（CSS の transform で引き伸ばさない）。
  図ごとの事情だけを `relation_map.js` に足す。本物の全画面が使えない端末（iPhone）の代わりの形（器の `faux-fullscreen`）は、
  広げているかを hook が持ち（`this.faux`）、描き直しで class が消えたら `updated()` で付け直す（器の class は `has-pick` のように中身で変わる）。札・線の詳細（`.artwork-backdrop`。器の外）は全画面より手前（z-index 65 > 60）に出し、本物の全画面の中で開いたら代わりの形に切り替える（サーバーの `modal_open` → `relation_map.js`。本物の全画面では器の外が描かれない）
