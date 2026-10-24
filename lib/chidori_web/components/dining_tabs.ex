defmodule ChidoriWeb.DiningTabs do
  @moduledoc """
  データ収集のタブ（上の段。`dataset_tabs/1`）と、食事処の中のタブ（「全体」と、作った範囲ごと。
  下の段。`dining_tabs/1`）。

  **範囲ごとのタブはデータ収集のタブとは別の段にする** —— 同じ段に並べると、範囲を
  足すたびにタブが伸びて、技術書や Pi-hole のタブが押し出される。かといってタブを
  置かずに「作った範囲」の一覧から開く形では、範囲を移るたびに一覧へ戻ることになった。

  「全体」は範囲の一覧・地図・全範囲の ZIP の画面（`ChidoriWeb.DiningAreasLive`）、
  範囲のタブはその範囲の収集の画面（`ChidoriWeb.DatasetsLive` の `view`）を開く。
  **下の段は閲覧の中の枠と同じ四角い札**（`home-subtabs`）—— 上下の段が両方タブの形だと、
  どちらが上の階層なのか読み取れない（閲覧の大きなタブと中の枠と同じ理由）。

  **食事処の段は収集の画面の「他アプリ用」にだけある**（食事処は Chidori で一覧にしない。読むのは travel-log）。
  上の段は `mode` で並べるものを変える —— 読む画面（`:read`。`/datasets`）と収集の画面のデータ収集
  （`:collect`。`/collect/datasets`）は Chidori で読む対象だけ（`Datasets.listed?/1`）、他アプリ用
  （`:apps`。`/collect/apps`）は他のアプリが読む対象と食事処（`Datasets.for_other_app?/1`）。
  """

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: ChidoriWeb.Endpoint,
    router: ChidoriWeb.Router,
    statics: ChidoriWeb.static_paths()

  # データ収集の定義の一覧（`Chidori.Datasets.list/0`）。範囲のものだけを並べる
  attr :datasets, :list, required: true
  # いま開いている範囲の定義の key。nil なら「全体」
  attr :current, :string, default: nil

  def dining_tabs(assigns) do
    assigns = assign(assigns, areas: Enum.filter(assigns.datasets, & &1[:area]))

    ~H"""
    <nav
      id="dining-tabs"
      class="home-subtabs dining-tabs"
      phx-hook="ScrollTabs"
      aria-label="食事処の範囲"
    >
      <.link
        navigate={~p"/collect/apps/areas"}
        class={if @current == nil, do: "selected"}
        aria-current={if @current == nil, do: "page"}
      >
        全体
      </.link>
      <.link
        :for={area <- @areas}
        navigate={~p"/collect/apps?view=#{area.key}"}
        class={if @current == area.key, do: "selected"}
        aria-current={if @current == area.key, do: "page"}
      >
        {area.name}
      </.link>
    </nav>
    """
  end

  # データ収集の対象の一覧（`Chidori.Datasets.list/0`）
  attr :datasets, :list, required: true

  # 開いている対象の key（範囲の食事処を開いているときも、その範囲の key）
  attr :current, :string, default: nil

  # 食事処の「全体」の画面にいるか（その画面ではタブの行き先と選んだ印が変わる）
  attr :on_areas, :boolean, default: false

  # どの画面の段か（`:read` = 読む画面 / `:collect` = 収集の画面の趣味 / `:apps` = 他アプリ用）
  attr :mode, :atom, default: :read

  # 最新情報の画面（`NewsLive`）から出しているか。映画・アニメは話題なので、その画面から
  # 趣味の段を出す —— そのときデータの対象へは別の LiveView へ移る（patch できない）
  attr :in_news, :boolean, default: false

  @doc """
  データ収集のタブ（上の段）。並びは `Chidori.Datasets.tabs/1`。食事処は範囲がいくつあっても
  1 つのタブで、範囲を開いているときも「全体」の画面にいるときも、このタブを選んだ印で出す。
  **データ収集の画面と食事処の「全体」の画面の 2 か所で同じものを出す**（別々に書いていた頃は、
  並びを変えるのに 2 か所を直すことになった）。
  """
  def dataset_tabs(assigns) do
    tabs = Chidori.Datasets.tabs(assigns.datasets)

    assigns =
      assign(assigns,
        tabs:
          if(assigns.mode == :apps,
            do: Enum.filter(tabs, &(&1 == :dining or Chidori.Datasets.for_other_app?(&1))),
            else: Enum.filter(tabs, &(&1 != :dining and in_mode?(&1, assigns.mode)))
          ),
        # **趣味の段の頭に映画・アニメ**（話題なので画面は最新情報のもの。`Topics.hobby?/1`）
        hobbies: if(assigns.mode == :apps, do: [], else: Chidori.Topics.hobbies()),
        news_base: if(assigns.mode == :collect, do: "/collect/news", else: "/news"),
        base:
          case assigns.mode do
            :read -> "/datasets"
            :collect -> "/collect/datasets"
            :apps -> "/collect/apps"
          end,
        dining?:
          assigns.on_areas or
            Enum.any?(assigns.datasets, &(&1[:area] && &1.key == assigns.current))
      )

    ~H"""
    <nav id="dataset-tabs" class="relation-tabs" phx-hook="ScrollTabs" aria-label="集めるもの">
      <.link
        :for={topic <- @hobbies}
        navigate={"#{@news_base}?view=#{topic.collection}"}
        class={if @current == topic.collection, do: "selected"}
        aria-current={if @current == topic.collection, do: "page"}
      >
        {topic.name}
      </.link>
      <%= for tab <- @tabs do %>
        <%= if tab == :dining do %>
          <.link
            :if={@on_areas}
            patch={~p"/collect/apps/areas"}
            class="selected"
            aria-current="page"
          >
            食事処
          </.link>
          <.link
            :if={!@on_areas}
            navigate={~p"/collect/apps/areas"}
            class={if @dining?, do: "selected"}
            aria-current={if @dining?, do: "page"}
          >
            食事処
          </.link>
        <% else %>
          <.link :if={@on_areas or @in_news} navigate={"#{@base}?view=#{tab.key}"}>
            {tab.name}
          </.link>
          <.link
            :if={!@on_areas and !@in_news}
            patch={"#{@base}?view=#{tab.key}"}
            class={if @current == tab.key, do: "selected"}
            aria-current={if @current == tab.key, do: "page"}
          >
            {tab.name}
          </.link>
        <% end %>
      <% end %>
    </nav>
    """
  end

  # 読む画面には読む画面で読む対象だけ（本棚はトップページ）、データ収集の収集の画面には
  # Chidori で読む対象を全部（本棚の収集もここ）
  defp in_mode?(dataset, :read), do: Chidori.Datasets.read_on_datasets?(dataset)
  defp in_mode?(dataset, _mode), do: Chidori.Datasets.listed?(dataset)
end
