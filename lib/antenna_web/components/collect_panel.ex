defmodule AntennaWeb.CollectPanel do
  @moduledoc """
  Chiezo の収集の枠。**関連図と最新情報で同じものを出します**。

  状態を見る場所と、直す場所と、押す場所を 1 つの枠にまとめます ——
  離れていると、何がどこへ効くのか読めません。
  """

  use Phoenix.Component

  import AntennaWeb.Collect

  attr :state, :map, required: true, doc: "収集を持つ画面の状態（`collection` を持つもの）"
  attr :picks, :map, default: %{}, doc: "巡回ごとに選ばれている相手"
  attr :backends, :list, default: [], doc: "Chiezo で頼める相手"

  @doc """
  巡回ごとに 1 行の表。**相手も進み具合も巡回ごとに違う**ので、収集に 1 つだけ
  出すと、そこに出る値はどちらか片方のものにしかなりません。
  """
  def sweep_table(assigns) do
    assigns = assign(assigns, :rows, sweep_rows(assigns.state))

    ~H"""
    <table :if={@rows != []} class="sweep-table">
      <thead>
        <tr>
          <th>巡回</th>
          <th>頼む相手</th>
          <th>間隔</th>
          <th>次にいつ</th>
          <th>一周のうち</th>
          <th>前回</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @rows}>
          <% backend = pick_of(@picks, row.name, :backend, row.backend) %>
          <% effort = pick_of(@picks, row.name, :effort, row.effort) %>
          <td>{row.name}</td>
          <td :if={row.mechanical} class="pick">
            <span class="muted-note">AI を使いません</span>
          </td>
          <td :if={!row.mechanical} class="pick">
            <select name={"sweep|#{row.name}|backend"}>
              <option value="">Chiezo の既定にまかせる</option>
              <option :for={b <- @backends} value={b.id} selected={b.id == backend}>
                {b.label}
              </option>
            </select>
            <%!-- 考える量の段階は相手ごとに違う（claude は 5 段、antigravity は 3 段）。
                 **選び直した相手のぶんを出す** —— 前の相手の段階を出すと、
                 その相手が受け付けない値を送ることになる --%>
            <select name={"sweep|#{row.name}|effort"}>
              <option value="">考える量は相手の既定</option>
              <option :for={e <- efforts_for(@backends, backend)} value={e} selected={e == effort}>
                {e}
              </option>
            </select>
          </td>
          <td>
            {row.interval}
            <span :if={row.round} class="muted-note">（{row.round}）</span>
          </td>
          <td>{row.next}</td>
          <td>{row.progress}</td>
          <td>{row.last}</td>
        </tr>
      </tbody>
    </table>
    """
  end
end
