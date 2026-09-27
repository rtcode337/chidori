defmodule Tazuna.News.Events do
  @moduledoc """
  技術イベントの**開催日・開催地・注目度**を読み、月ごとのカレンダーに並べます。

  ## どこから読むか

  **タグが先、無ければ本文。** 整理の回に次のタグを付けさせています（`refine_note/0`）。

  - `開催日:2026-10-25`（初日）と、連日なら `終了日:2026-10-27`
  - `開催地:東京都` / `開催地:オンライン`（両方あれば両方）
  - `注目度:高` / `注目度:中` / `注目度:低`

  connpass の配信は本文の頭に `開催日時: 2026/10/25 17:00 ～ 19:00` と
  `開催場所: 東京都千代田区…` を必ず書いているので、タグが付く前でも
  そこから日付と都道府県は読めます（詳細に出すときの予備）。

  ## カレンダーはタグで引く

  月の日付ぶんの `開催日:` タグを並べて 1 回で引きます（Chiezo の `filter` は
  カンマで並べたタグを「どれか」で引く）。**溜まっている全部を読みに行かない** ——
  connpass の新着は 1 日に数十件入るので、月をまたいで読むと画面を開くたびに
  数千件を運ぶことになります。
  """

  alias Tazuna.Chiezo
  alias Tazuna.Jst

  @date_tag "開催日"
  @end_tag "終了日"
  @place_tag "開催地"
  @attention_tag "注目度"
  @online "オンライン"

  # 1 回に引く件数（Chiezo 側の上限）
  @page_limit 500

  # 先を探す回が見る先（月）。**connpass の新着は募集が出たものしか流れてこない**ので、
  # 数か月先の大きなイベントはここで埋める
  @look_ahead_months 6

  # 先を探す回の間隔（分）。**週に 1 回** —— 先の予定は日ごとには動かないので、
  # 毎日探しても同じものを見つけ直すだけで枠を食う
  @look_ahead_minutes 7 * 24 * 60

  # 都道府県。**開催地がこのどれでもなければ海外**（整理の回には、海外は国名で
  # 書かせている）。国内か海外かで「行けるか」の読み方がまるで違うので、画面で分ける
  @prefectures ~w(北海道 青森県 岩手県 宮城県 秋田県 山形県 福島県 茨城県 栃木県 群馬県
                 埼玉県 千葉県 東京都 神奈川県 新潟県 富山県 石川県 福井県 山梨県 長野県
                 岐阜県 静岡県 愛知県 三重県 滋賀県 京都府 大阪府 兵庫県 奈良県 和歌山県
                 鳥取県 島根県 岡山県 広島県 山口県 徳島県 香川県 愛媛県 高知県 福岡県
                 佐賀県 長崎県 熊本県 大分県 宮崎県 鹿児島県 沖縄県)

  # 開催地の絞り込みで、まとめて選ぶ口（都道府県・国名ではない特別な値）
  @japan "国内"
  @abroad "海外"

  # 都道府県の書き出し（本文の「開催場所:」から拾う）
  @prefecture ~r/^(北海道|東京都|(?:京都|大阪)府|.{2,3}県)/u

  @doc "開催日のタグの頭。"
  def date_tag, do: @date_tag

  @doc "開催地のタグの頭。"
  def place_tag, do: @place_tag

  @doc "注目度のタグの頭。"
  def attention_tag, do: @attention_tag

  @doc """
  整理の回の依頼文に足す、技術イベントならではの頼みごと（`Tazuna.Topics` の `note`）。

  **並んだイベントは全部返させます**（タグの決まりは `tag_rules/0`）。ふだんの整理は「触ったものだけ返す」ですが、
  開催日のタグが無いイベントはカレンダーに出ません —— タグを付けるだけの返りなので、
  本文は返さなくて構いません（Chiezo は本文を返さなかった直しで本文を残します）。
  """
  def refine_note do
    """
    **この話題では、上に並んでいるイベントを全部、次のタグを付けて返してください**
    （「触ったものだけ」の例外です。タグを付けるだけなら body は返さなくて構いません。
    今のまま残ります）。カレンダーはこのタグで作るので、**付いていないイベントは
    読む人の目に入りません**。

    #{tag_rules()}

    ほかにも次のことを守ってください。

    - **申込先の URL** を `url` に入れてください。締切や参加費が分かれば body に 1 行
    - **終わったイベントは消してください**（墓標）。この話題は日付では古くなりません
      —— 終わったかどうかだけが古さです
    - **同じイベントの別の回は別の 1 件**にしてください（第 3 回と第 4 回は別物）。
      見出しに回や年を入れると混ざりません
    - **外から足す大きなイベントにも、同じタグを付けてください**。開催日が未定のものは
      "#{@date_tag}:" を付けずに足し、body に「開催日は未定」と書いてください
    """
  end

  @doc """
  開催日・開催地・注目度のタグの決まり。**整理の回と先を探す回で同じ文を使う** ——
  書き分けると、回によって付く印の揃い方が変わり、カレンダーの目立たせ方がぶれる。
  """
  def tag_rules do
    """
    - "#{@date_tag}:<YYYY-MM-DD>" —— **開催日（初日）を必ず 1 つ**。日本時間の日付で。
      connpass のものは本文の「開催日時:」、TECH PLAY のものは「日時:」に書いてあります
    - "#{@end_tag}:<YYYY-MM-DD>" —— **連日のときだけ**、最終日を
    - "#{@place_tag}:<都道府県>" / "#{@place_tag}:#{@online}" —— **開催地を必ず**。
      会場のある都道府県を「東京都」「大阪府」の形で。オンラインなら "#{@place_tag}:#{@online}"、
      会場とオンラインの両方なら両方。海外なら国名（"#{@place_tag}:アメリカ"）
    - "#{@attention_tag}:高" / "#{@attention_tag}:中" / "#{@attention_tag}:低" を**必ず 1 つ** ——
      **界隈がどれだけ注目しているか**です。カレンダーで目立たせるのに使います。
      - 高: 各社の年次カンファレンス・主要な国際会議・毎回満席になる大きな勉強会、
        界隈で話題になっている回（登壇者や題目で話題になっているものも）
      - 中: 名の通ったコミュニティの定例会、数十人規模で集まるもの
      - 低: 少人数の勉強会・もくもく会・社内向けに近いもの
      **迷ったら低に**（全部が高だと、目立たせる意味がなくなります）
    """
    |> String.trim_trailing()
  end

  @doc """
  整理の回の「上に無いものを探して足す」の、技術イベント向けの頼み方
  （`Tazuna.Topics` の `outside`）。

  **ニュース向けの頼み方のままだと、探す先が違います。** 話題に共通の文は
  「公式の発表・テックブログ・話題の論文（毎回必ず当たる）」を挙げていて、
  技術イベントでは論文を探すのに枠を使い、connpass に載らないイベントを
  探しに行きませんでした。
  """
  def outside do
    """
    **2. 上に無いイベントを探して足す。**
    配信元（connpass の新着）に載るのは、connpass で募集を出したものだけです。
    **それ以外の場所で告知されるイベント**を当たってください。たとえば次のようなところです。

    - カンファレンスの公式サイトで募集するもの（各社の年次カンファレンス、
      コミュニティが開く大きなカンファレンス）
    - connpass 以外の告知サイト（Doorkeeper、TECH PLAY、Peatix など）に出ているもの
    - 企業・団体・自治体が自分のサイトで告知している技術イベント

    **これから開かれるものだけ**を足してください（終わったものは足さない）。
    **確信が持てるものだけ**を挙げてください。探して見つからなければ 0 件で構いません。
    """
  end

  @doc "先を探す回の間隔（分）。"
  def look_ahead_minutes, do: @look_ahead_minutes

  @doc """
  先を探す回の依頼文（巡回「情報収集」）。**数か月先の大きなイベントを、月ごとに探させます**。

  connpass の新着は**募集が出た順**にしか流れてこないので、カレンダーは来月までで
  止まります（勉強会の多くは 1〜2 か月前に募集を出す）。先の月を埋めるのは、
  日程を早くから出す大きなイベント —— 各社の年次カンファレンスや、毎年開かれる
  コミュニティのカンファレンスです。

  **いま入っているものの見出しを見せます**（`{names}`）。見せないと、同じイベントを
  回ごとに言い回しを変えて足し直します。**開催日が決まったものだけ**足させます
  （決まっていないものはカレンダーに出ないので、足しても誰の目にも入らない）。
  """
  def look_ahead_prompt(interest, interests \\ []) do
    """
    これから開かれる技術のイベントのうち、**今日から #{@look_ahead_months} か月先までに
    開かれる大きなもの**を探して足してください。今日は {now} です。

    何を集めるかは次のとおりです。
    #{interest}

    配信元（connpass の新着）には、募集が出たイベントしか流れてきません。勉強会の多くは
    1〜2 か月前に募集を出すので、**それより先の月はほとんど空です**。ここで埋めてほしいのは、
    **日程を早くから出す大きなイベント**です。

    - 各社の年次カンファレンス・開発者向けイベント
    - 毎年開かれるコミュニティのカンファレンス（言語・技術ごとの大きなもの）
    - 主要な国際会議のうち、界隈が追いかけるもの
    - 企業・団体・自治体が開く、大きな技術イベント

    **月ごとに探してください**（来月、再来月、…と #{@look_ahead_months} か月先まで）。
    1 つの月でたくさん見つかっても、先の月を探さずに終えないでください。
    #{interest_section(interests)}
    いま入っているものは次のとおりです（見出しとタグ）。
    {names}

    **上に並んでいるイベントは足さないでください。** 見出しの書き方が違っても、
    同じイベントの同じ回は同じ 1 件です。**開催日が決まっているものだけ**足してください
    （未定のものはカレンダーに出ません）。**確信が持てるものだけ**を挙げてください。

    1 件ごとに次の形で返してください。
    - title: イベントの名前。**回や年を入れてください**（「◯◯ Conference 2027」のように。
      同じイベントの別の回は別の 1 件です）
    - body: 1〜2 行。何のイベントで、どういう人に向くか。申込の締切や参加費が分かれば 1 行
    - url: 公式サイトか申込ページ（**必ず入れる**）
    - tags: 次のとおり

    #{tag_rules()}
    """
  end

  # 読む人の興味トピックの分野のイベントも探させる節。**選んでいなければ何も足さない**。
  # 大きなイベントだけを探させると、興味のある分野の勉強会やハンズオンは
  # connpass に載るまで（1〜2 か月前まで）入らない —— 分野を名指しすれば、
  # 公式サイトや他の告知サイトで先に出ているものも拾える
  defp interest_section([]), do: ""

  defp interest_section(interests) do
    """

    **読む人の興味トピックの分野のイベントも探してください**:
    #{Enum.map_join(interests, "、", &"「#{&1}」")}。
    こちらは**大きさを問いません**（勉強会・ハンズオン・ミートアップ・カンファレンスの
    分科会も含む）。同じく #{@look_ahead_months} か月先まで、開催日が決まっているものだけを。
    """
  end

  @doc """
  1 件を、カレンダーに並べる形にします。記事の形（`Tazuna.News`）でも、
  Chiezo の生の 1 件（`"title"` / `"tags"` / `"extra"` / `"opening"`）でも受けます。
  """
  def entry(%{"title" => title} = doc) do
    extra = if is_map(doc["extra"]), do: doc["extra"], else: %{}

    entry(%{
      title: title,
      tags: Enum.map(doc["tags"] || [], &to_string/1),
      url: extra["url"],
      summary: doc["opening"]
    })
  end

  def entry(%{title: title, tags: tags} = article) do
    summary = Map.get(article, :summary) || ""
    date = tag_date(tags, @date_tag) || body_date(summary)

    %{
      title: title,
      url: safe_url(Map.get(article, :url)),
      summary: summary,
      date: date,
      end_date: tag_date(tags, @end_tag),
      time: body_time(summary),
      places: places(tags, summary),
      attention: attention(tags)
    }
  end

  @doc """
  その月の日付ぶんの `開催日:` タグ（カンマ区切り）。Chiezo の `filter` にそのまま渡します。
  """
  def month_tags(%Date{} = first) do
    first
    |> days_of_month()
    |> Enum.map_join(",", &"#{@date_tag}:#{Date.to_iso8601(&1)}")
  end

  @doc """
  その月のイベントを Chiezo から引きます。`{:ok, [entry]}` か `{:error, 理由}`。
  """
  def fetch_month(base, collection, %Date{} = first) do
    fetch(base, collection, month_tags(first), 0, [])
  end

  defp fetch(base, collection, tags, offset, acc) do
    case Chiezo.spot_docs(base, collection, tags, offset, @page_limit) do
      {:ok, %{docs: []}} ->
        {:ok, finish(acc)}

      {:ok, %{total: total, docs: docs}} ->
        got = acc ++ docs

        if length(got) >= total,
          do: {:ok, finish(got)},
          else: fetch(base, collection, tags, length(got), got)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish(docs), do: docs |> Enum.map(&entry/1) |> Enum.reject(&is_nil(&1.date))

  @doc "今日（JST）を含む月の 1 日。"
  def this_month do
    today = Jst.today()
    Date.new!(today.year, today.month, 1)
  end

  @doc "前後の月の 1 日。"
  def shift_month(%Date{year: year, month: month}, by) do
    index = year * 12 + (month - 1) + by
    Date.new!(div(index, 12), rem(index, 12) + 1, 1)
  end

  @doc """
  月のカレンダー。**日曜はじまり**の週の並びで、1 マスは
  `%{date:, in_month:, events: [entry]}`（その日に始まるイベント。注目度の高い順）。
  """
  def weeks(%Date{} = first, entries) do
    by_day = Enum.group_by(entries, & &1.date)
    start = Date.add(first, -rem(Date.day_of_week(first), 7))
    last = Date.end_of_month(first)
    finish = Date.add(last, 6 - rem(Date.day_of_week(last), 7))

    Date.range(start, finish)
    |> Enum.map(fn day ->
      %{
        date: day,
        in_month: day.month == first.month,
        events: day |> then(&Map.get(by_day, &1, [])) |> sort()
      }
    end)
    |> Enum.chunk_every(7)
  end

  @doc "注目度の高い順（同じなら見出し順）。"
  def sort(entries), do: Enum.sort_by(entries, &{-rank(&1.attention), &1.title})

  @doc """
  出てくる開催地。**オンラインを先頭に**（どこからでも行けるので、場所で絞る人も
  まず残したい）、次に国内、最後に海外（それぞれ多い順）。
  """
  def places_of(entries) do
    entries
    |> Enum.flat_map(& &1.places)
    |> Enum.frequencies()
    # オンライン → 国内（多い順）→ 海外（多い順）
    |> Enum.sort_by(fn {place, count} ->
      {Map.fetch!(%{online: 0, japan: 1, abroad: 2}, region(place)), -count, place}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  開催地で絞ります。**何も選んでいなければ全部**。開催地の分からないものは絞ると外れます。
  「国内」「海外」を選ぶと、都道府県すべて・国内とオンライン以外すべてに当たります。
  """
  def only_places(entries, []), do: entries

  def only_places(entries, picked) do
    Enum.filter(entries, fn entry ->
      Enum.any?(entry.places, fn place ->
        place in picked or (@japan in picked and region(place) == :japan) or
          (@abroad in picked and region(place) == :abroad)
      end)
    end)
  end

  @doc "開催地の絞り込みで、国内をまとめて選ぶ値。"
  def japan, do: @japan

  @doc "開催地の絞り込みで、海外をまとめて選ぶ値。"
  def abroad, do: @abroad

  @doc "開催地が国内（`:japan`）・海外（`:abroad`）・オンライン（`:online`）のどれか。"
  def region(@online), do: :online
  def region(place) when place in @prefectures, do: :japan
  def region(_place), do: :abroad

  @doc "海外で開かれるイベントか（国内の会場もあれば国内として扱う）。"
  def abroad?(%{places: places}) do
    Enum.any?(places, &(region(&1) == :abroad)) and
      not Enum.any?(places, &(region(&1) == :japan))
  end

  @doc """
  マスに添える開催地の短い呼び名（「東京」「大阪」「オンライン」「アメリカ」）。
  都道府県は末尾の都・府・県を落とす（北海道はそのまま）。**2 つまで**
  （会場とオンラインの両方、くらいまでがマスに収まる）。
  """
  def short_places(%{places: places}) do
    places |> Enum.take(2) |> Enum.map_join("・", &short_place/1)
  end

  defp short_place("北海道"), do: "北海道"

  defp short_place(place) do
    if region(place) == :japan, do: String.replace(place, ~r/[都府県]$/u, ""), else: place
  end

  # 説明に出す長さ。**読むかどうかを決める 2〜3 行**（全文は申込ページにある）
  @description_chars 200

  @doc """
  1 件の簡単な説明（日を押した一覧で、それぞれの下に出す）。

  **本文の頭を地の文にして使います。** connpass の本文は HTML のまま入っていて、
  頭に「開催日時:」「開催場所:」の行がある —— 日時と場所は一覧に別に出しているので
  落とし、タグを外して空白を詰め、#{@description_chars} 字で切ります。
  AI が書き直した本文（外から足したもの）はそのまま地の文なので、同じ扱いで通ります。
  """
  def description(%{summary: summary}) when is_binary(summary) do
    text =
      summary
      |> String.replace(~r/<br\s*\/?>|<\/p>|<\/h\d>|<\/li>/iu, "\n")
      |> String.replace(~r/<[^>]*>/u, "")
      |> unescape()
      |> String.split("\n")
      |> Enum.reject(&String.match?(&1, ~r/^\s*(開催日時|開催場所|日時|会場)[:：]/u))
      |> Enum.join(" ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    if String.length(text) > @description_chars,
      do: String.slice(text, 0, @description_chars) <> "…",
      else: text
  end

  def description(_entry), do: ""

  defp unescape(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  defp rank(:high), do: 3
  defp rank(:mid), do: 2
  defp rank(:low), do: 1
  defp rank(_other), do: 0

  defp days_of_month(first), do: Date.range(first, Date.end_of_month(first))

  defp tag_date(tags, head) do
    Enum.find_value(tags, fn tag ->
      with true <- String.starts_with?(tag, head <> ":"),
           {:ok, date} <-
             tag |> String.replace_prefix(head <> ":", "") |> String.trim() |> Date.from_iso8601() do
        date
      else
        _ -> nil
      end
    end)
  end

  defp body_date(text) do
    case Regex.run(~r/(?:開催)?日時[:：]\s*(\d{4})\/(\d{1,2})\/(\d{1,2})/u, text) do
      [_, y, m, d] ->
        case Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
          {:ok, date} -> date
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # 始まりの時刻（本文の「開催日時:」から。無ければ nil）
  defp body_time(text) do
    case Regex.run(
           ~r/(?:開催)?日時[:：]\s*\d{4}\/\d{1,2}\/\d{1,2}(?:\s*\([^)]*\))?\s+(\d{1,2}:\d{2})/u,
           text
         ) do
      [_, time] -> time
      _ -> nil
    end
  end

  defp places(tags, summary) do
    from_tags =
      for tag <- tags,
          String.starts_with?(tag, @place_tag <> ":"),
          place = tag |> String.replace_prefix(@place_tag <> ":", "") |> String.trim(),
          place != "",
          do: place

    if from_tags != [], do: Enum.uniq(from_tags), else: body_places(summary)
  end

  defp body_places(text) do
    case Regex.run(~r/開催場所[:：]\s*([^\n<]+)/u, text) do
      [_, where] ->
        where = String.trim(where)

        [
          if(String.contains?(where, @online), do: @online),
          case Regex.run(@prefecture, where) do
            [_, pref] -> pref
            _ -> nil
          end
        ]
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp attention(tags) do
    Enum.find_value(tags, fn
      @attention_tag <> ":" <> level -> Map.get(%{"高" => :high, "中" => :mid, "低" => :low}, level)
      _ -> nil
    end)
  end

  defp safe_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> url
      _ -> nil
    end
  end

  defp safe_url(_url), do: nil
end
