defmodule Tazuna.Themes do
  @moduledoc """
  トピック（話題の語と、そのつながり）を溜めるところ。

  **育てるのは Chiezo です。** 材料は**Chiezo に溜まった記事そのもの**で、AI は
  前回から入った記事（`{material}`）といま持っているトピック（`{current}`）を読んで、
  網を少しずつ育てます —— tazuna は**指示文を渡して、できたものを読む**だけです。
  数えたり、材料を作って渡したりはしません。

  **材料は配信元（RSS）ではなく、溜まった収集のほうです。** 配信元から引くと、
  整理の回が落とした宣伝や重複、付け直した重要度が効かないまま材料になります ——
  トピックは「読むに値すると判じたもの」から育てたい。

  **画面のタブ（話題）とは別のものです。** `Tazuna.Topics` は「技術ニュース」
  「ニュース」のような画面のタブで、こちらは記事から育つ語（AIエージェント、
  セキュリティ…）です。名前が紛らわしいので、コードの側では分けてあります。

  **溜め先は記事とは別の収集（網羅）にします。** 記事と同じ収集に置くと、流れの
  期限（30 日）でトピックまで消えます —— トピックは、増減はしても古いものが
  要らなくなるものではありません。

  **図の語彙はここが持ちます**（関連図の画家と同じ形）。図を読むのは tazuna なので、
  読む側と書かせる側が離れると静かにズレます。

  - `#{"トピック"}` —— 図に出す目印
  - `#{"親:"}<名前>` —— 上位のトピック（1 つ）
  - `#{"関連:"}<名前>:<一言>` —— つながり。線と、線の上の説明になる
  - `#{"分野:"}<名前>` —— 色分け
  """

  alias Tazuna.Chiezo

  @theme_tag "トピック"
  @parent_prefix "親:"
  @related_prefix "関連:"
  @field_prefix "分野:"

  # 読み込む上限。図に出せる数はもっと少ないが、一覧と数えるぶんは全部読む
  @limit 200

  # 育てる回と、整える回。**分けるのは仕事が違うから** —— 足すのは流れてきた記事を
  # 読む回、畳むのは手元にあるものを読む回で、1 つの間隔では表せない
  @grow_minutes 360
  @tidy_minutes 1440

  # 1 回に読ませる記事の数。**多すぎると読み切れない**（そのぶん枠も食う）
  @material_limit 60

  @doc "その話題のトピックを溜める収集の名前。**話題ごとに分けます**。"
  def collection_name(%{collection: collection}), do: collection <> "_topics"
  def collection_name(collection) when is_binary(collection), do: collection <> "_topics"

  @doc "図に出す目印。"
  def theme_tag, do: @theme_tag

  @doc "上位のトピックを載せるタグの頭。"
  def parent_tag, do: @parent_prefix

  @doc "つながりを載せるタグの頭。線と、線の上の説明になります。"
  def related_tag, do: @related_prefix

  @doc "分野を載せるタグの頭。色はこれで決まります。"
  def field_tag, do: @field_prefix

  @doc """
  収集の依頼の中身。**網羅**で、期限では落としません。

  材料は話題の収集（記事のほう）です —— **AI が自分で読んで育てる**ので、
  tazuna が材料を作って渡す必要はありません。
  """
  def attrs(topic, choices \\ %{}) do
    %{
      name: collection_name(topic),
      description: "tazuna の「#{topic.name}」のトピック（記事から育つ話題の網）",
      prompt: grow_prompt(topic),
      interval_minutes: @grow_minutes,
      kind: "stock",
      material: material_spec(topic),
      sweeps: with_choices(sweeps(topic), choices),
      requested_by: "tazuna"
    }
  end

  @doc """
  材料に読むソース。**記事とまとめが混ざるので、種別のタグで絞ります**
  （まとめを材料にすると、AI がまとめの言い回しからトピックを作ります）。
  """
  def material_spec(topic) do
    %{source: topic.collection, tag: "ニュース,記事", limit: @material_limit}
  end

  @doc """
  巡回。**育てる回と整える回に分けます**。

  - 育てる —— 流れてきた記事を読んで、トピックを足す・いま何が動いているかを書き直す
  - 整える —— 手元にあるものだけを読んで、重なりを畳み、親子と分野を揃える

  1 本にまとめると、どちらも薄い仕事になります（足すたびに全部を読み直すか、
  畳むために毎回記事を読むかのどちらかになる）。
  """
  def sweeps(topic) do
    [
      %{name: "育てる", interval_minutes: @grow_minutes, prompt: grow_prompt(topic)},
      %{name: "整える", interval_minutes: @tidy_minutes, prompt: tidy_prompt(topic)}
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
  育てる回の依頼文。**素材は Chiezo が差し込みます**（`{material}` と `{current}`）。
  """
  def grow_prompt(topic) do
    """
    {material}

    上は、#{topic.name}の収集に前回から入った記事です。

    {current}

    上は、いま持っているトピックです。

    素材を読んで、**#{topic.name}のトピックの網を育ててください**。トピックとは、
    記事をまたいで何度も出てくる話題の語です（「AIエージェント」「耐量子暗号」
    「観測可能性」のような、**読む人が追いかける単位**）。

    この回ですることは 2 つです。

    - **動き始めた話題を足す**（1 回に 5 件まで）
    - **既にあるトピックを書き直す**（1 回に 10 件まで）。いま何が動いているかを
      新しくし、つながりを足す

    **触らないものは返さないでください。** 返さなかったものはそのまま残ります。

    1 件ごとに次の形で返してください。

    - title: トピックの名前。**短い語**にしてください（固有名詞はそのまま。
      文や説明にしないでください —— これが図の丸に乗る文字です）
    - body: 2〜4 文。**何を指す語か**と、**いま何が動いているか**、
      **なぜ押さえるべきか**（読む人の判断がどう変わるか）
    - url: いちばん代表的な記事（無ければ空）
    - tags:
      - "#{@theme_tag}" を**必ず** 1 つ
      - "#{@field_prefix}<分野>" を 1 つ（例: #{@field_prefix}AI、#{@field_prefix}セキュリティ、
        #{@field_prefix}インフラ。**分野は増やしすぎないでください** —— 色が分かれすぎると図が読めません）
      - "#{@parent_prefix}<上位のトピック名>" を 1 つまで（**より広い語があるときだけ**）
      - "#{@related_prefix}<相手のトピック名>:<つながりを一言で>" を 1〜4 個。
        **相手は上に並んでいるか、この回で足すトピックの名前**にしてください ——
        無い名前を指すと、図では線の先が空になります
      - 言い換えがあれば "#{"同義:"}<語>"（図には出しませんが、同じ話題が
        2 つの名前で増えるのを防ぎます）

    **素材に出てこない話題を足さないでください。** 思いついた語を並べると、
    記事に出てこないトピックが図に増えます。

    **一般語を足さないでください**（「開発」「技術」「ニュース」のような、
    何にでも当てはまる語）。配信元の名前もトピックではありません。

    **道具が使えるなら、自分で引いて確かめて構いません**（Chiezo の search / doc /
    filter / query。**読むだけで、書き込みはできません**）。使いどころは
    「この語がこれまでどう出てきたか」「同じ話題が別の名前で入っていないか」の確認です
    —— **材料に出てこない話題を足すためではありません**。

    **つながりは数えられます。** `query` に SQL を渡すと、同じ記事に一緒に付いたタグを
    数えられます（`doc_tags` を自分自身と結ぶ）—— 一緒に出ている回数が多い組は、
    たいてい実際に関係のある話題です。思いつきで線を引くより、こちらを当たってください。
    """
  end

  @doc """
  整える回の依頼文。**手元にあるものだけを読みます**（記事は読みません）。
  """
  def tidy_prompt(topic) do
    """
    {current}

    上は、いま持っている#{topic.name}のトピックです。**この回は記事を読みません** ——
    手元にあるものを整えるだけの回です。

    次のものを直してください。

    - **同じ話題が 2 つの名前で入っているもの**は 1 つに畳んでください。残すほうの
      title に "#{"同義:"}<消すほうの名前>" を足し、消すほうは tags に
      "#{Chiezo.tombstone_tag()}" だけを入れて返してください（墓標。以後どの画面にも出ません）。
      **body に、なぜ畳むのかを 1 行で書いてください**
    - **つながりの先が無いもの**（"#{@related_prefix}" が、存在しないトピックを指している）は、
      正しい名前に直すか、そのタグを外してください —— 図では線の先が空になります
    - **上位と下位が入れ替わっているもの**（広い語に "#{@parent_prefix}狭い語" が付いている）を直す
    - **説明が古くなったもの**を書き直す（いま何が動いているか）
    - **一般語や配信元の名前**が混ざっていたら、墓標にしてください

    **触らないものは返さないでください。** 返さなかったものはそのまま残ります。
    **新しい話題をここで足さないでください**（足すのは記事を読む回の仕事です）。

    タグの書き方は育てる回と同じです（"#{@theme_tag}" / "#{@field_prefix}…" /
    "#{@parent_prefix}…" / "#{@related_prefix}…:…"）。

    **道具が使えるなら、引いて確かめて構いません**（Chiezo の search / doc / filter。
    **読むだけ**）。畳むかどうかの判断は、その語が実際にどう使われているかで決まります。
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
        "fields" => "title,tags,opening",
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

    %{
      name: title,
      note: result["opening"] || "",
      parent: first_after(tags, @parent_prefix),
      field: first_after(tags, @field_prefix),
      related: related_of(tags),
      tags: tags
    }
  end

  # 「関連:<相手>:<一言>」。**一言は線の上に出す**ので、無くても線は引く
  defp related_of(tags) do
    for tag <- tags, String.starts_with?(tag, @related_prefix) do
      case tag |> String.trim_leading(@related_prefix) |> String.split(":", parts: 2) do
        [to, note] -> %{to: String.trim(to), note: String.trim(note)}
        [to] -> %{to: String.trim(to), note: ""}
      end
    end
    |> Enum.reject(&(&1.to == ""))
  end

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
  予定を待たずに 1 回育てさせます。**止まっている収集は Chiezo が断ります**。
  """
  def grow_now(base, topic) do
    Chiezo.run(base, collection_name(topic), sweep: "育てる")
  end

  defp first_after(tags, prefix) do
    Enum.find_value(tags, fn tag ->
      if String.starts_with?(tag, prefix), do: String.trim_leading(tag, prefix)
    end)
  end
end
