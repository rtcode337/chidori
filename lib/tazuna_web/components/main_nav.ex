defmodule TazunaWeb.MainNav do
  @moduledoc """
  画面の頭の主要メニュー。**どの画面も同じ並びにする** —— 画面ごとに書いていた頃は、
  1 つ足すたびに全部の画面を直すことになった（直し忘れた画面だけ入口が無くなる）。
  """

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: TazunaWeb.Endpoint,
    router: TazunaWeb.Router,
    statics: TazunaWeb.static_paths()

  @items [
    {:home, "トップ", "/"},
    {:news, "最新情報", "/news"},
    {:relations, "関連図", "/relations"},
    {:datasets, "データ収集", "/datasets"},
    {:settings, "設定", "/settings"}
  ]

  attr :active, :atom, required: true

  def main_nav(assigns) do
    assigns = assign(assigns, items: @items)

    ~H"""
    <header>
      <%!-- 画面に出す名前は Chidori（開発コードは tazuna のまま） --%>
      <a href={~p"/"} class="brand" aria-label="Chidori トップページ">
        <img src={~p"/images/icon.svg"} alt="" class="brand-mark" /><b class="brand-name">Chidori</b>
      </a>
      <nav id="main-menu" phx-hook="ScrollTabs" aria-label="主要メニュー">
        <a
          :for={{key, label, href} <- @items}
          class={if @active == key, do: "active"}
          href={href}
          aria-current={if @active == key, do: "page"}
        >
          {label}
        </a>
      </nav>
    </header>
    """
  end
end
