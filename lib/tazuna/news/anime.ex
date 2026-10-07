defmodule Tazuna.News.Anime do
  @moduledoc """
  アニメの話題の**1 件 = 1 作品**の作り方（`Tazuna.Topics` の `works`）。映画
  （`Tazuna.News.Movies`）と同じ形で、追うのは**今期（いま放送・配信中）と来期**の
  テレビアニメと配信アニメです。

  ## 巡回

  - 情報収集（1 日に 1 回）—— 今期と来期の作品を探して足す。**1 回に探すのは
    1 区切りだけ**（`segments/0`。今期は 1 期で 50〜70 本あるので、放送の曜日で分ける）
  - 整理（12 時間ごと。どの収集も同じ）—— 放送日と注目度を付け直し、放送が始まった
    注目作に評判を書き足し、放送が終わって時間が経ったものを落とす

  ## タグ

  カレンダーは技術イベント・映画と同じ仕組み（`Tazuna.News.Events`）で、日付のタグは
  `放送開始:`。注目度のタグは同じもの（`注目度:高/中/低`）を使います。
  """

  alias Tazuna.News.Events

  @date_tag "放送開始"
  @end_tag "放送終了"
  @weekday_tag "曜日"
  @channel_tag "放送"
  @stream_tag "配信"
  @season_tag "期"
  @review_tag "評判"

  # 放送が終わってから何日で落とすか。**完走した作品は一気見の候補**なので、すぐには落とさない
  # （最終回のあとの評判が出そろうまで、要約でいちばん前に出したい時期）
  @keep_after_end_days 30

  # 終わりの日が分からない作品を、放送開始から何日で落とすか（2 クールぶん）
  @keep_without_end_days 190

  # 評判を書き直す間隔（日）。放送中は毎週話数が進むので、週に 1 回くらい
  @review_refresh_days 7

  # 探す回が順に回る区切り。**1 回に探すのは 1 つだけ** —— 今期のテレビアニメは
  # 1 期で 50〜70 本あり、AI が 1 回で返せる数十件に収まらない。曜日で分ければ
  # 1 回に 10〜20 本になる。配信だけの作品は曜日が決まらないことが多いので日曜に寄せる
  @segments ["今期・月火", "今期・水木", "今期・金土", "今期・日曜と配信のみ", "来期"]

  # 探す回の間隔（分）。1 日に 1 回で、区切りを一周するのに 5 日
  @survey_minutes 24 * 60

  @doc "放送開始日のタグの頭（カレンダーはこのタグで引く）。"
  def date_tag, do: @date_tag

  @doc "カレンダーの日付に添える言葉（「10月3日 放送開始」）。"
  def date_word, do: "放送開始"

  @doc "注目作の一覧の見出し（始まっているもの / これから始まるもの）。"
  def group_labels, do: {"放送中", "これから放送"}

  @doc "注目作の一覧に、始まってから何日前のものまで並べるか（整理の回が落とす長さと同じ）。"
  def recent_days, do: @keep_without_end_days

  @doc "探す回が順に回る区切り（この順で回り、最後の次は最初に戻る）。"
  def segments, do: @segments

  @doc "先を探す回の間隔（分）。"
  def survey_minutes, do: @survey_minutes

  @doc """
  作品に付けるタグの決まり。**探す回と整理の回で同じ文を使う**（書き分けると、
  回によって付く印の揃い方が変わる）。
  """
  def tag_rules do
    attention = Events.attention_tag()

    """
    - "#{@date_tag}:<YYYY-MM-DD>" —— **日本での放送（配信）開始日を必ず 1 つ**。
      テレビは最速の放送局の初回の日。配信だけの作品は配信開始の日。先行上映や先行配信の日ではなく
    - "#{@end_tag}:<YYYY-MM-DD>" —— 最終回の日が**決まっていれば**（無ければ付けない）
    - "#{@season_tag}:<YYYY年冬|春|夏|秋>" —— 放送が始まった期（1〜3 月が冬、4〜6 月が春、
      7〜9 月が夏、10〜12 月が秋）
    - "#{@weekday_tag}:<月|火|水|木|金|土|日>" —— 毎週の放送の曜日（最速の放送局のもの）。
      配信だけで曜日が決まっていなければ付けない
    - "#{@channel_tag}:<放送局>" —— 主な放送局を 2 つまで（「TOKYO MX」「日本テレビ」など）
    - "#{@stream_tag}:<配信サービス>" —— 主な配信サービスを 3 つまで（「Netflix」「ABEMA」など）
    - "#{attention}:高" / "#{attention}:中" / "#{attention}:低" を**必ず 1 つ** ——
      **どれだけ注目されているか**です。カレンダーで目立たせるのに使います。
      - 高: 人気シリーズの続編、大きな原作のアニメ化、評価の高い制作会社や監督の作品、
        放送が始まってから SNS や配信のランキングで話題になっているもの
      - 中: 名の通った原作や制作会社の作品だが、そこまで話題になっていないもの
      - 低: それ以外
      **迷ったら低に**（全部が高だと、目立たせる意味がなくなります）
    - ジャンル（ファンタジー・SF・ラブコメ・日常・スポーツ・ロボット など、当てはまるもの）と、
      原作の種類（漫画原作・ライトノベル原作・ゲーム原作・オリジナル）
    """
    |> String.trim_trailing()
  end

  @doc """
  探して足す回の依頼文（巡回「情報収集」）。**今期と来期の作品を、1 回に 1 区切りずつ**
  探させます（今回の区切りは `{cursor}`）。いま入っているものの見出しを見せます
  （`{names}`。見せないと、同じ作品を言い回しを変えて足し直す）。
  """
  def survey_prompt(interest) do
    """
    **今期（いま放送・配信中）と来期のアニメ**を探して足してください。今日は {now} です。
    期は 1〜3 月が冬、4〜6 月が春、7〜9 月が夏、10〜12 月が秋です。

    **今回探すのは「{cursor}」の区切りだけです。** 区切りは次の順に回ります
    （1 回に全部を探すと途中で打ち切られるので、分けて探しています）。
    #{segment_lines()}

    区切りが上のどれでもないとき（初めての回など）は「#{hd(@segments)}」を探してください。
    **next_cursor には、今回の次の区切りの名前**（#{Enum.join(@segments, " → ")} → #{hd(@segments)} の順）を
    そのまま入れてください。

    何を集めるかは次のとおりです。
    #{interest}

    **対象は、日本で放送・配信されるテレビアニメと配信アニメの新作**です
    （続編の新しいシーズンも入れる）。劇場アニメ・再放送・ショートアニメは入れないでください。
    期ごとの新作アニメの一覧（アニメの情報サイトの放送スケジュール、公式の発表）を当たると
    漏れが減ります。**その区切りの中は、漏れなく**探してください。

    - **放送（配信）開始日が決まっているものだけ**足してください（「202X 年放送予定」はまだ入れない）

    いま入っているものは次のとおりです（見出しとタグ）。
    {names}

    **上に並んでいる作品は足さないでください。** 見出しの書き方が違っても、
    同じ作品の同じシーズンは同じ 1 件です。**確信が持てるものだけ**を挙げてください。

    **返すのは 1 作品 = 1 件だけです。** 上の一覧の「まとめ:」で始まる見出しは、別の回が書く
    要約です。**まとめ・要約・一覧の 1 件は返さないでください**（真似て書くと、要約として
    画面に出てしまいます）。

    1 件ごとに次の形で返してください。
    - title: 作品の題名。**続編はシーズンが分かるように**（「第2期」「Season 3」など、公式の書き方で）
    - body: 次の形で。**先の展開は書かないでください**（読む人はこれから観ます）
        どんな作品か: 1〜2 文（原作・制作会社・監督・主な声優）
        注目の理由: 1 文（注目度が中以上のとき。なぜ注目されているか）
    - url: 公式サイト（**必ず入れる**。無ければ作品の情報ページ）
    - image: キービジュアルの画像の URL（公式サイトのページの og:image。
      **ページではなく画像そのものの URL**。分からなければ入れない）
    - tags: 次のとおり

    #{tag_rules()}
    """
  end

  # 区切りごとの説明（依頼文に並べる）
  defp segment_lines do
    Enum.map_join(@segments, "\n", fn
      "今期・月火" -> "- 今期・月火 —— 今期の作品のうち、毎週月曜か火曜に放送されるもの"
      "今期・水木" -> "- 今期・水木 —— 今期の作品のうち、毎週水曜か木曜に放送されるもの"
      "今期・金土" -> "- 今期・金土 —— 今期の作品のうち、毎週金曜か土曜に放送されるもの"
      "今期・日曜と配信のみ" -> "- 今期・日曜と配信のみ —— 今期の作品のうち、毎週日曜に放送されるものと、配信だけの作品"
      "来期" -> "- 来期 —— 次の期に放送が始まる作品（放送開始日が決まっているもの）"
    end)
  end

  @doc """
  整理の回の依頼文。**今ある作品を全部見せて**（`{current}`）、放送日と注目度を
  付け直し、放送が始まった注目作に評判を書き足し、要らないものを落とします。
  **評判は注目度が高い作品だけ**（全部に書かせると枠を食うわりに読まれない）。
  """
  def refine_prompt(interest) do
    """
    いま入っているアニメを見直して、**印を付け直し、注目作に評判を書き足し、
    要らないものを落としてください**。今日は {now} です。

    何を大事とみなすかは次のとおりです。
    #{interest}

    いま入っているものは次のとおりです。
    {current}

    **1. 放送日と注目度を付け直す。**
    放送開始日が変わった（延期・前倒し）ものは直してください。最終回の日が決まったら
    "#{@end_tag}:" を足してください。注目度は、放送が始まって話題になったものは上げ、
    期待ほどでなかったものは下げてください。

    **2. 放送が始まった注目作に、評判を書き足す。**
    "#{Events.attention_tag()}:高" の作品のうち、**放送が始まったもの**（放送開始日が今日以前）が対象です。
    まだ "#{@review_tag}:" のタグが無いもの、付いている日付から #{@review_refresh_days} 日以上
    経ったもの（放送中のもの）、**最終回のあとにまだ書き直していないもの**を当たってください。
    - body の末尾に次の形で足す（前に書いたものがあれば置き換える）
        評判（<M月D日>時点）: 観た人の反応の傾向を 2〜3 文。**自分の言葉で**
          （「作画を評価する声が多い」「原作との違いで賛否が割れている」）。
          最終回のあとなら、**通して観た人の評価**（完走して満足か、後半の失速など）を
    - 中だった作品も、放送が始まって話題になったら高に上げてから評判を書いてください
        出どころ: 当たったページの URL（1〜3 本）
    - tags に "#{@review_tag}:<YYYY-MM-DD>"（書いた日）を足す（前の日付は外す）
    - **感想の本文は写さないでください**（転載になるうえ、1 人の感想は作品の評判ではありません）
    - **先の展開は書かないでください**（読む人はこれから観ます）

    **3. 要らないものを落とす。**
    次のものは **tags に "#{Tazuna.Chiezo.tombstone_tag()}" だけを入れて返してください**（墓標）。
    **そのとき body に、なぜ消すのかを 1 行で書いてください**。
    - 最終回から #{@keep_after_end_days} 日以上経ったもの
    - 最終回の日が分からず、放送開始から #{@keep_without_end_days} 日以上経ったもの
    - 放送が中止・無期限延期になったもの、劇場アニメ・再放送だと分かったもの
    - 同じ作品の同じシーズンの 1 件が既にあるもの（**残すほうは 1 つだけ**。先に入っているほうを残す）

    **返すのは、触ったものと落とすものだけ**です。触らなかったものはそのまま残ります。
    **返すときは、title は今のまま、tags は全部**（変えないものも）返してください ——
    返した tags がそのまま付け替わります。body を変えないなら body は返さなくて構いません。
    **返す作品には image も入れてください** —— キービジュアルの画像の URL
    （公式サイトのページの og:image。**ページではなく画像そのものの URL**。分からなければ入れない）。
    **next_cursor は返さないでください**（情報収集の回が、次に探す区切りを覚えている印です）。

    タグの決まりは次のとおりです。

    #{tag_rules()}
    - "#{@review_tag}:<YYYY-MM-DD>" —— 評判を書いた日（書いたものだけ）
    """
  end

  @doc "作品の説明を、画面に出す形にします（評判まで全部出す。映画と同じ）。"
  def body_lines(entry), do: Tazuna.News.Movies.body_lines(entry)

  # 要約に名指しで渡す作品の数（Chiezo の割り込みで名指しできる上限）
  @digest_titles 50

  @doc """
  要約の材料として名指しする作品の見出し（`Tazuna.Digest`）。#{@digest_titles} 本まで。

  **放送が始まったもの（放送中と、最終回から #{@keep_after_end_days} 日以内）を先に**並べます。
  読む人は話題になった作品をまとめて観たいので、これから始まる作品は**注目度が高いものだけ**
  （中まで入れると、期の変わり目に来期の紹介で要約が埋まる）。
  """
  def digest_titles(base, topic) do
    case Events.fetch_tagged(base, topic.collection, notable_tags(), date_tag: @date_tag) do
      {:ok, entries} -> pick_for_digest(entries, Tazuna.Jst.today())
      {:error, _reason} -> []
    end
  end

  defp notable_tags, do: Enum.map_join(["高", "中"], ",", &"#{Events.attention_tag()}:#{&1}")

  @doc false
  def pick_for_digest(entries, today) do
    entries
    |> in_window(today)
    |> Enum.reject(&(upcoming?(&1, today) and &1.attention != :high))
    |> Enum.sort_by(
      &{stage(&1, today), if(&1.attention == :high, do: 0, else: 1),
       abs(Date.diff(&1.date, today)), &1.title}
    )
    |> Enum.take(@digest_titles)
    |> Enum.map(& &1.title)
  end

  # 絵を探させる作品。要約とは違い、これから始まる中の作品も入れる（カレンダーにも出るので）
  defp pick_for_images(entries, today) do
    entries
    |> in_window(today)
    |> Enum.sort_by(
      &{if(&1.attention == :high, do: 0, else: 1), abs(Date.diff(&1.date, today)), &1.title}
    )
    |> Enum.take(@digest_titles)
    |> Enum.map(& &1.title)
  end

  defp in_window(entries, today) do
    from = Date.add(today, -@keep_without_end_days)
    until = Date.add(today, 120)

    entries
    |> Enum.filter(&(Date.compare(&1.date, from) != :lt and Date.compare(&1.date, until) != :gt))
    |> Enum.reject(&ended_long_ago?(&1, today))
  end

  defp upcoming?(entry, today), do: Date.compare(entry.date, today) == :gt

  # 要約に並べる順。最終回を迎えたばかり（一気見どき）→ 放送中 → これから
  defp stage(entry, today) do
    cond do
      upcoming?(entry, today) -> 2
      (ended = ended_on(entry)) && Date.compare(ended, today) != :gt -> 0
      true -> 1
    end
  end

  defp ended_long_ago?(entry, today) do
    case ended_on(entry) do
      nil -> false
      date -> Date.diff(today, date) > @keep_after_end_days
    end
  end

  @doc """
  **絵の無い注目作に、絵を探させます**（割り込み 1 回。映画と同じ）。
  `{:ok, 名指しした数}` / `{:error, 理由}`。
  """
  def fill_images(base, topic) do
    with {:ok, entries} <-
           Events.fetch_tagged(base, topic.collection, notable_tags(), date_tag: @date_tag),
         titles when titles != [] <-
           entries
           |> Enum.filter(&(is_nil(&1.thumb) and is_nil(&1.image)))
           |> pick_for_images(Tazuna.Jst.today()),
         :ok <-
           Tazuna.Chiezo.focus(
             base,
             topic.collection,
             "名指しした作品に、絵（image）を付けてください。",
             titles,
             Tazuna.SweepNames.tidy(),
             nil,
             image_prompt()
           ) do
      {:ok, length(titles)}
    else
      [] -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "絵を探させる回の依頼文（その回だけの依頼文。定義の文は変わらない）。"
  def image_prompt do
    """
    下に並んでいるアニメそれぞれについて、**キービジュアルの画像の URL** を探して
    image に入れて返してください。

    {current}

    - image は公式サイトのページの og:image（**ページではなく画像そのものの URL**）。
      公式サイトが無ければアニメの情報サイトの作品ページのもの。
      **確かめられなければ入れないでください**（その作品は返さなくて構いません）
    - **title と tags は上のまま、tags は全部返してください** —— 返した tags がそのまま
      付け替わります（1 つでも落とすと、放送日や注目度が消えます）
    - **body は返さないでください**（本文は今のまま残ります）
    - **next_cursor は返さないでください**
    """
  end

  @doc "日付のあとに並べる事実（曜日・放送局・配信・最終回）。"
  def facts(entry) do
    [
      case values(entry, @weekday_tag) do
        [day | _] -> "毎週#{day}曜"
        [] -> nil
      end,
      case values(entry, @channel_tag) do
        [] -> nil
        channels -> Enum.join(channels, "・")
      end,
      case values(entry, @stream_tag) do
        [] -> nil
        services -> "配信: " <> Enum.join(services, "・")
      end,
      case ended_on(entry) do
        nil -> nil
        date -> "#{date.month}月#{date.day}日に最終回"
      end
    ]
  end

  @doc "最終回の日（タグから。決まっていなければ nil）。"
  def ended_on(entry) do
    Enum.find_value(values(entry, @end_tag), fn value ->
      case Date.from_iso8601(value) do
        {:ok, date} -> date
        _ -> nil
      end
    end)
  end

  defp values(%{tags: tags}, head) when is_list(tags) do
    for tag <- tags,
        String.starts_with?(tag, head <> ":"),
        value = tag |> String.replace_prefix(head <> ":", "") |> String.trim(),
        value != "",
        do: value
  end

  defp values(_entry, _head), do: []
end
