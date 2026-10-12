---
paths:
  - "mix.exs"
  - "mix.lock"
  - ".formatter.exs"
  - "config/**"
  - "test/support/**"
  - "test/test_helper.exs"
  - "assets/css/**"
  - "assets/js/app.js"
  - "priv/repo/**"
  - "priv/static/images/**"
  - "docker-compose.dev.yml"
---

# 開発の道具・テスト・資産

手順の全体は `docs/development.md`。

- mix はコンテナで回す（`elixir:1.20.4-otp-28`。版は `Dockerfile` の builder と揃える）。`HOME` は `.docker-home/`（gitignore 済み）
- テストは `docker-compose.dev.yml` の PostgreSQL（`127.0.0.1:7071`）を使う。外への取得は `Chidori.Http` を
  `test/support/http_stub.ex` に差し替え、ネットワークには出ない。Chiezo の置き場は `test/support/data_store_memory.ex`
- `mix format` は変えたファイルにだけかける（リポジトリ全体は揃えていない）
- 開発サーバーは watcher を持たない（`config/dev.exs` の `watchers: []`）。CSS は `mix tailwind chidori`、JS は `mix esbuild chidori` で焼く。
  開発サーバーが動いている間に別のコンテナから `MIX_ENV=dev mix assets.build` を回さない（`_build/dev` を作り直し、読み直しが止まる）
- 開発サーバーは作業ツリーをそのまま読み直す。構文の壊れたファイルを残さない
- 移行は開発サーバーが自動では当てない。本番は起動のたびに `Chidori.Release.migrate/0` で当てる
- アイコンの原本は `priv/static/images/icon.svg`。変えたら PNG と favicon を作り直す（`docs/development.md`「アイコン」）
