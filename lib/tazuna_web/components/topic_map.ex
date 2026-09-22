defmodule TazunaWeb.TopicMap do
  @moduledoc """
  記事から育った話題の網を描くところ。**置き場所を決めるのは `Tazuna.Themes.Graph`** で、
  ここは丸と線を SVG にするだけです。

  **まとめのすぐ下に置く前提**で書いてあります —— まとめが「この期間に何があったか」を
  文で言うのに対して、図は同じことを**語のつながり**で見せます。1 件ずつの一覧より先に
  置かないと、記事を読み終えた後の「で、いま何の話が太いのか」に答えられません。

  **一覧は畳んでおきます。** 図に置けるのは数が限られるので、こぼれたものも読める道は
  要りますが、記事より前に長い一覧が居座ると、読みに来た人の邪魔になります。
  """

  use Phoenix.Component

  alias Tazuna.Themes.Graph

  attr :state, :map, required: true, doc: "`Tazuna.Themes.read/2` が返すもの"

  def topic_map(assigns) do
    assigns =
      assign(assigns,
        map: Graph.build(assigns.state.themes),
        list: sorted(assigns.state.themes)
      )

    ~H"""
    <section :if={@map.nodes != []} class="topic-map" aria-label="トピックの網">
      <h2>いま動いている話題</h2>
      <svg
        viewBox={"0 0 #{@map.width} #{@map.height}"}
        role="img"
        aria-label="トピックのつながり"
      >
        <g class="topic-edges">
          <g :for={edge <- @map.edges}>
            <line
              x1={edge.x1}
              y1={edge.y1}
              x2={edge.x2}
              y2={edge.y2}
              class={if edge.kind == :parent, do: "is-parent"}
            />
            <text :if={edge.note != ""} x={edge.label_x} y={edge.label_y} text-anchor="middle">
              {edge.note}
            </text>
          </g>
        </g>
        <g class="topic-nodes">
          <g :for={node <- @map.nodes}>
            <circle
              cx={node.x}
              cy={node.y}
              r={node.r}
              style={node.hue && "fill: hsl(#{node.hue} 70% 92%); stroke: hsl(#{node.hue} 55% 55%)"}
            />
            <text x={node.label_x} y={node.label_y} text-anchor={node.anchor}>{node.name}</text>
          </g>
        </g>
      </svg>
      <p :if={@map.hidden > 0} class="muted-note">
        つながりの多い {length(@map.nodes)} 件を出しています（あと {@map.hidden} 件は下の一覧に）。
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
            </h3>
            <p :if={theme.note != ""} class="news-summary">{theme.note}</p>
            <p :if={theme.parent} class="muted-note">上位: {theme.parent}</p>
            <ul :if={theme.related != []} class="theme-children">
              <li :for={related <- theme.related}>
                <strong>{related.to}</strong>
                <span :if={related.note != ""} class="muted-note">{related.note}</span>
              </li>
            </ul>
          </article>
        </div>
      </details>
    </section>
    """
  end

  # 並びは、つながりの多い順。**同じ数なら名前の順**（開くたびに並びが変わらないように）
  defp sorted(themes) do
    linked =
      Enum.reduce(themes, %{}, fn theme, counted ->
        Enum.reduce(theme.related, counted, fn related, inner ->
          inner
          |> Map.update(theme.name, 1, &(&1 + 1))
          |> Map.update(related.to, 1, &(&1 + 1))
        end)
      end)

    Enum.sort_by(themes, &{-Map.get(linked, &1.name, 0), &1.name})
  end
end
