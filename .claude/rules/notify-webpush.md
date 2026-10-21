---
paths:
  - "lib/chidori/digest.ex"
  - "lib/chidori/digest/**"
  - "lib/chidori/notify.ex"
  - "lib/chidori/notify/**"
  - "lib/chidori/ntfy.ex"
  - "lib/chidori/web_push.ex"
  - "lib/chidori/web_push/**"
  - "lib/chidori_web/live/settings_live*"
  - "assets/js/web_push.js"
  - "priv/static/sw.js"
  - "priv/static/manifest.webmanifest"
  - "test/chidori/digest/**"
  - "test/chidori/digest_test.exs"
  - "test/chidori/notify_test.exs"
  - "test/chidori/ntfy_test.exs"
  - "test/chidori/web_push_test.exs"
  - "test/chidori_web/pwa_test.exs"
---

# 要約の段取り・ntfy・端末への通知

詳しい説明は `docs/news-and-topics.md`「まとめを ntfy で知らせます」「端末へ通知します（PWA）」、
設定の仕方は `docs/operations.md`「通知を使う」。

- 時刻は Chidori が持つ（`Chidori.Digest.Scheduler`。JST、カンマ区切り）。その時刻に 整理を 1 回起こす → 要約を起こす → 知らせる、まで進める。
  Chiezo には「いま回して」としか言わない。要約の巡回は Chiezo 側で `on_demand`
- 起こした先は待ってくれないので、終わったかは読み直して確かめる（整理は前回時刻、まとめは見出し）。整理・要約それぞれ 30 分まで待つ
- 409（取り込み中）は次の予定の時刻まで待って頼み直す（画面から押したときは 1 時間まで）
- 同じ回は二度走らせない。逃した回は 30 分までなら走らせ、それより過ぎたものは追わない
- いまの状態と前に走った回の記録は分けて出す（止まった理由を現在の状態として読ませない）
- 画面で頼んだ AI の答え（映画館を探した答え・上映時刻）が返ったら、話題に依らず ntfy と端末へ知らせる（`Notify.deliver_notice/4`・`Ntfy.notify_any/3`。話題の「知らせる」は見ない。「最後に知らせた」は進めない）
- 定時の回が止まったら、まとめと同じ送り先へ止まったことと理由を知らせる（`Notify.deliver_failure/2`）。画面から押した回・知らせない設定・送れなかったのが理由・収集を止めている回は送らない
- 通知へ流すのはレポート冒頭の要旨だけ。ntfy には URL のまま、画面では見出しのリンクにする
- 届かなかったものは知らせた扱いにしない。押されたときは知らせ済みでも送る
- ntfy の宛先（トピックと場所）は全部の通知で 1 つ（表 `ntfy_settings`）。既定の宛先は持たない。場所が空なら `https://ntfy.sh`
- 通知を押した先は `/news?view=<収集>&digest=latest`。`PHX_HOST` が `localhost` のままなら ntfy にリンクを添えない
- Web Push: 送り手の鍵（VAPID）は最初に要ったときに作って DB（`web_push_keys`）に置く。宛先はブラウザの配信元
  （Apple・Google・Mozilla・Microsoft）のホストだけ受け取る。404・410 を返した端末は外す。配信元の本文は画面に出さずログへ。
  ntfy と両方あれば両方へ送り、どちらか 1 つ届けば知らせた扱い
- 設定ページは 4 タブ（トップページ・Chiezo 収集・写真と表紙・通知）。タブで仕事を分ける。写真と表紙は `Relations.Faces.status/1`・`counts/0` と
  Chiezo の `GET /v1/thumbs/health`（`Chiezo.thumbs_health/1`）を並べる
