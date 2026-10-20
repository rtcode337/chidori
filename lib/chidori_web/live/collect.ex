defmodule ChidoriWeb.Collect do
  @moduledoc """
  Chiezo の収集を画面から扱うための道具。**関連図と最新情報で同じものを使います**。

  どちらも同じことをしています —— Chiezo に置いた収集の巡回を並べ、巡回ごとに
  頼む相手を選び、まとめて送る。**別々に書くと、片方だけ直る** ——
  選んだ相手が元へ戻る不具合はこの形のものなので、1 か所に集めてあります。
  """

  alias Chidori.Jst

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
  `sweep|ざっと見る|backend` の形で届くものを、巡回ごとにまとめ直します。
  """
  def sweep_choices(params) do
    for {key, value} <- params, reduce: %{} do
      acc ->
        case String.split(key, "|") do
          ["sweep", name, field] when field in ~w(backend model) ->
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
  頼める相手を、種類ごとに分けます。**ワーカーは相手と同じ欄に並びますが、
  別の見出しの下に置きます** —— 名前だけでは、1 つの相手なのか振り替える並びなのかが
  読めません（ワーカーは渡す先がそのときの枠で決まります）。
  """
  def by_kind(backends) do
    Enum.split_with(backends || [], &(Map.get(&1, :kind, "backend") != "worker"))
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

  **呼び名は Chiezo の管理画面と揃えます**（「流れ」「網羅」）。同じ収集を両方の
  画面で見るので、別の名前で呼ぶと同じものだと分からない。
  """
  def kind_text(%{kind: "flow"} = c), do: "流れ（時とともに増えるものを追う。#{held(c)}）"

  def kind_text(_collection),
    do: "網羅（ある括りの全部を集めて、端から端まで精査し続ける）"

  defp held(%{keep_days: days}) when is_integer(days) and days > 0,
    do: "#{days} 日ぶんを持ち、古いものは順に落とす"

  defp held(_collection), do: "期限では落とさない"

  # 区画を持たない収集（最新情報のような）には出さない
  defp partitions_fact(%{partitions_total: total}) when is_integer(total) and total > 0,
    do: {"区画", "#{total}"}

  defp partitions_fact(_collection), do: nil

  # **依頼文が `{cursor}` を使う収集だけに出す。** Chiezo は答えの形として毎回
  # `next_cursor` を求めるので、使わない収集でも AI が何かしら書いて返し、それが
  # そのまま残る（区画で回る画家の図に「1879-」とだけ出ていた）。使われない値を
  # 「進み具合」と呼ぶと、読んだ人はそこまで進んだのだと受け取る。
  # 区画で回る収集の進み具合は、巡回ごとの行（一周のうちどこまで）が持つ
  defp cursor_fact(%{cursor: cursor} = c) when is_binary(cursor) and cursor != "" do
    if uses_cursor?(c), do: {"進み具合", cursor}
  end

  defp cursor_fact(_collection), do: nil

  defp uses_cursor?(c) do
    [c[:prompt] | Enum.map(c[:sweeps] || [], & &1[:prompt])]
    |> Enum.any?(&(is_binary(&1) and String.contains?(&1, "{cursor}")))
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
          interval_minutes: c.interval_minutes,
          cover_days: nil,
          on_demand: false,
          use_extract: false,
          use_feed: false,
          use_pihole: false,
          by_hand: false,
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
      interval:
        cond do
          # **手で回す回は時計を持たない。** 走るのは、人が持ち帰った答えを
          # 読み込んだとき —— 間隔を出すと、勝手に動くように読める
          sweep[:by_hand] -> "手で回す"
          sweep[:on_demand] -> "時計なし"
          # 時計を外した回。間隔を出すと、勝手に動くように読める（起こすのは依頼元）
          sweep[:by_caller] -> "依頼元が起こす"
          sweep.interval_minutes -> "#{sweep.interval_minutes} 分ごと"
          true -> "—"
        end,
      round: if(sweep[:cover_days], do: "#{round(sweep.cover_days)} 日で一周", else: nil),
      # **機械で引く回は相手を選ばせない。** 選んでも何も起きない —— その回は AI を
      # 呼ばずに返すので、相手もモデルも読まれない。
      # **選べるのに効かない欄は「設定したつもり」を作る**
      # **例外は検索文を考える回**（依頼文に `{queries}` を書いた機械で引く回）——
      # 引くのは機械だが、その前に検索文をその巡回の相手に考えさせる
      mechanical:
        sweep[:use_extract] == true or sweep[:by_hand] == true or sweep[:use_pihole] == true or
          (sweep[:use_feed] == true and not thinks_queries?(sweep)),
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

  @doc "検索文を AI に考えさせてから引く回か（Chiezo の `{queries}` の差し込み口）。"
  def thinks_queries?(sweep),
    do:
      sweep[:use_feed] == true and String.contains?(to_string(sweep[:prompt] || ""), "{queries}")

  defp last_text(%{last_run_at: nil}), do: "まだ"

  defp last_text(%{last_status: "error", last_error: error}) when is_binary(error),
    do: "失敗: #{error}"

  defp last_text(c), do: Jst.format(c.last_run_at) || "まだ"

  @doc """
  区画を名指しして走らせられる巡回だけ。

  **手で回す回はここに出しません** —— こちらから走らせる道が無く、選んでも
  Chiezo に断られます（走らせる中身は、人が持ち帰って読み込んだときに揃う）。
  機械で引く回も同じ理由で外します。

  **判断は Chiezo が言うことに従います**（こちらで場合分けを書き写さない）。
  巡回の一覧が読めないときは、渡された名前をそのまま返します —— 選べないより、
  押して断られるほうがまだ読める。
  """
  def runnable_sweeps(state, names) do
    rows = sweep_rows(state)

    case Enum.reject(names, fn name ->
           Enum.any?(rows, &(&1.name == name and &1.mechanical))
         end) do
      [] -> names
      kept -> kept
    end
  end

  @doc """
  区画の見終わり具合（`{巡回の名前, 見終わった区画の数}`）。**いま回っている巡回のもの**
  を返します —— 前の巡回（ざっと見る）が一周するまではその数、一周したら次の巡回
  （整理・情報収集）の数。全部が一周していれば最後の巡回の数です。

  見出しに「この数 / 総数」と並べるので、1 つだけ返します（巡回ごとの数は表の列が持つ）。
  """
  def partition_progress([], _sweeps), do: nil
  def partition_progress(_rows, []), do: nil

  def partition_progress(rows, sweeps) do
    total = length(rows)
    counts = Enum.map(sweeps, fn sweep -> {sweep, Enum.count(rows, &(sweep in &1.seen_by))} end)
    Enum.find(counts, fn {_sweep, count} -> count < total end) || List.last(counts)
  end

  @doc """
  区画の一覧。**まだ見ていないものが先**（次に回ってくる順）。

  数百あるので、そのまま並べると画面が埋まります。畳んだ中に出して、
  先頭だけが見えるようにします。

  **見た印は巡回ごとに別**なので、どの巡回の目で見るかを渡します ——
  ざっと見るが見終えた区画を整理はまだ見ていない、が普通に起きます。

  **区画を回る巡回をまとめて渡せます**（`["ざっと見る", "整理"]`）。
  **どこまで進んだかは 1 本では読めません** —— 1 本だけを見ると、もう片方が
  回っているのに「まだ」のままになります。返す `stage` は**何本が見たか**
  （0 がまだ）、`by` と `at` は**いちばん最近に見た**巡回とその時刻です。

  **深さでは数えません。** 巡回は並んで回るので、後ろに書いた回だけが見た区画が
  普通にできます —— 順番で数えると、その区画が「両方とも見終えた」に化けます。
  """
  def partition_rows(state, sweep) when is_binary(sweep), do: partition_rows(state, [sweep])

  def partition_rows(%{collection: %{partitions: list}}, sweeps)
      when is_list(list) and is_list(sweeps) do
    list
    |> Enum.map(&partition_row(&1, sweeps))
    |> Enum.sort_by(&{&1.stage, &1.at || "", &1.key})
  end

  def partition_rows(_state, _sweeps), do: []

  defp partition_row(partition, sweeps) do
    seen =
      sweeps
      |> Enum.map(&{&1, Map.get(partition.visits, &1)})
      |> Enum.reject(fn {_sweep, at} -> is_nil(at) end)

    {by, at} =
      case Enum.sort_by(seen, &elem(&1, 1), :desc) do
        [{sweep, at} | _rest] -> {sweep, at}
        [] -> {nil, nil}
      end

    %{
      key: partition.key,
      count: partition.count,
      stage: length(seen),
      # **どの巡回が見たか**（地図の色分けに使う。何本かだけでは、どこまで進んだのか
      # 読めない —— 後の回だけが見た区画が普通にできる）
      seen_by: Enum.map(seen, &elem(&1, 0)),
      # 巡回ごとの見た時刻（JST の文字列。まだなら無い）。**巡回ごとに列を出す**ため
      seen_at: Map.new(seen, fn {sweep, at} -> {sweep, Jst.format(at)} end),
      by: by,
      at: at,
      seen: Jst.format(at)
    }
  end

  @doc """
  断られた理由の一文。**どの画面でも同じことが起きる**ので、ここに 1 つだけ置きます
  —— 画面ごとに書くと、同じ理由の説明が食い違ったまま片方だけ直ります。

  **知らない理由でも、そのまま出します。** 「失敗しました」だけだと、押した人にも
  直す人にも何も分かりません（実際にこれが出て、原因を画面から辿れなかった）。
  ここに来るのは自分たちが返した印であって、外から来た文言ではありません。
  """
  def reason_text(:chiezo_not_configured),
    do: "CHIEZO_BASE_URL が設定されていないため、Chiezo に頼めません。"

  def reason_text(:chiezo_unavailable), do: "Chiezo に接続できませんでした。"
  def reason_text({:chiezo_status, status}), do: "Chiezo が #{status} を返しました。"
  def reason_text(:chiezo_unexpected_body), do: "Chiezo の応答を解釈できませんでした。"
  def reason_text({:chiezo_refused, status, nil}), do: "Chiezo が依頼を断りました（#{status}）。"
  def reason_text({:chiezo_refused, _status, message}), do: "Chiezo が依頼を断りました: #{message}"

  # 同じ依頼がこの Chidori の中でまだ走っている（`Chidori.SingleFlight`）
  def reason_text(:busy),
    do: "同じ依頼がまだ走っています。終わってからもう一度押してください。"

  def reason_text(:chiezo_busy),
    do:
      "いま Chiezo が取り込み中なので、割り込みを受け付けてもらえませんでした。" <>
        "終わってからもう一度押してください。"

  def reason_text(:collect_unsupported),
    do: "この Chiezo には「集める」層がありません。Chiezo を新しくすると使えるようになります。"

  def reason_text(:collect_disabled),
    do:
      "Chiezo 側で「集める」層が無効です。" <>
        "CHIEZO_NOTES_DIR と CHIEZO_TRIGGER_URL を設定すると有効になります。"

  def reason_text(:collection_disabled),
    do:
      "この収集は Chiezo 側で止まっています。" <>
        "Chiezo の管理画面の「集める」で有効にすると動き出します。"

  # 頼む直前に区画を読み直したら、控えがどの区画にも入らなかった（`Requests.send_partition/5`）
  def reason_text(:partitions_moved),
    do:
      "控えた依頼の座標が、いまの区画のどれにも入りませんでした。控えは残してあります。" <>
        "範囲を広げた直後なら、次の回で区画が割り直されてから頼んでください。"

  def reason_text(:not_requested), do: "Chiezo にこの収集がありません。もう一度押すと作り直します。"
  def reason_text(:collection_crashed), do: "問い合わせの途中で問題が起きました。もう一度押してください。"
  def reason_text(:too_soon), do: "続けて押しています。少し時間を置いてからもう一度押してください。"

  def reason_text(:pihole_not_configured),
    do:
      "Chiezo に Pi-hole の接続先がありません（Chiezo の管理画面の API キーの面で pihole_url と pihole_password を登録してください）。"

  def reason_text(:pihole_unavailable), do: "Chiezo から Pi-hole に繋がりませんでした。"

  def reason_text(nil), do: ""
  def reason_text(reason), do: "Chiezo とのやり取りに失敗しました（#{inspect(reason)}）。"
end
