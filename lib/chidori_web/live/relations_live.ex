defmodule ChidoriWeb.RelationsLive do
  @moduledoc """
  関連図。収集の進み具合はそのまま画面へ反映します。

  AI に web 検索をさせるので数十秒かかります。押した人に再読み込みをさせず、
  `Chidori.Relations` からの通知で描き直します。
  """

  use ChidoriWeb, :live_view

  import ChidoriWeb.Collect
  import ChidoriWeb.CollectPanel
  import ChidoriWeb.RecentRuns, only: [recent_runs: 1]

  alias Chidori.Jst
  alias Chidori.Relations
  alias Chidori.Relations.CarrySetting
  alias Chidori.Relations.FilmCarry
  alias Chidori.Relations.Films
  alias Chidori.Relations.Mark
  alias Chidori.Relations.Marks

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
       # 押した画家の記事の先頭画像（自画像や写真）。nil / :loading / 見つかったもの / :none
       portrait: nil,
       edge: nil,
       style_filter: nil,
       # 直近の巡回で動いたものだけを出しているか。**様式の絞り込みとは排他** ——
       # 2 つ重ねると、出ていないものが「動かなかった」のか「別の様式」なのか読めない
       changed_only: false,
       # レビューの有無で絞っているか（nil / "reviewed" / "unreviewed"）。
       # **ほかの絞り込みとは排他**（重ねると、出ていない理由が読めない）
       review_filter: nil,
       focus_sent: nil,
       # 1 回押した札の名前（その札と線と線の先を目立たせる。もう一度押すと詳細が開く）。
       # **名前で持つ** —— 図は読み直すたびに id が振り直される（印と同じ理由）
       picked: nil,
       # 1 回押した線（`{from, to, kind}`）。その線と両端を立たせる。共通項の線（同じ監督・
       # 同じ主演）なら、その人の作品だけを鎖ごと立たせる。もう一度押すと詳細
       picked_edge: nil,
       # 開いている作品の主演のうち、芸能人の図に載っている人（映画の図。押すとその人へ飛ぶ）
       star_people: MapSet.new(),
       # URL の `focus` で名指しされた人。**図がまだ読めていなければ、読めたときに寄る**
       pending_focus: nil,
       # 名簿を引き直した結果の一言（芸能人の図）
       reroster_message: nil,
       # 設定欄。**開いたときだけ Chiezo から読む**（図を開くたびには読まない）。
       # settings は nil（まだ）/ :loading / 読めたもの / {:error, 理由}
       settings_open: false,
       settings: nil,
       # この図の収集の最近の回（収集の画面を開いたときに読む）
       recent_runs: [],
       # 「見た」印。**ノード名で引く** —— 図は読み直すたびに id が振り直されるので、
       # id で持つと印が別人へ移る
       marks: %{},
       # 置き場にある記録そのもの（見出し → 記録）。`marks` は図の札の名前で引ける形に
       # 直したもので、映画の図では見出しが札の名前と違うことがある（`Films.marks_by_node/2`）
       raw_marks: %{},
       # 映画の図で、まだ図に載っていない見た記録（見出し → 記録）
       unplaced_marks: %{},
       # 「見た映画を足す」の結果の一言
       film_added: nil,
       # 引き継ぎの時計の設定と前回の記録・次の予定（映画の図で開いたときに読む。
       # 時刻と 1 回の数を直すのは収集の画面（`/collect`））
       carry_setting: nil,
       carry_next: nil,
       # 引き継ぎを待っている作品（nil = まだ読んでいない / :loading / 一覧 / {:error, 理由}）。
       # **押したときだけ Chiezo に聞く**（図を開くたびには聞かない）
       carry_pending: nil,
       # 「いま頼む」の結果の一言
       carry_message: nil,
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

  @doc """
  「最後に取得」と「最新の情報を取得」の行。**関連図の画面では見出しの下、
  トップページに埋め込んだときは図の下**に置く（`embed`）。
  """
  attr :relation, :map, required: true

  def checked_line(assigns) do
    ~H"""
    <%!-- **開くたびには取りに行かない。** 8,000 人ぶんを読むので数秒かかるのに、
       Chiezo の側は数時間に 1 度しか動かない。いつのものを見ているかを出して、
       取り直すかは読む人に決めてもらう --%>
    <p class="relation-checked">
      <span class="muted-note">
        <%= if at = @relation[:checked_at] do %>
          最後に取得: <strong>{Jst.format(at)}（{Jst.ago(at)}）</strong>
        <% else %>
          まだ取得していません
        <% end %>
      </span>
      <%!-- **取り直しの最中も印を出す。** 読むのは `status` が :loading のあいだで、
         収集の途中経過（`step`）だけを見ていた頃は、取得中もボタンが押せるままで
         押したのかどうかが分からなかった --%>
      <% loading = reloading?(@relation) %>
      <button
        type="button"
        phx-click="reload"
        disabled={loading}
        aria-busy={if loading, do: "true"}
        class={if loading, do: "is-loading"}
      >
        {if loading, do: "取得しています…", else: "最新の情報を取得"}
      </button>
    </p>
    """
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # **どれを最初に開くかは 1 か所で決める**（`Relations.valid_key/1`）——
    # ここにも既定を書くと、片方だけ直したときに URL の有無で別の図が出る
    # 対象なしで（か知らない対象で）開いたら、関連図のタブの先頭（芸術家は趣味に並べるので外す）
    view =
      if Relations.chiezo_view?(params["view"]),
        do: params["view"],
        else: Relations.relation_views() |> hd() |> elem(0)

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

    # **収集の画面**（`/collect/relations`）か、図を見る画面か。収集の画面は設定を開いた形で出す
    collect_mode = socket.assigns.live_action == :collect

    socket =
      assign(socket,
        view: view,
        collect_mode: collect_mode,
        base_path: if(collect_mode, do: "/collect/relations", else: "/relations"),
        # トップページに埋め込まれているか（頭のメニューとタブと設定を出さない）
        embed: params["embed"] == "1",
        relation: Relations.current(view),
        mark_saved: nil,
        film_added: nil,
        carry_pending: nil,
        carry_message: nil,
        # 図を切り替えたら設定は読み直す（別の収集のもの）
        settings_open: false,
        settings: nil,
        recent_runs: [],
        pending_focus: params["focus"],
        detail: nil,
        edge: nil
      )
      # 印は図ごとに別。切り替えたら引き直す
      |> with_marks(Marks.for_view(mark_view(view)))
      |> load_carry()

    # 収集の画面は設定を開いた形で出す（開いたときに Chiezo から読む）
    socket =
      if collect_mode and connected?(socket),
        do: socket |> assign(settings_open: true) |> load_settings(),
        else: socket

    {:noreply, apply_pending_focus(socket)}
  end

  # URL の `focus` で名指しされた人へ寄り、詳細を開く（映画の図の主演から飛んできたとき）。
  # **図がまだ読めていなければ待つ**（読めたら `:relation_updated` でもう一度試す）
  defp apply_pending_focus(%{assigns: %{pending_focus: name}} = socket) when is_binary(name) do
    case Enum.find(socket.assigns.relation[:nodes] || [], &(&1.name == name)) do
      nil ->
        socket

      node ->
        socket
        |> assign(pending_focus: nil)
        |> focus_node(name)
        |> open_detail(node)
    end
  end

  defp apply_pending_focus(socket), do: socket

  # 未レビューの画家の区画を、先にざっと見てもらう。**区画は押したときに割り出す**
  # （区画の一覧は設定なので、図を開いただけでは読んでいない）
  def handle_event("focus_painter_partition", %{"name" => name}, socket) do
    case Enum.find(socket.assigns.relation.nodes, &(&1.name == name)) do
      nil -> :ok
      node -> Relations.focus_painter_partition(socket.assigns.view, name, node[:tags])
    end

    {:noreply, socket}
  end

  # **この区画を先に調べて、を頼む。** 区画を名指しするので、その区画には印が付く
  # —— 先に見てほしいと頼んだのだから、巡回が同じところをもう一度見る必要は無い
  # **どの巡回として頼むかを選べる。** 整理（漏れ探しと磨き）のほかに、
  # 未レビューの人が残る区画を「先にざっと見て」と頼める
  def handle_event("focus_partition", %{"key" => key} = params, socket) do
    sweep = params["sweep"] || Relations.survey_sweep()

    Relations.focus_partition(
      socket.assigns.view,
      key,
      partition_note(key, params["note"], sweep),
      sweep
    )

    {:noreply, socket}
  end

  # **取り直す口。** 開くたびに聞きに行くのをやめた代わりに、押したときだけ取りに行く
  def handle_event("reload_recent_runs", _params, socket),
    do: {:noreply, load_recent_runs(socket)}

  def handle_event("reload", _params, socket) do
    Relations.refresh(socket.assigns.view)
    {:noreply, socket}
  end

  @impl true
  # 「収集の設定を更新」。**画面で選んだ相手を一緒に送る** ——
  # Chidori は覚えない（正は Chiezo が持っているもの）ので、押したときに載せる
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
  # 名簿の知名度の下限を変えて、名簿を引き直す（芸能人・映画の図）。**選べる値だけ受ける**
  def handle_event("reroster", %{"min" => min}, socket) do
    with true <- socket.assigns.view in ["people", "films"],
         {value, ""} <- Integer.parse(to_string(min)),
         true <- value in Chidori.Relations.Settings.choices(),
         :ok <- Relations.reroster(socket.assigns.view, value) do
      {:noreply,
       assign(socket,
         reroster_message: "月 #{delimit(value)} 以上で名簿を引き直すよう頼んでいます…"
       )}
    else
      {:error, reason} -> {:noreply, assign(socket, reroster_message: relation_reason(reason))}
      _bad -> {:noreply, socket}
    end
  end

  def handle_event("pick_sweep", params, socket),
    do: {:noreply, assign(socket, picks: sweep_choices(params))}

  # モーダルから「この画家を詳しく調べて」を Chiezo へ割り込ませる。
  # **定時の巡回には触らない**ので、待たずに頼める
  def handle_event("focus_painter", %{"name" => name} = params, socket) do
    Relations.focus_painter(socket.assigns.view, name, focus_note(name, params["note"]))
    {:noreply, assign(socket, focus_sent: name)}
  end

  # 消えた画家を「戻して」と頼む。**名指しの割り込み**なので、消えた状態の
  # 中身と消した理由が必ず AI に見せられる
  def handle_event("restore_painter", %{"name" => name} = params, socket) do
    reason =
      Enum.find_value(socket.assigns.relation[:removed] || [], "", fn
        %{name: ^name, reason: reason} -> reason
        _other -> nil
      end)

    Relations.focus_painter(socket.assigns.view, name, restore_note(name, reason, params["note"]))
    {:noreply, assign(socket, focus_sent: name)}
  end

  def handle_event("show_node", %{"name" => name}, socket) do
    node = Enum.find(socket.assigns.relation.nodes, &(&1.name == name))

    cond do
      node == nil ->
        {:noreply, socket}

      # 詳細が開いている札をもう一度押したら閉じる
      detail_name(socket.assigns.detail) == name ->
        {:noreply, assign(socket, detail: nil, artwork: nil, portrait: nil, mark_saved: nil)}

      # 目立たせている札をもう一度押したら詳細を開く
      socket.assigns.picked == name ->
        {:noreply, open_detail(socket, node)}

      # 1 回目は、その札と線と線の先を目立たせるだけ（トピックの網と同じ押し方）。
      # いきなり詳細を開くと、図の上でどこと繋がっているかを見る前に覆われる
      true ->
        {:noreply, assign(socket, picked: name, picked_edge: nil)}
    end
  end

  # 余白を押したら目立たせるのをやめる（`relation_map.js`）
  def handle_event("unpick", _params, socket),
    do: {:noreply, assign(socket, picked: nil, picked_edge: nil)}

  # 影響の線を押したら、**何をもって影響元としたか**を出す。
  #
  # 出せるのは AI が書いた一言と、両者の記事へのリンクだけ。**それを隠さない** ——
  # 影響関係は Wikipedia に書いていないので機械では引けず、ここは AI の判断そのもの。
  # 根拠を確かめたい人が記事へ行けることが、いま渡せる最良のもの。
  def handle_event("show_edge", %{"from" => from, "to" => to} = params, socket) do
    nodes = Map.new(socket.assigns.relation.nodes, &{&1.id, &1})

    # **知っている種類だけ読む**（画面から来る値なので、そのまま atom にしない）
    kind =
      Map.get(
        %{
          "influence" => :influence,
          "family" => :family,
          "spouse" => :spouse,
          "duo" => :duo,
          "costar" => :costar,
          "director" => :director,
          "group" => :group
        },
        params["kind"],
        :related
      )

    edges = socket.assigns.relation.edges
    edge = Enum.find(edges, fn e -> e.from == from and e.to == to and e.kind == kind end)

    key = {from, to, kind}

    cond do
      edge == nil or nodes[from] == nil or nodes[to] == nil ->
        {:noreply, socket}

      # **1 回目は立たせるだけ**（札と同じ押し方）。共通項の線（同じ監督・同じ主演）なら、
      # その人の作品だけを鎖ごと立たせる —— 札を押したときは札の共通項の全部が立つので、
      # 1 人に絞って見たいときの口になる。いきなり詳細を開くと、図の上で鎖を見る前に覆われる
      socket.assigns.picked_edge != key ->
        {:noreply, assign(socket, picked: nil, picked_edge: key, edge: nil)}

      # もう一度押したら詳細
      true ->
        {:noreply, open_edge(socket, edge, nodes, from, to, kind)}
    end
  end

  # 凡例を押したら、その様式だけにする。**もう一度押すと戻る**
  def handle_event("filter_style", %{"style" => style}, socket) do
    style = String.trim(style)
    next = if style == "" or socket.assigns.style_filter == style, do: nil, else: style

    # 絞り込みを変えたら見ている場所も倍率も意味を失うので、図を初めから見せ直す
    {:noreply,
     assign(socket,
       style_filter: next,
       changed_only: false,
       review_filter: nil,
       viewport: nil,
       focus: nil
     )}
  end

  # 直近の巡回で動いたものだけにする。**もう一度押すと戻る**（凡例と同じ押し方）
  def handle_event("filter_changed", _params, socket) do
    {:noreply,
     assign(socket,
       changed_only: not socket.assigns.changed_only,
       review_filter: nil,
       style_filter: nil,
       viewport: nil,
       focus: nil
     )}
  end

  # レビュー済みだけ / 未レビューだけにする。**同じものをもう一度押すと戻る**
  def handle_event("filter_review", %{"only" => only}, socket)
      when only in ["reviewed", "unreviewed"] do
    {:noreply,
     assign(socket,
       review_filter: if(socket.assigns.review_filter == only, do: nil, else: only),
       changed_only: false,
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

    view = socket.assigns.view
    key = mark_key(socket, name)

    case Marks.put(mark_view(view), key, attrs) do
      {:ok, mark} ->
        raw =
          if mark,
            do: Map.put(socket.assigns.raw_marks, key, mark),
            else: Map.delete(socket.assigns.raw_marks, key)

        {:noreply, socket |> with_marks(raw) |> assign(mark_saved: name)}

      {:error, _changeset} ->
        # 書けなかったことは黙って捨てない。押した人には確かめようがない
        {:noreply, put_flash(socket, :error, "メモを保存できませんでした。")}
    end
  end

  # 閉じ方は3つとも同じところへ来る（ボタン・図の外を押す・Esc）
  def handle_event("close_work", _params, socket) do
    {:noreply,
     assign(socket, detail: nil, artwork: nil, portrait: nil, edge: nil, mark_saved: nil)}
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

  # 図に無い映画を、見た記録と一緒に足す（映画の図）。**記録はその場で書き**、図へは
  # 引き継ぎを頼む（AI が足すので、載るのは取り込みが終わってから）
  def handle_event("add_film", params, socket) do
    title = String.trim(params["title"] || "")
    hint = params["hint"] || ""

    attrs = %{
      "seen" => true,
      "seen_on" => blank_to_nil(params["seen_on"]),
      "note" => params["note"] || ""
    }

    cond do
      socket.assigns.view != "films" or title == "" ->
        {:noreply, socket}

      # 図にもうある作品なら、その札に記録を付けるだけ（頼まない）
      # （比べ方は探すときと同じ。大文字と小文字、全角と半角を区別しない）
      node = Enum.find(socket.assigns.relation[:nodes] || [], &(fold(&1.name) == fold(title))) ->
        handle_event(
          "save_mark",
          Map.merge(attrs, %{"name" => node.name, "seen" => "on"}),
          socket
        )
        |> then(fn {:noreply, socket} -> {:noreply, focus_node(socket, node.name)} end)

      true ->
        case Marks.put(Films.mark_view(), title, attrs) do
          {:ok, mark} ->
            raw = Map.put(socket.assigns.raw_marks, title, mark)
            pid = self()

            Task.Supervisor.start_child(Chidori.TaskSupervisor, fn ->
              send(pid, {:film_carried, title, FilmCarry.carry_now([title], hint)})
            end)

            {:noreply,
             socket
             |> with_marks(raw)
             |> assign(film_added: "「#{title}」を記録しました。図に足すよう頼んでいます…")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "記録を保存できませんでした。")}
        end
    end
  end

  # 引き継ぎを待っている作品を Chiezo に聞く（押したときだけ）
  def handle_event("carry_pending", _params, socket) do
    pid = self()

    Task.Supervisor.start_child(Chidori.TaskSupervisor, fn ->
      result =
        case Chidori.Chiezo.base_url() do
          nil -> {:error, :chiezo_not_configured}
          base -> FilmCarry.pending(base)
        end

      send(pid, {:carry_pending, result})
    end)

    {:noreply, assign(socket, carry_pending: :loading)}
  end

  # 時計を待たずにいま頼む（上から 1 回に頼む数まで）。**重ねて押しても 1 本**（AI を使うので）
  def handle_event("carry_batch", _params, socket) do
    {:noreply, start_carry(socket, &FilmCarry.carry_batch_now/0)}
  end

  # 1 作品だけ頼む（時計が頼むのをやめた作品を頼み直す。見た記録は付けない）
  def handle_event("carry_one", %{"title" => title}, socket) when title != "" do
    {:noreply, start_carry(socket, fn -> FilmCarry.carry_now([title]) end)}
  end

  # 見た印を付けたものへ寄る。**名前を思い出せなくても行き先が選べる**のが、
  # この口の役目 —— 探す欄は名前を打てる人のためのもので、
  # 「前に見たあの画家」を探すのには使えない
  def handle_event("focus_marked", %{"name" => name}, socket) do
    {:noreply, focus_node(socket, name)}
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

  @doc """
  消えた画家を戻すよう頼む指示文。**必ず画家の名前で始めます**。

  **何をしてほしいかを全部書きます。** 割り込みは「次の指示にだけ従って」と
  前置きされるので、区画を見て、とだけ書くと消したものの見直しには手を付けない
  （実際、消し間違いが載っていたのにそのまま残った）。戻す印の名前も書く ——
  消えた印を外して返しても戻らない。
  """
  def restore_note(name, reason, note) do
    why = if String.trim(reason || "") == "", do: "", else: "「#{String.trim(reason)}」という理由で"

    base =
      "#{name}について。この画家は#{why}消えています。確かめて、消し間違いなら" <>
        "tags に \"#{Chidori.Chiezo.restore_tag()}\" を入れて同じ見出しで返して戻し、" <>
        "年代（西暦の「生年-没年」。生年が分からなければ推し量った年に「頃」を付ける）と" <>
        "地域のタグを直してください。いま付いているほかのタグは残してください。" <>
        "消したのが正しければ、何も返さなくて構いません。"

    case String.trim(note || "") do
      "" -> base
      written -> base <> "補足: " <> written
    end
  end

  defp open_detail(socket, node) do
    socket
    |> assign(detail: node, edge: nil, focus_sent: nil, mark_saved: nil)
    |> assign(star_people: star_people(socket.assigns.view, node))
    |> with_portrait(node)
    |> with_works(works_of(node))
  end

  # 作品の主演のうち、芸能人の図に載っている人。**押したときに 1 度だけ引く**
  # （芸能人の図は数千人ぶんあるので、描き直しのたびには引かない）
  defp star_people("films", node) do
    case stars_of(node) do
      [] ->
        MapSet.new()

      stars ->
        known = MapSet.new(Relations.current("people")[:nodes] || [], & &1.name)
        stars |> Enum.filter(&MapSet.member?(known, &1)) |> MapSet.new()
    end
  end

  defp star_people(_view, _node), do: MapSet.new()

  @doc "作品の主演（映画の図。タグ「主演:<名前>」）。"
  def stars_of(node), do: for(t <- node[:tags] || [], v = strip(t, "主演:"), do: v)

  @doc """
  主演の名前の行き先。**芸能人の図に載っていればその人へ**（図の中で寄って詳細を開く）、
  載っていなければ Wikipedia の記事へ。
  """
  def star_href(name, star_people) do
    if MapSet.member?(star_people, name),
      do: {:inside, "/relations?" <> URI.encode_query(%{"view" => "people", "focus" => name})},
      else: {:outside, "https://ja.wikipedia.org/wiki/" <> URI.encode(name)}
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
        # 札の大きさ（`r`）も渡す。**寄る倍率は札の大きさで決まる** —— 知られていない人ほど
        # 札が小さく、決め打ちの倍率では描かれる大きさに届かず、探しても何も出なかった
        |> push_event("focus", %{x: node.x, y: node.y, r: radius_of(node)})
    end
  end

  defp search(relation, q) do
    case String.trim(q) do
      "" ->
        []

      needle ->
        needle = fold(needle)

        relation.nodes
        |> Enum.filter(&String.contains?(fold(&1.name), needle))
        |> Enum.sort_by(&radius_of/1, :desc)
        |> Enum.take(@max_matches)
    end
  end

  @doc """
  探すときに比べる形。**大文字と小文字、全角と半角を区別しない** —— 映画の題は
  「STAR WARS」「Ｓｔａｒ　Ｗａｒｓ」「star wars」のどれでも書かれていて、
  打った人の書き方と札の書き方が揃っているとは限らない（揃っていないと 1 件も出ない）。
  """
  def fold(text), do: text |> String.normalize(:nfkc) |> String.downcase()

  @impl true
  def handle_async(:recent_runs, {:ok, {:ok, runs}}, socket),
    do: {:noreply, assign(socket, recent_runs: runs)}

  def handle_async(:recent_runs, _result, socket), do: {:noreply, socket}

  def handle_async(:settings, {:ok, {:ok, loaded}}, socket),
    do: {:noreply, assign(socket, settings: loaded)}

  def handle_async(:settings, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, settings: {:error, reason})}

  def handle_async(:settings, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, settings: {:error, :chiezo_unavailable})}

  def handle_async(:artwork, {:ok, result}, socket) do
    {:noreply, assign(socket, artwork: result)}
  end

  # **届いたときに開いている画家のものだけを使う。** 続けて別の画家を押すと、
  # 前の画家の画像があとから届くことがある
  def handle_async(:portrait, {:ok, found}, socket) do
    case {socket.assigns.detail, found} do
      {nil, _found} ->
        {:noreply, socket}

      {_detail, :none} ->
        {:noreply, assign(socket, portrait: :none)}

      {detail, %{title: title}} ->
        {:noreply, assign(socket, portrait: portrait_for(detail, title, found))}
    end
  end

  def handle_async(:portrait, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, portrait: :none)}

  def handle_async(:artwork, {:exit, _reason}, socket) do
    # **空の一覧にする。** nil にすると「探している最中」と見分けが付かない
    {:noreply, assign(socket, artwork: [])}
  end

  # **その画家の姿。** 画家の記事の先頭画像は、たいてい自画像か肖像写真になる
  # （代表作の記事の先頭がその絵になるのと同じ理屈）。引き方は代表作と同じ
  # `Chidori.Artwork` —— まず Chiezo、無ければ Wikipedia、結果は 1 日覚える
  # **顔写真の写しがある人は、記事の画像を引き直さない**（芸能人の図）。両方出すと、
  # 同じ人の写真が詳細に 2 枚並ぶ（写しも記事の先頭画像から取っているので、たいてい同じ写真）
  defp with_portrait(socket, %{face: face}) when is_binary(face),
    do: assign(socket, portrait: :none)

  defp with_portrait(socket, node) do
    case node[:article] || node[:name] do
      title when is_binary(title) ->
        socket
        |> assign(portrait: :loading)
        |> start_async(:portrait, fn -> Chidori.Artwork.lookup(title) || :none end)

      _ ->
        assign(socket, portrait: :none)
    end
  end

  # 絵が無いことは分かっているので、探しているふりをしない
  defp with_works(socket, []), do: assign(socket, artwork: [])

  defp with_works(socket, works) do
    socket
    |> assign(artwork: :loading)
    |> start_async(:artwork, fn ->
      # **見つからなかった作品も落とさない。** 記事の無い作品は多く、落とすと
      # 代表作が入っているのに何も出ない。画面が画像検索へのリンクにする
      Enum.map(works, &(Chidori.Artwork.lookup(&1) || %{title: &1, image: nil}))
    end)
  end

  # 押したときに送る値。**覚えているほうを勝たせる** —— 画面が描き直されると
  # フォームはサーバーが言うとおりに戻るので、覚えているものが選んだ本人の意思に近い。
  # 一度も選んでいなければ、いま出ている値（＝ Chiezo に入っている値）がそのまま返る。
  #
  # **選び直し（`pick_sweep`）では使わない。** あちらはフォームのほうが新しい
  defp picks(socket, params), do: merged_picks(socket.assigns.picks, params)

  @impl true
  def handle_info({:reroster, _key, result}, socket) do
    message =
      case result do
        :ok -> "名簿を引き直しました。新しく入った人は、ざっと見る回で順に詳しくなります。"
        {:error, reason} -> "名簿を引き直せませんでした: " <> relation_reason(reason)
      end

    {:noreply, assign(socket, reroster_message: message)}
  end

  def handle_info({:film_carried, title, result}, socket) do
    message =
      case result do
        {:ok, _count} ->
          "「#{title}」を記録しました。図に足すよう頼みました" <>
            "（取り込みが終わって図を取り直すと載ります）。"

        {:error, reason} ->
          "「#{title}」を記録しましたが、図に足すよう頼めませんでした: " <>
            relation_reason(reason) <> "（あとで自動でもう一度頼みます）"
      end

    {:noreply, socket |> assign(film_added: message) |> load_carry()}
  end

  def handle_info({:carry_done, result}, socket) do
    message =
      case result do
        {:ok, 0} -> "引き継ぐ作品はありませんでした。"
        {:ok, n} -> "#{n} 本を図に足すよう頼みました（取り込みが終わって図を取り直すと載ります）。"
        {:error, reason} -> "頼めませんでした: " <> relation_reason(reason)
      end

    # 一覧は頼んだ後では古いので畳む（もう一度押せば読み直す）
    {:noreply, socket |> assign(carry_message: message, carry_pending: nil) |> load_carry()}
  end

  def handle_info({:carry_pending, result}, socket) do
    pending =
      case result do
        {:ok, items} -> items
        {:error, reason} -> {:error, relation_reason(reason)}
      end

    {:noreply, assign(socket, carry_pending: pending)}
  end

  # 設定の枠で収集を止めた・動かした（`ChidoriWeb.CollectSwitch`）。設定を読み直して、止めた色を付け直す
  def handle_info({:collection_switched, _name}, socket),
    do: {:noreply, if(socket.assigns.settings_open, do: load_settings(socket), else: socket)}

  def handle_info({:relation_updated, relation}, socket) do
    # **設定を送り終えたら、開いている設定欄を読み直す。** 送った中身は Chiezo の
    # 側で書き換わっているので、前に読んだものを出し続けると、送れていないように見える
    sent? = socket.assigns.relation[:pushing] == true and relation[:pushing] != true

    socket =
      socket
      |> assign(relation: relation)
      # 札が入れ替わると、記録の見出しと札の名前の対応も変わる（映画の図）
      |> with_marks(socket.assigns.raw_marks)
      |> apply_pending_focus()

    {:noreply,
     if(sent? and socket.assigns.settings_open, do: load_settings(socket), else: socket)}
  end

  defp load_settings(socket) do
    view = socket.assigns.view
    nodes = socket.assigns.relation[:nodes] || []

    socket
    |> assign(settings: :loading)
    |> start_async(:settings, fn -> Relations.settings(view, nodes) end)
    |> load_recent_runs()
  end

  # **この図の収集の最近の回**（Chiezo の変更履歴をそのまま新しい順に。依頼の印は付かない）
  defp load_recent_runs(socket) do
    name = Relations.collection_of(socket.assigns.view)

    start_async(socket, :recent_runs, fn ->
      with base when is_binary(base) <- Chidori.News.chiezo_base_url(),
           {:ok, rows} <- Chidori.Chiezo.changes(base, name, limit: 10) do
        {:ok, Enum.map(rows, &%{change: &1, by_request: false})}
      end
    end)
  end

  @doc """
  設定欄に渡す状態。**図の状態に、読んできた設定を重ねたもの**です
  （設定欄の部品は、収集の設定を `collection` で受け取る）。
  """
  def with_settings(relation, %{collection: collection} = loaded) do
    relation
    |> Map.put(:collection, collection)
    |> Map.put(:partition_unreviewed, loaded[:partition_unreviewed] || %{})
  end

  @doc "設定を読み終えたか。"
  def settings_ready?(settings), do: is_map(settings)

  @doc """
  図を取り直している最中か（読んでいる・収集の途中経過が届いている、のどちらか）。
  「最新の情報を取得」を押せなくし、取得中だと分かるようにするのに使います。
  """
  def reloading?(relation), do: relation[:status] == :loading or relation[:step] not in [nil, %{}]

  @doc "未レビューの数がいつのものか（図を取得した時刻。JST）。"
  def unreviewed_as_of(%{checked_at: at}) when at != nil, do: Jst.format(at)
  def unreviewed_as_of(_relation), do: "まだ取得していません"

  @doc """
  AI に頼んでいる本文。**依頼した後は Chiezo が持っているものを出す** ——
  向こうの画面から直せるので、Chidori の雛形を出し続けると食い違う。
  """
  def prompt_text(relation, view \\ "painters")

  def prompt_text(%{collection: %{prompt: prompt}}, _view)
      when is_binary(prompt) and prompt != "",
      do: prompt

  def prompt_text(_relation, view), do: Chidori.Relations.prompt_of(view)

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

  alias Chidori.Relations.Graph

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

  @doc "グループの枠の色（グループの札と同じ色相で、中のメンバーが読めるよう薄く）。"
  def cluster_style(cluster) do
    case cluster[:hue] do
      nil -> nil
      hue -> "fill: hsl(#{hue} 60% 94% / 0.5); stroke: hsl(#{hue} 45% 55%)"
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
  def shown(relation, %{review_filter: "unreviewed"}), do: Graph.only_unreviewed(relation)
  def shown(relation, %{review_filter: "reviewed"}), do: Graph.only_reviewed(relation)
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

  @doc """
  取り直している最中か。**そのあいだは、ほかの操作を受け付けません**。

  読むのに数秒かかり、届いた図は**いま見ているものを丸ごと入れ替えます** ——
  途中で絞り込みや探索を押されると、押した結果が届いた図に上書きされ、
  押した人には何が起きたのか読めません（押せたのに効かない、という形になります）。
  """
  def busy?(%{step: step}) when step not in [nil, %{}], do: true
  def busy?(_relation), do: false

  @doc "割り込みが断られた理由の一文。"
  def focus_error(%{reason: reason}), do: relation_reason(reason)
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
  区画への割り込みの指示文。**必ず区画の名前で始めます**。

  区画は `partition` で別に渡していて、Chiezo はそちらを見て範囲を差し込みます。
  ただし**指示文だけを読んだ人には、どこ宛てか分かりません**。
  """
  def partition_note(key, note, sweep \\ Relations.survey_sweep()) do
    case {String.trim(note || ""), sweep == Relations.rough_sweep()} do
      {"", true} ->
        "#{key} の区画を先にざっと見てください。まだ目を通していない画家が残っています。"

      # **いつもの整理の手順を全部書く。** 割り込みは「次の指示にだけ従って」と
      # 前置きされるので、「調べて」とだけ書くと空欄埋めと漏れ探ししかしない
      # （下に並ぶ「消したもの」の消し間違いが、載っていても戻らなかった）
      {"", false} ->
        "#{key} の区画を、いつもの整理と同じ手順で先に見てください" <>
          "（漏れを足す・内容を磨く・要らないものを消す・消したものに消し間違いが無いか見直す）。"

      {written, _rough} ->
        "#{key} の区画について。#{written}"
    end
  end

  @doc "その画家の地域（タグのまま。複数あれば全部）。"
  def regions_of(node), do: for(t <- node[:tags] || [], v = strip(t, "地域:"), do: v)

  @doc "線の両端に共通する様式。"
  def shared_styles(%{from: from, to: to}),
    do: Enum.filter(from[:styles] || [], &(&1 in (to[:styles] || [])))

  @doc "空なら「—」。表の空欄を、書き忘れと見分けるため。"
  def blank_dash(""), do: "—"
  def blank_dash(text), do: text

  @doc """
  図の器の縦横比。**図と同じ比にします**（表示例のあいだは決めない）。
  """
  def canvas_style(%{sample?: true}, _shown), do: nil

  def canvas_style(_relation, %{width: w, height: h})
      when is_number(w) and is_number(h) and w > 0 and h > 0,
      do: "aspect-ratio: #{w} / #{h}"

  def canvas_style(_relation, _shown), do: nil

  # 開いている画家の記事と同じものか（別の画家の画像を出さない）
  defp portrait_for(detail, title, found) do
    if title in [detail[:article], detail[:name]], do: found, else: :none
  end

  @doc "区画ごとの未レビューの人数（無ければ 0）。"
  def unreviewed_in(relation, key), do: get_in(relation, [:partition_unreviewed, key]) || 0

  @doc """
  区画への割り込みの届き具合（その区画宛てのものだけ）。
  """
  def partition_state(relation, key), do: focus_state(relation, key)

  @doc """
  記事の無い代表作を探す先。**画家名と題名を並べて引く** —— 題名だけだと、
  同じ題の別の絵（「自画像」「睡蓮」）ばかり並ぶ。
  """
  def image_search_url(painter, work) do
    "https://www.google.com/search?" <>
      URI.encode_query(%{"tbm" => "isch", "q" => "#{painter} #{work}"})
  end

  # 見た記録の置き場の種類。**映画の図は最新情報の映画と同じ置き場**（`Films.mark_view/0`）
  defp mark_view("films"), do: Films.mark_view()
  defp mark_view(view), do: view

  defp start_carry(socket, fun) do
    pid = self()

    case Chidori.SingleFlight.start(:film_carry, fn -> send(pid, {:carry_done, fun.()}) end) do
      {:ok, _pid} -> assign(socket, carry_message: "頼んでいます…")
      {:error, :busy} -> assign(socket, carry_message: "いま頼んでいる最中です。")
    end
  end

  # 引き継ぎの時計の設定・前回の記録・次に確かめる時刻（映画の図だけ。DB と時計に聞くだけで、
  # Chiezo には聞かない）
  defp load_carry(%{assigns: %{view: "films"}} = socket) do
    setting = CarrySetting.get()
    assign(socket, carry_setting: setting, carry_next: FilmCarry.next_at(setting))
  end

  defp load_carry(socket), do: socket

  # 置き場の記録を、図の札の名前で引ける形にして持つ
  defp with_marks(socket, raw) do
    nodes = socket.assigns[:relation][:nodes] || []

    if socket.assigns.view == "films" do
      assign(socket,
        raw_marks: raw,
        marks: Films.marks_by_node(raw, nodes),
        unplaced_marks: Films.unplaced(raw, nodes)
      )
    else
      assign(socket, raw_marks: raw, marks: raw, unplaced_marks: %{})
    end
  end

  # その札の記録を書く見出し（映画の図は、既に書いてある見出しを優先する）
  defp mark_key(socket, name) do
    with "films" <- socket.assigns.view,
         %{} = node <- Enum.find(socket.assigns.relation[:nodes] || [], &(&1.name == name)) do
      Films.mark_key(node, socket.assigns.raw_marks)
    else
      _other -> name
    end
  end

  @doc """
  まだ図に載っていない見た記録（映画の図）。見た日の新しい順に `{見出し, 一言}`。
  """
  def unplaced_options(unplaced) do
    unplaced
    |> Enum.sort_by(fn {name, mark} -> {seen_order(mark), name} end)
    |> Enum.map(fn {name, mark} -> {name, seen_label(name, mark)} end)
  end

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
  def unit_of("films"), do: "作品"
  def unit_of(_view), do: "人"

  @doc "数を数える助数詞（帯・凡例・レビューの数に添える）。作品は「本」、人は「人」。"
  def counter_of("films"), do: "本"
  def counter_of(_view), do: "人"

  @doc "札の色の元になるもの（線の詳細の表の見出し）。"
  def style_heading("painters"), do: "様式"
  def style_heading("films"), do: "国"
  def style_heading(_view), do: "種別"

  @doc "相互リンクの線が「何ではないか」（線の詳細の説明）。"
  def related_not("painters"), do: "影響関係"
  def related_not("films"), do: "同じ監督・同じ主演のつながり"
  def related_not(_view), do: "家族やコンビの関係"

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
      {"地域", regions_of(node)},
      {"様式", for(t <- tags, v = strip(t, "様式:"), do: v)},
      {"代表作", for(t <- tags, v = strip(t, "代表作:"), do: v)},
      {"影響元", for(t <- tags, v = strip(t, "影響元:"), do: v)},
      # 芸能人の図のタグ
      {"種別", for(t <- tags, v = strip(t, "種別:"), do: v)},
      {"家族", for(t <- tags, v = strip(t, "家族:"), do: family_text(v))},
      {"グループ", for(t <- tags, v = strip(t, "グループ:"), do: v)},
      # 映画の図のタグ
      {"監督", for(t <- tags, v = strip(t, "監督:"), do: v)},
      {"国", for(t <- tags, v = strip(t, "国:"), do: v)},
      {"主演", stars_of(node)},
      {"その他", for(t <- tags, plain_tag?(t), do: t)}
    ]
    |> Enum.reject(fn {_label, values} -> values == [] end)
  end

  # 「相手:親子」を「相手（親子）」に（続柄が無ければ相手だけ）
  defp family_text(value) do
    case String.split(value, ":", parts: 2) do
      [name, relation] -> "#{name}（#{relation}）"
      [name] -> name
    end
  end

  defp strip(tag, prefix) do
    case tag do
      ^prefix <> rest -> rest
      _ -> nil
    end
  end

  # 頭に区分の付いていないタグ（「画家」など）。**関連は出さない**（線で見えている）
  defp plain_tag?(tag) do
    # **機械の印（`_chiezo_…`）も出さない** —— 未レビューかどうかは見出しの横に出す
    not Enum.any?(
      ~w(年代: 地域: 様式: 代表作: 影響元: 関連: 種別: メンバー: 元メンバー: 家族: グループ: 区分: 監督: 国: 主演: _chiezo_),
      &String.starts_with?(tag, &1)
    )
  end

  @doc """
  その画家の Wikipedia の記事。**代表作ではなく画家を指す**。
  Chiezo が持っている URL は http・https のときだけ使う（`Chidori.SafeUrl`）。
  """
  def article_url(node) do
    Chidori.SafeUrl.href(node[:url]) ||
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
    # **選んだ札（`pick_of/2`）なら、同じ監督・同じ主演の鎖の先まで必ず描く**（`near`）。
    # 線の先しか残していなかった頃は、鎖の 2 つ先の作品が小さいと間引かれ、そこへの線も
    # 引けないので、鎖が 1 本目で途切れて見えた。探して選んだ人（id）は今までどおり線の先まで
    {focus_id, kept} =
      case focus do
        %{id: id, near: near} -> {id, near}
        nil -> {nil, MapSet.new()}
        id -> {id, neighbourhood(relation, id)}
      end

    couples = couples(relation)

    shown =
      relation.nodes
      |> Enum.filter(&(visible?(&1, viewport) and big_enough?(&1, viewport)))
      |> MapSet.new(& &1.id)

    # **夫婦の相手は、小さくても描く**（芸能人の図）。線は両端の札が描かれているときだけ
    # 引くので、相手が小さくて間引かれると、いちばん見たい夫婦の線が全体表示で 1 本も
    # 出なかった（親子の線だけが見えていた）
    partners = for id <- shown, other <- Map.get(couples, id, []), into: MapSet.new(), do: other

    relation.nodes
    |> Enum.filter(fn node ->
      MapSet.member?(kept, node.id) or MapSet.member?(shown, node.id) or
        (MapSet.member?(partners, node.id) and visible?(node, viewport))
    end)
    # **選んだ札そのものを先頭に**、次にその相手、次に夫婦の組、あとは大きい順に。
    # **置く順がそのまま優先順**で、先に置いたものが場所を取る —— 選んだ札が小さいと、
    # 相手の大きい札に場所を取られて、選んだ札だけが消えていた
    |> Enum.sort_by(fn node ->
      {node.id != focus_id, !MapSet.member?(kept, node.id), !Map.has_key?(couples, node.id),
       -radius_of(node)}
    end)
    # 重なりを見るのは総当たりなので、見る数に蓋をする（選んだ札とその相手は数えずに残す）
    |> then(fn nodes ->
      {must, rest} = Enum.split_with(nodes, &MapSet.member?(kept, &1.id))
      must ++ Enum.take(rest, @max_drawn * 4)
    end)
    |> without_overlap(kept)
    |> then(fn nodes ->
      {must, rest} = Enum.split_with(nodes, &MapSet.member?(kept, &1.id))
      must ++ Enum.take(rest, max(@max_drawn - length(must), 0))
    end)
  end

  # 夫婦の組（id → 相手の id の並び）。夫婦の線を持たない図では空
  defp couples(relation) do
    for edge <- relation.edges || [], edge.kind == :spouse, reduce: %{} do
      acc ->
        acc
        |> Map.update(edge.from, [edge.to], &[edge.to | &1])
        |> Map.update(edge.to, [edge.from], &[edge.from | &1])
    end
  end

  # 札が重なるものを落とす。
  #
  # **場所を空けるのではなく、描くのをやめる。** 札は名前の幅で決まるので升目より
  # ずっと大きく、有名な画家の札は隣を何人ぶんも覆う。押しのけて避けようとすると
  # 位置が生年からずれ、縦の年表が意味を失う（地図が地名を間引くのと同じ考え方）。
  #
  # **消えたものは拡大すると出てくる。** 拡大するほど見える範囲が狭まり、
  # 同じ場所を取り合う相手が減るため。
  # **選んだ札とその相手（`keep`）は重なっても落とさない** —— 見たいのはその鎖で、
  # 落とすと線ごと消える。ほかの札は、それらの場所を避けて描く。
  defp without_overlap(candidates, keep) do
    candidates
    |> Enum.reduce({[], []}, fn node, {drawn, boxes} ->
      box = label_box(node)

      if not MapSet.member?(keep, node.id) and Enum.any?(boxes, &overlap?(&1, box)),
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

  # 線の詳細（2 回目に押したとき）
  defp open_edge(socket, edge, nodes, from, to, kind) do
    edges = socket.assigns.relation.edges

    assign(socket,
      edge: %{
        from: nodes[from],
        to: nodes[to],
        label: edge.label,
        kind: kind,
        excerpt: edge[:excerpt] || [],
        # **逆向きの影響も書かれているか**（互いに影響し合った組）
        mutual: Enum.any?(edges, &(&1.from == to and &1.to == from and &1.kind == :influence)),
        # 受けた側が、ほかに誰から受けているか。**この線だけを見て「この人から
        # 学んだ画家」と読まないため** —— 影響元が 5 人いる 1 本かもしれない
        others:
          for(
            e <- edges,
            e.kind == :influence and e.to == to and e.from != from,
            other = nodes[e.from],
            do: other.name
          )
      },
      detail: nil,
      artwork: nil,
      portrait: nil
    )
  end

  @doc """
  目立たせる札（`picked` は札の名前）。`%{id: 札の id, near: 線の先の id の集まり（札を含む）}`。
  図に出ていない（絞り込みで外れた）札なら nil。
  """
  def pick_of(_relation, nil), do: nil

  # 1 回押した線（`{from, to, kind}`）。札は選ばず、その線と両端を立たせる。共通項の線
  # （同じ監督・同じ主演）なら、その人の作品だけを鎖ごと立たせる。図に無い線なら nil
  def pick_of(relation, {from, to, kind}) do
    case Enum.find(relation.edges, &(&1.from == from and &1.to == to and &1.kind == kind)) do
      nil ->
        nil

      edge ->
        chains = MapSet.new(chains_of(edge))

        near =
          for other <- relation.edges,
              on_chain?(chains, other),
              id <- [other.from, other.to],
              into: MapSet.new([from, to]),
              do: id

        %{id: nil, near: near, chains: chains, edge: {from, to, kind}}
    end
  end

  def pick_of(relation, name) do
    case Enum.find(relation.nodes, &(&1.name == name)) do
      nil ->
        nil

      node ->
        # **共通項の線（同じ監督・同じ主演・同じグループ）は鎖ごと立たせる。** 線は隣どうし
        # しか結ばないので、押した札に触れている線だけでは、2 つ先の同じ俳優の作品が沈む
        chains =
          for edge <- relation.edges,
              node.id in [edge.from, edge.to],
              chain <- chains_of(edge),
              into: MapSet.new(),
              do: chain

        near =
          for edge <- relation.edges,
              on_chain?(chains, edge),
              id <- [edge.from, edge.to],
              into: neighbourhood(relation, node.id),
              do: id

        %{id: node.id, near: near, chains: chains}
    end
  end

  @doc """
  描く横の帯。**帯が 1 つしか無ければ描かない** —— 横の帯を持たない図（芸能人）は全員が
  「その他」の 1 本に入るので、帯の名前を出すと意味の無い「その他」が図の上に載る。
  """
  def split_bands(relation) do
    case relation[:bands] || [] do
      [_only] -> []
      bands -> bands
    end
  end

  @doc "その線を立たせるか（押した札に触れている線と、押した札の共通項の鎖）。"
  def lit?(nil, _edge), do: false

  def lit?(pick, edge),
    do:
      pick.id in [edge.from, edge.to] or on_chain?(pick.chains, edge) or
        pick[:edge] == {edge.from, edge.to, edge.kind}

  # 線が載っている鎖（共通項ごとに 1 つ）。**2 本の作品が主演を 2 人とも共にしていると、
  # 線は 1 本でも鎖は 2 つ**（`values`。`Graph` が畳むときに全部残す）
  defp chains_of(edge) do
    case edge[:values] || List.wrap(edge[:value]) do
      [] -> []
      values -> for value <- values, do: {edge[:via], value}
    end
  end

  defp on_chain?(chains, edge), do: Enum.any?(chains_of(edge), &MapSet.member?(chains, &1))

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
        # 枠に入っているメンバーへの線は描かない（枠で分かる）
        !edge[:framed?],
        from = by_id[edge.from],
        to = by_id[edge.to] do
      # **矢印の先は札の枠で止める。** 中央まで引くと、先端が札の下に隠れて
      # 「どちらへ向かっているのか」が読めない（矢印の意味がまるごと消える）
      {x2, y2} = at_border(from, to)

      %{
        x1: from.x,
        y1: from.y,
        x2: x2,
        y2: y2,
        kind: edge.kind,
        label: edge.label,
        # 共通項の線の鎖（札を押したときに鎖ごと立たせる）
        via: edge[:via],
        value: edge[:value],
        values: edge[:values],
        # 押されたときに誰と誰の線かを引き当てる
        from: edge.from,
        to: edge.to,
        mid_x: (from.x + to.x) / 2,
        mid_y: (from.y + to.y) / 2 - 8
      }
    end
  end

  # 札の枠と、中央どうしを結んだ線が交わるところ。**札は軸に平行な長方形**なので、
  # 「横で当たるか、縦で当たるか」の近いほうを取れば求まる
  defp at_border(from, to) do
    dx = to.x - from.x
    dy = to.y - from.y
    half_w = label_width_of(to) / 2
    half_h = label_height_of(to) / 2

    case reaches(dx, dy, half_w, half_h) do
      # 同じところに重なっている（動かしようが無い）
      [] -> {to.x, to.y}
      ratios -> shrunk(to, dx, dy, Enum.min(ratios))
    end
  end

  defp reaches(dx, dy, half_w, half_h) do
    [
      if(dx != 0, do: half_w / abs(dx)),
      if(dy != 0, do: half_h / abs(dy))
    ]
    |> Enum.reject(&is_nil/1)
  end

  # 1 を超えるのは、相手が近すぎて札の中に始点がいるとき（そのときは中央でよい）
  defp shrunk(to, dx, dy, ratio) when ratio >= 1, do: {to.x - dx, to.y - dy}
  defp shrunk(to, dx, dy, ratio), do: {to.x - dx * ratio, to.y - dy * ratio}

  @doc """
  名前を入れる札の大きさ。**名前がはみ出さない幅**を `Graph.sized/2` が見積もっています。

  持っていないノード（人物の図）には、以前の丸と同じ大きさの札を返します。
  """
  def label_width_of(node),
    do: (node[:label_width] || radius_of(node) * 2.6) + face_slot(node)

  def label_height_of(node), do: node[:label_height] || radius_of(node) * 1.6

  @doc """
  顔写真のぶん札に足す幅（札の高さの正方形）。写しの無い人は 0。**札の幅に数える** ——
  数えないと、重なりを避ける仕組みが写真のぶんを知らずに隣と重ねる。
  """
  def face_slot(node), do: if(node[:face], do: label_height_of(node), else: 0)

  @doc "顔写真の札の縁からの余白。"
  def face_inset(node), do: label_height_of(node) * 0.08

  @doc "丸の半径。知名度が引けていなければ既定の大きさ。"
  def radius_of(node), do: node[:radius] || if(node[:kind] == :group, do: 47, else: 42)

  @doc """
  名前の字の大きさ。**知名度で 1 人ずつ違う**（`Graph.sized/2` が決める）。

  持っていないノード（人物の図は知名度を引かない）には、以前と同じ大きさを返します。
  """
  def name_size_of(node), do: node[:name_size] || 13

  @doc "様式と年代の字。名前より小さい。"
  def sub_size_of(node), do: node[:sub_size] || 10

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

    prefix <> relation_reason(reason)
  end

  @doc """
  ボタンの説明。**図は Chiezo に溜まったものを読みます**。

  集めて整理するのは Chiezo の役目で、Chidori は図の形に読み直して見せるだけです。
  """
  def source_note(_view),
    do: "このボタンは、Chidori が持っている依頼文と回り方を Chiezo へ送り直すだけで、集めさせはしません。"

  @doc """
  設定欄の頭に置く、この図の出どころ。**ボタンの説明とは分ける** ——
  出どころは図そのものの話で、ボタンを押すかどうかに関わらず読むもの。
  """
  def origin_note(view),
    do:
      "この図は Chiezo に溜まった内容から作っています（収集「#{Chidori.Relations.collection_of(view)}」）。" <>
        "集めるのは Chiezo で、決まった間隔で回します。"

  @doc """
  図を読めなかったときの一文。**読めているときは何も出しません**
  （「表示しています」と書くまでもない）。
  """
  def trouble_message(%{status: :ready, reason: nil}), do: nil
  def trouble_message(%{status: :sample, reason: nil}), do: nil
  def trouble_message(%{status: :loading}), do: nil
  def trouble_message(relation), do: status_message(relation)

  # **この図でしか起きない理由だけを書く。** 残りは画面をまたいで同じことが
  # 起きるので、共有の `ChidoriWeb.Collect.reason_text/1` が言う ——
  # 画面ごとに書くと、同じ理由の説明が食い違ったまま片方だけ直る
  defp relation_reason(:collection_missing),
    do:
      "この図の収集は、まだ Chiezo に作られていません。" <>
        "「収集の設定を更新」を押すと、Chiezo に依頼して作ります。"

  defp relation_reason(:nothing_collected),
    do:
      "Chiezo にまだ何も溜まっていません。この図の収集を動かすと、集まったものがここに出ます" <>
        "（収集の画面（一覧）の「動かす」で動かせます（Chiezo の管理画面で外部からの有効化を許可してあるとき））。"

  # **指定が書けなければ収集を作らない。** 作ってしまうと、名簿が空のまま AI に
  # 「いまの内容から 10 人ほど選べ」と頼むことになり、10 件の図ができて終わる
  # （実測）。そのとき押した人には、なぜそうなったのかが読めない
  defp relation_reason({:extract_failed, _detail}),
    do:
      "Wikipedia から機械的に引く条件を AI に書かせられませんでした。" <>
        "収集は作っていません。もう一度押すか、相手を変えて試してください。"

  defp relation_reason(:no_partitions),
    do: "Chiezo の収集がまだ区画を持っていないので、区画を名指しできませんでした。"

  defp relation_reason(:no_partition),
    do: "この画家の入る区画が見つかりませんでした（区画を割り直したばかりのときに起きます）。"

  defp relation_reason(reason), do: reason_text(reason)

  @doc "数を 3 桁ごとに区切る（10000 → 10,000）。"
  def delimit(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
