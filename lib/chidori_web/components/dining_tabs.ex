defmodule ChidoriWeb.DiningTabs do
  @moduledoc """
  食事処の中のタブ（「全体」と、作った範囲ごと）。データ収集のタブの下の段に置く。

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
end
