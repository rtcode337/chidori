# Chidori

- 日々確認したいニュースや趣味の情報を、関心に合わせて集め・要約し、決めた時刻に知らせる Web アプリ
- 知識と AI は [Chiezo](https://github.com/rtcode337/chiezo) が持つ。Chidori はそれを人に見せ、何を集めてほしいかを Chiezo に渡す層
- Elixir / Phoenix LiveView 製。本番は GHCR のイメージと PostgreSQL を `docker compose` で動かす

## できること

| 画面 | 中身 |
|---|---|
| トップ（`/`） | 設定で選んだ枠（話題の要約・注目イベント・関連図・技術書）をタブで並べる |
| 最新情報（`/news`） | 話題ごと（一般・技術ニュース、技術・お笑いイベント、映画、アニメ、市況）に、Chiezo が集めた記事・カレンダー・要約を読む |
| トピック（`/news` の要約の下） | 記事のタグから育った話題の網。興味トピックを選ぶと、記事に興味度が付き、興味の要約が別に届く |
| 関連図（`/relations`） | 画家の影響関係と年代、芸能人の夫婦・家族・グループをネットワーク図で見る |
| データ収集（`/datasets`） | 他のアプリで使うデータ（技術書の本棚・Pi-hole の通信・travel-log 向けの食事処）を Chiezo に集めさせる |
| 設定（`/settings`） | トップに並べる枠、Chiezo に頼んでいる収集の一覧と送り直し、通知先（ntfy・端末） |

各画面の詳しい説明は [全体像](docs/overview.md) から辿れる。

## 起動する

動いている [Chiezo](https://github.com/rtcode337/chiezo) が要る（Chiezo 側で `CHIEZO_NOTES_DIR` を設定しておく）。
使うのは `docker-compose.yml` と `.env.example` だけ。

```bash
git clone https://github.com/rtcode337/chidori.git && cd chidori
cp .env.example .env     # 下の 2 つを書く
docker compose pull
docker compose up -d     # http://localhost:7000
```

`.env` に書くもの:

- `SECRET_KEY_BASE` —— `mix phx.gen.secret` か `openssl rand -base64 64` で作る。64 バイト未満だと起動時に断る
- `CHIEZO_BASE_URL` —— Chiezo のルート URL（`/v1` は付けない）。未設定だと最新情報も関連図もデータ収集も使えない
- 手元以外から開くなら `PHX_HOST` にその宛先を書く（通知のリンクの組み立てに使う）

`.env` もリポジトリも置けない環境（管理画面に YAML を貼るタイプ）では、
`docker-compose.standalone.example.yml` をコピーして値を直書きする。イメージは公開なので `docker login` は要らない。
手順と、環境変数の一覧は [運用](docs/operations.md)。

## 使う

1. `/news` を開き、「Chiezo の収集」の枠で「収集の設定を更新」を押す。Chiezo に収集が止まった状態で作られる
2. Chiezo の管理画面でその収集を有効にする。以後は Chiezo が決まった間隔で集め、Chidori はそれを読む（この画面から AI が勝手に動くことはない）
3. 「要約」の枠に要約を作る時刻（`07:00,21:00` のように JST で）を書く。知らせたいなら、設定の「通知」タブに ntfy のトピックを書くか、端末を登録する（端末への通知は https で開いているときだけ）
4. 関連図・データ収集の各タブも、同じく「収集の設定を更新」→ Chiezo で有効化、の順で始まる

## 運用

```bash
docker compose pull && docker compose up -d   # 更新。DB の移行は起動のたびに自動で当たる
```

- バックアップは、止めてから `data/`（PostgreSQL の実体）を丸ごとコピーする。興味トピックと読んだ・見た記録は Chiezo の置き場 `chidori_data` にある
- イメージのタグは `latest` と `sha-<短縮SHA>`（`v*` のタグを打てばその名前も）。動かす版を固定したいときは `sha-` を指す

| したいこと | 参照 |
|---|---|
| 環境変数を確かめる・接続を通す宛先を絞る | [運用](docs/operations.md#環境変数) |
| `.env` を置けない環境で起動する | [単体定義](docs/operations.md#env-を置けない環境で起動する単体定義) |
| 通知（ntfy・端末）を使う | [通知を使う](docs/operations.md#通知を使う) |
| 何を残せば戻せるか | [バックアップ](docs/operations.md#バックアップ) |

## ドキュメント

| | 中身 |
|---|---|
| [全体像](docs/overview.md) | Chiezo との関係・名前の由来・題材の線引き・トップと設定の画面・利用者が書いたことの置き場 |
| [最新情報とトピック](docs/news-and-topics.md) | 話題・巡回・要約・記事一覧・市況ニュース・トピックの網・興味トピック・ntfy と端末への通知 |
| [関連図](docs/relations.md) | 画家と芸能人の図の育て方・図の操作・見た記録 |
| [データ収集](docs/datasets.md) | 技術書の本棚・Pi-hole の通信・食事処（travel-log 向け）と書き出しの対応表 |
| [運用](docs/operations.md) | 起動・環境変数・イメージ・単体定義・更新・通知・バックアップ |
| [開発](docs/development.md) | mix をコンテナで回す・テスト・スタイルと JavaScript・アイコン・ローカルビルド |
| [基本設計](docs/basic-design.md)・[技術選定](docs/technology-selection.md) | 初期構想（作り始める前の計画で、今の実装とは違う） |

## ライセンス

このリポジトリのコードは [MIT License](LICENSE)。

画面に出すデータは、それぞれの提供元の条件に従う。

| データ | 提供元 | 扱い |
|---|---|---|
| 白地図の海岸線（`priv/geo/japan_coast.json`） | [Natural Earth](https://www.naturalearthdata.com/) | パブリックドメイン。リポジトリに含む唯一のデータ |
| 寄ったときの地図 | [地理院タイル](https://maps.gsi.go.jp/development/ichiran.html)（国土地理院） | 見る人のブラウザが直接取る。画面に出典を表示 |
| 名簿・説明・代表作の絵・閲覧数 | Chiezo が取り込んだ日本語版 Wikipedia・Wikimedia Commons | 本文は CC BY-SA。絵と写真は 1 枚ずつ条件が違う（顔写真には Commons のファイルのページへのリンクを添え、画家と代表作には記事へのリンクを出す） |
| 食事処の名前・座標など | Chiezo が取り込んだ OpenStreetMap（ODbL）・Overture Maps・Wikipedia | travel-log への書き出しには 1 件ごとに出典を添える |
| 技術書の表紙 | [版元ドットコム](https://www.hanmoto.com/) | 見る人のブラウザが直接取る |
