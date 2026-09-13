defmodule AntennaWeb.RelationsLive do
  @moduledoc """
  関連図。収集の進み具合はそのまま画面へ反映します。

  AI に web 検索をさせるので数十秒かかります。押した人に再読み込みをさせず、
  `Antenna.Relations` からの通知で描き直します。
  """

  use AntennaWeb, :live_view

  alias Antenna.Jst
  alias Antenna.Relations
  alias Antenna.Relations.Mark
  alias Antenna.Relations.Marks

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

  # 凡例に並べる様式の数。**全部は並べない** —— 様式は AI が足していくので、
  # 増えるほど凡例が図より長くなる。少ない様式は丸の下の字で読む
  @legend_max 14

  # 札どうしのあいだに空ける幅（図の座標）。0 にすると線がぴったり接して、
  # 2 枚あるのか 1 枚なのか読めなくなる
  @label_gap 2

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "関連図",
       detail: nil,
       artwork: nil,
       edge: nil,
       style_filter: nil,
       # 直近の巡回で動いたものだけを出しているか。**様式の絞り込みとは排他** ——
       # 2 つ重ねると、出ていないものが「動かなかった」のか「別の様式」なのか読めない
       changed_only: false,
       focus_sent: nil,
       backends: [],
       # 「見た」印。**ノード名で引く** —— 図は読み直すたびに id が振り直されるので、
       # id で持つと印が別人へ移る
       marks: %{},
       mark_saved: nil,
       # 巡回ごとに選んだ相手。**サーバー側で覚える** —— 覚えないと、図が届いた
       # 拍子にフォームが描き直されて、選んだところが元の値に戻る（選んだつもりで
       # 押すと、いま入っている値がそのまま送り返される）
       picks: %{}
     )
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
      # **開くたびには取り直さない。** 8,000 人ぶんを読むので数秒かかるうえ、
      # Chiezo の側は数時間に 1 度しか動かない —— 開いた回数だけ待たされる意味が無い。
      # まだ 1 度も読めていないときだけ取りに行き、あとは「最新の情報を取得」で
      if Relations.current(view)[:checked_at] == nil, do: Relations.refresh(view)
    end

    socket =
      assign(socket,
        view: view,
        relation: Relations.current(view),
        # 印は図ごとに別。切り替えたら引き直す
        marks: Marks.for_view(view),
        mark_saved: nil
      )

    # 相手の一覧は**繋がってから、待たずに**引く。画面の中で同期に引くと、Chiezo が
    # 遅いあいだページが固まる（選択肢が無くても図は読めるので、待つ価値が無い）
    {:noreply,
     if(connected?(socket),
       do: start_async(socket, :backends, &Relations.ai_backends/0),
       else: socket
     )}
  end

  @impl true
  # 「収集の設定を更新」。**画面で選んだ相手を一緒に送る** ——
  # antenna は覚えない（正は Chiezo が持っているもの）ので、押したときに載せる
  def handle_event("collect", params, socket) do
    Relations.collect_now(socket.assigns.view, picks(socket, params))
    {:noreply, socket}
  end

  # 選び直したら、その場で覚える。**送るのは押したときだけ**で、ここでは何もしない。
  #
  # **ここでは覚えているほうを勝たせない。** この事象そのものが選び直しなので、
  # 前に覚えた値を優先すると、一度覚えた欄を二度と変えられなくなる ——
  # 相手を選んだ拍子に「考える量: 空」まで覚えてしまい、そのあと考える量を選んでも
  # 空のまま送られていた（画面では選べているように見えるので、押すまで気づけない）。
  # フォームは変更のたびに丸ごと届くので、この控えだけで全部の欄が揃う
  def handle_event("pick_sweep", params, socket),
    do: {:noreply, assign(socket, picks: sweep_choices(params))}

  # モーダルから「この画家を詳しく調べて」を Chiezo へ割り込ませる。
  # **定時の巡回には触らない**ので、待たずに頼める
  def handle_event("focus_painter", %{"name" => name} = params, socket) do
    Relations.focus_painter(socket.assigns.view, name, focus_note(name, params["note"]))
    {:noreply, assign(socket, focus_sent: name)}
  end

  def handle_event("show_node", %{"name" => name}, socket) do
    node = Enum.find(socket.assigns.relation.nodes, &(&1.name == name))

    cond do
      node == nil ->
        {:noreply, socket}

      # もう一度押したら閉じる
      detail_name(socket.assigns.detail) == name ->
        {:noreply, assign(socket, detail: nil, artwork: nil, mark_saved: nil)}

      works_of(node) == [] ->
        # 絵が無いことは分かっているので、探しているふりをしない
        {:noreply,
         assign(socket, detail: node, artwork: [], edge: nil, focus_sent: nil, mark_saved: nil)}

      true ->
        works = works_of(node)

        {:noreply,
         socket
         |> assign(detail: node, artwork: :loading, edge: nil, focus_sent: nil, mark_saved: nil)
         |> start_async(:artwork, fn ->
           works |> Enum.map(&Antenna.Artwork.lookup/1) |> Enum.reject(&is_nil/1)
         end)}
    end
  end

  # 影響の線を押したら、**何をもって影響元としたか**を出す。
  #
  # 出せるのは AI が書いた一言と、両者の記事へのリンクだけ。**それを隠さない** ——
  # 影響関係は Wikipedia に書いていないので機械では引けず、ここは AI の判断そのもの。
  # 根拠を確かめたい人が記事へ行けることが、いま渡せる最良のもの。
  def handle_event("show_edge", %{"from" => from, "to" => to} = params, socket) do
    nodes = Map.new(socket.assigns.relation.nodes, &{&1.id, &1})
    kind = if params["kind"] == "influence", do: :influence, else: :related

    edge =
      Enum.find(socket.assigns.relation.edges, fn e ->
        e.from == from and e.to == to and e.kind == kind
      end)

    if edge && nodes[from] && nodes[to] do
      {:noreply,
       assign(socket,
         edge: %{from: nodes[from], to: nodes[to], label: edge.label, kind: kind},
         detail: nil,
         artwork: nil
       )}
    else
      {:noreply, socket}
    end
  end

  # 凡例を押したら、その様式だけにする。**もう一度押すと戻る**
  def handle_event("filter_style", %{"style" => style}, socket) do
    style = String.trim(style)
    next = if style == "" or socket.assigns.style_filter == style, do: nil, else: style
    # 絞り込みを変えたら見ている場所も倍率も意味を失うので、図を初めから見せ直す
    {:noreply, assign(socket, style_filter: next, changed_only: false, viewport: nil, focus: nil)}
  end

  # 直近の巡回で動いたものだけにする。**もう一度押すと戻る**（凡例と同じ押し方）
  def handle_event("filter_changed", _params, socket) do
    {:noreply,
     assign(socket,
       changed_only: not socket.assigns.changed_only,
       style_filter: nil,
       viewport: nil,
       focus: nil
     )}
  end

  # 「見た」印とメモを書く。**空にしたら消える** —— 何も書かれていない印が
  # 残っていると、図の上で見たものと見分けが付かない
  def handle_event("save_mark", %{"name" => name} = params, socket) do
    attrs = %{
      # チェックが外れているとキーごと来ない（HTML のチェックボックス）
      "seen" => params["seen"] == "on",
      "seen_on" => blank_to_nil(params["seen_on"]),
      "note" => params["note"] || ""
    }

    case Marks.put(socket.assigns.view, name, attrs) do
      {:ok, mark} ->
        marks =
          if mark,
            do: Map.put(socket.assigns.marks, name, mark),
            else: Map.delete(socket.assigns.marks, name)

        {:noreply, assign(socket, marks: marks, mark_saved: name)}

      {:error, _changeset} ->
        # 書けなかったことは黙って捨てない。押した人には確かめようがない
        {:noreply, put_flash(socket, :error, "メモを保存できませんでした。")}
    end
  end

  # 閉じ方は3つとも同じところへ来る（ボタン・図の外を押す・Esc）
  def handle_event("close_work", _params, socket) do
    {:noreply, assign(socket, detail: nil, artwork: nil, edge: nil, mark_saved: nil)}
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
    {:noreply, focus_node(socket, name)}
  end

  # 見た印を付けたものへ寄る。**名前を思い出せなくても行き先が選べる**のが、
  # この口の役目 —— 探す欄は名前を打てる人のためのもので、
  # 「前に見たあの画家」を探すのには使えない
  def handle_event("focus_marked", %{"name" => name}, socket) do
    {:noreply, focus_node(socket, name)}
  end

  # **取り直す口。** 開くたびに聞きに行くのをやめた代わりに、押したときだけ取りに行く
  def handle_event("reload", _params, socket) do
    Relations.refresh(socket.assigns.view)
    {:noreply, socket}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, assign(socket, query: "", matches: [], focus: nil)}
  end

  # 名前に含まれるかで探し、**知られている順**に返す。前方一致にしないのは、
  # 「ゴッホ」で「フィンセント・ファン・ゴッホ」を出したいため
  @doc """
  割り込みの指示文。**必ず画家の名前で始めます**。

  名指しは `titles` で別に渡していて、Chiezo はそちらを見てプロンプトへ載せます。
  ただし**指示文だけを読んだ人には誰宛てか分からない** —— 「影響元が空なので調べて」
  とだけ書くと、Chiezo の画面にもそれしか残りません。
  """
  def focus_note(name, note) do
    case String.trim(note || "") do
      "" -> "#{name}について、影響を受けた画家と代表作を詳しく調べて埋めてください。"
      written -> "#{name}について。#{written}"
    end
  end

  # ノードを押したら、その人のことを出す。**代表作を持っていなくても押せる** ——
  # 押せる丸と押せない丸が混じっていると、押しても何も起きない丸を何度も押すことになる。
  # 出すのは、もとになった記事・Chiezo に入っているタグ・（あれば）代表作の絵。
  #
  # **絵は押されたときだけ引く** —— 先に集めると、見ない絵まで毎回取りに行くことになる
  defp focus_node(socket, name) do
    case Enum.find(socket.assigns.relation.nodes, &(&1.name == name)) do
      nil ->
        socket

      node ->
        socket
        |> assign(focus: node.id, query: name, matches: [])
        |> push_event("focus", %{x: node.x, y: node.y})
    end
  end

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
  def handle_async(:backends, {:ok, list}, socket) when is_list(list) do
    {:noreply, assign(socket, backends: list)}
  end

  # 引けなくても図は出る。**選べないだけ**
  def handle_async(:backends, _result, socket), do: {:noreply, socket}

  def handle_async(:artwork, {:ok, result}, socket) do
    {:noreply, assign(socket, artwork: result)}
  end

  def handle_async(:artwork, {:exit, _reason}, socket) do
    # **空の一覧にする。** nil にすると「探している最中」と見分けが付かない
    {:noreply, assign(socket, artwork: [])}
  end

  # 押したときに送る値。**覚えているほうを勝たせる** —— 画面が描き直されると
  # フォームはサーバーが言うとおりに戻るので、覚えているものが選んだ本人の意思に近い。
  # 一度も選んでいなければ、いま出ている値（＝ Chiezo に入っている値）がそのまま返る。
  #
  # **選び直し（`pick_sweep`）では使わない。** あちらはフォームのほうが新しい
  defp picks(socket, params),
    do: Map.merge(sweep_choices(params), socket.assigns.picks, fn _name, from_form, remembered ->
      Map.merge(from_form, remembered)
    end)

  # `sweep|ざっと|backend` の形で届くものを、巡回ごとにまとめ直す
  defp sweep_choices(params) do
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
      {"溜まった数", "#{c.docs} 件"},
      {"区画", if(c[:partitions_total] in [nil, 0], do: "まだ割っていません", else: "#{c.partitions_total}")},
      {"進み具合", if(c.cursor == "", do: "（まだ無し。次は一気に作ります）", else: c.cursor)},
      # 集まるものが変わらなかった日でも、**押した結果はここが動く**
      {"最後に確かめた", Jst.format(relation[:checked_at]) || "まだ確かめていません"}
    ]
  end

  def collection_facts(_relation), do: []

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
  def sweep_rows(%{collection: %{sweeps: sweeps}} = relation) when sweeps != [],
    do: Enum.map(sweeps, &sweep_row(&1, relation))

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

  def sweep_rows(_relation), do: []

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
    do: "いま Chiezo が持っている内容です。"

  def prompt_note(_relation),
    do: "まだ Chiezo に収集がありません。「収集の設定を更新」を押すと、この内容で作ります。"

  alias Antenna.Relations.Graph

  @doc """
  丸に当てる色。様式を持たない画家には当てません（白のまま）。

  **薄く塗って、枠線だけ濃くします。** 名前を読むのが先なので、塗りを濃くすると
  字が読みにくくなる —— 色は「同じ派閥か」を見分けるための印で、主役ではない。
  """
  def hue_style(node) do
    case Graph.hue_of(node) do
      nil -> nil
      hue -> "fill: hsl(#{hue} 62% 92%); stroke: hsl(#{hue} 45% 58%)"
    end
  end

  @doc """
  色の凡例に出す様式（多い順）。**全部は並べません**（`@legend_max`）——
  様式は AI が足していくので、増えるほど凡例が図より長くなります。
  """
  def style_legend(relation), do: Enum.take(relation[:styles] || [], @legend_max)

  @doc """
  いま描く図。**絞り込みが掛かっていれば、その人たちだけで置き直したもの**を返します。

  位置をもとのままにして絞ると、数十人が高さ 2,500 の面に散らばって拡大しないと
  読めません（絞った意味が無い）。
  """
  def shown(relation, %{changed_only: true}), do: Graph.only_changed(relation)
  def shown(relation, %{style_filter: style}), do: Graph.only(relation, style)

  @doc """
  割り込み（この画家を詳しく調べて）の届き具合。**断られたことも出します**。

  取り込みが走っている間の割り込みは Chiezo が受け付けません。黙って捨てると
  「頼んだのに何も起きない」だけが残り、押した人には確かめようがない
  （実際、定時の巡回が走っている最中に押して、そのまま消えていた）。
  """
  def focus_state(relation, painter) do
    case relation[:focus] do
      %{painter: ^painter} = focus -> focus
      _ -> nil
    end
  end

  @doc "割り込みが断られた理由の一文。"
  def focus_error(%{reason: reason}), do: reason_text(reason)
  def focus_error(_focus), do: nil

  @doc """
  直近の巡回で動いたものの一言。動いたものが無ければ nil。

  **時刻と件数の両方を出す** —— 件数だけではいつの話か分からず、時刻だけでは
  何件動いたのか分からない。**最初の一括作成では出ません**（全部が同じ刻みなので、
  比べる先が無い）。
  """
  def changed_note(%{changed: count, changed_at: at}) when is_integer(count) and count > 0,
    do: "#{Jst.format(at)} の巡回で #{count} 件が動きました"

  def changed_note(_relation), do: nil

  @doc "その画家の代表作（無ければ空）。**印を出すかの判断もここを見る**。"
  def works_of(node), do: node[:works] || []

  @doc "いま開いている人の名前（開いていなければ nil）。"
  def detail_name(nil), do: nil
  def detail_name(node), do: node[:name]

  @doc """
  見た印の付いた行き先。**図に出ているものだけ**を並べます ——
  選んでも動かない行き先を混ぜると、押し間違えたのか壊れているのか読めません。

  並びは見た日の新しい順（日付を書いていないものは後ろ）。
  """
  def seen_options(relation, marks) do
    names = MapSet.new(relation.nodes, & &1.name)

    marks
    |> Enum.filter(fn {name, _mark} -> MapSet.member?(names, name) end)
    |> Enum.sort_by(fn {name, mark} -> {seen_order(mark), name} end)
    |> Enum.map(fn {name, mark} -> {name, seen_label(name, mark)} end)
  end

  # 日付を書いていないものは後ろ。**書いた順では並べない** ——
  # 後から日付だけ直したときに、並びが書いた順のまま残る
  defp seen_order(%Mark{seen_on: %Date{} = date}), do: {0, -Date.to_gregorian_days(date)}
  defp seen_order(_mark), do: {1, 0}

  defp seen_label(name, %Mark{seen_on: %Date{} = date}), do: "#{name}（#{Date.to_iso8601(date)}）"
  defp seen_label(name, _mark), do: name

  @doc """
  数える単位。図ごとに並んでいるものが違うので、口の名前もそれに合わせます。
  """
  def unit_of("painters"), do: "画家"
  def unit_of(_view), do: "人"

  @doc """
  いつ読んだか。**開くたびに取り直さない**ので、いま見ているものの古さが読めないと困ります。
  """
  def checked_text(%{checked_at: at}) when at != nil, do: "最後に取得: #{Jst.format(at)}"
  def checked_text(_relation), do: "まだ取得していません"

  @doc """
  そのノードに付いている「見た」印。まだ無ければ空の印を返します。

  空を返すのは、**フォームを 2 通り書かずに済ませる**ため —— 初めて書く人と
  書き直す人で見た目が変わる理由が無い。
  """
  def mark_of(marks, name), do: Map.get(marks, name) || %Mark{}

  @doc "印が付いているか。図の上の目印と、札の出し分けに使う。"
  def marked?(marks, name), do: Map.has_key?(marks, name)

  @doc """
  「見た日」の欄に最初から入れておく日付。

  既に書いてあるならそれを、無ければ**日本時間の今日**を入れます ——
  展覧会から帰って書くことがほとんどなので、打ち直さずに済む側へ寄せます。
  """
  def seen_on_value(%Mark{seen_on: %Date{} = date}), do: Date.to_iso8601(date)
  def seen_on_value(_mark), do: Jst.today() |> Date.to_iso8601()

  @doc "印を1行で言う（ノードの札の下に出す）。"
  def mark_summary(%Mark{seen: true, seen_on: %Date{} = date}),
    do: "見た（#{Date.to_iso8601(date)}）"

  def mark_summary(%Mark{seen: true}), do: "見た"
  def mark_summary(%Mark{note: note}) when is_binary(note) and note != "", do: "メモあり"
  def mark_summary(_mark), do: nil

  # 空欄は「入れていない」。空文字のまま渡すと日付として読めずに弾かれる
  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank_to_nil(value), do: value

  @doc """
  その画家について Chiezo に入っているタグを、読める形に分けます。

  **そのまま並べない** —— 「関連」は多い人で数十件あり、しかも図の上に線として
  出ているので、一覧で繰り返す意味が薄い。押した人が知りたいのは
  「どういう条件でこの人が名簿に入り、何が分かっているのか」のほう。
  """
  def tag_groups(node) do
    tags = node[:tags] || []

    [
      {"年代", for(t <- tags, v = strip(t, "年代:"), do: v)},
      {"様式", for(t <- tags, v = strip(t, "様式:"), do: v)},
      {"代表作", for(t <- tags, v = strip(t, "代表作:"), do: v)},
      {"影響元", for(t <- tags, v = strip(t, "影響元:"), do: v)},
      {"その他", for(t <- tags, plain_tag?(t), do: t)}
    ]
    |> Enum.reject(fn {_label, values} -> values == [] end)
  end

  defp strip(tag, prefix) do
    case tag do
      ^prefix <> rest -> rest
      _ -> nil
    end
  end

  # 頭に区分の付いていないタグ（「画家」など）。**関連は出さない**（線で見えている）
  defp plain_tag?(tag) do
    not Enum.any?(~w(年代: 様式: 代表作: 影響元: 関連:), &String.starts_with?(tag, &1))
  end

  @doc "その画家の Wikipedia の記事。**代表作ではなく画家を指す**。"
  def article_url(node) do
    node[:url] ||
      if title = node[:article] do
        "https://ja.wikipedia.org/wiki/" <> URI.encode(String.replace(title, " ", "_"))
      end
  end

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
        # 押されたときに誰と誰の線かを引き当てる
        from: edge.from,
        to: edge.to,
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
  ボタンを押させない場面。**押して送っている最中だけ**。

  かつては「開いたときの読み直し中」と「Chiezo で取り込みが走っている間」も止めて
  いた。前者は読むだけなので止める理由が無く（開くたびに数秒押せなくなっていた）、
  後者は**ボタンが集めさせていた頃の名残**です —— いまは送るだけなので、取り込みが
  走っていても困りません。
  """
  def collecting?(%{pushing: true}), do: true
  def collecting?(_relation), do: false

  @doc """
  ボタンの文字。**何を待っているのかまで出す。**

  押しても数分は Chiezo 側に何も出ません（先に AI へ抽出の指定を書かせるため）。
  「収集中…」だけだと、押せていないのと区別が付きません。
  """
  def collect_label(%{pushing: true} = relation), do: step_text(relation) || "送っています…"
  def collect_label(_relation), do: "収集の設定を更新"

  @doc """
  Chiezo 側で取り込みが走っているときの一言。**止めるためではなく、知らせるため**。

  走っている最中は図がもうすぐ変わるので、いま読んでいるものが最新でないと分かる。
  ボタンは止めない（押しても送るだけで、走らせはしない）。
  """
  def busy_note(%{busy: true}),
    do: "いま Chiezo が取り込み中です。終わると図が変わります。"

  def busy_note(_relation), do: nil

  @doc "いま何をしているか。分からなければ nil。"
  def step_text(%{step: :checking}), do: "収集があるか確かめています…"
  def step_text(%{step: :requesting}), do: "Chiezo に収集を依頼しています…"
  def step_text(%{step: :pushing}), do: "Chiezo の設定を書き換えています…"
  def step_text(%{step: :collecting}), do: "Chiezo に集めさせています…"
  def step_text(%{step: :reading}), do: "溜まったものを読んでいます…"
  def step_text(_relation), do: nil

  @doc "その段でどれくらい待つのか。押した人が席を立ってよいかの目安。"
  def step_note(%{step: :collecting}),
    do: "指定どおりに引いて長期記憶へ焼いています。AI は動きません。"

  def step_note(_relation), do: nil

  @doc """
  図の代わりに出す一言（まだ本物を読めていないとき）。

  **表示例の図は描きません。** 本物と見分けが付かないので、読み込みが終わるまで
  5 人の関連図が出て「これは何」になります。読めない理由があればそれを、
  無ければ何を待っているかを出します。
  """
  def sample_message(%{reason: reason} = relation) when reason != nil,
    do: status_message(relation)

  def sample_message(%{status: :loading}), do: "Chiezo から読み込んでいます…"

  def sample_message(_relation),
    do: "まだ読み込んでいません。Chiezo に溜まったものを読むとここに図が出ます。"

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
      "**集めるのは Chiezo が決まった間隔で回します。** このボタンは、" <>
      "antenna が持っている依頼文と回り方を Chiezo へ送り直すだけで、集めさせはしません。"
  end

  def source_note(_view), do: "「関連図を収集」を押すと、その場で AI に調べさせて図を作り直します。"

  defp reason_text(:too_soon), do: "続けて収集しようとしています。少し時間を置いてから押してください。"

  defp reason_text(:chiezo_not_configured),
    do: "CHIEZO_BASE_URL が設定されていないため収集できません。"

  defp reason_text(:chiezo_busy),
    do:
      "いま Chiezo が取り込み中なので、割り込みを受け付けてもらえませんでした。" <>
        "終わってからもう一度押してください。"

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

  defp reason_text(:collection_missing),
    do:
      "この図の収集は、まだ Chiezo に作られていません。" <>
        "「関連図を収集」を押すと、Chiezo に依頼して作ります。"

  defp reason_text(:nothing_collected),
    do:
      "Chiezo にまだ何も溜まっていません。Chiezo の管理画面の「集める」で" <>
        "この図の収集を有効にすると、集まったものがここに出ます。"

  # **指定が書けなければ収集を作らない。** 作ってしまうと、名簿が空のまま AI に
  # 「いまの内容から 10 人ほど選べ」と頼むことになり、10 件の図ができて終わる
  # （実測）。そのとき押した人には、なぜそうなったのかが読めない
  defp reason_text({:extract_failed, _detail}),
    do:
      "Wikipedia から機械的に引く条件を AI に書かせられませんでした。" <>
        "収集は作っていません。もう一度押すか、相手を変えて試してください。"

  defp reason_text(:invalid_ai_response), do: "AIの応答から関連図を作れませんでした。もう一度収集してください。"
  defp reason_text(:collection_crashed), do: "収集の途中で問題が起きました。もう一度収集してください。"
  defp reason_text(:not_requested), do: "Chiezo にこの収集がありません。もう一度押すと作り直します。"
  defp reason_text(nil), do: ""

  # **知らない理由でも、そのまま出す。** 「収集に失敗しました」だけだと、押した人にも
  # 直す人にも何も分からない（実際にこれが出て、原因を画面から辿れなかった）。
  # ここに来るのは自分たちが返した印であって、外から来た文言ではない
  defp reason_text(reason), do: "収集に失敗しました（#{inspect(reason)}）。"
end
