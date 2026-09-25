defmodule TazunaWeb.TopicMap do
  @moduledoc """
  記事から育った話題の網を描くところ。**置き場所を決めるのは `Tazuna.Themes.Graph`** で、
  ここは札と線を SVG にするだけです。

  **まとめのすぐ下に置く前提**で書いてあります —— まとめが「この期間に何があったか」を
  文で言うのに対して、図は同じことを**語のつながり**で見せます。1 件ずつの一覧より先に
  置かないと、記事を読み終えた後の「で、いま何の話が太いのか」に答えられません。

  **全部のトピックを図に置きます**（関連図と同じく、引きずって動かし、つまんで拡大する）。
  開いたときは、いちばん動いている話題を真ん中に置きます。

  **一覧は畳んでおきます。** 数や説明は図では読めないので、読める道は要りますが、
  記事より前に長い一覧が居座ると、読みに来た人の邪魔になります。
  """

  use Phoenix.Component

  alias Tazuna.Themes.Graph

  attr :state, :map, required: true, doc: "`Tazuna.Themes.read/2` が返すもの"
  attr :interests, :list, default: [], doc: "選んでいる興味トピック（札に印を付ける）"
  attr :picked, :string, default: nil, doc: "押して選んでいる語（その線を濃くする）"

  def topic_map(assigns) do
    assigns =
      assign(assigns,
        map: Graph.build(assigns.state.themes),
        list: sorted(assigns.state.themes)
      )

    # **選んでいる語はサーバーでも描く** —— 画面が描き直されると、`topic_map.js` が
    # 付けた印は消える（押した直後はあちらが先に付け、描き直しの後はこちらが持つ）
    assigns = assign(assigns, near: near(assigns.map.edges, assigns.picked))

    ~H"""
    <section :if={@map.nodes != []} class="topic-map" aria-label="トピックの網">
      <h2>いま動いている話題</h2>
      <%!-- **操作は関連図と同じ**（`TopicMap` は関連図と同じ `pan_zoom` を使う）。
           開いたときは、いちばん動いている話題を真ん中に置く —— そこから引きずって
           周りの話題を見に行く。全体は「全体」のボタンで見られる --%>
      <div
        id="topic-canvas"
        class={["relation-canvas topic-canvas", @picked && "has-pick"]}
        phx-hook="TopicMap"
        data-focus-x={@map.focus.x}
        data-focus-y={@map.focus.y}
      >
        <div class="relation-tools">
          <button type="button" data-zoom="in" aria-label="拡大">＋</button>
          <button type="button" data-zoom="out" aria-label="縮小">−</button>
          <button type="button" data-zoom="reset" aria-label="全体を表示">全体</button>
          <button type="button" data-zoom="full" aria-label="全画面で見る">全画面</button>
        </div>
        <p class="relation-hint">
          <span class="only-touch">押すと全画面。指で動かし、2 本の指でつまんで拡大縮小。</span><span class="only-mouse">引きずって移動、Ctrl+ホイールで拡大縮小。</span>
        </p>
        <svg
          viewBox={"0 0 #{@map.width} #{@map.height}"}
          role="img"
          aria-label="トピックのつながり"
        >
          <%!-- 親子の囲み。**外側から順に描く**（内側の囲みを上に重ねる） --%>
          <g class="topic-clusters">
            <g :for={cluster <- @map.clusters} class="topic-cluster">
              <rect
                x={cluster.x - cluster.w / 2}
                y={cluster.y - cluster.h / 2}
                width={cluster.w}
                height={cluster.h}
                rx="18"
                style={cluster_style(cluster, @map.nodes)}
              >
                <title>{cluster.name} の仲間</title>
              </rect>
              <%!-- **何のクラスタかを枠に書く**（上位の話題の名前を左上に） --%>
              <text
                x={cluster.x - cluster.w / 2 + 12}
                y={cluster.y - cluster.h / 2 + cluster.font + 4}
                style={cluster_label_style(cluster, @map.nodes, cluster.font)}
              >
                {cluster.name}
              </text>
            </g>
          </g>
          <g class="topic-edges">
            <%!-- 線は全部出す（網に見えるように）。**数百本あるので薄く描き**、札を押すと
                 その話題の線だけを濃く残す（`topic_map.js` が `is-lit` を付ける） --%>
            <line
              :for={edge <- @map.edges}
              class={@picked in [edge.from, edge.to] && "is-lit"}
              data-from={edge.from}
              data-to={edge.to}
              x1={edge.x1}
              y1={edge.y1}
              x2={edge.x2}
              y2={edge.y2}
              style={"stroke-width: #{edge.width}"}
            />
          </g>
          <g class="topic-nodes">
            <g
              :for={node <- @map.nodes}
              class={[
                "topic-node",
                node.name in @interests && "is-interest",
                @picked == node.name && "is-picked",
                MapSet.member?(@near, node.name) && "is-near"
              ]}
              data-name={node.name}
            >
              <%!-- 話題は角丸の札。**大きさは字の大きさ**（直近の記事の数）で、
                   幅と高さは名前から決まる（名前を削らない） --%>
              <rect
                x={node.x - node.w / 2}
                y={node.y - node.h / 2}
                width={node.w}
                height={node.h}
                rx={node.font * 0.5}
                style={node.hue && "fill: hsl(#{node.hue} 70% 92%); stroke: hsl(#{node.hue} 55% 55%)"}
              />
              <%!-- 名前は札の中。**行の高さぶん上へ寄せて**、中心で釣り合わせる --%>
              <text
                x={node.x}
                y={node.y + node.label_y}
                text-anchor="middle"
                style={"font-size: #{node.font}px"}
              >
                <title>{node.name}</title>
                <tspan
                  :for={{line, row} <- Enum.with_index(node.lines)}
                  x={node.x}
                  dy={if row == 0, do: 0, else: node.font * 1.25}
                >
                  {line}
                </tspan>
              </text>
            </g>
          </g>
        </svg>
      </div>
      <p class="muted-note">
        {length(@map.nodes)} 件の話題を出しています。札の大きさは直近の記事の数、囲みは親子（上位の話題とその仲間）、★ の札は興味トピック。札を押すと、その話題の記事が図の下に並びます。線は一緒に出てきた話題どうしを結び（太いほど多い）、札を押すとその話題の線だけが濃く残ります。
      </p>

      <%!-- 図に出ないものも読める道を残す。**畳んでおく** —— 記事より前に
           長い一覧が居座ると、読みに来た人の邪魔になる --%>
      <details :if={@list != []}>
        <summary>トピックの一覧（{length(@list)} 件）</summary>
        <div class="theme-list">
          <article :for={theme <- @list}>
            <h3>
              {theme.name}
              <span :if={theme.field} class="theme-count">{theme.field}</span>
              <%!-- 札の大きさの根拠。図では大きさでしか出ないので、一覧では数で出す --%>
              <span class="theme-count">直近 {theme.recent} 件 / 計 {theme.docs} 件</span>
            </h3>
            <p :if={theme.note != ""} class="news-summary">{theme.note}</p>
            <p :if={theme.parent} class="muted-note">上位: {theme.parent}</p>
            <p :if={theme.recent == 0 and theme.last_seen != ""} class="muted-note">
              最後に出たのは {theme.last_seen}
            </p>
            <ul :if={theme.related != []} class="theme-children">
              <li :for={related <- theme.related}>
                <strong>{related.to}</strong>
                <span class="muted-note">一緒に {related.n} 件</span>
              </li>
            </ul>
          </article>
        </div>
      </details>
    </section>
    """
  end

  # 選んでいる語と線で結ばれている語
  defp near(_edges, nil), do: MapSet.new()

  defp near(edges, picked) do
    for edge <- edges,
        picked in [edge.from, edge.to],
        name <- [edge.from, edge.to],
        into: MapSet.new(),
        do: name
  end

  # 見出しの色は、枠と同じ分野の色を濃くしたもの
  defp cluster_label_style(cluster, nodes, font) do
    color =
      case Enum.find(nodes, &(&1.name == cluster.name)) do
        %{hue: hue} when is_integer(hue) -> "fill: hsl(#{hue} 45% 38%);"
        _other -> ""
      end

    "#{color} font-size: #{font}px"
  end

  # 囲みの色は、上位の話題の分野の色（薄く）。分野が無ければ灰色
  defp cluster_style(cluster, nodes) do
    case Enum.find(nodes, &(&1.name == cluster.name)) do
      %{hue: hue} when is_integer(hue) ->
        "fill: hsl(#{hue} 60% 97% / .7); stroke: hsl(#{hue} 45% 70%)"

      _other ->
        nil
    end
  end

  # 並びは、いま動いている順。**図と同じ並べ方**にします —— 図とは別の順で並べると、
  # 「図で大きいもの」を一覧から探すことになります
  defp sorted(themes), do: Enum.sort_by(themes, &{-&1.recent, -&1.docs, &1.name})
end
