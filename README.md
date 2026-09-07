# antenna

日々確認したいニュースや趣味の情報を、利用者ごとの関心に合わせて収集・要約し、適切なタイミングで知らせる情報アンテナアプリです。技術情報に限らず、暮らし、スポーツ、エンターテインメント、地域情報などを扱います。

Elixir と Phoenix で実装し、現在は情報の価値を伝えるトップ画面を表示します。

## 関連図

`/relations` では、人物の家族・コンビ関係と、画家の影響関係・活躍年代をネットワーク図で表示します。

**画家の図は [Chiezo](https://github.com/rtcode337/chiezo) に溜めます。** 「関連図を収集」を押すと、antenna が Chiezo に**整理する収集**（`mode=refine`）を依頼し、その場で 1 回集めさせます。作られるのは止まった状態なので、最初の 1 回は Chiezo の管理画面で有効にしてから押してください（止まっている収集は Chiezo が断ります）。有効にすれば Chiezo が決まった間隔でも図を育て、antenna はそれを読んで表示します。

**実行のたびに全部を作り直すのではなく、少しずつ良くしていく形**です。1 回で仕上げようとせず、抜けている画家を足す・説明の粗いものを書き直す・粒度を揃える、といった直し方を頼みます。触れなかったものはそのまま残り、消えるのは AI が消すと明示したときだけです。

**図の構造は Chiezo に持ち込みません。** 向こうにあるのは「1 画家 = 1 文書」の普通のソースで、属性と関係はタグに載せてあります。

| タグ | 意味 |
| --- | --- |
| `画家` | この図に取り込む目印 |
| `様式:ポスト印象派` | ノードに添える様式 |
| `年代:1880-1890` | ノード下の年代帯。並び順もこれで決まる |
| `影響元:クロード・モネ:光と色彩` | その画家から受けた影響。線と、線の上の説明になる |

ノードとエッジという読み方を与えるのは antenna 側です。判断や見せ方を Chiezo に持たせない、という線を崩さないための形にしてあります。

**人物の図は、まだその場で AI に聞く形**です。収集に失敗した場合は、直前の図または表示例を維持し、失敗した理由を画面に出します。

AI の応答に出典が付いていない関係、実在しないノードを指す関係、`http`/`https` 以外の出典は取り込みません。連続して押したときは間隔を空けます。

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
| `DATABASE_URL` | なし | PostgreSQL の接続先。本番では必須 |
| `ANTENNA_PAINTERS_COLLECTION` | `antenna_painters` | 画家の図を溜める Chiezo の収集の名前 |

誰に頼むかは本来 Chiezo 側の判断なので、名指しするのは「この収集だけは別の相手に」と決めたときだけです。依頼した後は Chiezo の管理画面からも変えられ、画面には Chiezo が持っている値を出します。

## 設定と選別

`/settings` では、話題ごとに **集める相手** と **選ぶ相手** を別に決められます。役割が違うので、速さと質の釣り合いも別に決めたいためです。集めるのは web を歩く仕事、選ぶのは溜まったものを読む仕事です。どちらも未指定なら Chiezo の既定にまかせます。相手とモデルの候補は Chiezo に聞くので、こちらに写しを持ちません。

ニュースの画面の「AI に選ばせる」を押すと、溜まったものから **いま読むべきもの** を選ばせます。何が重要かは利用者の関心で決まるので、選ぶのは antenna の仕事です（Chiezo は判断や好みを持ちません）。

**選ぶたびに AI を呼びません。** 溜まったものが変わっていなければ前の結果をそのまま出します。**選ばれなかったものも消しません** —— 選別は絞り込みであって検閲ではないので、選から漏れたものも下に並びます。

## 起動

`docker compose` で PostgreSQL ごと立てる。開発サーバーは `http://localhost:7070`。

```bash
cp .env.example .env   # SECRET_KEY_BASE と CHIEZO_BASE_URL を書く
docker compose up -d
```

`SECRET_KEY_BASE` は `mix phx.gen.secret` で作る。**64 バイト未満だと起動時に断る**
（通すと起動には成功して全リクエストが 500 になり、原因を追いにくい）。
移行は起動のたびに当たるので、手で流す必要はない。

手元のソースから作り直すときは重ねる。

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

ホストで直接動かすなら、DB だけ立てて繋ぐ。

```bash
docker compose -f docker-compose.dev.yml up -d
mix setup && mix phx.server
```

テストは DB が要る。外部への取得はスタブへ差し替えてあるので、ネットワークには出ない。

```bash
docker compose -f docker-compose.dev.yml up -d
mix test
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
