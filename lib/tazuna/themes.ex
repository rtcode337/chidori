defmodule Tazuna.Themes do
  @moduledoc """
  トピック（話題の語と、そのつながり）を溜めるところ。

  **語は機械が拾います。** 記事に付いたタグがそのままトピックになり（Chiezo の
  `extract` の `of: "tags"`）、件数・直近の件数・一緒に出てくる語も機械が数えます ——
  AI に語を思いつかせていた頃は、記事に出てこない語が混ざり、同じ話題が回ごとに
  違う表記で増えました。

  **AI がやるのは精査だけです。** 言い換えを 1 つに畳む、親子を決める、技術の話で
  ない語（媒体名・一般語）を外す、一言で説明する —— どれも数では決まらないことです。
  tazuna は**指示文を渡して、できたものを読む**だけで、数えも材料作りもしません。

  **画面のタブ（話題）とは別のものです。** `Tazuna.Topics` は「技術ニュース」
  「ニュース」のような画面のタブで、こちらは記事から拾う語（AIエージェント、
  セキュリティ…）です。名前が紛らわしいので、コードの側では分けてあります。

  **溜め先は記事とは別の収集（網羅）にします。** 記事と同じ収集に置くと、流れの
  期限（30 日）でトピックまで消えます —— 記事が落ちてもトピックは残り、
  **「最後に見たのはいつか」が読める**のはそのためです。

  **図の語彙はここが持ちます**（関連図の画家と同じ形）。図を読むのは tazuna なので、
  読む側と書かせる側が離れると静かにズレます。

  - `#{"トピック"}` —— 図に出す目印（機械が付ける）
  - `#{"親:"}<名前>` —— 上位のトピック（1 つ。AI が決める）
  - `#{"分野:"}<名前>` —— 色分け（AI が決める）
  - `#{"同義:"}<語>` —— 畳んだ言い換え（AI が書く）

  数のほうは脇書きに入ります（機械が毎回入れ替えます）。

  - `docs` / `docs_recent` —— その語が付いた記事の件数と、直近の窓のぶん。
    **丸の大きさは直近のほう** —— 件数だけだと、昔よく出てきた語がいつまでも大きい
  - `last_seen` —— 最後にその語が付いた日。静かになった話題が読めます
  - `links` —— 一緒に出てくる語（`語:回数`）。**そのまま線になります**
  """

  alias Tazuna.Chiezo

  @theme_tag "トピック"
  @parent_prefix "親:"
  @field_prefix "分野:"
  @synonym_prefix "同義:"

  # 読み込む上限。図に出せる数はもっと少ないが、一覧と数えるぶんは全部読む
  @limit 200

  # 巡回の名前。**他の収集（食事処・関連図）の巡回と同じ呼び名にそろえる** ——
  # Chiezo の管理画面では収集をまたいで並ぶので、同じ仕事が別の名前だと読み比べられない
  @pick_sweep Tazuna.SweepNames.machine()
  @tidy_sweep Tazuna.SweepNames.tidy()

  # 機械収集の回と、整理の回。**分けるのは仕事が違うから** —— 機械収集は機械が数える回で、
  # AI を呼ばないぶん短い間隔で回せる。整理は読んで判断する回
  @pick_minutes 60
  @tidy_minutes 360

  # 語として拾う下限。**1 件しか付いていない語は、まだ話題かどうかも分からない**
  # （次の回に増えていれば入る）
  @min_docs 2

  # 「いま動いているか」を見る窓（日）。**時間軸はここに入る** —— 件数だけだと、
  # 昔よく出てきた語がいつまでも大きいままになる
  @recent_days 7

  # 1 語につき運ぶ「一緒に出てくる語」の数。多いと図が毛玉になる
  @link_count 6

  # 拾う語の上限。図に出せるのはこのうちの上位だけだが、一覧と親子の突き合わせには
  # それより多く要る
  @tag_limit 200

  @doc "その話題のトピックを溜める収集の名前。**話題ごとに分けます**。"
  def collection_name(%{collection: collection}), do: collection <> "_topics"
  def collection_name(collection) when is_binary(collection), do: collection <> "_topics"

  @doc "図に出す目印。"
  def theme_tag, do: @theme_tag

  @doc "そのトピックに畳んだ言い換え（「#{@synonym_prefix}<語>」のタグ）。"
  def synonyms_of(%{tags: tags}) do
    for tag <- tags, String.starts_with?(tag, @synonym_prefix) do
      tag |> String.replace_prefix(@synonym_prefix, "") |> String.trim()
    end
    |> Enum.reject(&(&1 == ""))
  end

  @doc "上位のトピックを載せるタグの頭。"
  def parent_tag, do: @parent_prefix

  @doc "分野を載せるタグの頭。色はこれで決まります。"
  def field_tag, do: @field_prefix

  @doc "畳んだ言い換えを載せるタグの頭。**図には出しません**（探すときに効きます）。"
  def synonym_tag, do: @synonym_prefix

  @doc """
  収集の依頼の中身。**網羅**で、期限では落としません。

  **語を拾うのは機械です**（`extract` の `of: "tags"`）。記事に付いたタグが
  そのままトピックになり、件数も一緒に出てくる語も Chiezo が数えます。
  """
  def attrs(topic, choices \\ %{}) do
    %{
      name: collection_name(topic),
      description: "tazuna の「#{topic.name}」のトピック（記事のタグから作る話題の網）",
      prompt: tidy_prompt(topic),
      interval_minutes: @tidy_minutes,
      kind: "stock",
      extract: extract_spec(topic),
      sweeps: with_choices(sweeps(topic), choices),
      requested_by: "tazuna"
    }
  end

  @doc """
  語を拾ってくる指定。**記事の収集のタグを、そのまま名簿にします**。

  **外す語はここで書きます** —— 機械が読む印（`_chiezo_…`）と、tazuna が決めている
  語（種別・重要度・話題度・興味度・まとめの印）は話題ではありません。**配信元の名前は書けません**
  （配信元が名乗るタイトルなので、tazuna は知りません）—— あれは整理の回が
  「技術の話ではない」として外します。
  """
  def extract_spec(topic) do
    %{
      source: topic.collection,
      of: "tags",
      skip: [
        "^_chiezo_",
        "^#{Tazuna.News.importance_tag()}:",
        "^#{Tazuna.News.buzz_tag()}:",
        "^#{Tazuna.News.interest_tag()}:",
        # まとめの印も話題ではない（記事ではなく、要約の回が書いた読み物に付く）
        "^(#{Tazuna.News.digest_tag()}|#{Tazuna.News.interest_digest_tag()})$",
        "^(#{Enum.join(Tazuna.News.kind_tags(), "|")})$"
      ],
      min_docs: @min_docs,
      recent_days: @recent_days,
      links: @link_count,
      limit: @tag_limit,
      tags: [%{const: @theme_tag}]
    }
  end

  @doc """
  巡回。**機械収集の回と整理の回に分けます**。

  - 機械収集 —— 記事のタグを名簿にし、件数と一緒に出てくる語を数え直す（**AI を呼びません**）
  - 整理 —— 手元にある語を読んで、言い換えを畳み、親子と分野を決め、話題でない語を外す

  **機械収集の回は足すだけ**にします。組にしないと、AI が書いた説明を機械の 1 行で
  上書きします（数のほうは足すだけの回でも入れ替わります）。
  """
  def sweeps(topic) do
    [
      %{name: @pick_sweep, interval_minutes: @pick_minutes, use_extract: true, only_new: true},
      %{name: @tidy_sweep, interval_minutes: @tidy_minutes, prompt: tidy_prompt(topic)}
    ]
  end

  defp with_choices(sweeps, choices) do
    for sweep <- sweeps do
      case Map.get(choices, sweep.name) do
        nil -> sweep
        picked -> Map.merge(sweep, picked)
      end
    end
  end

  @doc """
  整理の回の依頼文。**語はもう拾ってあります**（機械が）。この回は**精査だけ**です。

  分類の 4 択にしてあるのは、**間違い方に差がある**からです —— 言い換えでないものを
  畳むと片方が消え、外した語は二度と戻ってきません。迷ったものは触らせずに
  次の回へ送ります。
  """
  # 依頼文の例。**話題が書いていればそちら**（`Tazuna.Topics` の `theme_examples`）——
  # 一般ニュースの網に「AI」「インフラ」を例に出すと、分野がそちらへ引っ張られる
  defp field_examples(topic) do
    topic
    |> theme_examples(:fields, ["AI", "セキュリティ", "インフラ"])
    |> Enum.map_join("、", &(@field_prefix <> &1))
  end

  defp parent_example(topic) do
    {child, parent} = theme_examples(topic, :parent, {"AIエージェント", "AI"})
    "「#{child}」の親は「#{parent}」"
  end

  defp theme_examples(topic, key, default),
    do: topic |> Map.get(:theme_examples, %{}) |> Map.get(key, default)

  def tidy_prompt(topic) do
    """
    {names}

    上は、いま持っている#{topic.name}のトピックです（**見出しとタグだけ**。本文は
    出していません —— 全部を載せると、育つほど入り切らなくなります）。
    **この回は記事を読みません** —— 語はもう機械が拾ってあります（記事に付いたタグが
    そのまま 1 件になっています）。**あなたの仕事は精査**です。

    **まだ手を入れていないものから始めてください。** 目印は「#{@field_prefix}」の付いて
    いないものです（機械は「#{@theme_tag}」しか付けません）。全部を見直す必要はありません
    —— 1 回で終わらなくても、次の回に続きから読めます。手元はこう引けます（読むだけ）。

        query(source: "#{"#{collection_name(topic)}"}",
              sql: "SELECT title FROM docs WHERE doc_id NOT IN
                      (SELECT doc_id FROM doc_tags WHERE tag LIKE '#{@field_prefix}%')")

    1 件ずつ、次のどれかにしてください。

    **1. 言い換えを畳む。** 既にある別のトピックと**同じものを指す語**（表記違い・
    略称・和英）は、1 つに畳んでください。残すほうに "#{@synonym_prefix}<畳んだ語>" を足し、
    消すほうは tags に "#{Chiezo.tombstone_tag()}" だけを入れて返します（墓標。以後
    どの画面にも出ません）。**body に、どちらへ畳んだのかを 1 行で書いてください**。
    **粒度が違うだけの語は畳まないでください** —— それは次の親子です。

    **2. 親子を決める。** より広い語が手元にあるなら "#{@parent_prefix}<広いほうの名前>" を
    1 つだけ付けてください（例: #{parent_example(topic)}）。**上に並んでいる
    名前だけ**を指してください —— 無い名前を指すと、図では線の先が空になります。

    **3. 話題でない語を外す。** 媒体や配信元の名前、種別、読む人の行動、
    何にでも当てはまる一般語（「技術」「開発」「ニュース」など）は、tags に
    "#{Chiezo.tombstone_tag()}" だけを入れて返してください。**外した語は二度と入りません**
    （同じ語が記事に付いても、もう拾われません）。

    **4. 迷ったら触らない。** 知らない語・新しすぎて判断できない語は**返さないで
    ください**。次の回にもう一度見られます —— **間違って外すより、1 回見送るほうが
    ずっと安いです**。

    残すものには、次を書いてください。

    - body: **2〜4 文**。**何を指す語か**と、**なぜ押さえるべきか**（読む人の判断が
      どう変わるか）。機械が入れた「この語が付いているのは N 件」の 1 行は、
      説明に書き換えてください（数は脇書きに残るので、本文で繰り返す必要はありません）。
      **本文は上に出していない**ので、いまの説明を読みたいときは `doc` で引けます
    - tags:
      - "#{@theme_tag}" は**そのまま残してください**（図に出す目印です）
      - "#{@field_prefix}<分野>" を 1 つ（例: #{field_examples(topic)}。
        **分野は増やしすぎないでください** —— 色が分かれすぎると図が読めません）
      - 親と言い換えは上のとおり

    **触らないものは返さないでください。** 返さなかったものはそのまま残ります。
    **新しい語をここで足さないでください** —— 語を拾うのは機械の回の仕事です。

    **道具が使えるなら、引いて確かめて構いません**（Chiezo の search / doc / filter /
    query。**読むだけ**）。畳むかどうかも外すかどうかも、その語が記事の中で実際に
    どう使われているかで決まります。
    """
  end

  @doc """
  いま溜まっているトピック。**図と一覧はこれだけを見ます**。
  """
  def list(base, topic) do
    name = collection_name(topic)

    query =
      URI.encode_query(%{
        "tag" => @theme_tag,
        # **脇書きまで取る** —— 件数も一緒に出てくる語もここに入っている
        "fields" => "title,tags,opening,extra",
        "limit" => @limit
      })

    case Chiezo.get(base <> "/v1/" <> name <> "/filter?" <> query) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"results" => results}} when is_list(results) ->
            {:ok, Enum.map(results, &to_theme/1)}

          _other ->
            {:error, :chiezo_unexpected_body}
        end

      # まだ 1 度も焼いていなければソースごと無い（失敗ではない）
      {:ok, %{status: 404}} ->
        {:ok, []}

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  @doc false
  def to_theme(%{"title" => title} = result) do
    tags = for tag <- result["tags"] || [], is_binary(tag), do: tag
    extra = if is_map(result["extra"]), do: result["extra"], else: %{}

    %{
      name: title,
      note: result["opening"] || "",
      parent: first_after(tags, @parent_prefix),
      field: first_after(tags, @field_prefix),
      # 数はすべて機械のもの（AI は書きません）
      docs: counted(extra["docs"]),
      recent: counted(extra["docs_recent"]),
      last_seen: to_string(extra["last_seen"] || ""),
      related: related_of(extra["links"]),
      tags: tags
    }
  end

  # 一緒に出てくる語（`語:回数`）。**語そのものに `:` が入りうる**ので、
  # 右端で割ります（「CodeZine:新着一覧」のような配信元の名前がそれです）
  defp related_of(links) when is_list(links) do
    for link <- links, is_binary(link), reduce: [] do
      acc ->
        case String.split(link, ":") do
          [_one] ->
            acc

          parts ->
            {name, [count]} = Enum.split(parts, length(parts) - 1)
            name = name |> Enum.join(":") |> String.trim()
            if name == "", do: acc, else: acc ++ [%{to: name, n: counted(count)}]
        end
    end
  end

  defp related_of(_links), do: []

  # 機械が入れた数。**読めなければ 0**（無い間は「静か」と同じ扱いでよい）
  defp counted(value) when is_integer(value), do: value

  defp counted(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> 0
    end
  end

  defp counted(_value), do: 0

  @doc """
  画面が見るもの。**収集の状態とトピックを 1 回で揃えます**。

  読めなかったところは空にします —— 片方が読めないだけで画面が開けなくなるほうが
  困ります（何が読めていないかは収集の状態に出ます）。
  """
  def read(base, topic) do
    collection =
      case Chiezo.collection(base, collection_name(topic), 0) do
        {:ok, found} -> found
        {:error, _reason} -> nil
      end

    themes =
      case list(base, topic) do
        {:ok, list} -> list
        {:error, _reason} -> []
      end

    %{collection: collection, themes: themes, checked_at: DateTime.utc_now()}
  end

  @doc """
  収集を用意します —— **無ければ作り、あれば設定を送り直します**。
  作られるのは止まった状態なので、これで AI が動き出すことはありません。
  """
  def setup(base, topic, choices \\ %{}) do
    attrs = attrs(topic, choices)

    with :ok <- Chiezo.request(base, attrs) do
      Chiezo.patch(base, attrs.name, attrs)
    end
  end

  @doc """
  予定を待たずに 1 回、語を拾い直させます。**AI は呼びません**（機械が数えるだけ）。

  **止まっている収集は Chiezo が断ります。**
  """
  def pick_now(base, topic) do
    Chiezo.run(base, collection_name(topic), sweep: @pick_sweep)
  end

  defp first_after(tags, prefix) do
    Enum.find_value(tags, fn tag ->
      if String.starts_with?(tag, prefix), do: String.trim_leading(tag, prefix)
    end)
  end
end
