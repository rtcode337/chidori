defmodule AntennaWeb.Collect do
  @moduledoc """
  Chiezo の収集を画面から扱うための道具。**関連図と最新情報で同じものを使います**。

  どちらも同じことをしています —— Chiezo に置いた収集の巡回を並べ、巡回ごとに
  頼む相手を選び、まとめて送る。**別々に書くと、片方だけ直る** ——
  選んだ相手が元へ戻る不具合はこの形のものなので、1 か所に集めてあります。
  """

  alias Antenna.Jst

  @doc """
  その巡回でいま選ばれているもの。**覚えているほうを先に見ます**。

  画面が描き直されるとフォームはサーバーが言うとおりに戻るので、覚えたものを
  出し直さないと、選んだところが勝手に元へ戻ります（選んだつもりで押すと、
  いま入っている値がそのまま送り返される）。
  """
  def pick_of(picks, name, field, fallback) do
    case get_in(picks, [name, field]) do
      nil -> fallback
      picked -> picked
    end
  end

  @doc """
  `sweep|ざっと|backend` の形で届くものを、巡回ごとにまとめ直します。
  """
  def sweep_choices(params) do
    for {key, value} <- params, reduce: %{} do
      acc ->
        case String.split(key, "|") do
          ["sweep", name, field] when field in ~w(backend model effort) ->
            Map.update(acc, name, %{String.to_atom(field) => value}, fn picked ->
              Map.put(picked, String.to_atom(field), value)
            end)

          _ ->
            acc
        end
    end
  end

  @doc """
  送るときの選択。**覚えているほうが勝ちます**（フォームは描き直しで元へ戻るため）。
  """
  def merged_picks(remembered, params) do
    Map.merge(sweep_choices(params), remembered, fn _name, from_form, kept ->
      Map.merge(from_form, kept)
    end)
  end

  @doc """
  その相手が受け付ける「考える量」。**相手を選び直すまでは、いまの相手のぶん**。

  相手ごとに段階が違うので（claude は 5 段、antigravity は 3 段）、まとめて並べると
  選べない値が出ます。
  """
  def efforts_for(backends, backend) do
    case Enum.find(backends || [], &(&1.id == backend)) do
      nil -> []
      found -> found.efforts
    end
  end

  @doc """
  巡回ごとの行（名前・いつ走るか・一周のうちどこまで・前回）。

  **巡回を書いていない収集にも 1 行出ます**（定義そのものが 1 本の巡回として動く）。
  """
  def sweep_rows(%{collection: %{sweeps: sweeps}} = state) when sweeps != [],
    do: Enum.map(sweeps, &sweep_row(&1, state))

  def sweep_rows(%{collection: c}) when is_map(c) do
    [
      sweep_row(
        %{
          name: "既定",
          backend: c.backend,
          model: c.model,
          effort: c.effort,
          interval_minutes: c.interval_minutes,
          cover_days: nil,
          on_demand: false,
          use_extract: false,
          use_feed: false,
          enabled: c.enabled,
          next_run_at: c.next_run_at,
          last_run_at: c.last_run_at,
          last_status: c.last_status,
          last_error: c.last_error,
          partitions_visited: 0
        },
        %{collection: c}
      )
    ]
  end

  def sweep_rows(_state), do: []

  defp sweep_row(sweep, %{collection: c}) do
    total = c[:partitions_total] || 0

    %{
      name: sweep.name,
      backend: sweep.backend,
      model: sweep.model,
      effort: sweep.effort,
      interval:
        cond do
          sweep[:on_demand] -> "時計なし"
          sweep.interval_minutes -> "#{sweep.interval_minutes} 分ごと"
          true -> "—"
        end,
      round: if(sweep[:cover_days], do: "#{round(sweep.cover_days)} 日で一周", else: nil),
      # **機械で引く回は相手を選ばせない。** 選んでも何も起きない —— その回は AI を
      # 呼ばずに返すので、相手もモデルも読まれない。
      # **選べるのに効かない欄は「設定したつもり」を作る**
      mechanical: sweep[:use_extract] == true or sweep[:use_feed] == true,
      next:
        cond do
          not sweep.enabled -> "止めている"
          # 時計を持たない巡回（割り込み用）。押されたときだけ動く
          sweep[:on_demand] -> "頼まれたとき"
          next = Jst.format(sweep.next_run_at) -> next
          true -> "いますぐ"
        end,
      progress: if(total > 0, do: "#{total} のうち #{sweep.partitions_visited}", else: "—"),
      last: last_text(sweep)
    }
  end

  defp last_text(%{last_run_at: nil}), do: "まだ"

  defp last_text(%{last_status: "error", last_error: error}) when is_binary(error),
    do: "失敗: #{error}"

  defp last_text(c), do: Jst.format(c.last_run_at) || "まだ"
end
