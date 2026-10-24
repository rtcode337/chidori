defmodule Chidori.Home do
  @moduledoc """
  トップページ。**枠を 4 つの大きなタブにまとめて並べます**（ニュース・イベント・関連図・データ収集）。
  大きなタブを押すと、その中の枠が下の段に並びます（ニュースなら 一般・興味・技術・技術興味・
  映画・アニメ・市況）。**並びは決めた順で、設定ページで選ぶのは出すかどうかだけ**です ——
  1 つずつ並べ替えさせていた頃は、話題が増えるたびに並びを考え直すことになり、
  同じ仲間の枠がばらばらの位置に散った。

  並べられる枠は次のとおりです。

  - 話題の要約（`topic:<収集>`）—— 最新情報の話題のうち、要約を作るもの。
    要約を別の収集から読む話題（市況ニュース）は、書き手ごとの要約を並べる
  - 興味トピックの要約（`interest:<収集>`）—— 同じ話題を、選んだ興味トピックに
    絞って書いたもの（トピックの網を育てる話題だけ。「技術興味ニュース」など）
  - これからの注目イベント（`events:<収集>`）—— 要約を作らず、開催日のカレンダーを
    持つ話題（技術イベント）。注目度が高いもの（話題によっては中も）で、これから 2 か月のもの
  - 関連図（`relations:<種類>`）—— 関連図の画面をそのまま埋め込む
  - 技術書（`books`）—— 本棚の未読の上位 10 冊（`ChidoriWeb.TopBooks`。オライリーの本は札の印で見分ける）と、
    その下に畳んだ本棚の全冊（`ChidoriWeb.BookshelfList`。本棚を読むのはここだけ）
  - レシピ（`recipes`）—— レシピ集を種類ごとに（`ChidoriWeb.RecipeBook`）
  - いま止めている通信（`pihole_live`。大きなタブ「ツール」）—— Pi-hole が止めた問い合わせをその場で流す（`ChidoriWeb.PiholeLive`）

  **何も選んでいなければ一般ニュースの要約だけ**（トップを開いて何も出ないより、
  いちばん読まれるものを出す）。
  """

  import Ecto.Query, only: [select: 3]

  alias Chidori.Home.Panel
  alias Chidori.Repo
  alias Chidori.Topics

  @default ["topic:" <> Chidori.News.collection_name()]

  # 大きなタブ（並べる順）
  @groups [news: "ニュース", events: "イベント", relations: "関連図", datasets: "趣味", tools: "ツール"]

  # 枠の並び（大きなタブの中の順）と、下の段に出す短い名前。**ここに無い枠は、
  # その大きなタブの後ろに元の名前で並ぶ**（話題を足したときに消えないように）
  @order [
    {"topic:chidori_news", "一般"},
    {"interest:chidori_news", "興味"},
    {"topic:chidori_tech", "技術"},
    {"interest:chidori_tech", "技術興味"},
    {"topic:chidori_movies", "映画"},
    {"topic:chidori_anime", "アニメ"},
    {"topic:chidori_market", "市況"},
    {"events:chidori_comedy", "お笑い"},
    {"events:chidori_events", "技術"},
    {"relations:painters", "芸術家"},
    {"relations:people", "芸能人"},
    {"relations:films", "映画"},
    {"books", "技術書"},
    {"recipes", "レシピ"},
    {"pihole_live", "止めている通信"}
  ]

  @doc "大きなタブ（`[{鍵, 名前}]`。並べる順）。"
  def groups, do: @groups

  @doc """
  選べる枠（並べる順）。`%{key:, name:, short:, group:, kind:}` の並び。
  `name` は設定ページに出す名前、`short` はトップの下の段に出す短い名前。
  """
  def catalog do
    topics =
      Enum.flat_map(Topics.list(), fn topic ->
        cond do
          # **要約を別の収集から読む話題は、書き手ごとの要約**（市況ニュース。
          # `Chidori.News.AiDigests`）。キーは要約を作る話題と同じ形にして、選んであった枠を生かす
          Topics.digest_from(topic) ->
            [
              %{
                key: "topic:" <> topic.collection,
                name: topic.name,
                kind: :ai_digests,
                group: :news,
                topic: topic
              }
            ]

          # **要約を作る話題は要約、作らずにカレンダーを持つ話題は注目イベント**
          Topics.digest?(topic) ->
            [
              %{
                key: "topic:" <> topic.collection,
                name: topic.name,
                kind: :topic,
                # 映画・アニメは「趣味」の大きなタブ（頭のメニューと同じ分け方）
                group: if(Topics.hobby?(topic), do: :datasets, else: :news),
                topic: topic
              }
            ] ++
              interest_panel(topic)

          Topics.calendar?(topic) ->
            [
              %{
                key: "events:" <> topic.collection,
                name: topic.name,
                kind: :events,
                group: :events,
                topic: topic
              }
            ]

          true ->
            []
        end
      end)

    relations =
      for {key, name} <- Chidori.Relations.views() do
        # 芸術家は「趣味」の大きなタブ（頭のメニューと同じ分け方）
        if Chidori.Relations.hobby?(key),
          do: %{
            key: "relations:" <> key,
            name: name,
            kind: :relations,
            group: :datasets,
            view: key
          },
          else: %{
            key: "relations:" <> key,
            name: "関連図（#{name}）",
            kind: :relations,
            group: :relations,
            view: key
          }
      end

    datasets = [
      %{key: "books", name: "技術書", kind: :books, group: :datasets},
      %{key: "recipes", name: "レシピ", kind: :recipes, group: :datasets}
    ]

    # **ツール**（溜めたものを読むのではなく、その場の様子を見る道具）
    tools = [
      %{
        key: "pihole_live",
        name: "いま止めている通信（Pi-hole）",
        kind: :pihole_live,
        group: :tools
      }
    ]

    (topics ++ relations ++ datasets ++ tools)
    |> Enum.map(&Map.put(&1, :short, short_name(&1)))
    |> sort()
  end

  defp short_name(%{key: key, name: name}) do
    case List.keyfind(@order, key, 0) do
      {_key, short} -> short
      nil -> name
    end
  end

  # 大きなタブの順、その中は `@order` の順（無いものは後ろに、元の並びのまま）
  defp sort(panels) do
    groups = Keyword.keys(@groups)
    ranks = @order |> Enum.with_index() |> Map.new(fn {{key, _short}, i} -> {key, i} end)

    panels
    |> Enum.with_index()
    |> Enum.sort_by(fn {panel, i} ->
      {Enum.find_index(groups, &(&1 == panel.group)), Map.get(ranks, panel.key, 1000 + i)}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "その大きなタブの名前。"
  def group_name(group), do: Keyword.fetch!(@groups, group)

  @doc """
  並べている枠を大きなタブごとにまとめます（`[{鍵, 名前, [枠]}]`。枠の無い大きなタブは出さない）。
  """
  def grouped(panels) do
    for {group, name} <- @groups,
        members = Enum.filter(panels, &(&1.group == group)),
        members != [],
        do: {group, name, members}
  end

  # 興味トピックの要約。**トピックの網を育てる話題だけ**（興味トピックは網の札から選ぶ）。
  # 元の話題のすぐ後ろに並べる
  defp interest_panel(topic) do
    if Topics.themes?(topic),
      do: [
        %{
          key: "interest:" <> topic.collection,
          name: interest_name(topic.name),
          kind: :interest,
          group: :news,
          topic: topic
        }
      ],
      else: []
  end

  @doc """
  興味トピックの要約の枠の名前。「技術ニュース」なら「技術興味ニュース」。
  「ニュース」で終わらない話題は後ろに「（興味）」を付ける。
  """
  def interest_name(name) do
    if String.ends_with?(name, "ニュース"),
      do: String.replace_suffix(name, "ニュース", "興味ニュース"),
      else: name <> "（興味）"
  end

  @doc "いま並べている枠（決めた順）。選んでいなければ既定。"
  def selected do
    keys = Panel |> select([p], p.key) |> Repo.all() |> MapSet.new()
    keys = if MapSet.size(keys) == 0, do: MapSet.new(@default), else: keys

    # **いまは無い枠は黙って落とす**（話題を消したあとも行が残っていることがある）
    case Enum.filter(catalog(), &MapSet.member?(keys, &1.key)) do
      [] -> Enum.filter(catalog(), &(&1.key in @default))
      panels -> panels
    end
  end

  @doc "選んだ枠のキー（設定ページのチェックに使う）。"
  def selected_keys, do: Enum.map(selected(), & &1.key)

  @doc """
  出す枠を置き換えます（**並びは決めた順で、渡した順は使わない**）。
  知らないキーは捨てます（画面から来る値なので、そのまま DB に入れない）。
  """
  def put(keys) when is_list(keys) do
    keys = MapSet.new(keys)
    picked = Enum.filter(catalog(), &MapSet.member?(keys, &1.key))

    Repo.transaction(fn ->
      Repo.delete_all(Panel)

      picked
      |> Enum.with_index()
      |> Enum.each(fn {panel, position} ->
        %Panel{} |> Panel.changeset(%{key: panel.key, position: position}) |> Repo.insert!()
      end)
    end)

    :ok
  end
end
