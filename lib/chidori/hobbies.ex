defmodule Chidori.Hobbies do
  @moduledoc """
  頭のメニューの「趣味」に並べる、**よその画面のもの**（映画・アニメの話題と、芸術家の関連図）。

  画面と道はそれぞれの画面のまま（映画・アニメは `/news?view=…`。通知のリンクがこの形。
  芸術家は `/relations?view=painters`）で、趣味の段（`ChidoriWeb.DiningTabs.dataset_tabs/1`）の
  頭に並べ、開いているときは頭のメニューの「趣味」に印を付ける。元の画面のタブには出さない。
  """

  alias Chidori.Relations
  alias Chidori.Topics

  # 段の頭ではなく、データの対象の後ろに置くもの（`id` → その後ろに置く対象の key）
  @follows %{"chidori_anime" => "recipes"}

  @doc """
  趣味の段に並べるもの（並べる順）。`%{id:, name:, read:, collect:, follows:}`。
  `id` は開いているかを比べる鍵（話題は収集の名前、関連図は図の鍵）。`follows` が nil なら
  段の頭、データの対象の key ならその後ろ（`arrange/2`）。
  """
  def entries do
    topics =
      for topic <- Topics.hobbies() do
        %{
          id: topic.collection,
          name: topic.name,
          read: "/news?view=#{topic.collection}",
          collect: "/collect/news?view=#{topic.collection}",
          follows: @follows[topic.collection]
        }
      end

    relations =
      for key <- Relations.hobby_views() do
        %{
          id: key,
          name: Relations.title_of(key),
          read: "/relations?view=#{key}",
          collect: "/collect/relations?view=#{key}",
          follows: @follows[key]
        }
      end

    topics ++ relations
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
