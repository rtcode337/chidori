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

- mix はコンテナで回す（`elixir:1.20.4-otp-28`）。`HOME` は `.docker-home/`（gitignore 済み）。
  Elixir は `Dockerfile` の builder と揃えるが、OTP は builder が 29、手元が 28（開発サーバーと `_build` を
  共有するので、別の OTP で焼くと開発サーバーが読めなくなる）。どちらでもコンパイルできる書き方にとどめる
  （OTP 29 にしか無い関数を使わない）
- CI（`.github/workflows/ci.yml`）は builder と同じイメージで `hex.audit`・`compile --warnings-as-errors`・
  変えたファイルの `mix format --check-formatted`・`mix test` を回す。警告を残すと落ちる
- テストは `docker-compose.dev.yml` の PostgreSQL（`127.0.0.1:7001`）を使う。外への取得は `Chidori.Http` を
  `test/support/http_stub.ex` に差し替え、ネットワークには出ない。Chiezo の置き場は `test/support/data_store_memory.ex`
- `mix format` は変えたファイルにだけかける（リポジトリ全体は揃えていない）
- 開発サーバーは watcher を持たない（`config/dev.exs` の `watchers: []`）。CSS は `mix tailwind chidori`、JS は `mix esbuild chidori` で焼く。
  開発サーバーが動いている間に別のコンテナから `MIX_ENV=dev mix assets.build` を回さない（`_build/dev` を作り直し、読み直しが止まる）
- 開発サーバーは作業ツリーをそのまま読み直す。構文の壊れたファイルを残さない
- ブラウザの自動再読み込み（`phoenix_live_reload`）は入れない。ファイルの見張りに `inotify-tools` が要り、素の `elixir`
  イメージでは動かずに起動時のエラーだけ出ていた。開発サーバーは普段使いも兼ねるので、直すたびに開いた画面が
  読み直されるのも困る。ソースの読み直し（`code_reloader`）は別物で、次のリクエストで効く
- 移行は開発サーバーが自動では当てない。本番は起動のたびに `Chidori.Release.migrate/0` で当てる
- アイコンの原本は `priv/static/images/icon.svg`。変えたら PNG と favicon を作り直す（`docs/development.md`「アイコン」）
