# 運用

README の「起動する」「運用」の詳細。起動・環境変数・イメージ・`.env` を置けない環境・通知・バックアップ。

## 起動

`docker compose` で PostgreSQL ごと立てる。既定では `http://localhost:7000` で開く（`PORT`）。

```bash
cp .env.example .env   # SECRET_KEY_BASE と CHIEZO_BASE_URL を書く
docker compose up -d
```

`SECRET_KEY_BASE` は `mix phx.gen.secret` で作る。**64 バイト未満だと起動時に断る**
（通すと起動には成功して全リクエストが 500 になり、原因を追いにくい）。
移行は起動のたびに当たるので、手で流す必要はない。

## 画面の接続を通す宛先

**画面（LiveView）の接続は、開いた宛先と同じ名前からのものだけ通します。** どの名前・IP で
開いても繋がり、別のサイトに置かれたページからの接続は断ります（scheme とポートは見ないので、
前段で TLS をほどく逆プロキシでもそのまま動く。プロキシが `Host` を書き換えるなら
`X-Forwarded-Host` を付けるか `PHX_HOST` を公開名にする）。通す名前を固定したいときは
`PHX_CHECK_ORIGIN` に `https://chidori.example.com` のようにカンマ区切りで並べる。

## 環境変数

主な環境変数（例は `.env.example`）。

| 変数 | 既定 | 説明 |
| --- | --- | --- |
| `SECRET_KEY_BASE` | なし | 本番では必須（64 バイト以上） |
| `DATABASE_URL` | なし | PostgreSQL の接続先。本番では必須（`docker-compose.yml` が組み立てる） |
| `PHX_HOST` | `localhost` | ブラウザから見えるホスト名（リンクの組み立てに使う） |
| `PORT` | `7000` | 待ち受けのポート |
| `PHX_SCHEME` | `http` | 前段に TLS を置いたときだけ `https` にする（Web Push は https の URL が要る） |
| `PHX_URL_PORT` | `https` なら 443、`http` なら `PORT` | リンクに書くポート。**https の逆プロキシが 443 以外で待つときだけ**書く（ntfy の通知を押したときの URL と、Web Push の送り手の名乗りがこのポートを指す） |
| `PHX_CHECK_ORIGIN` | なし | 画面の接続を通す宛先をカンマ区切りで固定する（上の段落） |
| `CHIEZO_BASE_URL` | なし | Chiezo のルートURL（Chidori から引く宛先）。未設定ならニュースも関連図もデータ収集も使えない |
| `CHIEZO_PUBLIC_URL` | `CHIEZO_BASE_URL` | 画面に置く Chiezo へのリンクの宛先（見る人のブラウザから開けるもの）。Chiezo をコンテナの名前でつないでいるときに書く |
| `NTFY_BASE_URL` | `https://ntfy.sh` | ntfy のルートURL の既定。**通知先（トピック）は設定の「通知」タブで決める**（空なら知らせない） |

Chiezo 側では `CHIEZO_NOTES_DIR` が設定されている必要があります（利用者が書いたことの置き場 `chidori_data` を作るため。[利用者が書いたことの置き場](overview.md#利用者が書いたことの置き場)）。

## イメージ

本番用イメージは `Dockerfile` でビルドする。イメージの中でスタイルと JavaScript も作る。
`main` へ push すると GitHub Actions（`.github/workflows/build-and-push-image.yml`）が
`ghcr.io/rtcode337/chidori:latest` と `:sha-<短縮SHA>` を公開する（amd64 のみ）。`v1.2.3` のような
タグを push すると、同じ名前のイメージのタグも付く。GHCR にはタグ付きの直近 20 版と `v*` のタグを残し、
それより古い版は消す。パッケージは公開なので、`docker login` なしで pull できる。
テスト（`.github/workflows/ci.yml`）の結果は待たずに公開する。

## `.env` を置けない環境で起動する（単体定義）

`.env` もリポジトリも置けない環境（管理画面に YAML を貼るタイプ）では
`docker-compose.standalone.example.yml` を `docker-compose.standalone.yml` にコピーし、
値を直書きして貼る（コピーは gitignore 済み）。

雛形の頭のコメントに手順がある。イメージは公開なので、貼る先のホストで `docker login` は要らない。
`docker-compose.yml` のサービス・環境変数を変えたら、雛形にも同じ変更を入れる（値の直書きぶん古くなりやすい）。

## 更新する

```bash
docker compose pull && docker compose up -d
```

移行（DB のスキーマの変更）は起動のたびに当たる（`Chidori.Release.migrate/0`。当て終わっているものは飛ばされる）。
動かすイメージを固定したいときは、`docker-compose.yml` の `image:` を `:latest` から `:sha-<短縮SHA>` に替える。
新しい版で起動できなかったときの戻し先にもなる（GHCR に残るのは直近 20 版と `v*` のタグ）。

## 通知を使う

要約を知らせる先は 2 つある。どちらも、宛先は環境変数ではなく設定の「通知」タブで決める。
動きの詳しい説明は [最新情報とトピック](news-and-topics.md#まとめを-ntfy-で知らせます) にある。

- ntfy —— 「通知」タブにトピック名を書く。場所は書かなければ `https://ntfy.sh`（`NTFY_BASE_URL` で既定を替えられる）。公開の ntfy では推測されない名前にする
- 端末（Web Push・PWA）—— https で開いていることが要る。前段に TLS をほどく逆プロキシを置き、`PHX_HOST` を公開名に、`PHX_SCHEME=https` にする（443 以外で待つなら `PHX_URL_PORT` も）。送り手の鍵（VAPID）は最初に要ったときに作って DB に置くので、手で用意するものはない
- 通知を押したときに開く先は `PHX_HOST` から組み立てる。既定の `localhost` のままだと、ntfy にはリンクを添えない

## バックアップ

- DB の実体は `data/`（単体定義では雛形に書いた置き場）にある。コンテナを止めてから丸ごとコピーすればよい
- 興味トピックと、読んだ・見た記録、ニュースのお気に入りは Chidori の DB ではなく Chiezo の置き場 `chidori_data` にある。そちらは Chiezo 側でバックアップする
- 巡回の間隔・整理を止める収集・知名度の下限・食事処の範囲は、DB を失っても Chiezo の収集から戻せる（[利用者が書いたことの置き場](overview.md#利用者が書いたことの置き場)）
- DB を作り直すと Web Push の鍵が替わるので、端末は登録し直す
