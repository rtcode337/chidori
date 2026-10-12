---
paths:
  - "lib/chidori/topics.ex"
  - "lib/chidori/news.ex"
  - "lib/chidori/news/**"
  - "lib/chidori/themes.ex"
  - "lib/chidori/themes/**"
  - "lib/chidori/home.ex"
  - "lib/chidori/home/**"
  - "lib/chidori_web/live/news_live*"
  - "lib/chidori_web/live/home_live*"
  - "lib/chidori_web/components/report.ex"
  - "lib/chidori_web/components/topic_map.ex"
  - "lib/chidori_web/components/ai_digests.ex"
  - "lib/chidori_web/components/work_modal.ex"
  - "lib/chidori_web/components/top_books.ex"
  - "assets/js/topic_map.js"
  - "assets/js/digest_swipe.js"
  - "assets/js/panel_swipe.js"
  - "assets/js/ask_nearby.js"
  - "test/chidori/news/**"
  - "test/chidori/themes/**"
  - "test/chidori/news_test.exs"
  - "test/chidori/themes_test.exs"
  - "test/chidori/topics_test.exs"
---

# 最新情報・トピック・トップページ

詳しい説明と、それぞれの形にした理由（実測値つき）は `docs/news-and-topics.md`。トップと設定は `docs/overview.md`。

- 話題は `Chidori.Topics.defined/0` に 1 つ書けば、タブも収集も増える。収集も溜まったものも話題ごとに別
- 何を集めるかは話題の「関心」から作る。整理の回の頼み方は話題ごとに書き分ける（`outside`・`buzz`・`theme_examples`・`note`）
- 巡回は 見出し / 集める（溜める）・整理（印を付け直し・落とし・外から足す。落とす力はこの回だけ）・要約（時計を持たず、Chidori が起こす）。
  整理は定時でも回す（既定 12 時間ごと。`Chidori.SweepNames.tidy_minutes/0`）
- 古くなり方は話題で違う。イベントは `ages_out: false`（期限で落とさず、終わったものを整理が落とす）
- 映画・アニメは 1 件 = 1 作品（`works`）。お笑いイベントは整理の回を置かず情報収集の回に寄せる。先の月は `look_ahead` で 1 回 1 区切りずつ、次の区切りは Chiezo のカーソルに覚えさせる
- 作品の絵は Chiezo が 1 回だけ取って縮めて持つ（`thumbs`）。画面から外のサイトの絵を直に指さない
- 重要度（AI の印）・話題度（反応の判断）・興味度（選んだ語への近さ）は別の軸。混ぜない。低いものも消さない（並びであってふるい分けではない）
- 整理はまとめに触らない。まとめは直近の窓ではなくタグで引き直す。出典は見出しで Chiezo から引き直す
- 重複は見出しではなく URL で確かめさせる。まとめは記事の URL を名乗らない
- 章の番号・目次・出典一覧は画面の側で付ける（本文に書かせない）
- 市況ニュースは Chidori では要約を作らず、`pta_market` の要約を書き手ごとに最新 1 本並べる（`digest_from`・`Chidori.News.AiDigests`）
- トピックの網: 語を拾うのは機械（記事のタグ。`extract` の `of: "tags"`）、AI は精査だけ（畳む・親子・外す・説明。迷ったものは触らせない）。
  溜め先は記事とは別の網羅の収集 `<話題>_topics`。図の語彙（`トピック`・`分野:`・`親:`・`同義:`）は Chidori が持つ
- 網の置き方は決まった手順で詰める（同じ材料なら同じ図）。札の大きさは直近の件数、線は一緒に出た回数
- 興味トピックは `chidori_data` に持ち、依頼文に書き込んで送る。選び直したら整理と興味の要約の依頼文をその場で送り直す。付け終えた興味度は動かさない
- トップ（`Chidori.Home`）は設定で選んだ枠を選んだ順にタブで並べる。何も選んでいなければ一般ニュースの要約だけ
