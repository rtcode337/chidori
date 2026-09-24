defmodule Tazuna.Datasets.Bookshelf do
  @moduledoc """
  **定番の技術書**。記事の収集（`Tazuna.Datasets.Books`）に付いた
  「本:<書名>」のタグから、**機械で**作ります。

  **数えるのは機械です。** その本のタグが付いている記事の数が、そのまま
  「何本の記事が勧めているか」になります —— AI に数えさせていた頃は、
  **その回の検索運で数が動きました**（同じ本が次の回では見つからない）。

  **AI がやるのは整えるところだけ**です。言い換えを畳む（「リーダブルコード」と
  「Readable Code」）、分野を付ける、技術書でない語を外す、一言で説明する ——
  どれも数では決まりません。**トピックの網とまったく同じ形**です。

  **定番と候補は数で分けます**（#{3} 本以上で定番）。1 人が絶賛した本と、
  何十本の記事が挙げてきた本は別物で、そこが「技術者なら読んでいる」の境目です。
  """

  alias Tazuna.Chiezo
  alias Tazuna.Datasets.Books

  @collection "tazuna_books"

  # 1 冊ごとに必ず付く印
  @kind_tag "技術書"

  # 分野のタグの頭
  @field_tag "分野"

  # 定番と候補の印
  @classic_tag "定番"
  @candidate_tag "候補"

  # 定番に上げる下限（勧めている記事の数）。**3 は「たまたま」を外せる数**
  @classic_sources 3

  # 名簿に載せる下限。**1 本の記事にしか出てこない本は、まだ本棚に置かない**
  # （記事が増えれば上がってくる）
  @min_docs 2

  # 直近として数える日数（画面で「いま挙げられている本」を見るため）
  @recent_days 180

  # 一緒に挙げられている本を、1 冊あたり何冊まで持つか
  @link_count 6

  # 名簿の上限
  @tag_limit 400

  # 拾う回（機械）と整える回（AI）の間隔
  @pick_minutes 360
  @tidy_minutes 1440

  @doc "1 冊ごとに必ず付く印。"
  def kind_tag, do: @kind_tag

  @doc "分野のタグの頭。"
  def field_tag, do: @field_tag

  @doc "定番の印。"
  def classic_tag, do: @classic_tag

  @doc "候補の印。"
  def candidate_tag, do: @candidate_tag

  @doc "定番に上げる下限（勧めている記事の数）。"
  def classic_sources, do: @classic_sources

  @doc "分野の語彙。**tazuna が持ちます** —— AI に決めさせると回ごとに表記が割れます。"
  def fields_of_study do
    [
      "プログラミング言語",
      "設計・アーキテクチャ",
      "アルゴリズムとデータ構造",
      "OS・低レイヤ",
      "ネットワーク",
      "データベース",
      "分散システム",
      "セキュリティ",
      "テスト・品質",
      "開発プロセス・チーム",
      "機械学習・AI",
      "インフラ・運用",
      "フロントエンド",
      "数学・理論",
      "キャリア・働き方"
    ]
  end

  @doc "溜め先の収集の名前。**後から変えない**。"
  def collection do
    case System.get_env("TAZUNA_BOOKS_COLLECTION", "") |> String.trim() do
      "" -> @collection
      name -> name
    end
  end

  @doc "画面に出す名前（親の収集の下に並べます）。"
  def name, do: "本棚（定番の技術書）"

  @doc """
  語を拾ってくる指定。**記事のタグのうち「本:」で始まるものだけ**を名簿にします。

  **外す側で書いているのは、いまの Chiezo にそういう口しか無いから**です
  （先頭で選ぶ指定はありません）。`^(?!本:)` は「本: で始まらないものを外す」
  という意味で、記事の種別も配信元の名前もこれで落ちます。
  """
  def extract_spec do
    %{
      source: Books.collection(),
      of: "tags",
      skip: ["^(?!#{Books.book_tag()}:)"],
      min_docs: @min_docs,
      recent_days: @recent_days,
      links: @link_count,
      limit: @tag_limit,
      tags: [%{const: @kind_tag}]
    }
  end

  @doc """
  巡回 2 本。**拾う回は AI を呼びません**（機械がタグを数えるだけ）。
  """
  def sweeps do
    [
      %{name: "拾う", interval_minutes: @pick_minutes, use_extract: true, only_new: true},
      %{name: "整える", interval_minutes: @tidy_minutes, prompt: :tidy}
    ]
  end

  @doc """
  整える回の依頼文。**数には触らせません**（数えるのは機械の仕事）。
  """
  def tidy_prompt do
    """
    技術書の本棚を整えます。**1 冊 1 文書**で、見出しは書名です。

    {current}

    **数は機械が数えています**（その本を挙げている記事の本数）。
    **数を書き換えないでください** —— あなたの仕事は、**読めるようにする**ことです。

    **やってほしいことは 4 つ**です。

    **1. 言い換えを 1 つに畳む。** 「リーダブルコード」と「Readable Code」、
    副題の有無、版違いは同じ本です。**残すのは邦題のあるほう**で、
    消すほうには墓標を付けてください（tags に "#{Chiezo.tombstone_tag()}" を入れ、
    body に「◯◯と同じ本」と 1 行）。

    **2. 技術書でない語を外す。** 「入門書」「名著」のような**本の名前でないもの**、
    雑誌、資格の問題集は本棚に置きません（同じく墓標で）。

    **3. 分野を付ける。** 「#{@field_tag}:<分野>」を 1〜2 個。
    **下の語彙から選んでください**（新しい語は作らない）。
    #{Enum.map_join(fields_of_study(), " / ", & &1)}

    **4. 一言で説明する。** body に 2〜3 行 —— **何の本で、どういう人が読むと効くか**。
    「名著です」ではなく、**読むかどうかを決められること**を書いてください。
    原書名・著者・出た年が分かれば 1 行足してください。

    **印は数で決まります**（あなたは書かなくて構いません）——
    「#{@classic_tag}」は #{@classic_sources} 本以上の記事が挙げている本、
    「#{@candidate_tag}」はそれ未満です。

    **迷ったものは触らないでください。** 間違って畳んだ本は、記事の側から
    もう一度上がってくるまで戻りません。

    **触ったものだけ返してください。** 触れなかったものはそのまま残ります。
    """
  end

  @doc "Chiezo へ送る収集の設定ぜんぶ。"
  def attrs(choices \\ %{}) do
    %{
      name: collection(),
      description: "tazuna のデータ収集（定番の技術書。記事のタグから作る本棚）",
      prompt: tidy_prompt(),
      interval_minutes: @tidy_minutes,
      kind: "stock",
      extract: extract_spec(),
      sweeps: with_choices(sweeps(), choices),
      requested_by: "tazuna"
    }
  end

  @doc """
  収集を用意します —— **無ければ作り、あれば設定を送り直します**
  （トピックの網と同じ形）。
  """
  def setup(base, choices \\ %{}) do
    attrs = attrs(choices)

    with :ok <- Chiezo.request(base, attrs) do
      Chiezo.patch(base, attrs.name, attrs)
    end
  end

  defp with_choices(sweeps, choices) do
    for sweep <- Enum.map(sweeps, &resolve_prompt/1) do
      case Map.get(choices, sweep.name) do
        nil -> sweep
        picked -> Map.merge(sweep, Map.reject(picked, fn {_k, v} -> is_nil(v) end))
      end
    end
  end

  defp resolve_prompt(%{prompt: :tidy} = sweep), do: %{sweep | prompt: tidy_prompt()}
  defp resolve_prompt(sweep), do: sweep
end
