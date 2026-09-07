# antenna

日々確認したいニュースや趣味の情報を、利用者ごとの関心に合わせて収集・要約し、適切なタイミングで知らせる情報アンテナアプリです。技術情報に限らず、暮らし、スポーツ、エンターテインメント、地域情報などを扱います。

Elixir と Phoenix で実装し、現在は情報の価値を伝えるトップ画面を表示します。

## 関連図

`/relations` では、人物の家族・コンビ関係と、画家の影響関係・活躍年代をネットワーク図で表示します。「関連図を収集」を押すと Chiezo 経由でAIが公開情報を調べ、関係・年代・出典URLを更新します。収集は数十秒かかりますが、終わると画面が自動で切り替わります。収集に失敗した場合は、直前の図または表示例を維持し、失敗した理由を画面に出します。

AIの応答に出典が付いていない関係、実在しないノードを指す関係、`http`/`https` 以外の出典は取り込みません。連続して押したときは間隔を空けます。

関連図の収集を有効にするには、コンテナ起動時にChiezoのLAN内接続先を渡します。接続先や認証情報はイメージへ含めません。

```bash
docker run --env CHIEZO_BASE_URL=http://chiezo.example.lan:7010 \
  --env CHIEZO_RELATIONS_BACKEND=claude \
  --env CHIEZO_RELATIONS_MODEL=haiku ...
```

## ニュース

`/news` では、[Chiezo](https://github.com/rtcode337/chiezo) の「集める」層に収集を依頼し、溜まったものを読みます。集めるのは Chiezo で、antenna は依頼と閲覧だけを持ちます。定期実行の時計も、AI の呼び出しも、集めたものの置き場も、すでに Chiezo にあるためです。

「収集を依頼する」を押すと、Chiezo に**止まった状態の**収集が作られます。動き出すのは Chiezo の管理画面の「集める」で有効にしたときだけなので、**この画面から AI が勝手に動くことはありません**。有効にすると Chiezo が決まった間隔で集め、antenna はそれを読みます。「いま集めさせる」で予定を待たずに1回走らせることもできます（止まっている収集は Chiezo が断ります）。

見出しの横の「優先」は antenna が付けます。災害、避難、金融政策などの語を含む見出しを先に表示します。記事本文は antenna に保存せず、見出しを押すと Chiezo の中身（要約と出典）が開きます。

Chiezo 側で `CHIEZO_COLLECT_DIR` と `CHIEZO_NOTES_DIR` の両方が設定されている必要があります。

| 変数 | 既定 | 説明 |
| --- | --- | --- |
| `CHIEZO_BASE_URL` | なし | Chiezo のルートURL。未設定ならニュースも関連図も使えない |
| `ANTENNA_NEWS_COLLECTION` | `antenna_news` | Chiezo に置く収集の名前。Chiezo のソース名になる |
| `ANTENNA_NEWS_BACKEND` | なし | 収集を頼む相手（`claude` など）。未設定なら Chiezo の既定にまかせる |
| `ANTENNA_NEWS_MODEL` | なし | その相手のモデル |
| `ANTENNA_NEWS_EFFORT` | なし | その相手の考える量 |

誰に頼むかは本来 Chiezo 側の判断なので、名指しするのは「この収集だけは別の相手に」と決めたときだけです。依頼した後は Chiezo の管理画面からも変えられ、画面には Chiezo が持っている値を出します。

## 起動

開発サーバーは `http://localhost:7070` で起動します。ポートは `PORT` で変えられます。

```bash
docker run --rm -it --user 1000:1000 \
  -e HOME=/tmp -e MIX_HOME=/tmp/.mix -e HEX_HOME=/tmp/.hex \
  -p 7070:7070 \
  -v "$PWD:/app" -w /app \
  hexpm/elixir:1.20.4-erlang-28.5.0.6-debian-bookworm-20260824-slim \
  sh -lc 'mix local.hex --force && mix deps.get && mix assets.setup && mix assets.build && mix phx.server'
```

画面のスタイルと JavaScript は `mix assets.build` が作る。作らずに起動すると、装飾も画面の自動更新も効かない。

テストは同じイメージで実行する。外部への取得はスタブへ差し替えてあるので、ネットワークには出ない。

```bash
docker run --rm --user 1000:1000 \
  -e HOME=/tmp -e MIX_HOME=/tmp/.mix -e HEX_HOME=/tmp/.hex \
  -v "$PWD:/app" -w /app \
  hexpm/elixir:1.20.4-erlang-28.5.0.6-debian-bookworm-20260824-slim \
  sh -lc 'mix local.hex --force && mix deps.get && mix test'
```

アイコンの原本は `priv/static/images/icon.svg`。変えたら PNG を作り直す。

```bash
docker run --rm -v "$PWD/priv/static:/w" -w /w debian:bookworm-slim sh -c \
  'apt-get update -qq && apt-get install -y -qq --no-install-recommends librsvg2-bin \
   && rsvg-convert -w 180 -h 180 images/icon.svg -o images/icon-180.png \
   && rsvg-convert -w 64 -h 64 images/icon.svg -o images/icon-64.png \
   && rsvg-convert -w 64 -h 64 images/icon.svg -o favicon.ico'
```

本番用イメージは `Dockerfile` でビルドする。イメージの中でスタイルと JavaScript も作る。公開時は `ghcr.io/<owner>/antenna:<commit-sha>` のようにコミット SHA を含むタグを付ける。

基本設計は [docs/basic-design.md](docs/basic-design.md) を参照してください。
採用技術と選定理由は [docs/technology-selection.md](docs/technology-selection.md) を参照してください。
