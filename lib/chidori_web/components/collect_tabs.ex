defmodule ChidoriWeb.CollectTabs do
  @moduledoc """
  収集の画面の頭の段（一覧・ニュース・趣味・イベント・他アプリ用）。**頭のメニューの「収集」から直接たどれるように**
  —— 一覧だけだった頃は、話題・図・データごとの収集の画面へ一覧の行のリンクからしか行けず、
  食事処やご当地グルメも一覧の行を探して開くことになった。

  収集の画面はどれもこの段を頭に置き、その下にそれぞれの画面のタブ（話題・図・集めるもの）を並べる。
  """

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: ChidoriWeb.Endpoint,
    router: ChidoriWeb.Router,
    statics: ChidoriWeb.static_paths()

  @tabs [
    {:list, "一覧", "/collect"},
    {:news, "ニュース", "/collect/news"},
    {:datasets, "趣味", "/collect/news?view=chidori_movies"},
    {:events, "イベント", "/collect/events"},
    # 他のアプリ（travel-log）が読む収集。Chidori のデータ収集と並べると、どちらで読むものか分からない
    {:apps, "他アプリ用", "/collect/apps"}
  ]

  # いま開いている段（`:list` / `:news` / `:relations` / `:datasets` / `:apps`）
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
end
