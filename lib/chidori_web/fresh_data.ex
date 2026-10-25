defmodule ChidoriWeb.FreshData do
  @moduledoc """
  画面を開いたときに、利用者が書いた記録（`Chidori.DataStore`）を Chiezo から読み直す
  （`on_mount`。どの画面も `use ChidoriWeb, :live_view` で付く）。画面の mount より前に
  走るので、画面は読み直した記録で描く。

  **つながってからだけ読む**（最初の描画では読まない。同じ開き方で 2 回叩かない）。
  続けて開いたときに読み直さないのは `DataStore.refresh/0` の側が決める。
  """

  import Phoenix.LiveView, only: [connected?: 1]

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Chidori.DataStore.refresh()
    {:cont, socket}
  end
end
