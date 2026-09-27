defmodule Tazuna.Topics do
  @moduledoc """
  話題（最新情報の画面のタブ）。

  **話題は tazuna の機能で、利用者のデータではありません。** 関連図の「人物」「画家」と
  同じ立ち位置で、集め方も関心も話題ごとに違う —— だから**定義はコードに置きます**
  (`defined/0`)。DB に持たせていた頃は、コードに足した話題が**既に使っている環境へ
  永遠に届きませんでした**（最初の 1 回だけ配る作りだったため。実際、技術のタブが
  出ないまま気づかれずにいた）。

  **DB は持ちません。** 話題ごとに持つ設定はもう無く、誰に頼むかは巡回ごとに
  画面の表から選んで Chiezo へ送ります —— 収集の設定を持っているのは Chiezo なので、
  こちらに写しを置くと、どちらが本物か分からなくなります。
  """

  @doc """
  tazuna が持っている話題。**この並びがタブの並び**。

  足すときはここへ 1 つ書きます（関連図のタブを足すのと同じ手順）。
  `collection` は Chiezo のソース名になるので、**後から変えない** ——
  変えると、それまで溜めた先を見失います。

  `feeds` は機械で引く配信元（RSS / Atom）。**書いてあれば、集めるのは機械の仕事**に
  なります（`Tazuna.News` が「機械収集」の巡回として Chiezo へ渡す）。空なら AI が集めます。

  `every` は巡回の間隔（分）。**話題によって世の中の動く速さが違う**ので、書かない
  話題は既定のまま、書いた話題はその値で回ります —— 動きの遅い話題を短い間隔で
  回しても、同じものを読み直すだけで枠を食います。

  `note` は**その話題ならではの頼みごと**で、整理の回の依頼文に足されます。
  関心（何を集めるか）とは別物です —— あちらは「何が読む価値があるか」、
  こちらは「1 件ごとに何を書き足すか」。

  `works` は**1 件 = 1 作品として育てる話題**の作り方（映画。`Tazuna.News.Movies`）。
  書くと記事を溜めず、巡回も依頼文もそのモジュールが決めます。

  `thumbs` は**絵を Chiezo に縮めて持たせる**指定（Chiezo の収集の `thumbs` へそのまま渡す）。
  `true` なら AI が返した絵だけ、`%{pages_from: [ホスト]}` ならそのホストのページの
  `og:image` も拾わせます。
  """
  def defined do
    [
      # **一般ニュースを先頭に置く。** タブの並びの先頭が、何も選ばずに開いたとき
      # （トップページ）に出る話題になる
      %{
        name: "一般ニュース",
        # **収集の名前は変えない**（それまで溜めた先を見失う）
        collection: Tazuna.News.collection_name(),
        interest:
          "暮らし・社会・政治・経済・国際のうち、影響が大きいこと。" <>
            "読む人の判断や備えが変わるもの(災害と避難、制度や料金の変更、" <>
            "金融政策と相場の大きな動き、選挙と政権の動き、大きな事件・事故)を優先する。" <>
            "多くの媒体が一斉に報じている話題も拾う",
        # **トピックの網を育てる**（技術ニュースと同じ）。記事が毎日まとまった数で
        # 流れてくる話題なので、語を拾って図にでき、興味トピックも選べる
        themes: true,
        # 網の依頼文の例（技術の例のままだと、分野がそちらへ引っ張られる）
        theme_examples: %{
          fields: ["政治", "経済", "国際", "社会", "災害"],
          parent: {"日銀の利上げ", "金融政策"}
        },
        # **話題度の人気枠は一般ニュースのもの**（技術の既定ははてブの IT や Qiita）
        buzz: """
        - 高: 同じ出来事を複数の媒体が一斉に報じている、各社のトップや速報で扱われて
          いる、はてなブックマークの総合の人気エントリーや SNS で大きく反応されている
        - 中: 複数の媒体が報じているが、トップ級の扱いではない
        - 低: 1 つの媒体だけ、または公式の発表のまま広がっていないもの
          （**広がっていないことは悪いことではありません**。早いだけです）
        """,
        # **外を当たる先も一般ニュースのもの**（話題に共通の文は論文やテックブログを
        # 探させるので、ニュースには合わない）
        outside: """
        **2. 上に無いものを探して足す。**
        決まった配信元だけを見ていると、そこに載らないものは永遠に入りません。
        **上に並んでいない出どころ**を当たってください。たとえば次のようなところです。

        - 一次情報（官公庁・自治体・気象庁・日銀などの発表、企業の公式発表）
        - 上に無い報道機関（全国紙・通信社・地方紙・経済紙）が大きく扱っているもの
        - 海外で大きく報じられていて、日本に関わるもの

        **確信が持てるものだけ**を挙げてください。探して見つからなければ 0 件で構いません。
        """,
        # **機械で引ける配信元は機械で引く。** 見出し・要約・URL・配信日は機械が
        # 正確に取れるので、AI の枠は「何が重要か」「どうまとめるか」へ回す
        feeds: [
          %{url: "https://news.web.nhk/n-data/conf/na/rss/cat0.xml", tags: ["ニュース"]},
          %{url: "https://news.web.nhk/n-data/conf/na/rss/cat1.xml", tags: ["ニュース"]},
          %{url: "https://news.web.nhk/n-data/conf/na/rss/cat4.xml", tags: ["ニュース"]},
          %{url: "https://news.web.nhk/n-data/conf/na/rss/cat5.xml", tags: ["ニュース"]},
          %{url: "https://news.web.nhk/n-data/conf/na/rss/cat6.xml", tags: ["ニュース"]},
          %{url: "https://www.asahi.com/rss/asahi/newsheadlines.rdf", tags: ["ニュース"]},
          %{url: "https://news.yahoo.co.jp/rss/topics/top-picks.xml", tags: ["ニュース"]}
        ]
      },
      %{
        name: "技術ニュース",
        collection: "tazuna_tech",
        # **話題になっていること自体も拾う。** 判断が変わるかどうかだけで選ぶと、
        # 界隈が丸一日その話をしていても、まとめに出てこない
        # **分野は絞らない。** 技術に関することを幅広く拾い、その中から読む人が
        # 興味トピックで選ぶ（絞るのは興味トピックの役目）。特定の分野を書き並べると、
        # 書いていない分野（ゲーム開発・ハードウェアなど）が「関係ない」として落とされる
        interest:
          "技術に関する新しい動き。分野は問わない" <>
            "(ソフトウェア・AI・インフラに限らず、ゲーム開発・ハードウェア・" <>
            "デザインや制作の道具・研究なども含む)。" <>
            "作る人・使う人の判断が変わるもの(新しい版や製品、使えるようになった道具、" <>
            "定石の変化、対処のいる不具合や脆弱性)を優先する。" <>
            "界隈で話題になっているもの(あちこちで取り上げられている、" <>
            "反応が大きい)も拾う",
        # **トピックの網を育てる話題。** 記事から語を拾って図にするのは、記事が
        # 毎日まとまった数で流れてくる話題でないと意味を持たない —— 数日に数件の
        # 話題では、網になる前にその語が古くなる
        themes: true,
        # **機械で引ける配信元は機械で引く。** 見出し・要約・URL・配信日は
        # 機械が正確に取れるので、AI の枠は「何が重要か」「どうまとめるか」へ回す。
        # タグは同じ収集の中で束を分けるためのもの（ニュースと記事を混ぜて溜めて、
        # 後から分けて取り出せるように）
        feeds: [
          %{url: "https://www.publickey1.jp/atom.xml", tags: ["ニュース"]},
          %{url: "https://rss.itmedia.co.jp/rss/2.0/news_bursts.xml", tags: ["ニュース"]},
          %{url: "https://feed.infoq.com/jp/", tags: ["ニュース"]},
          %{url: "https://codezine.jp/rss/new/20/index.xml", tags: ["ニュース"]},
          %{url: "https://zenn.dev/feed", tags: ["記事"]},
          %{url: "https://qiita.com/popular-items/feed", tags: ["記事"]},
          %{url: "https://b.hatena.ne.jp/hotentry/it.rss", tags: ["記事"]},
          # **話題の論文**（Hugging Face の Daily Papers。投稿と upvote で選ばれたもの）。
          # RSS を配っていないので、JSON の読み方を書いて Chiezo に引かせる。
          # 整理の回に論文を探させるだけでは、入り方が回によって安定しなかった
          %{
            url: "https://huggingface.co/api/daily_papers?limit=50",
            tags: ["論文"],
            json: %{
              title: "paper.title",
              url: "https://arxiv.org/abs/{paper.id}",
              summary: "paper.summary",
              at: "publishedAt",
              subjects: "paper.ai_keywords",
              from: "Hugging Face Daily Papers"
            }
          }
        ]
      },
      %{
        name: "技術イベント",
        collection: "tazuna_events",
        interest:
          "これから開かれる技術のイベント(カンファレンス・勉強会・ハンズオン)。" <>
            "行くかどうかの判断が変わるもの(開催日、場所とオンラインの別、" <>
            "申込の開始と締切、登壇者と題目、参加費)を優先する。" <>
            "国内のものを中心に、海外でも界隈が追いかける大きなもの" <>
            "(各社の年次カンファレンス、主要な国際会議)は入れる",
        # **終わったら要らなくなるものは、日付では落とせません。**
        # ニュースは日が経てば古くなりますが、イベントは「まだ先か、終わったか」
        # で決まります —— 半年先のイベントを 30 日で落とすわけにはいかないので、
        # 期限を持たせず、終わったものを整理の回に落とさせます
        ages_out: false,
        # **要約は作りません。** イベントは読み物ではなく「いつ・どこで・行く価値が
        # あるか」で選ぶもので、見たいのは開催日のカレンダーです（`calendar`）
        digest: false,
        calendar: true,
        # 配信元は毎時見てよい(新しい募集が絶えず立つ)。整えるのは半日に 1 度で足りる
        every: %{feed: 60, refine: 720},
        feeds: [
          %{url: "https://connpass.com/explore/ja.atom", tags: ["勉強会"]},
          # connpass 以外の告知（キー無しの RSS）。本文の頭に「日時:」がある
          %{url: "https://rss.techplay.jp/event/w3c-rss-format/rss.xml", tags: ["勉強会"]}
        ],
        note: Tazuna.News.Events.refine_note(),
        # **外を当たる先も話題で違う**（整理の「上に無いものを探して足す」）。
        # 話題に共通の文は論文やテックブログを探させるので、イベントには合わない
        outside: Tazuna.News.Events.outside(),
        # **興味トピックは技術ニュースのものを使う**（このタブには興味トピックを選ぶ
        # 図が無い）。先の月を探す回が、その分野のイベントも探しに行く
        interests_from: "tazuna_tech",
        # **先の月を探す回を置く**（巡回「情報収集」。1 日に 1 回、1 か月ずつ）。connpass の新着は
        # 募集が出たものしか流れてこないので、そのままではカレンダーが来月で止まる
        look_ahead: true,
        # **絵を Chiezo に縮めて持たせる。** connpass は配信に絵を載せないので、イベントの
        # ページの og:image を Chiezo に拾わせる（名指ししたホストだけ）。外から足した
        # イベントは AI が返す絵から。TECH PLAY は配信の絵をそのまま使う
        thumbs: %{pages_from: ["connpass.com"]}
      },
      %{
        name: "映画",
        collection: "tazuna_movies",
        interest:
          "日本の映画館でこれから公開される映画と、公開中の映画。" <>
            "観るかどうかの判断が変わるもの(公開日と上映形式、注目の度合い、" <>
            "公開後の口コミの傾向と興行成績、配信の開始)を優先する",
        # **1 件 = 1 作品**（`Tazuna.News.Movies`）。記事を溜めると、同じ作品の記事が
        # 何本も並び、公開日も注目度も口コミも作品ごとにまとまらない。
        # 配信元は持たず、公開予定を探す回（情報収集）と、注目度と口コミを育てる回
        # （整理）だけで回す
        works: Tazuna.News.Movies,
        feeds: [],
        # **公開日のカレンダーを出す**（技術イベントと同じ仕組みで、日付のタグが違う）
        calendar: true,
        date_tag: Tazuna.News.Movies.date_tag(),
        item_word: "公開作",
        # **日付では落とさない**（3 か月先の作品を、足した日から 30 日で落とすことになる）。
        # 公開から時間が経ったものは整理の回に落とさせる
        ages_out: false,
        # **要約は作りません。** 見たいのは公開日と注目作で、定時にまとめて知らせる
        # ほど日々動く話題ではない
        digest: false,
        # **記事一覧は出しません**（1 件が記事ではなく作品なので）。代わりに注目作を並べる
        articles: false,
        # **ポスターを Chiezo に縮めて持たせる**（AI が公式サイトの絵の URL を返す）。
        # 画面が公式サイトの絵をそのまま指すと、見る人のブラウザが外へつなぎに行く
        thumbs: true
      }
    ]
  end

  @doc """
  日が経つだけで古くなる話題か。**既定はそう**（ニュースも記事も、時とともに
  要らなくなります）。

  **終わったら要らなくなるもの**は別で、そこは日付では落とせません ——
  半年先のイベントを 30 日の期限で落とすと、いちばん要るときに消えます。
  そういう話題は期限を持たず、終わったものを整理の回に落とさせます。
  """
  def ages_out?(%{ages_out: false}), do: false
  def ages_out?(_topic), do: true

  @doc """
  トピックの網を育てる話題か。**持たない話題では、図も収集の枠も出しません** ——
  押せる口だけあって中身が育たないのは、設定し忘れに見えます。
  """
  def themes?(%{themes: true}), do: true
  def themes?(_topic), do: false

  @doc """
  要約を作る話題か。**既定は作る**。作らない話題には要約の回を置かず、
  通知の設定も出しません（知らせるのは要約なので）。
  """
  def digest?(%{digest: false}), do: false
  def digest?(_topic), do: true

  @doc "開催日のカレンダーを出す話題か（`Tazuna.News.Events`）。"
  def calendar?(%{calendar: true}), do: true
  def calendar?(_topic), do: false

  @doc "カレンダーの日付を読むタグの頭（既定は技術イベントの `開催日`）。"
  def date_tag(%{date_tag: tag}) when is_binary(tag), do: tag
  def date_tag(_topic), do: Tazuna.News.Events.date_tag()

  @doc "カレンダーに並ぶものの呼び名（「その日の〜」。既定は「イベント」）。"
  def item_word(%{item_word: word}) when is_binary(word), do: word
  def item_word(_topic), do: "イベント"

  @doc """
  1 件 = 1 作品として育てる話題なら、その作り方のモジュール（`Tazuna.News.Movies`）。
  記事を溜める話題では nil。
  """
  def works(%{works: module}) when is_atom(module) and module != nil, do: module
  def works(_topic), do: nil

  @doc "記事の一覧を出す話題か。**既定は出す**（作品を育てる話題では出さない）。"
  def articles?(%{articles: false}), do: false
  def articles?(_topic), do: true

  @doc "話題の一覧（定義の順）。そのままタブの並びになります。"
  def list, do: defined()

  @doc "1 つぶん。定義に無い名前なら nil。"
  def get(collection) when is_binary(collection) do
    Enum.find(defined(), &(&1.collection == collection))
  end

  def get(_collection), do: nil
end
