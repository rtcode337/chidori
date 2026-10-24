defmodule ChidoriWeb.CollectSwitch do
  @moduledoc """
  各収集の設定の枠に置く「止める」「動かす」（Chiezo の `POST /v1/collect/{name}/enabled`。
  `Chidori.Chiezo.switch/3`）。収集の一覧の「止める」「動かす」と同じもの。

  **動かすのは Chiezo の管理画面で「外部からの有効化を許可する」を押したときだけ通る。**
  許していなければ（`outside_switch_allowed` が偽）、押せないボタンを出す代わりに
  Chiezo の管理画面のその収集の面への入口を出す —— 動かすかどうかを決めるのは Chiezo の側。

  切り替えたら、置いている画面へ `{:collection_switched, 収集の名前}` を送る（画面は
  収集の状態を読み直す。止めた色を付け直すため）。
  """

  use Phoenix.LiveComponent

  alias Chidori.Chiezo

  @impl true
  def mount(socket), do: {:ok, assign(socket, switching: false, message: nil)}

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("switch", %{"enabled" => enabled}, socket) do
    on? = enabled == "true"
    name = socket.assigns.collection.name

    case Chidori.News.chiezo_base_url() do
      base when is_binary(base) ->
        {:noreply,
         socket
         |> assign(switching: true, message: nil)
         |> start_async(:switch, fn -> {on?, Chiezo.switch(base, name, on?)} end)}

      _none ->
        {:noreply, assign(socket, message: "Chiezo の場所が決まっていません。")}
    end
  end

  @impl true
  def handle_async(:switch, {:ok, {on?, result}}, socket) do
    if result == :ok, do: send(self(), {:collection_switched, socket.assigns.collection.name})
    {:noreply, assign(socket, switching: false, message: text(on?, result))}
  end

  def handle_async(:switch, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, switching: false, message: "切り替えられませんでした。")}

  @doc "切り替えた結果の一言（収集の一覧と同じ言い方）。"
  def text(on?, result), do: ChidoriWeb.SettingsLive.switch_text(on?, result)

  @doc "Chiezo の管理画面の、その収集の面。"
  def admin_page(name),
    do: Chiezo.link("/admin/collect/" <> URI.encode(name, &URI.char_unreserved?/1))

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="collect-switch">
      <%= cond do %>
        <% @collection.enabled -> %>
          <button
            type="button"
            class="collection-switch"
            phx-click="switch"
            phx-value-enabled="false"
            phx-target={@myself}
            disabled={@switching}
          >
            止める
          </button>
        <% @collection[:outside_switch_allowed] -> %>
          <button
            type="button"
            class="collection-switch"
            phx-click="switch"
            phx-value-enabled="true"
            phx-target={@myself}
            disabled={@switching}
            data-confirm="この収集を動かします。Chiezo の時計で AI が回り始めます。よろしいですか？"
          >
            動かす
          </button>
        <% true -> %>
          <a
            :if={admin_page(@collection.name)}
            href={admin_page(@collection.name)}
            target="_blank"
            rel="noreferrer"
            class="collect-switch-link"
          >
            Chiezo で動かす ↗
          </a>
          <span class="muted-note">
            Chiezo で外部からの有効化を許可していないので、Chiezo の収集の面で動かしてください。
          </span>
      <% end %>
      <p :if={@message} class="muted-note" aria-live="polite">{@message}</p>
    </div>
    """
  end
end
