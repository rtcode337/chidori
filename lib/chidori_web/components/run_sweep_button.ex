defmodule ChidoriWeb.RunSweepButton do
  @moduledoc """
  巡回の表（`ChidoriWeb.CollectPanel.sweep_table/1`）の 1 行に置く「今すぐ走らせる」。

  **人が押した 1 回として頼む**（`Chidori.Chiezo.by_hand/1`。止めた収集でも走る）。ふつうの回
  なので、進み具合も次の予定も進む。**頼んでいる最中か・結果の一言はこの部品が持つ** ——
  巡回の表は最新情報・関連図・趣味の収集の画面で同じものを使うので、画面ごとに持たせると
  同じ処理を 3 か所に書くことになる。表はフォームの中にあるので、ボタンは送信しない形にする。
  """

  use Phoenix.LiveComponent

  alias Chidori.Chiezo

  @impl true
  def mount(socket), do: {:ok, assign(socket, running: false, message: nil)}

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("run", _params, socket) do
    %{collection: name, sweep: sweep} = socket.assigns

    case Chidori.News.chiezo_base_url() do
      base when is_binary(base) ->
        {:noreply,
         socket
         |> assign(running: true, message: nil)
         |> start_async(:run, fn ->
           Chiezo.by_hand(fn -> Chiezo.run(base, name, sweep: sweep) end)
         end)}

      _none ->
        {:noreply,
         assign(socket, message: ChidoriWeb.Collect.reason_text(:chiezo_not_configured))}
    end
  end

  @impl true
  def handle_async(:run, {:ok, result}, socket),
    do: {:noreply, assign(socket, running: false, message: text(result))}

  def handle_async(:run, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, running: false, message: text({:error, :collection_crashed}))}

  @doc "頼んだ結果の一言。"
  def text(:ok), do: "頼みました（取り込みが埋まっていれば並んで待ちます）。"
  def text({:error, reason}), do: "頼めませんでした: " <> ChidoriWeb.Collect.reason_text(reason)

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="run-sweep">
      <button
        type="button"
        phx-click="run"
        phx-target={@myself}
        disabled={@running}
        data-confirm={"「#{@sweep}」を今すぐ 1 回走らせます。AI を使う回なら枠を使います。よろしいですか？"}
      >
        {if @running, do: "頼んでいます…", else: "今すぐ走らせる"}
      </button>
      <p :if={@message} class="muted-note" aria-live="polite">{@message}</p>
    </div>
    """
  end
end
