---
paths:
  - "lib/chidori/topics.ex"
  - "lib/chidori/news.ex"
  - "lib/chidori/news/**"
  - "lib/chidori/themes.ex"
  - "lib/chidori/themes/**"
  - "lib/chidori_web/live/news_live*"
  - "lib/chidori_web/components/report.ex"
  - "lib/chidori_web/components/topic_map.ex"
  - "lib/chidori_web/components/ai_digests.ex"
  - "lib/chidori_web/components/work_modal.ex"
  - "lib/chidori_web/components/theater_panel.ex"
  - "lib/chidori_web/showtime_ask.ex"
  - "lib/chidori_web/components/top_books.ex"
  - "assets/js/topic_map.js"
  - "assets/js/digest_swipe.js"
  - "assets/js/panel_swipe.js"
  - "assets/js/ask_nearby.js"
  - "assets/js/theater_nearby.js"
  - "test/chidori/news/**"
  - "test/chidori/themes/**"
  - "test/chidori/news_test.exs"
  - "test/chidori/themes_test.exs"
  - "test/chidori/topics_test.exs"
---

# 最新情報・イベント・トピック

詳しい説明と、それぞれの形にした理由（実測値つき）は `docs/news-and-topics.md`。トップと設定は `docs/overview.md`。

- 頭のメニューでは「ニュース」。映画・アニメ（`hobby: true`。`Topics.hobby?/1`）は「趣味」の段に並べ、ニュースのタブ（`Topics.news/0`）には出さない。
  画面と道（`/news?view=…`）はそのまま（通知のリンクがこの形）。開いているときは頭のメニューの「趣味」に印を付け、趣味の段（`DiningTabs.dataset_tabs/1` の `elsewhere`。並びは `Chidori.Hobbies`）を出す
- **読む画面（`/news`）と収集の画面（`/collect/news`）は同じ `NewsLive`**（`@collect_mode`）。収集の設定・トピックの収集・要約の時刻・知らせる設定・「絵を探させる」は収集の画面、
  記事の詳細の「この記事について Chiezo に頼む」は読む画面に残す（見ている 1 件から頼む口）
- 話題は `Chidori.Topics.defined/0` に 1 つ書けば、タブも収集も増える。収集も溜まったものも話題ごとに別
- 何を集めるかは話題の「関心」から作る。整理の回の頼み方は話題ごとに書き分ける（`outside`・`buzz`・`theme_examples`・`note`）
- 巡回は 見出し / 集める（溜める）・整理（印を付け直し・落とし・外から足す。落とす力はこの回だけ）・要約（時計を持たず、Chidori が起こす）。
  整理は定時でも回す（既定 12 時間ごと。`Chidori.SweepNames.tidy_minutes/0`）
- 古くなり方は話題で違う。イベントは `ages_out: false`（期限で落とさず、終わったものを整理が落とす）
- ニュースのお気に入りは見出しと URL だけを `chidori_data` に残す（`Chidori.News.Favorites`。種類 `news_favorites`・鍵は URL）。
  記事は Chiezo の期限で消えるに任せ、原文の写しは持たない。タブは話題の最後の「お気に入り」（`?view=favorites`。話題は nil にする）
- 映画・アニメは 1 件 = 1 作品（`works`）。お笑いイベントは整理の回を置かず情報収集の回に寄せる。先の月は `look_ahead` で 1 回 1 区切りずつ、次の区切りは Chiezo のカーソルに覚えさせる
- 作品の絵は Chiezo が 1 回だけ取って縮めて持つ（`thumbs`）。画面から外のサイトの絵を直に指さない
- 映画のタブの中の「映画館」（`ChidoriWeb.TheaterPanel`。`/news?view=chidori_movies&section=theaters`。最新・関連図・映画館・見た映画は見出しの下の四角い札（見出しは 4 つで同じ `DiningTabs.movie_intro/1`。機能を切り替えても札の位置が動かないように。関連図の説明は札の下） `DiningTabs.movie_tabs/1` で切り替え、映画館・見た映画のときはそれだけを出す。見た映画は `section=seen`・`ChidoriWeb.SeenFilms`。押した作品は最新情報に無ければ映画の図から見出しか `記録:` で引く `WorkModal.fetch/3`）: 映画館は **AI に web で探させる**（`Chidori.News.TheaterFinder`）。
  出発地（駅名・地名か現在地）から決めた時間（既定 30 分）以内に**着ける**館を、着くまでの時間が短い順に（直線の距離ではない）。
  同じ館は 1 つにまとめさせ、営業中の館だけ。AI が挙げた館は店舗辞典（`overture_japan` の `category=cinema`。試写室・会社・
  確からしさ 0.6 未満を除く。`Theaters.to_theater/1`）と名前（`Theaters.similar_name?/2`。会社の名前だけでは当てない）と
  市区町村で突き合わせ、合わない館には「辞典で確かめられない」と印を付ける。お気に入りは `chidori_data` の種類 `theaters`
  （鍵は店舗辞典の id か `ai:<名前>`、住所・サイト・座標・駅は `detail`）。
  上映時刻は押したときだけ Chiezo の `/v1/ai/complete`（`web: true`。頼める相手は web を持つ相手から画面で選ぶ）に JSON で返させる（`Chidori.News.Showtimes`）。
  確かめられなかった館は推し量らせず「分からない」。出どころの頁を添える。答えは館をまたいで上映の始まる順に 1 本に並べる
  （`TheaterPanel.timeline/1`）。お気に入りの館は最寄り駅で場所を言う（座標があれば `Theaters.nearest_station/3` で徒歩の目安、
  無ければ AI が書いた駅）。AI に頼んだ答え（映画館を探した答え・上映時刻）は返ったら通知でも知らせ（`Notify.deliver_notice/4`。話題の「知らせる」は見ない）、画面に直接送らず `AskStore` に置いて
  PubSub で知らせる（頼んでいる最中に画面を移っても、戻ってきた画面が読める）
- 「近くの上映館を Gemini に聞く」は普通のリンクとして開く（`ask_nearby.js`）。空のタブを開いてから行き先を入れると PWA で白いまま残る
- 上映スケジュールを調べる動きは画面どうしで共通（`ChidoriWeb.ShowtimeAsk`）。映画館の欄と、作品の詳細の欄
  （`TheaterPanel.showtime_box/1`。その作品だけを調べ、その作品の答えだけを出す）から使う
- 映画・アニメの作品の組（公開中・これから）は既定で畳む。「注目作」の見出しは付けず、公開中（放送中）はカレンダーの上、これからはカレンダーの下（`NewsLive.works_part/1`）
- 重要度（AI の印）・話題度（反応の判断）・興味度（選んだ語への近さ）は別の軸。混ぜない。低いものも消さない（並びであってふるい分けではない）
- 整理はまとめに触らない。まとめは直近の窓ではなくタグで引き直す。出典は見出しで Chiezo から引き直す
- 重複は見出しではなく URL で確かめさせる。まとめは記事の URL を名乗らない
- 章の番号・目次・出典一覧は画面の側で付ける（本文に書かせない）
- 市況ニュースは Chidori では要約を作らず、`pta_market` の要約を書き手ごとに最新 1 本並べる（`digest_from`・`Chidori.News.AiDigests`）
- トピックの網: 語を拾うのは機械（記事のタグ。`extract` の `of: "tags"`）、AI は精査だけ（畳む・親子・外す・説明。迷ったものは触らせない）。
  溜め先は記事とは別の網羅の収集 `<話題>_topics`。図の語彙（`トピック`・`分野:`・`親:`・`同義:`）は Chidori が持つ
- 網の置き方は決まった手順で詰める（同じ材料なら同じ図）。札の大きさは直近の件数、線は一緒に出た回数
- 興味トピックは `chidori_data` に持ち、依頼文に書き込んで送る。選び直したら整理と興味の要約の依頼文をその場で送り直す。付け終えた興味度は動かさない
- トップページ（閲覧）は廃止した。`/` はニュースへ送る（`ChidoriWeb.PageController`）
- イベント（技術イベント・お笑いイベント。`event: true`・`Topics.events/0`）は頭のメニューの「イベント」（`/events`。`NewsLive` の `:events` / `:collect_events`）。ニュースのタブ（`Topics.news/0`）には出さず、`/news?view=<イベント>` はイベントの道へ送る
