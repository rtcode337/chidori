defmodule ChidoriWeb.ToolsLive do
  @moduledoc """
  **ツール**（`/tools`）。溜めたものを読む画面ではなく、その場の様子を見る道具を置く。
  いまは Pi-hole の「いま止めている通信」（`ChidoriWeb.PiholeLive`。流しているかと行は部品が持つ）。
  """

  use ChidoriWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "ツール")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="relations-page page-head">
      <div>
        <ChidoriWeb.MainNav.main_nav active={:tools} />
      </div>
    </div>

    <main id="page-scroll" class="relations-page tools-page" phx-hook="PageScroll">
      <div>
        <section class="relations-intro">
          <p>TOOLS</p>
          <h1>ツール</h1>
          <p>溜めたものを読むのではなく、その場の様子を見る道具です。</p>
        </section>
        <.live_component module={ChidoriWeb.PiholeLive} id="pihole-live" />
      </div>
    </main>
    """
  end
end
