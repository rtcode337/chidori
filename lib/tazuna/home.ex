defmodule Tazuna.Home do
  @moduledoc """
  トップページ。**設定ページで選んだ枠を、選んだ順にタブで並べます**
  （最初の枠が開いたときに出る）。

  並べられる枠は次のとおりです。

  - 話題の要約（`topic:<収集>`）—— 最新情報の話題のうち、要約を作るもの。
    要約を別の収集から読む話題（市況ニュース）は、書き手ごとの要約を並べる
  - 興味トピックの要約（`interest:<収集>`）—— 同じ話題を、選んだ興味トピックに
    絞って書いたもの（トピックの網を育てる話題だけ。「技術興味ニュース」など）
  - これからの注目イベント（`events:<収集>`）—— 要約を作らず、開催日のカレンダーを
    持つ話題（技術イベント）。注目度が高いもの（話題によっては中も）で、これから 2 か月のもの
  - 関連図（`relations:<種類>`）—— 関連図の画面をそのまま埋め込む
  - 技術書（`books`）—— 本棚の上位の数冊

  **何も選んでいなければ一般ニュースの要約だけ**（トップを開いて何も出ないより、
  いちばん読まれるものを出す）。
  """

  import Ecto.Query

  alias Tazuna.Home.Panel
  alias Tazuna.Repo
  alias Tazuna.Topics

  @default ["topic:" <> Tazuna.News.collection_name()]

  @doc """
  選べる枠（並べられる順）。`%{key:, name:, kind:}` の並び。
  """
  def catalog do
    topics =
      Enum.flat_map(Topics.list(), fn topic ->
        cond do
          # **要約を別の収集から読む話題は、書き手ごとの要約**（市況ニュース。
          # `Tazuna.News.AiDigests`）。キーは要約を作る話題と同じ形にして、選んであった枠を生かす
          Topics.digest_from(topic) ->
            [
              %{
                key: "topic:" <> topic.collection,
                name: topic.name,
                kind: :ai_digests,
                topic: topic
              }
            ]

          # **要約を作る話題は要約、作らずにカレンダーを持つ話題は注目イベント**
          Topics.digest?(topic) ->
            [%{key: "topic:" <> topic.collection, name: topic.name, kind: :topic, topic: topic}] ++
              interest_panel(topic)

          Topics.calendar?(topic) ->
            [%{key: "events:" <> topic.collection, name: topic.name, kind: :events, topic: topic}]

          true ->
            []
        end
      end)

    relations =
      for {key, name} <- Tazuna.Relations.views() do
        %{key: "relations:" <> key, name: "関連図（#{name}）", kind: :relations, view: key}
      end

    topics ++ relations ++ [%{key: "books", name: "技術書", kind: :books}]
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

  @doc "いま並べている枠（選んだ順）。選んでいなければ既定。"
  def selected do
    keys =
      Panel
      |> order_by([p], asc: p.position, asc: p.id)
      |> select([p], p.key)
      |> Repo.all()

    by_key = Map.new(catalog(), &{&1.key, &1})

    # **いまは無い枠は黙って落とす**（話題を消したあとも行が残っていることがある）
    case keys |> Enum.map(&by_key[&1]) |> Enum.reject(&is_nil/1) do
      [] -> @default |> Enum.map(&by_key[&1]) |> Enum.reject(&is_nil/1)
      panels -> panels
    end
  end

  @doc "選んだ枠のキー（設定ページのチェックに使う）。"
  def selected_keys, do: Enum.map(selected(), & &1.key)

  @doc """
  並べる枠を置き換えます。**渡した順がそのまま並び**になります。
  知らないキーは捨てます（画面から来る値なので、そのまま DB に入れない）。
  """
  def put(keys) when is_list(keys) do
    known = MapSet.new(catalog(), & &1.key)
    keys = keys |> Enum.filter(&MapSet.member?(known, &1)) |> Enum.uniq()

    Repo.transaction(fn ->
      Repo.delete_all(Panel)

      keys
      |> Enum.with_index()
      |> Enum.each(fn {key, position} ->
        %Panel{} |> Panel.changeset(%{key: key, position: position}) |> Repo.insert!()
      end)
    end)

    :ok
  end
end
