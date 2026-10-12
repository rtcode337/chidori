---
paths:
  - "Dockerfile"
  - ".dockerignore"
  - "docker-compose.yml"
  - "docker-compose.build.yml"
  - "docker-compose.standalone.example.yml"
  - ".github/**"
  - ".env.example"
  - "lib/chidori/release.ex"
  - "lib/chidori_web/socket_origin.ex"
  - "config/runtime.exs"
---

# イメージ・compose・CI

運用の手順と環境変数の表は `docs/operations.md`。

- 本番はイメージ `ghcr.io/rtcode337/chidori` を pull して動かす。`main` への push で GitHub Actions
  （`.github/workflows/build-and-push-image.yml`）が `latest` と `sha-<短縮SHA>` を公開する（amd64 のみ）。
  ドキュメントだけの変更では走らない（`paths-ignore`）
- `Dockerfile` はマルチステージ。実行は非 root（`chidori`）。起動のたびに `Chidori.Release.migrate/0` を当ててから立てる（リリースに Mix は入らない）
- compose の分け方: `docker-compose.yml`（本番。GHCR のイメージ + PostgreSQL）、`docker-compose.build.yml`（重ねると手元のソースから作る）、
  `docker-compose.dev.yml`（開発用の DB だけ。プロジェクト名 `chidori-dev` で本番の構成と混ざらない）、
  `docker-compose.standalone.example.yml`（`.env` を置けない環境向けの単体定義の雛形）
- `docker-compose.yml` のサービス・環境変数を変えたら、単体定義の雛形と `.env.example` と `docs/operations.md` の表にも同じ変更を入れる。
  雛形の実値入りのコピー `docker-compose.standalone.yml` は gitignore 済みで、コミットしない
- DB の実体はホストの `data/`（名前付きボリュームにしない。丸ごとコピーでバックアップになる）。postgres:18 の匿名ボリュームは tmpfs で抑える
- 設定は環境変数で与える（`SECRET_KEY_BASE` は 64 バイト以上でないと起動時に断る）。LiveView の接続元は開いた宛先と同じ名前だけ通す
  （`ChidoriWeb.SocketOrigin`。固定するなら `PHX_CHECK_ORIGIN`）
