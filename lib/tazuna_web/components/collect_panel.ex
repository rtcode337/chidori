defmodule TazunaWeb.CollectPanel do
  @moduledoc """
  Chiezo の収集の枠。**関連図と最新情報で同じものを出します**。

  状態を見る場所と、直す場所と、押す場所を 1 つの枠にまとめます ——
  離れていると、何がどこへ効くのか読めません。
  """

  use Phoenix.Component

  import TazunaWeb.Collect

  attr :state, :map, required: true, doc: "収集を持つ画面の状態（`collection` を持つもの）"
  attr :picks, :map, default: %{}, doc: "巡回ごとに選ばれている相手"
  attr :backends, :list, default: [], doc: "Chiezo で頼める相手"

  attr :triggered, :list,
    default: [],
    doc: "tazuna が時刻に起こす巡回の名前（Chiezo 側では止めてあるもの）"

  @doc """
  巡回ごとに 1 行の表。**相手も進み具合も巡回ごとに違う**ので、収集に 1 つだけ
  出すと、そこに出る値はどちらか片方のものにしかなりません。
  """
  def sweep_table(assigns) do
    assigns =
      assign(assigns, :rows, assigns.state |> sweep_rows() |> triggered_rows(assigns.triggered))

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
          <% model = pick_of(@picks, row.name, :model, row.model) %>
          <td>{row.name}</td>
          <td :if={row.mechanical} class="pick">
            <span class="muted-note">AI を使いません</span>
          </td>
          <%!-- モデルは相手ごとに別物なので、**選び直した相手のぶんを出す** ——
               前の相手のものを出すと、その相手が受け付けない値を送ることになる。
               **選べるものが無ければ欄ごと出さない** —— 「既定」しか入っていない
               セレクトは、押せるのに何も選べない。ワーカーもここに当たる
               （渡す先はそのときの枠で決まるので、モデルを 1 つ選んでも
               どの相手に対する指定なのかが決まらない）。
               **考える量の欄は持ちません** —— モデルの名前に畳んであります --%>
          <% models = models_for(@backends, backend) %>
          <% {plain, hands} = by_kind(@backends) %>
          <td :if={!row.mechanical} class="pick">
            <select name={"sweep|#{row.name}|backend"}>
              <option value="">Chiezo の既定にまかせる</option>
              <option :for={b <- plain} value={b.id} selected={b.id == backend}>
                {b.label}
              </option>
              <%!-- **ワーカーは別の見出しの下へ** —— 名前だけでは、1 つの相手なのか
                   振り替える並びなのかが読めない --%>
              <optgroup :if={hands != []} label="ワーカー（枠を見て振り替える）">
                <option :for={b <- hands} value={b.id} selected={b.id == backend}>
                  {b.label}
                </option>
              </optgroup>
            </select>
            <select :if={models != []} name={"sweep|#{row.name}|model"}>
              <option value="">モデルは相手の既定</option>
              <option :for={m <- models} value={m} selected={m == model}>
                {m}
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

  # **tazuna が起こす巡回は、要約と同じ出し方にする**（時計なし・頼まれたとき）。
  # Chiezo 側では止めてあるので、そのまま出すと Chiezo の間隔と「止めている」が並び、
  # 動かないように読める。いつ起こすかは tazuna の欄が出す
  defp triggered_rows(rows, []), do: rows

  defp triggered_rows(rows, names) do
    Enum.map(rows, fn row ->
      if row.name in names,
        do: %{row | interval: "時計なし", round: nil, next: "頼まれたとき"},
        else: row
    end)
  end
end
