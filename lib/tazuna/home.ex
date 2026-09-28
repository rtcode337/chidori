defmodule Tazuna.Home do
  @moduledoc """
  トップページ。**設定ページで選んだ枠を、選んだ順にタブで並べます**
  （最初の枠が開いたときに出る）。

  並べられる枠は 3 種類です。

  - 話題の要約（`topic:<収集>`）—— 最新情報の話題のうち、要約を作るもの
  - これからの注目イベント（`events:<収集>`）—— 要約を作らず、開催日のカレンダーを
    持つ話題（技術イベント）。注目度が中以上で、これから 2 か月のもの
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
      for topic <- Topics.list(), Topics.digest?(topic) or Topics.calendar?(topic) do
        # **要約を作る話題は要約、作らずにカレンダーを持つ話題は注目イベント**
        if Topics.digest?(topic),
          do: %{key: "topic:" <> topic.collection, name: topic.name, kind: :topic, topic: topic},
          else: %{
            key: "events:" <> topic.collection,
            name: topic.name,
            kind: :events,
            topic: topic
          }
      end

    relations =
      for {key, name} <- Tazuna.Relations.views() do
        %{key: "relations:" <> key, name: "関連図（#{name}）", kind: :relations, view: key}
      end

    topics ++ relations ++ [%{key: "books", name: "技術書", kind: :books}]
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
