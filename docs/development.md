# 開発

テスト・CI・開発サーバー・スタイルと JavaScript の作り直し・アイコン・ローカルビルド。

## mix をコンテナで回す

手元に Elixir を入れずに、公式イメージで mix を回せる。Elixir の版は `Dockerfile` の builder と揃える。
OTP は builder が 29、手元のコマンドは 28 にしている。開発サーバーと `_build` を共有するので、
別の OTP で焼くと開発サーバーが読めなくなるため。コードはどちらでもコンパイルできる書き方にとどめる。
テストは `docker-compose.dev.yml` の PostgreSQL（`localhost:7001`）を使うので、先に立てておく。

```bash
docker compose -f docker-compose.dev.yml up -d
docker run --rm --network host -u "$(id -u):$(id -g)" -v "$PWD:/app" -w /app \
  -e HOME=/app/.docker-home -e MIX_ENV=test elixir:1.20.4-otp-28 mix test
```

`HOME` をリポジトリの中（`.docker-home/`、gitignore 済み）に向けるのは、hex と依存の取得物をコンテナを捨てても残すため。

- `mix format` は変えたファイルにだけかける（リポジトリ全体は揃えていないので、全体にかけると関係ない差分が出る）
- 移行は開発サーバーが自動では当てない。足したら `mix ecto.migrate` を流す
- 開発サーバーは作業ツリーをそのまま読み直す。構文の壊れたファイルを残さない（読み直しに失敗したまま、開いている画面が動かなくなる）
- 開発サーバーが動いている間に、別のコンテナから `MIX_ENV=dev mix assets.build` を回さない。`_build/dev` をコンパイルし直すので、開発サーバーが読み直さなくなる。スタイルだけなら `mix tailwind chidori`、JavaScript だけなら `mix esbuild chidori`

## CI

push と PR で `.github/workflows/ci.yml` が回る。`Dockerfile` の builder と同じイメージの中で、
ジョブを 2 つ並べて走らせる。

`audit` は `mix hex.audit` で、退役した版・既知の脆弱性のある版を使っていないかを見る。
テストとは別のジョブにしてあるので、上流の修正がまだ出ていない勧告で落ちても、
コンパイル・整形・テストはいつもどおり走る（落ちたまま残るのは `audit` だけ）。

`test` は次を順に見る。

- `mix compile --warnings-as-errors` —— 警告を残すと落ちる
- `mix format --check-formatted` —— 変えたファイルだけ（PR は取り込み先と、push は push 前と比べる）
- `mix test` —— PostgreSQL はサービスのコンテナで立てる（`DATABASE_URL` で向ける）

builder のタグを上げたら、`ci.yml` のイメージも同じタグに直す（食い違うと CI が落ちる）。
依存・ベースイメージ・Actions の更新は Dependabot（`.github/dependabot.yml`）が週 1 で PR にする。

## 手元のソースからイメージを作る

手元のソースから作り直すときは重ねる。

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

## ホストで動かす

ホストで直接動かすなら、DB だけ立てて繋ぐ（開発用の DB は `127.0.0.1:7001` にだけ開く）。

```bash
docker compose -f docker-compose.dev.yml up -d
mix setup && mix phx.server
```

## テスト

テストは DB が要る。外部への取得はスタブへ差し替えてあるので、ネットワークには出ない。

```bash
docker compose -f docker-compose.dev.yml up -d
mix test
```

## スタイルと JavaScript

**CSS を触ったら焼き直す。** 開発サーバーは watcher を持たない（`config/dev.exs` の `watchers: []`）ので、`assets/css/app.css` を変えても `priv/static` は古いままになる。直したのに画面が変わらないときはここを疑う。

```bash
mix tailwind chidori   # JS も変えたなら mix assets.build
```

## アイコン

アイコンの原本は `priv/static/images/icon.svg`。変えたら PNG を作り直す。

```bash
docker run --rm -v "$PWD/priv/static:/w" -w /w debian:bookworm-slim sh -c \
  'apt-get update -qq && apt-get install -y -qq --no-install-recommends librsvg2-bin \
   && rsvg-convert -w 180 -h 180 images/icon.svg -o images/icon-180.png \
   && rsvg-convert -w 64 -h 64 images/icon.svg -o images/icon-64.png \
   && rsvg-convert -w 64 -h 64 images/icon.svg -o favicon.ico'
```
