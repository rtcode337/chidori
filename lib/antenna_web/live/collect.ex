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
  その相手が持つモデル。**相手を選び直すまでは、いまの相手のぶん**。

  考える量と同じ理由でまとめて並べません —— 相手ごとに別物なので、混ぜると
  その相手に無いモデルを選べてしまいます。**一覧を持たない相手では空**で、
  そのときは「相手の既定」だけが残ります。
  """
  def models_for(backends, backend) do
    case Enum.find(backends || [], &(&1.id == backend)) do
      nil -> []
      found -> found.models
    end
  end

  @doc """
  収集の状態。**関連図でも最新情報でも同じものを、同じ並びで出します** ——
  画面ごとに書いていた頃は、見出しも並びも食い違っていました。

  **巡回ごとの値はここに出しません**（相手も間隔も次の予定も巡回ごとに違うので、
  1 つだけ出すと、どれか 1 本のものにしかならない）。ここに出すのは、
  収集ぜんたいで 1 つに決まることだけです。
  """
  def collection_facts(%{collection: c} = state) when is_map(c) do
    [
      {"状態", if(c.enabled, do: "有効", else: "止まっている")},
      {"集め方", kind_text(c)},
      {"溜まった数", "#{c.docs} 件"},
      partitions_fact(c),
      cursor_fact(c),
      # 集まるものが変わらなかった日でも、**押した結果はここが動く**
      {"最後に確かめた", Jst.format(state[:checked_at]) || "まだ確かめていません"}
    ]
    |> Enum.reject(&is_nil/1)
  end

  def collection_facts(_state), do: []

  @doc """
  集め方の言い方。**収集の種類から出します**。

  流れ（ニュースのように時とともに増えるもの）と網羅（画家の名簿のようにある括りの
  全部）は、そもそも別のことをしています —— 同じ言い方になるほうがおかしい。
  """
  def kind_text(%{kind: "flow"} = c), do: "流れを追う（新しいものを足し、直近を整理する）#{held(c)}"

  def kind_text(_collection),
    do: "全部を精査する（その括りの全部を集めて、端から端まで見直す）"

  defp held(%{keep_days: days}) when is_integer(days) and days > 0,
    do: "。#{days} 日ぶんを持ち、古いものは順に落ちます"

  defp held(_collection), do: ""

  # 区画を持たない収集（最新情報のような）には出さない
  defp partitions_fact(%{partitions_total: total}) when is_integer(total) and total > 0,
    do: {"区画", "#{total}"}

  defp partitions_fact(_collection), do: nil

  defp cursor_fact(%{cursor: cursor}) when is_binary(cursor) and cursor != "",
    do: {"進み具合", cursor}

  defp cursor_fact(_collection), do: nil

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
      # **走らない回に「いますぐ」と出さない。** 予定を持っていないだけの回と、
      # 先の回の一周を待っている回は、どちらも予定が空 —— 区別せずに出すと、
      # 3 日動かないものを「いますぐ」と読んで待ち続けることになる。
      # **理由は Chiezo が言う**（こちらで場合分けを書き写さない）
      next:
        cond do
          sweep[:blocked] not in [nil, ""] -> sweep.blocked
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
