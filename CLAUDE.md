# Chidori — Chiezo と利用者のあいだに立つ画面

**日々確認したいニュースや趣味の情報を、関心に合わせて集め・要約し、決めた時刻に知らせる Web アプリ。**
Elixir / Phoenix LiveView 製。知識と AI と収集の時計は [Chiezo](https://github.com/rtcode337/chiezo) が持ち、
Chidori はそれを人に見せ、人の意図（何を集めてほしいか・何に関心があるか）を Chiezo に渡す。

| 相手 | Chidori との関係 |
|---|---|
| Chiezo | 収集を頼み、溜まったものを読む。依頼文・抽出の指定・区画の割り方・巡回は Chidori が書いて送る |
| 利用者 | 画面で読み、関心と記録を書く。要約を ntfy・端末（Web Push）で受け取る |
| travel-log | Chidori が集めさせた食事処とご当地グルメを、travel-log の形の ZIP に直して渡す |
| 売買提案のアプリ | Chiezo の収集（市況ニュースの記事・`pta_market` の要約）を読み書きするだけ |

## 守る線引き

- **題材ごとの事情は Chidori が持つ。** Chiezo は題材を選ばないまま置く。向こうにあるのは
  「1 件 = 1 文書」の普通のソースとタグで、ノードとエッジ・トピック・カレンダーといった読み方を
  与えるのは Chidori 側。図の語彙（どのタグをどう読むか）も Chidori に置く
- **受け取る側に Chidori を知らせない。** travel-log には Chidori の名前も決めごと（タグの書き方）も
  持たせず、こちらが travel-log の形（`settings.json`・`spots.csv`・`exclude.txt`）に直して渡す
  （`Chidori.Datasets.TravelLog`）。売買提案のアプリも Chiezo を読むだけで、Chidori を経由しない
- **機械で取れるものは AI に書かせない。** 名簿・年代・座標・件数は Chiezo の抽出と機械収集で引く。
  AI に頼むのは、そこに書いていないこと（影響関係・説明・営業しているか・重要度などの判断）だけ
- **画面から AI を勝手に動かさない。** 「収集の設定を更新」は収集を止まった状態で作るか送り直すだけで、
  動かすのは Chiezo の管理画面で有効にしたとき。人が押した 1 回だけは、止めた収集でも
  `Chidori.Chiezo.by_hand/1`（`manual=true`）で走らせる。定時の時計は申告しない
- **要約の時刻は Chidori が持つ**（`Chidori.Digest.Scheduler`）。Chiezo には「いま回して」としか言わない
- **選り分けは Chiezo の側。** 消えたもの（`_chiezo_removed`）・未レビュー（`_chiezo_unreviewed`）は
  Chiezo の読み口が既定で外す。Chidori で選り分け直さない
- **データ収集の画面は溜まったものを見せない**（読むのは使う側のアプリ）。例外は読む側のアプリを
  持たない対象（技術書の本棚・Pi-hole）
- **利用者が書いたこと（興味トピック・読んだ/見た記録・ニュースのお気に入り）は Chiezo の置き場 `chidori_data`、**
  その Chidori ごとの設定（トップの並び・通知・控えている依頼）は手元の DB に置く（`Chidori.DataStore`）

## 詳しい記述の置き場（`.claude/rules/`）

このファイルには、どの変更にも効く原則・地図・コマンド・約束事だけを置く。
領域ごとの詳しい記述は `.claude/rules/<名前>.md` にあり、さらに長い説明は `docs/*.md` にある。

- 各ファイルは先頭の `paths` に挙げたファイルを触ると、Claude Code が自動で読み込む
- 該当するファイルを触らずにその領域を相談・設計するときは、下の表から選んで明示的に読む

| ルールファイル | 領域 | 自動で読み込まれる主なファイル |
|---|---|---|
| `docs.md` | ドキュメントの置き場と書き方 | `README.md`・`docs/**`・`CLAUDE.md` |
| `chiezo-client.md` | Chiezo とのやり取りの共通部・収集の一覧と送り直し・巡回名 | `chiezo.ex`・`collect_*.ex`・`sweep_names.ex`・`settings_restore.ex`・`data_store*`・`live/collect.ex` |
| `news-topics.md` | 最新情報・話題・トピックの網・興味トピック・トップページ | `news*`・`topics.ex`・`themes*`・`home*`・`news_live*`・`home_live*` |
| `notify-webpush.md` | 要約の段取りと時計・ntfy・Web Push・設定ページ | `digest*`・`notify*`・`ntfy.ex`・`web_push*`・`settings_live*`・`sw.js` |
| `relations.md` | 関連図（画家・芸能人・映画）・代表作・顔写真・図の操作 | `relations*`・`artwork.ex`・`relations_live*`・`face_controller.ex`・`pan_zoom.js` |
| `datasets-dining.md` | データ収集（技術書・Pi-hole・ご当地グルメ・食事処）・区画の地図・県の地図・travel-log への書き出しと依頼 | `datasets*`・`geo/**`・`dining_areas_live*`・`partition_map*`・`prefecture_map*`・`gsi_tiles.js` |
| `dev-tooling.md` | mix の回し方・テスト・資産の作り直し・移行 | `mix.exs`・`config/**`・`test/support/**`・`assets/css/**`・`priv/repo/**` |
| `deploy.md` | Dockerfile・compose・CI・単体定義 | `Dockerfile`・`docker-compose*.yml`・`.github/**`・`.env.example`・`release.ex` |

## アーキテクチャ（地図）

- `lib/chidori/` — 画面に依らない中身
  - Chiezo とのやり取り —— `chiezo.ex`（依頼・読み・走らせる、の共通部）・`http.ex`（外への HTTP の唯一の口）・
    `collect_catalog.ex` / `collect_drift.ex` / `collect_overview.ex` / `collect_pace.ex`（設定の「Chiezo 収集」）・
    `sweep_names.ex`・`settings_restore.ex`・`single_flight.ex` → `chiezo-client.md`
  - 利用者が書いたことの置き場 —— `data_store.ex`・`data_store/` → `chiezo-client.md`
  - 最新情報 —— `topics.ex`（話題の定義）・`news.ex`・`news/`（映画・アニメ・イベント・市況の要約・はてブ数・レポート）・
    `themes.ex` / `themes/`（トピックの網）・`home.ex` / `home/`（トップの枠） → `news-topics.md`
  - 要約と通知 —— `digest.ex` / `digest/scheduler.ex`・`notify.ex` / `notify/`・`ntfy.ex`・`web_push.ex` / `web_push/` → `notify-webpush.md`
  - 関連図 —— `relations.ex`・`relations/`（図・区画・芸能人・映画・最新情報からの引き継ぎ・見た記録・顔写真）・`artwork.ex` → `relations.md`
  - データ収集 —— `datasets.ex`・`datasets/`（技術書・Pi-hole・ご当地グルメ・食事処・範囲・依頼・travel-log 書き出し）・`geo/` → `datasets-dining.md`
  - 共通の道具 —— `jst.ex`（人に見せる日時）・`safe_url.ex`（外から来た URL）・`repo.ex`・`release.ex`（移行）
- `lib/chidori_web/` — 画面
  - `live/` —— `home_live`・`news_live`・`relations_live`・`datasets_live`・`dining_areas_live`・`settings_live`・`collect.ex`（収集の枠の道具）
  - `components/` —— 収集の枠・レポート・トピックの網・区画の地図・県の地図・食事処の中のタブ・作品の詳細・主要メニューなど
  - `controllers/` —— travel-log 用 ZIP・顔写真・サムネイルの配り口
  - `socket_origin.ex` —— LiveView の接続元の見比べ（`PHX_CHECK_ORIGIN`）
- `assets/js/` — 図の操作（`pan_zoom.js` を関連図・トピック・区画の地図・県の地図で共有）、地理院タイル、スワイプ、Web Push、
  中身のスクロール位置（`page_scroll.js`）
- `priv/geo/` — 白地図 `japan_coast.json` と県の境界 `japan_prefectures.json`（どちらも Natural Earth。県は `scripts/build_prefectures.py` で作る）。`priv/static/` — PWA の `manifest.webmanifest`・`sw.js`・アイコン
- `docs/` — 人向けの詳しい説明（README から辿る）。`basic-design.md`・`technology-selection.md` は作り始める前の構想で、今の実装とは違う

## コマンド

起動・運用は README と `docs/operations.md`、開発の手順は `docs/development.md` が正。

```bash
# mix はコンテナで回す（手元に Elixir を入れない）。テストは docker-compose.dev.yml の
# PostgreSQL（localhost:7001）を使うので先に立てる
docker compose -f docker-compose.dev.yml up -d
docker run --rm --network host -u "$(id -u):$(id -g)" -v "$PWD:/app" -w /app \
  -e HOME=/app/.docker-home -e MIX_ENV=test elixir:1.20.4-otp-28 mix test

# 整形は変えたファイルにだけかける（リポジトリ全体は揃えていない）
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/app" -w /app \
  -e HOME=/app/.docker-home elixir:1.20.4-otp-28 mix format lib/chidori/foo.ex

# 開発サーバーは CSS / JS を作り直さない（watchers: []）。変えたら手で焼く（mix は上と同じ docker run の形で）
mix tailwind chidori
mix esbuild chidori

# 手元のソースからイメージを作って動かす
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

- 開発サーバーは作業ツリーをそのまま読み直す。**構文の壊れたファイルを残さない**
  （`.ex` を直したら、開発サーバーのログに CompileError が出ていないかを見る）
- 開発サーバーが動いている間に、別のコンテナから `MIX_ENV=dev mix assets.build` を回さない
  （`_build/dev` をコンパイルし直し、開発サーバーが読み直さなくなる）。スタイルと JS は上の 2 つで個別に焼く
- 移行は開発サーバーが自動では当てない（本番のイメージは起動のたびに当てる）
- テストは外へ出ない。外への取得は `Chidori.Http` を通し、テストでは `test/support/http_stub.ex` が差し込む

## 実装上の約束事

- **外への HTTP は `Chidori.Http` だけを通す。** テストで差し替えられなくなるため
- **巡回の名前は `Chidori.SweepNames` から選ぶ**（新しい名前を作らない。仕事が同じなら同じ名前）
- **Chiezo とのやり取りで話題に依らない部分は `Chidori.Chiezo` に 1 つだけ置く。**
  話題ごとに違うもの（依頼文・見せ方）は呼ぶ側が持つ
- **AI を動かす依頼は `Chidori.SingleFlight` で重ねない**（押すたびに Chiezo の枠を食う）
- **人に見せる日時は `Chidori.Jst` で書く。** 持ち回りと比較は UTC、変換は出す直前だけ。実行環境の TZ に頼らない
- **外から来た URL をリンクや画像に使うときは `Chidori.SafeUrl` を通す**（http/https でホストのあるものだけ）
- **頭のメニューとタブは画面の上に残し、スクロールするのは中身の `main#page-scroll` だけ。**
  body を画面の高さの縦並びにし（`root.html.heex`）、各画面は頭（`.page-head`）と `main` を並べる。
  `position: fixed` や sticky で留めない（iPhone の PWA でキーボードの出し入れのあとに位置がずれて取り残される）。
  ページ全体（window）はスクロールしないので、位置を読む・戻すのは `main` に対して書く（`PageScroll`）
- 収集の名前は `chidori_` で始める（`chidori_tech`・`chidori_people`・`chidori_gourmet`・`chidori_dining_<番号>` など）。
  `pta_market` は売買提案のアプリが書く収集で、Chidori は読むだけ
- コードを変えたら、同じ変更で README（入口。1 画面に収める）と対応する `docs/*.md`、このファイルと
  `.claude/rules/` の該当ファイルを更新する。新しいファイルを足したら、どのルールファイルの `paths` に入るかも確かめる。
  README には詳細を書き戻さない
