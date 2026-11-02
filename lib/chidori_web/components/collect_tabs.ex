defmodule ChidoriWeb.CollectTabs do
  @moduledoc """
  収集の画面の頭の段（流れ・網羅・他アプリ用・写真と表紙）と、その下の収集の段（`kind_tabs/1`）。
  **頭のメニューの「収集」から直接たどれるように**。

  **段は Chiezo の収集の種類で分ける**（流れ = 古いものを捨てていく話題、網羅 = 全部を育てる図と
  データ）。読む画面の分け方（ニュース・趣味）で分けていた頃は、映画の最新（流れ）と映画の目録
  （網羅）が同じ段に並び、巡回の組み方も頼む相手の選び方も違う収集が混ざって読めなかった。
  画面はそれぞれのまま（話題は `/collect/news`・`/collect/events`、図は `/collect/relations`、
  データは `/collect/datasets`）で、段だけを種類で組む。

  収集の一覧（巡回の間隔・相手・前回・次回の表）は設定の「収集の一覧」（`/settings?tab=chiezo`）。
  """

  use Phoenix.Component

  alias Chidori.Datasets
  alias Chidori.Relations
  alias Chidori.Topics

  @tabs [
    {:flow, "流れ", "/collect/news"},
    {:stock, "網羅", "/collect/relations?view=painters"},
    # 他のアプリ（travel-log）が読む収集。Chidori のデータ収集と並べると、どちらで読むものか分からない
    {:apps, "他アプリ用", "/collect/apps"},
    # 顔写真・レシピの写真・技術書の表紙を Chiezo に頼む列の様子（もとは設定ページのタブ）
    {:photos, "写真と表紙", "/collect/photos"}
  ]

  # 網羅の段に出す図の短い名前（図の見出しは長いので）
  @relation_names %{"films" => "映画の目録", "people" => "芸能人", "painters" => "芸術家"}

  # いま開いている段（`:flow` / `:stock` / `:apps` / `:photos`）
  attr :current, :atom, required: true

  def collect_tabs(assigns) do
    assigns = assign(assigns, tabs: @tabs)

    ~H"""
    <nav
      id="collect-tabs"
      class="relation-tabs collect-tabs"
      phx-hook="ScrollTabs"
      aria-label="収集の画面"
    >
      <.link
        :for={{key, label, href} <- @tabs}
        navigate={href}
        class={if @current == key, do: "selected"}
        aria-current={if @current == key, do: "page"}
      >
        {label}
      </.link>
    </nav>
    """
  end

  @doc """
  流れ・網羅の段に並べる収集（並べる順）。`[{id, 名前, 道}]`。`id` は開いているかを比べる鍵
  （話題は収集の名前、図とデータは画面の `view`）。
  """
  def entries(:flow) do
    # 並びは読む画面のニュースのタブ（ニュース・イベント）のあとに、趣味の話題（映画）
    for topic <- Topics.news_tabs() ++ Topics.hobbies() do
      base = if Topics.event?(topic), do: "/collect/events", else: "/collect/news"
      {topic.collection, topic.name, "#{base}?view=#{topic.collection}"}
    end
  end

  def entries(:stock) do
    relations =
      for {key, title} <- Relations.views(),
          do: {key, @relation_names[key] || title, "/collect/relations?view=#{key}"}

    datasets =
      for dataset <- Datasets.tabs(Datasets.list()),
          is_map(dataset),
          not Datasets.for_other_app?(dataset),
          do: {dataset.key, dataset.name, "/collect/datasets?view=#{dataset.key}"}

    relations ++ datasets
  end

  # 流れか網羅か
  attr :kind, :atom, required: true

  # 開いている収集（話題は収集の名前、図とデータは `view`）
  attr :current, :string, default: nil

  @doc "流れ・網羅の段の下の、収集ごとのタブ。**画面をまたぐので navigate で移る**。"
  def kind_tabs(assigns) do
    assigns = assign(assigns, entries: entries(assigns.kind))

    ~H"""
    <nav
      id="collect-kind-tabs"
      class="relation-tabs"
      phx-hook="ScrollTabs"
      aria-label={if @kind == :flow, do: "流れの収集", else: "網羅の収集"}
    >
      <.link
        :for={{id, label, href} <- @entries}
        navigate={href}
        class={if @current == id, do: "selected"}
        aria-current={if @current == id, do: "page"}
      >
        {label}
      </.link>
    </nav>
    """
  end
end
