---
paths:
  - "lib/chidori/chiezo.ex"
  - "lib/chidori/http.ex"
  - "lib/chidori/collect_*.ex"
  - "lib/chidori/sweep_names.ex"
  - "lib/chidori/settings_restore.ex"
  - "lib/chidori/single_flight.ex"
  - "lib/chidori/data_store.ex"
  - "lib/chidori/data_store/**"
  - "lib/chidori_web/live/collect.ex"
  - "lib/chidori_web/components/collect_panel.ex"
  - "test/chidori/collect_*_test.exs"
  - "test/chidori/data_store_test.exs"
  - "test/chidori/settings_restore_test.exs"
  - "test/chidori/sweep_names_test.exs"
  - "test/support/http_stub.ex"
  - "test/support/data_store_memory.ex"
---

# Chiezo とのやり取り

Chidori は Chiezo の「集める」層に収集を頼み、溜まったものを読む。定期実行の時計も、AI の呼び出しも、
集めたものの置き場も Chiezo にある。詳しい背景は `docs/overview.md`「Chiezo との関係」。

- `Chidori.Chiezo` —— 収集の定義を読む・依頼する・走らせる、のうち話題に依らない部分。2 か所に分けない
- `Chidori.Http` —— 外への HTTP の唯一の口。テストでは `test/support/http_stub.ex` が応答を差し込み、
  差し込まないまま外へ出ようとしたら失敗させる
- 人が押した 1 回は `Chidori.Chiezo.by_hand/1` で包む（Chiezo に `manual=true` と申告し、止めた収集でも走る）。
  定時の時計（要約・情報収集）からは申告しない
- 「収集の設定を更新」は、無ければ止まった状態で作り、あれば Chidori の今の依頼文・抽出の指定・区画・巡回を送り直す。
  その場で走らせない。送るときは Chiezo に入っている巡回ごとの相手をそのまま載せる（載せないと既定へ戻る）
- 収集の画面（`/collect`） —— `Chidori.CollectCatalog`（Chidori の画面の並びで収集を並べ、送る）、
  `Chidori.CollectDrift`（Chiezo の今の設定と Chidori の定義の違い。頼む相手と止めた・動かしたは比べない）、
  `Chidori.CollectOverview`、`Chidori.CollectPace`（整理・ざっと見るの間隔。区画を回る巡回は一周の日数も同じ比で）、
  `Chidori.SettingsRestore`（Chiezo の収集から間隔・整理を止める収集・知名度の下限を戻す）
- 表には Chidori の時計が起こす行も並ぶ（要約の回の時刻・映画の図の「最新情報からの引き継ぎ」・食事処の「情報収集」。`CollectOverview.chidori_rows/1` と `wake/2`）。
  時刻は Chidori が持つので、ここで直しても Chiezo へは送らない（引き継ぎの行は相手を選ばせず、送るときも数えない）
- 設定ページの表で収集を止める・動かす（`Chidori.Chiezo.switch/3` → Chiezo の `POST /v1/collect/{name}/enabled`。名乗りは `chidori`）。
  動かすのは Chiezo の管理画面で「外部からの有効化を許可する」を押したときだけ通る（403 ならそう出す）。止まっている収集は塊ごと色を付ける（`tbody.is-stopped`）
- Chiezo の管理画面のボタンと同じ操作（やり直す・一周をやり直す・区画を割り直す・未確認に戻す・取り込みを止める・検索文の控え・
  ワーカーを止める / 動かす / 起こす）は収集の画面から頼む（`Chidori.Chiezo.operate/3`・`queries/2`・`forget_queries/3`・
  `pause_worker/3`・`wake_worker/2`）。断られたら Chiezo の言い分をそのまま出す。取り消せない操作は Chiezo の管理画面だけ
- 巡回を今すぐ 1 回走らせるのは各収集の画面の巡回の表（`ChidoriWeb.RunSweepButton`。状態は部品が持つ。人が押した 1 回として `by_hand/1`）
- 整理を自動で回さない収集は `by_caller`（Chiezo の巡回の時計だけを外す）。選んだものは表 `tidy_stops` に覚え、送り直すたびに載せる
- 巡回の名前は `Chidori.SweepNames` から選ぶ。仕事が同じなら同じ名前にし、当てはまらない仕事が出たときだけ足す
- AI を動かす依頼は `Chidori.SingleFlight` で鍵ごとに 1 本にする（重ねて押されても枠を食わない）
- Chiezo は取り込み中の依頼を 409 で断る。断られたら空くのを待って頼み直す（待つ上限は呼ぶ側で決める）
- `Chidori.DataStore` —— 利用者が書いたこと（興味トピック・読んだ/見た記録・ニュースのお気に入り・お気に入りの映画館）は Chiezo の名前付きの置き場 `chidori_data`。
  起動時に全部を読んで手元に持ち、書くときは Chiezo に書いてから手元を直す。届かない間は空として扱い、書くのは断る。
  Chiezo 側に `CHIEZO_NOTES_DIR` が要る
