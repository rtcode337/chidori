defmodule ChidoriWeb.PiholeLive do
  @moduledoc """
  **いま止めている通信**（Pi-hole の画面の「1件ずつ流す」に当たるもの）。トップページの
  「ツール」の大きなタブに置く。押した時点から先に Pi-hole が止めた問い合わせを、5 秒ごとに
  Chiezo 越しに読み（`Chidori.Datasets.Pihole.blocked_since/2`）、新しいものを上に 1 件 1 行で足す。

  溜めたもの（趣味の Pi-hole のドメイン）を読むのではなく、その場の様子を見る道具なので、
  読む画面とは分けて置く。**状態はこの部品が持つ**（流しているか・行・続きの印）—— 置く画面が
  時計や行を抱えずに済む。止めたら読みに行かない。
  """

  use Phoenix.LiveComponent

  alias Chidori.Datasets
  alias Chidori.Datasets.Pihole
  alias Chidori.Jst

  # 1 回ぶん読み終えてから次を予約する（Pi-hole が遅いときに重ならない）
  @every_ms 5_000

  @impl true
  def mount(socket) do
    {:ok, assign(socket, on: false, rows: [], cursor: nil, error: nil)}
  end

  @impl true
  def update(%{tick: true}, socket) do
    if socket.assigns.on, do: {:ok, poll(socket)}, else: {:ok, socket}
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("start", _params, socket) do
    socket = assign(socket, on: true, rows: [], cursor: System.os_time(:second), error: nil)
    {:noreply, poll(socket)}
  end

  def handle_event("stop", _params, socket), do: {:noreply, assign(socket, on: false)}

  def handle_event("clear", _params, socket), do: {:noreply, assign(socket, rows: [])}

  @impl true
  def handle_async(:read, {:ok, {:ok, %{rows: rows, cursor: cursor}}}, socket) do
    # **新しいものを上に**（流し見るときに目が行くのは上）。古いものから落とす
    kept = Enum.take(Enum.reverse(rows) ++ socket.assigns.rows, Pihole.live_keep())

    {:noreply,
     socket
     |> assign(rows: kept, cursor: cursor || socket.assigns.cursor, error: nil)
     |> schedule()}
  end

  # 読めなかった回は理由を出し、**止めずに次の回も試す**（Pi-hole の再起動などは待てば戻る）
  def handle_async(:read, {:ok, {:error, reason}}, socket),
    do: {:noreply, socket |> assign(error: reason) |> schedule()}

  def handle_async(:read, {:exit, _reason}, socket),
    do: {:noreply, socket |> assign(error: :collection_crashed) |> schedule()}

  defp poll(socket) do
    cursor = socket.assigns.cursor

    start_async(socket, :read, fn ->
      with {:ok, base} <- Datasets.base_url(), do: Pihole.blocked_since(base, cursor)
    end)
  end

  defp schedule(socket) do
    if socket.assigns.on,
      do: send_update_after(__MODULE__, [id: socket.assigns.id, tick: true], @every_ms)

    socket
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="live-blocked" aria-label="いま止めている通信">
      <h2>
        いま止めている通信 <span :if={@on} class="live-dot" aria-hidden="true"></span>
      </h2>
      <p class="button-row">
        <button :if={!@on} type="button" phx-click="start" phx-target={@myself}>流す</button>
        <button :if={@on} type="button" phx-click="stop" phx-target={@myself}>止める</button>
        <button :if={@rows != []} type="button" phx-click="clear" phx-target={@myself}>消す</button>
        <span class="muted-note">
          押した時点から先に Pi-hole が止めた問い合わせを、5 秒ごとに 1 件 1 行で足します（同じドメインでも来るたびに 1 行）。
        </span>
      </p>
      <p :if={@error} class="muted-note">{ChidoriWeb.Collect.reason_text(@error)}</p>
      <p :if={@on and @rows == [] and !@error} class="muted-note">待っています…</p>
      <table :if={@rows != []} class="live-table">
        <thead>
          <tr>
            <th>時刻</th><th>ドメイン</th><th>アクセス元</th><th>止め方</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows}>
            <td>{Jst.format(row.at)}</td>
            <td class="live-domain">{row.domain}</td>
            <td>
              {row.client}<span :if={row.client_name} class="muted-note">（{row.client_name}）</span>
            </td>
            <td class="muted-note">{row.status}</td>
          </tr>
        </tbody>
      </table>
      <p class="muted-note">
        溜めたドメインと調べた結果は<a href="/datasets?view=pihole">趣味の Pi-hole</a>で見られます。
      </p>
    </section>
    """
  end
end
