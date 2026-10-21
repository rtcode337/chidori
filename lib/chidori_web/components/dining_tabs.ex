defmodule ChidoriWeb.DiningTabs do
  @moduledoc """
  データ収集のタブ（上の段。`dataset_tabs/1`）と、食事処の中のタブ（「全体」と、作った範囲ごと。
  下の段。`dining_tabs/1`）。

  **範囲ごとのタブはデータ収集のタブとは別の段にする** —— 同じ段に並べると、範囲を
  足すたびにタブが伸びて、技術書や Pi-hole のタブが押し出される。かといってタブを
  置かずに「作った範囲」の一覧から開く形では、範囲を移るたびに一覧へ戻ることになった。

  「全体」は範囲の一覧・地図・全範囲の ZIP の画面（`ChidoriWeb.DiningAreasLive`）、
  範囲のタブはその範囲の収集の画面（`ChidoriWeb.DatasetsLive` の `view`）を開く。
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
      class="relation-tabs dining-tabs"
      phx-hook="ScrollTabs"
      aria-label="食事処の範囲"
    >
      <.link
        navigate={~p"/datasets/areas"}
        class={if @current == nil, do: "selected"}
        aria-current={if @current == nil, do: "page"}
      >
        全体
      </.link>
      <.link
        :for={area <- @areas}
        navigate={~p"/datasets?view=#{area.key}"}
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

  @doc """
  データ収集のタブ（上の段）。並びは `Chidori.Datasets.tabs/1`。食事処は範囲がいくつあっても
  1 つのタブで、範囲を開いているときも「全体」の画面にいるときも、このタブを選んだ印で出す。
  **データ収集の画面と食事処の「全体」の画面の 2 か所で同じものを出す**（別々に書いていた頃は、
  並びを変えるのに 2 か所を直すことになった）。
  """
  def dataset_tabs(assigns) do
    assigns =
      assign(assigns,
        tabs: Chidori.Datasets.tabs(assigns.datasets),
        dining?:
          assigns.on_areas or
            Enum.any?(assigns.datasets, &(&1[:area] && &1.key == assigns.current))
      )

    ~H"""
    <nav id="dataset-tabs" class="relation-tabs" phx-hook="ScrollTabs" aria-label="集めるもの">
      <%= for tab <- @tabs do %>
        <%= if tab == :dining do %>
          <.link
            :if={@on_areas}
            patch={~p"/datasets/areas"}
            class="selected"
            aria-current="page"
          >
            食事処
          </.link>
          <.link
            :if={!@on_areas}
            navigate={~p"/datasets/areas"}
            class={if @dining?, do: "selected"}
            aria-current={if @dining?, do: "page"}
          >
            食事処
          </.link>
        <% else %>
          <.link :if={@on_areas} navigate={~p"/datasets?view=#{tab.key}"}>{tab.name}</.link>
          <.link
            :if={!@on_areas}
            patch={~p"/datasets?view=#{tab.key}"}
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
end
