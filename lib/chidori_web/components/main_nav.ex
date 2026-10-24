defmodule ChidoriWeb.MainNav do
  @moduledoc """
  画面の頭の主要メニュー。**どの画面も同じ並びにする** —— 画面ごとに書いていた頃は、
  1 つ足すたびに全部の画面を直すことになった（直し忘れた画面だけ入口が無くなる）。
  """

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: ChidoriWeb.Endpoint,
    router: ChidoriWeb.Router,
    statics: ChidoriWeb.static_paths()

  @items [
    {:news, "ニュース", "/news"},
    # 趣味（映画・芸術家・技術書・レシピ・芸能人・アニメ・Pi-hole）。先頭のタブ（映画）を開く
    {:datasets, "趣味", "/news?view=chidori_movies"},
    # 技術イベント・お笑いイベント（画面は最新情報のもの）
    {:events, "イベント", "/events"},
    # その場の様子を見る道具（いま止めている通信）
    {:tools, "ツール", "/tools"},
    # 収集の画面（Chiezo へ頼む口をまとめた所）。読む画面とは分ける
    {:collect, "収集", "/collect"},
    {:settings, "設定", "/settings"}
  ]

  attr :active, :atom, required: true

  def main_nav(assigns) do
    assigns = assign(assigns, items: @items)

    ~H"""
    <header>
      <%!-- 画面に出す名前は Chidori --%>
      <a href={~p"/news"} class="brand" aria-label="Chidori ニュース">
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
