defmodule TazunaWeb.PartitionMap do
  @moduledoc """
  区画を地図として描くところ。**押せる四角**にして、そこから頼めるようにします。

  **地図の絵は敷きません**（`Tazuna.Datasets.Map` に理由）。区画そのものが日本の形に
  なるので、外の地図を読みに行かずに済みます。

  **見終わった区画は色を変えます。** 進み具合は数では読めません ——
  「8,185 区画のうち 2 つ」と出しても、それがどこなのかは分からないので。
  """

  use Phoenix.Component

  attr :map, :map, required: true, doc: "`Tazuna.Datasets.Map.build/1` が返すもの"
  attr :sweeps, :list, default: [], doc: "区画を回る巡回の名前（回る順）"
  attr :picked, :string, default: nil, doc: "いま選んでいる区画の鍵"
  attr :origin_label, :string, default: nil, doc: "起点の名前（ピンに添える）"
  attr :find_query, :string, default: "", doc: "地名の検索窓に打っている語"
  attr :find_places, :any, default: nil, doc: "地名の候補（`Tazuna.Chiezo.places/2` の結果）"
  attr :marker, :map, default: nil, doc: "探して寄った場所（`%{x, y, label}`）"

  def partition_map(assigns) do
    ~H"""
    <section :if={@map.rects != []} class="partition-map" aria-label="区画の地図">
      <p class="muted-note">
        四角のひとつひとつが区画です。<strong>店の多いところほど細かく</strong>切られているので、
        細かい格子がそのまま「たくさん集まっているところ」になります。 <strong>押すと、その区画を先に調べてもらえます。</strong>
        濃いところほど詰まっています（区画は海の上まで覆うので、同じ濃さで塗ると島の形が沈みます）。 <strong>寄ると区画の境目が出ます。</strong>
        <strong>色が付いているのは見終わった区画です</strong>（{seen_note(@sweeps)}）—— {@map.visited} / {length(
          @map.rects
        )}。
      </p>
      <%!-- **操作は関連図と同じ**（引きずって移動、Ctrl+ホイールで拡大縮小、
           指 2 本でつまむ）—— 図ごとに操作が違うと、画面を移るたびに覚え直すことになる --%>
      <div class="map-canvas" id="partition-canvas" phx-hook="PartitionMap">
        <%!-- **地名で探して寄る口**（関連図・トピックの図と同じく左上）。探すのは
             起点と同じ地図辞典。候補を選ぶとその場所へ寄って印を立てる --%>
        <div class="relation-find">
          <form
            id="map-search"
            class="relation-search"
            phx-submit="search_map_place"
            phx-change="search_map_place"
            autocomplete="off"
          >
            <input
              type="search"
              name="q"
              value={@find_query}
              placeholder="地名で探す"
              aria-label="地名で探す"
              phx-debounce="400"
            />
            <button
              :if={@find_query != ""}
              type="button"
              phx-click="clear_map_search"
              aria-label="検索をやめる"
            >
              ×
            </button>
            <%= case @find_places do %>
              <% {:ok, [_ | _] = places} -> %>
                <ul class="relation-matches">
                  <li :for={{place, index} <- Enum.with_index(places)}>
                    <button type="button" phx-click="focus_map_place" phx-value-index={index}>
                      {place.name}
                      <span class="match-years">{place_note(place)}</span>
                    </button>
                  </li>
                </ul>
              <% {:ok, []} -> %>
                <ul class="relation-matches">
                  <li class="muted-note">見つかりませんでした</li>
                </ul>
              <% :loading -> %>
                <ul class="relation-matches">
                  <li class="muted-note">探しています…</li>
                </ul>
              <% {:error, _reason} -> %>
                <ul class="relation-matches">
                  <li class="muted-note">地名を引けませんでした</li>
                </ul>
              <% _none -> %>
            <% end %>
          </form>
        </div>
        <div class="map-tools">
          <button type="button" data-zoom="in" aria-label="拡大">＋</button>
          <button type="button" data-zoom="out" aria-label="縮小">−</button>
          <button type="button" data-zoom="reset" aria-label="全体を表示">全体</button>
          <TazunaWeb.FullscreenButton.fullscreen_button />
        </div>
        <svg
          viewBox={"0 0 #{@map.width} #{@map.height}"}
          role="img"
          aria-label="区画の広がり"
        >
          <%!-- 白地図。**手元に持っている輪郭**（外の地図を読みに行かない）。
               区画の下に敷くので、押す口は四角のまま --%>
          <path :for={ring <- @map.coast} d={ring} class="coast" />

          <%!-- **押す口は四角そのもの。** 区画の一覧から鍵を探して押す形だと、
               地図で見つけた区画を名前で照合し直すことになる --%>
          <rect
            :for={rect <- @map.rects}
            x={rect.x}
            y={rect.y}
            width={rect.width}
            height={rect.height}
            class={[
              rect.tiny && "is-tiny",
              seen_class(rect, @sweeps),
              rect.key == @picked && "is-picked"
            ]}
            style={"opacity: #{rect.tone}"}
            phx-click="pick_partition"
            phx-value-key={rect.key}
          >
            <title>{rect.key}（{rect.count} 件{if rect.by, do: "・#{rect.by} 済み", else: ""}）</title>
          </rect>

          <%!-- 起点のピン。**区画の上に立てる**（ここから放射状に回ることが地図で読める）。
               **拡大しても同じ大きさに見せる** —— 図と一緒に大きくなると、寄ったときに
               区画を覆い隠す（`partition_map.js` が倍率で割り戻す）。押す口ではない --%>
          <g
            :if={@map.origin}
            class="origin-pin"
            data-pin
            data-x={@map.origin.x}
            data-y={@map.origin.y}
            transform={"translate(#{@map.origin.x} #{@map.origin.y})"}
          >
            <title>起点{if @origin_label, do: "：#{@origin_label}", else: ""}</title>
            <path d="M0 0 C-4 -6 -7 -9.5 -7 -14 A7 7 0 1 1 7 -14 C7 -9.5 4 -6 0 0 Z" />
            <circle cx="0" cy="-14" r="2.6" />
          </g>

          <%!-- **探して寄った場所の印**（起点のピンとは色を変える）。押す口ではない --%>
          <g
            :if={@marker}
            class="find-pin"
            data-pin
            data-x={@marker.x}
            data-y={@marker.y}
            transform={"translate(#{@marker.x} #{@marker.y})"}
          >
            <title>{@marker.label}</title>
            <path d="M0 0 C-4 -6 -7 -9.5 -7 -14 A7 7 0 1 1 7 -14 C7 -9.5 4 -6 0 0 Z" />
            <circle cx="0" cy="-14" r="2.6" />
          </g>
        </svg>
      </div>
      <p class="muted-note map-hint">
        <span class="only-touch">指で動かし、2 本の指でつまんで拡大縮小。</span><span class="only-mouse">引きずって移動、Ctrl+ホイールで拡大縮小。</span>
        海岸線は {Tazuna.Geo.Japan.source()}。
      </p>
    </section>
    """
  end

  # 候補の添え書き（行政区・種別）。同じ名前の別の場所を見分けるため
  defp place_note(place) do
    [place[:area], place[:feature]] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("・")
  end

  # 区画の色。**最後に回る巡回まで見た区画は薄い緑、それより前の巡回だけが
  # 見た区画は薄い黄色**。何本が見たかで濃さを変えていた頃は、どの巡回まで
  # 済んだのかが読めなかった（後の回だけが見た区画も「片方」に数わる）
  defp seen_class(rect, sweeps) do
    cond do
      sweeps != [] and List.last(sweeps) in rect.seen_by -> "is-done"
      rect.stage > 0 -> "is-seen"
      true -> nil
    end
  end

  defp seen_note([_ | _] = sweeps) when length(sweeps) >= 2 do
    last = List.last(sweeps)
    earlier = sweeps |> Enum.drop(-1) |> Enum.map_join("」「", & &1)
    "薄い黄色が「#{earlier}」まで、薄い緑が「#{last}」まで見終わった区画"
  end

  defp seen_note([only]), do: "薄い緑が「#{only}」まで見終わった区画"
  defp seen_note(_sweeps), do: "見終わったぶん"
end
