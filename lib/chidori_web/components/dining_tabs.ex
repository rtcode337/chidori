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

  # よその画面（最新情報・関連図）から出しているか。映画・アニメ・芸術家はその画面のものなので、
  # そこから趣味の段を出す —— そのときデータの対象へは別の LiveView へ移る（patch できない）
  attr :elsewhere, :boolean, default: false

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
        # **趣味の段には映画・芸術家・アニメも並べる**（画面はそれぞれのもの。並びは
        # `Chidori.Hobbies.arrange/2`）
        hobbies: if(assigns.mode == :apps, do: [], else: Chidori.Hobbies.entries()),
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
      <%= for item <- Chidori.Hobbies.arrange(@hobbies, @tabs) do %>
        <%= case item do %>
          <% {:hobby, hobby} -> %>
            <.link
              navigate={if @mode == :collect, do: hobby.collect, else: hobby.read}
              class={if Chidori.Hobbies.current?(hobby, @current), do: "selected"}
              aria-current={if Chidori.Hobbies.current?(hobby, @current), do: "page"}
            >
              {hobby.name}
            </.link>
          <% {:tab, tab} -> %>
            <.dataset_tab
              tab={tab}
              on_areas={@on_areas}
              elsewhere={@elsewhere}
              base={@base}
              current={@current}
              dining?={@dining?}
            />
        <% end %>
      <% end %>
    </nav>
    """
  end

  attr :tab, :any, required: true
  attr :on_areas, :boolean, required: true
  attr :elsewhere, :boolean, required: true
  attr :base, :string, required: true
  attr :current, :string, default: nil
  attr :dining?, :boolean, required: true

  # データの対象 1 つぶんのタブ（食事処は範囲の「全体」へ）
  defp dataset_tab(assigns) do
    ~H"""
    <%= if @tab == :dining do %>
      <.link :if={@on_areas} patch={~p"/collect/apps/areas"} class="selected" aria-current="page">
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
      <.link :if={@on_areas or @elsewhere} navigate={"#{@base}?view=#{@tab.key}"}>
        {@tab.name}
      </.link>
      <.link
        :if={!@on_areas and !@elsewhere}
        patch={"#{@base}?view=#{@tab.key}"}
        class={if @current == @tab.key, do: "selected"}
        aria-current={if @current == @tab.key, do: "page"}
      >
        {@tab.name}
      </.link>
    <% end %>
    """
  end

  # 読む画面には読む画面で読む対象だけ（本棚はトップページ）、データ収集の収集の画面には
  # Chidori で読む対象を全部（本棚の収集もここ）
  defp in_mode?(dataset, :read), do: Chidori.Datasets.read_on_datasets?(dataset)
  defp in_mode?(dataset, _mode), do: Chidori.Datasets.listed?(dataset)

  attr :current, :atom, required: true, doc: "`:latest`（最新）・`:graph`（関連図）・`:theaters`（映画館）"
  attr :mode, :atom, default: :read

  @doc """
  趣味の映画のタブの中の切り替え（最新・関連図・映画館）。**四角い札**（`home-subtabs`）——
  上の段がタブの形なので、両方タブだとどちらが上の階層か読めない。**本文の頭に置き、下に線を
  引く**（`movie-tabs`。その下の要約や図から区切る）。画面はそれぞれ（最新情報と関連図）の
  ものなので、移るのは `navigate`。収集の画面では映画館を出さない（頼むものが無い）。
  """
  def movie_tabs(assigns) do
    tabs =
      for {_key, _name, _read, collect} = tab <- Chidori.Hobbies.movie_tabs(),
          assigns.mode != :collect or collect != nil,
          do: tab

    assigns = assign(assigns, tabs: tabs)

    ~H"""
    <nav
      id="movie-tabs"
      class="home-subtabs movie-tabs"
      phx-hook="ScrollTabs"
      aria-label="映画の中の切り替え"
    >
      <.link
        :for={{key, name, read, collect} <- @tabs}
        navigate={if @mode == :collect, do: collect, else: read}
        class={if @current == key, do: "selected"}
        aria-current={if @current == key, do: "page"}
      >
        {name}
      </.link>
    </nav>
    """
  end
end
