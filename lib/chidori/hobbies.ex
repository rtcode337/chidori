defmodule Chidori.Hobbies do
  @moduledoc """
  頭のメニューの「趣味」に並べる、**よその画面のもの**（映画・アニメの話題と、芸術家の関連図）。

  画面と道はそれぞれの画面のまま（映画・アニメは `/news?view=…`。通知のリンクがこの形。
  芸術家は `/relations?view=painters`）で、趣味の段（`ChidoriWeb.DiningTabs.dataset_tabs/1`）の
  頭に並べ、開いているときは頭のメニューの「趣味」に印を付ける。元の画面のタブには出さない。
  """

  alias Chidori.Relations
  alias Chidori.Topics

  @doc """
  趣味の段の頭に並べるもの（並べる順）。`%{id:, name:, read:, collect:}`。
  `id` は開いているかを比べる鍵（話題は収集の名前、関連図は図の鍵）。
  """
  def entries do
    topics =
      for topic <- Topics.hobbies() do
        %{
          id: topic.collection,
          name: topic.name,
          read: "/news?view=#{topic.collection}",
          collect: "/collect/news?view=#{topic.collection}"
        }
      end

    relations =
      for key <- Relations.hobby_views() do
        %{
          id: key,
          name: Relations.title_of(key),
          read: "/relations?view=#{key}",
          collect: "/collect/relations?view=#{key}"
        }
      end

    topics ++ relations
  end
end
