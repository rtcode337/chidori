defmodule Chidori.Hobbies do
  @moduledoc """
  頭のメニューの「趣味」に並べる、**よその画面のもの**（映画・アニメの話題と、芸術家・芸能人の関連図）。

  画面と道はそれぞれの画面のまま（映画・アニメは `/news?view=…`。通知のリンクがこの形。
  芸術家・芸能人は `/relations?view=…`）で、趣味の段（`ChidoriWeb.DiningTabs.dataset_tabs/1`）に
  並べ、開いているときは頭のメニューの「趣味」に印を付ける。元の画面のタブには出さない。

  **映画の関連図は映画のタブの中**に置く（`movie_tabs/0`。最新と関連図を四角い札で切り替える）。
  映画を見に来た人が、最新の作品とつながりの図を行き来できるように。
  """

  alias Chidori.Relations
  alias Chidori.Topics

  # 段の頭ではなく、データの対象の後ろに置くもの（`id` → その後ろに置く対象の key）
  @follows %{"people" => "recipes", "chidori_anime" => "recipes"}

  # 並べる順（同じ場所に置くものどうしの順もこれで決まる）
  @order ["chidori_movies", "painters", "people", "chidori_anime"]

  # 段に出す短い名前（図の見出しは長いので）
  @names %{"people" => "芸能人"}

  # そのタブの中に置く、ほかの画面のもの（開いているとき、そのタブに印を付ける）
  @inside %{"chidori_movies" => ["films"]}

  @doc """
  趣味の段に並べるもの（並べる順）。`%{id:, name:, read:, collect:, follows:, inside:}`。
  `id` は開いているかを比べる鍵（話題は収集の名前、関連図は図の鍵）。`follows` が nil なら
  段の頭、データの対象の key ならその後ろ（`arrange/2`）。`inside` はそのタブの中に置く
  ほかの画面の鍵（映画のタブの中の映画の関連図）。
  """
  def entries do
    topics =
      for topic <- Topics.hobbies() do
        entry(
          topic.collection,
          topic.name,
          "/news?view=#{topic.collection}",
          "/collect/news?view=#{topic.collection}"
        )
      end

    inside = @inside |> Map.values() |> List.flatten()

    relations =
      for key <- Relations.hobby_views(), key not in inside do
        entry(
          key,
          @names[key] || Relations.title_of(key),
          "/relations?view=#{key}",
          "/collect/relations?view=#{key}"
        )
      end

    Enum.sort_by(topics ++ relations, fn entry ->
      Enum.find_index(@order, &(&1 == entry.id)) || 99
    end)
  end

  defp entry(id, name, read, collect) do
    %{
      id: id,
      name: name,
      read: read,
      collect: collect,
      follows: @follows[id],
      inside: Map.get(@inside, id, [])
    }
  end

  @doc "そのタブを開いているか（タブの中に置いたほかの画面を開いているときも）。"
  def current?(entry, current), do: current == entry.id or current in entry.inside

  @doc """
  映画のタブの中の切り替え（最新・関連図・映画館）。`[{鍵, 名前, 読む道, 収集の道}]`。
  収集の道が nil のものは読む画面にだけ出す（映画館は頼むものが無い）。
  """
  def movie_tabs do
    [
      {:latest, "最新", "/news?view=chidori_movies", "/collect/news?view=chidori_movies"},
      {:graph, "関連図", "/relations?view=films", "/collect/relations?view=films"},
      {:theaters, "映画館", "/news?view=chidori_movies&section=theaters", nil}
    ]
  end

  @doc """
  趣味の段の並び。`follows` を持たないものを頭に、持つものはその対象の後ろに差し込む
  （`{:hobby, entry}` と `{:tab, 対象}` の並び）。その対象が段に無ければ（読む画面に無い対象など）
  いちばん後ろに置く。
  """
  def arrange(hobbies, tabs) do
    {placed, rest} = Enum.split_with(hobbies, &is_nil(&1.follows))
    head = Enum.map(placed, &{:hobby, &1})

    {body, left} =
      Enum.flat_map_reduce(tabs, rest, fn tab, left ->
        key = if is_map(tab), do: tab.key
        {here, left} = Enum.split_with(left, &(&1.follows == key))
        {[{:tab, tab} | Enum.map(here, &{:hobby, &1})], left}
      end)

    head ++ body ++ Enum.map(left, &{:hobby, &1})
  end
end
