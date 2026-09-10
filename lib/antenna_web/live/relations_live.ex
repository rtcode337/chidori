defmodule AntennaWeb.RelationsLive do
  @moduledoc """
  関連図。収集の進み具合はそのまま画面へ反映します。

  AI に web 検索をさせるので数十秒かかります。押した人に再読み込みをさせず、
  `Antenna.Relations` からの通知で描き直します。
  """

  use AntennaWeb, :live_view

  alias Antenna.Jst
  alias Antenna.Relations

  # 1 度に描く丸の上限。**図がどれだけ大きくても、ここで頭打ちにする** ——
  # 4,250 人ぶんを SVG に並べると、線と札を合わせて 2 万を超える要素になり、
  # 引きずるだけで画面が固まる。入り切らないぶんは大きい順に残す
  @max_drawn 400

  # 画面の上でこれ未満にしか見えない丸は描かない（単位は px）。**読めないものは
  # 出さない** —— 全体表示では点にしかならず、DOM を重くするだけで何も伝えない。
  # 拡大すれば見える大きさになるので、そのとき出てくる。
  #
  # 7px では全体表示に 1,361 人が残り、点の海の中から目印を選べなかった。
  # 8px と `Graph` 側の曲げ具合（`@fame_curve`）を合わせて 272 人まで落としてある
  @min_drawn_px 8.0

  # 見えている範囲の外側にも少し描いておく幅（画面の幅に対する割合）。
  # 引きずった先が空白から描き起こされるのを防ぐ
  @viewport_margin 0.35

  # 検索で出す候補の数。**選ぶための一覧**なので、多すぎると選べない
  @max_matches 8

  # 札どうしのあいだに空ける幅（図の座標）。0 にすると線がぴったり接して、
  # 2 枚あるのか 1 枚なのか読めなくなる
  @label_gap 2

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "関連図", artwork: nil, artwork_for: nil)
     # 検索。`focus` が決まっているあいだは、その人と繋がっている相手を
     # 大きさに関わらず描く（周りの関連図を見るのが目的なので）
     |> assign(query: "", matches: [], focus: nil)
     # 見えている範囲。**最初は不明**にしておき、画面が繋がってから figure が知らせる
     # （繋がる前は全体が見えている前提で、大きいものだけを描く）
     |> assign(viewport: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view = Relations.valid_key(params["view"] || "people")

    # 種類を切り替えたら購読も付け替える。付け替えないと、見ていない側の
    # 収集結果でこの画面が書き換わる
    if connected?(socket) do
      if previous = socket.assigns[:view] do
        Relations.unsubscribe(previous)
      end

      Relations.subscribe(view)
      # Chiezo の側は antenna と関係なく進むので、開くたびに取り直す
      Relations.refresh(view)
    end

    {:noreply, assign(socket, view: view, relation: Relations.current(view))}
  end

  @impl true
  def handle_event("collect", _params, socket) do
    Relations.collect_now(socket.assigns.view)
    {:noreply, socket}
  end

  # ノードを押したら、その人の代表作を出す。**押されたときだけ引く** ——
  # 12 人ぶんを先に集めると、見ない絵まで毎回取りに行くことになる
  def handle_event("show_work", %{"name" => name}, socket) do
    node = Enum.find(socket.assigns.relation.nodes, &(&1.name == name))

    cond do
      node == nil ->
        {:noreply, socket}

      # もう一度押したら閉じる
      socket.assigns.artwork_for == name ->
        {:noreply, assign(socket, artwork: nil, artwork_for: nil)}

      true ->
        {:noreply,
         socket
         |> assign(artwork_for: name, artwork: :loading)
         |> start_async(:artwork, fn -> Antenna.Artwork.lookup(node[:work]) end)}
    end
  end

  # 閉じ方は3つとも同じところへ来る（ボタン・図の外を押す・Esc）
  def handle_event("close_work", _params, socket) do
    {:noreply, assign(socket, artwork: nil, artwork_for: nil)}
  end

  # 図が「いまどこを、どれくらいの倍率で見ているか」を知らせてくる。
  # `ppu` は図の 1 単位が画面の何 px にあたるか（拡大するほど大きくなる）。
  def handle_event("viewport", %{"x" => x, "y" => y, "w" => w, "h" => h, "ppu" => ppu}, socket) do
    {:noreply, assign(socket, viewport: %{x: x, y: y, w: w, h: h, ppu: ppu})}
  end

  def handle_event("viewport", _params, socket), do: {:noreply, socket}

  # 名前で探す。**候補を出すだけで、図はまだ動かさない** —— 打っている途中で
  # 図が飛び回ると、どこを見ていたのか分からなくなる
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, assign(socket, query: q, matches: search(socket.assigns.relation, q))}
  end

  # 候補を選んだら、その人を真ん中に置いて寄る。
  #
  # **寄せるのは画面の側**（`focus` を figure へ送る）。サーバーが持っているのは
  # 図の座標だけで、いま器が何 px なのかは向こうしか知らない。
  def handle_event("focus", %{"name" => name}, socket) do
    case Enum.find(socket.assigns.relation.nodes, &(&1.name == name)) do
      nil ->
        {:noreply, socket}

      node ->
        {:noreply,
         socket
         |> assign(focus: node.id, query: name, matches: [])
         |> push_event("focus", %{x: node.x, y: node.y})}
    end
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, assign(socket, query: "", matches: [], focus: nil)}
  end

  # 名前に含まれるかで探し、**知られている順**に返す。前方一致にしないのは、
  # 「ゴッホ」で「フィンセント・ファン・ゴッホ」を出したいため
  defp search(relation, q) do
    case String.trim(q) do
      "" ->
        []

      needle ->
        relation.nodes
        |> Enum.filter(&String.contains?(&1.name, needle))
        |> Enum.sort_by(&radius_of/1, :desc)
        |> Enum.take(@max_matches)
    end
  end

  @impl true
  def handle_async(:artwork, {:ok, result}, socket) do
    {:noreply, assign(socket, artwork: result)}
  end

  def handle_async(:artwork, {:exit, _reason}, socket) do
    {:noreply, assign(socket, artwork: nil)}
  end

  @impl true
  def handle_info({:relation_updated, relation}, socket) do
    {:noreply, assign(socket, relation: relation)}
  end

  @doc """
  Chiezo の収集の状態。動いているかの判断に要るものを並べる。

  **画家の図だけが持つ** —— 人物のほうはまだその場で AI に聞く形で、
  向こうに溜め先が無い。
  """
  def collection_facts(%{collection: c} = relation) when is_map(c) do
    [
      {"状態", if(c.enabled, do: "有効", else: "止まっている")},
      {"頼む相手", backend_text(c)},
      {"間隔", if(c.interval_minutes, do: "#{c.interval_minutes} 分ごと", else: "—")},
      {"次に集める", if(c.enabled, do: Jst.format(c.next_run_at) || "—", else: "—（止まっています）")},
      {"溜まった数", "#{c.docs} 件"},
      {"進み具合", if(c.cursor == "", do: "（まだ無し。次は一気に作ります）", else: c.cursor)},
      {"前回", last_text(c)},
      # 集まるものが変わらなかった日でも、**押した結果はここが動く**
      {"最後に確かめた", Jst.format(relation[:checked_at]) || "まだ確かめていません"}
    ]
  end

  def collection_facts(_relation), do: []

  defp backend_text(%{backend: nil}), do: "Chiezo の既定にまかせる"

  defp backend_text(%{backend: backend} = c) do
    detail = Enum.reject([c.model, c.effort], &(&1 in [nil, ""]))
    if detail == [], do: backend, else: "#{backend}（#{Enum.join(detail, " / ")}）"
  end

  defp last_text(%{last_run_at: nil}), do: "まだ集めていません"

  defp last_text(%{last_status: "error", last_error: error}) when is_binary(error),
    do: "失敗: #{error}"

  defp last_text(c),
    do:
      "#{Jst.format(c.last_run_at)}（+#{c.last_added} 件" <>
        if(c.last_removed > 0, do: " / -#{c.last_removed} 件）", else: "）")

  @doc """
  AI に頼んでいる本文。**依頼した後は Chiezo が持っているものを出す** ——
  向こうの画面から直せるので、antenna の雛形を出し続けると食い違う。
  """
  def prompt_text(%{collection: %{prompt: prompt}}) when is_binary(prompt) and prompt != "",
    do: prompt

  def prompt_text(_relation), do: Antenna.Relations.painters_prompt()

  @doc """
  最初の 1 回を機械的に埋める指定（持っていなければ nil）。

  **何で埋まったのかが読めないと、図の間違いを AI のせいにしてしまいます** ——
  名簿と年代は Wikipedia から引いたもので、AI が書いたのは影響関係と代表作です。
  """
  def extract_text(%{collection: %{extract: spec}}) when is_map(spec),
    do: Jason.encode!(spec, pretty: true)

  def extract_text(_relation), do: nil

  def prompt_note(%{collection: c}) when is_map(c),
    do: "いま Chiezo が持っている内容です。直すのは Chiezo の管理画面の「集める」から。"

  def prompt_note(_relation),
    do: "「関連図を収集」を押すと、この内容で Chiezo に頼みます。"

  @doc "その人の代表作の見出し（無ければ nil）。押せるかどうかの判断にも使う。"
  def work_of(node), do: node[:work]

  @doc """
  いま描く丸だけを選びます。**全部は描きません。**

  絞りは 3 段です。どれも「読めないものを出さない」という 1 つの考えから来ています。

  1. **見えている範囲の外は落とす。** 引きずった先が空白にならないよう、少しはみ出して
     残します（`@viewport_margin`）
  2. **画面の上で小さすぎるものは落とす**（`@min_drawn_px`）。全体表示では点にしか
     ならず、DOM を重くするだけで何も伝えません。拡大すれば見える大きさになり、
     そのとき出てきます
  3. **それでも多ければ、大きい順に頭打ち**（`@max_drawn`）。図がどれだけ大きくても
     描く数が一定に収まるので、引きずったときの重さが人数に比例しません

  範囲がまだ分からないとき（画面が繋がる前）は、全体が見えている前提で選びます。
  """
  def drawn_nodes(relation, viewport, focus \\ nil) do
    kept = neighbourhood(relation, focus)

    relation.nodes
    |> Enum.filter(fn node ->
      MapSet.member?(kept, node.id) or
        (visible?(node, viewport) and big_enough?(node, viewport))
    end)
    # 探して選んだ人とその相手を先に、あとは大きい順に。**置く順がそのまま優先順**で、
    # 先に置いたものが場所を取る
    |> Enum.sort_by(fn node -> {!MapSet.member?(kept, node.id), -radius_of(node)} end)
    # 重なりを見るのは総当たりなので、見る数に蓋をする
    |> Enum.take(@max_drawn * 4)
    |> without_overlap()
    |> Enum.take(@max_drawn)
  end

  # 札が重なるものを落とす。
  #
  # **場所を空けるのではなく、描くのをやめる。** 札は名前の幅で決まるので升目より
  # ずっと大きく、有名な画家の札は隣を何人ぶんも覆う。押しのけて避けようとすると
  # 位置が生年からずれ、縦の年表が意味を失う（地図が地名を間引くのと同じ考え方）。
  #
  # **消えたものは拡大すると出てくる。** 拡大するほど見える範囲が狭まり、
  # 同じ場所を取り合う相手が減るため。
  defp without_overlap(candidates) do
    candidates
    |> Enum.reduce({[], []}, fn node, {drawn, boxes} ->
      box = label_box(node)

      if Enum.any?(boxes, &overlap?(&1, box)),
        do: {drawn, boxes},
        else: {[node | drawn], [box | boxes]}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # 札が占める場所。**下に出す様式と年代のぶんも含める** —— 札だけで見ると、
  # 下の札の名前と上の札の年代が重なる
  defp label_box(node) do
    half_width = label_width_of(node) / 2 + @label_gap
    half_height = label_height_of(node) / 2

    %{
      left: node.x - half_width,
      right: node.x + half_width,
      top: node.y - half_height - @label_gap,
      bottom: node.y + half_height + sub_size_of(node) * 2.9 + @label_gap
    }
  end

  defp overlap?(a, b) do
    a.left < b.right and b.left < a.right and a.top < b.bottom and b.top < a.bottom
  end

  @doc """
  選んだ人と、その人に線で繋がっている相手。

  **大きさに関わらず描きます。** 探して寄ったのは周りの関連図を見るためなので、
  相手が小さいという理由で消えては用をなしません（探した本人まで消えることもある）。
  """
  def neighbourhood(_relation, nil), do: MapSet.new()

  def neighbourhood(relation, focus) do
    Enum.reduce(relation.edges, MapSet.new([focus]), fn edge, acc ->
      cond do
        edge.from == focus -> MapSet.put(acc, edge.to)
        edge.to == focus -> MapSet.put(acc, edge.from)
        true -> acc
      end
    end)
  end

  defp visible?(_node, nil), do: true

  defp visible?(node, %{x: x, y: y, w: w, h: h}) do
    margin_x = w * @viewport_margin
    margin_y = h * @viewport_margin

    node.x >= x - margin_x and node.x <= x + w + margin_x and
      node.y >= y - margin_y and node.y <= y + h + margin_y
  end

  # 画面の上での直径。倍率が上がるほど、小さい丸も出てくる
  defp big_enough?(node, nil), do: radius_of(node) * 2 >= @min_drawn_px

  defp big_enough?(node, %{ppu: ppu}) when is_number(ppu) and ppu > 0,
    do: radius_of(node) * 2 * ppu >= @min_drawn_px

  defp big_enough?(_node, _viewport), do: true

  @doc """
  線を引くための座標を、エッジ 1 本につき 1 つ返します。

  **ノードは Map で引きます。** かつてはテンプレートがエッジごとに
  `Enum.find(nodes, ...)` していたので、ノード数 × エッジ数の線形探索になっていました
  （500 人で 25,500 回。人数を増やすほど二乗で効いてきます）。

  **両端が描かれている線だけを引きます。** 片方しか出ていない線は、どこへ向かって
  いるのか読めないまま画面の外へ消えるだけで、数だけが増えます。

  端が見つからないエッジは落とします —— 図に出ていない相手への線は引けません。
  """
  def edge_lines(relation, drawn) do
    by_id = Map.new(drawn, &{&1.id, &1})

    for edge <- relation.edges,
        from = by_id[edge.from],
        to = by_id[edge.to] do
      %{
        x1: from.x,
        y1: from.y,
        x2: to.x,
        y2: to.y,
        kind: edge.kind,
        label: edge.label,
        mid_x: (from.x + to.x) / 2,
        mid_y: (from.y + to.y) / 2 - 8
      }
    end
  end

  @doc """
  名前を入れる札の大きさ。**名前がはみ出さない幅**を `Graph.sized/2` が見積もっています。

  持っていないノード（人物の図）には、以前の丸と同じ大きさの札を返します。
  """
  def label_width_of(node), do: node[:label_width] || radius_of(node) * 2.6
  def label_height_of(node), do: node[:label_height] || radius_of(node) * 1.6

  @doc "丸の半径。知名度が引けていなければ既定の大きさ。"
  def radius_of(node), do: node[:radius] || if(node.kind == :group, do: 47, else: 42)

  @doc """
  名前の字の大きさ。**知名度で 1 人ずつ違う**（`Graph.sized/2` が決める）。

  持っていないノード（人物の図は知名度を引かない）には、以前と同じ大きさを返します。
  """
  def name_size_of(node), do: node[:name_size] || 13

  @doc "様式と年代の字。名前より小さい。"
  def sub_size_of(node), do: node[:sub_size] || 10

  @doc """
  名前を丸の中心からどれだけ上へ置くか。

  **字の大きさに合わせてずらす。** 固定にすると、大きい丸では名前が中心に寄りすぎ、
  小さい丸では様式の札と重なる。
  """
  def name_offset(node), do: Float.round(sub_size_of(node) * 0.3, 1)

  @doc """
  いま押せないかどうか。

  自分が読んでいる間だけでなく、**Chiezo 側で取り込みが走っている間も押させません** ——
  走っている間の「いま集めて」は向こうが断るので、押してから断られることになります。
  """
  def collecting?(%{status: :loading}), do: true
  def collecting?(%{busy: true}), do: true
  def collecting?(_relation), do: false

  @doc """
  ボタンの文字。**何を待っているのかまで出す。**

  押しても数分は Chiezo 側に何も出ません（先に AI へ抽出の指定を書かせるため）。
  「収集中…」だけだと、押せていないのと区別が付きません。
  """
  def collect_label(%{status: :loading} = relation), do: step_text(relation) || "収集中…"
  def collect_label(%{busy: true}), do: "Chiezo が取り込み中…"
  def collect_label(_relation), do: "関連図を収集"

  @doc "いま何をしているか。分からなければ nil。"
  def step_text(%{step: :checking}), do: "収集があるか確かめています…"
  def step_text(%{step: :drafting}), do: "AI に抽出の指定を書かせています…"
  def step_text(%{step: :requesting}), do: "Chiezo に収集を依頼しています…"
  def step_text(%{step: :collecting}), do: "Chiezo に集めさせています…"
  def step_text(%{step: :reading}), do: "溜まったものを読んでいます…"
  def step_text(_relation), do: nil

  @doc "その段でどれくらい待つのか。押した人が席を立ってよいかの目安。"
  def step_note(%{step: :drafting}),
    do:
      "どのカテゴリから引けるかを AI が Chiezo の索引で確かめています。" <>
        "数分から十数分かかり、この間は Chiezo 側にはまだ何も出ません。"

  def step_note(%{step: :collecting}),
    do: "指定どおりに引いて長期記憶へ焼いています。AI は動きません。"

  def step_note(_relation), do: nil

  @doc """
  いまの状態を1文で言う。失敗したときは、直前の図を出していることまで書く。
  """
  def status_message(%{status: :loading}), do: "AIが出典を確認しながら関連図を作成しています。"
  def status_message(%{status: :ready, reason: nil}), do: "AIが収集した情報を表示しています。"
  def status_message(%{status: :sample, reason: nil}), do: "現在は表示例です。収集すると公開情報に基づく図へ更新します。"

  def status_message(%{status: status, reason: reason}) do
    prefix =
      case status do
        :stale -> "前回の収集結果を表示しています。"
        :ready -> "AIが収集した情報を表示しています。"
        _ -> "表示例を表示しています。"
      end

    prefix <> reason_text(reason)
  end

  @doc """
  この図がどこから来るか。**画家は Chiezo に溜まったものを読みます**。

  集めて整理するのは Chiezo の役目で、antenna は図の形に読み直して見せるだけです。
  人物のほうは、まだその場で AI に聞く形のままです。
  """
  def source_note("painters") do
    "この図は Chiezo に溜まった内容から作っています（収集「#{Antenna.Relations.painters_collection()}」）。" <>
      "集めて整理するのは Chiezo で、antenna は図の形にして見せるだけです。"
  end

  def source_note(_view), do: "「関連図を収集」を押すと、その場で AI に調べさせて図を作り直します。"

  defp reason_text(:too_soon), do: "続けて収集しようとしています。少し時間を置いてから押してください。"

  defp reason_text(:chiezo_not_configured),
    do: "CHIEZO_BASE_URL が設定されていないため収集できません。"

  defp reason_text(:chiezo_unavailable), do: "Chiezoに接続できませんでした。"
  defp reason_text({:chiezo_status, status}), do: "Chiezoが #{status} を返しました。"
  defp reason_text(:chiezo_unexpected_body), do: "Chiezoの応答を解釈できませんでした。"

  defp reason_text({:chiezo_refused, status, nil}), do: "Chiezo が依頼を断りました（#{status}）。"

  defp reason_text({:chiezo_refused, _status, message}), do: "Chiezo が依頼を断りました: #{message}"

  defp reason_text(:collect_unsupported),
    do: "この Chiezo には「集める」層がありません。Chiezo を新しくすると使えるようになります。"

  defp reason_text(:collect_disabled),
    do: "Chiezo 側で「集める」層が無効です。CHIEZO_NOTES_DIR と CHIEZO_TRIGGER_URL を設定すると有効になります。"

  defp reason_text(:collection_disabled),
    do:
      "この収集は Chiezo 側で止まっているので、集めさせられませんでした。" <>
        "Chiezo の管理画面の「集める」で有効にすると、押したときに集まります。"

  defp reason_text(:nothing_collected),
    do:
      "Chiezo にまだ何も溜まっていません。Chiezo の管理画面の「集める」で" <>
        "この図の収集を有効にすると、集まったものがここに出ます。"

  defp reason_text(:invalid_ai_response), do: "AIの応答から関連図を作れませんでした。もう一度収集してください。"
  defp reason_text(:collection_crashed), do: "収集の途中で問題が起きました。もう一度収集してください。"
  defp reason_text(:not_requested), do: "Chiezo にこの収集がありません。もう一度押すと作り直します。"
  defp reason_text(nil), do: ""

  # **知らない理由でも、そのまま出す。** 「収集に失敗しました」だけだと、押した人にも
  # 直す人にも何も分からない（実際にこれが出て、原因を画面から辿れなかった）。
  # ここに来るのは自分たちが返した印であって、外から来た文言ではない
  defp reason_text(reason), do: "収集に失敗しました（#{inspect(reason)}）。"
end
