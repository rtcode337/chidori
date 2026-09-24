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

  def partition_map(assigns) do
    ~H"""
    <section :if={@map.rects != []} class="partition-map" aria-label="区画の地図">
      <p class="muted-note">
        四角のひとつひとつが区画です。<strong>店の多いところほど細かく</strong>切られているので、
        細かい格子がそのまま「たくさん集まっているところ」になります。 <strong>押すと、その区画を先に調べてもらえます。</strong>
        濃いところほど詰まっています（区画は海の上まで覆うので、同じ濃さで塗ると島の形が沈みます）。 <strong>寄ると区画の境目が出ます。</strong>
        <strong>緑は見終わった区画です</strong>（{seen_note(@sweeps)}）—— {@map.visited} / {length(@map.rects)}。
      </p>
      <%!-- **操作は関連図と同じ**（引きずって移動、Ctrl+ホイールで拡大縮小、
           指 2 本でつまむ）—— 図ごとに操作が違うと、画面を移るたびに覚え直すことになる --%>
      <div class="map-canvas" id="partition-canvas" phx-hook="PartitionMap">
        <div class="map-tools">
          <button type="button" data-zoom="in" aria-label="拡大">＋</button>
          <button type="button" data-zoom="out" aria-label="縮小">−</button>
          <button type="button" data-zoom="reset" aria-label="全体を表示">全体</button>
          <button type="button" data-zoom="full" aria-label="全画面で見る">全画面</button>
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
              rect.stage > 0 && "is-seen",
              rect.stage > 1 && "is-done",
              rect.key == @picked && "is-picked"
            ]}
            style={"opacity: #{rect.tone}"}
            phx-click="pick_partition"
            phx-value-key={rect.key}
          >
            <title>{rect.key}（{rect.count} 件{if rect.by, do: "・#{rect.by} 済み", else: ""}）</title>
          </rect>
        </svg>
      </div>
      <p class="muted-note map-hint">
        <span class="only-touch">指で動かし、2 本の指でつまんで拡大縮小。</span><span class="only-mouse">引きずって移動、Ctrl+ホイールで拡大縮小。</span>
        海岸線は {Tazuna.Geo.Japan.source()}。
      </p>
    </section>
    """
  end

  # 緑の読み方。**濃さは「何本が見たか」** —— 巡回は並んで回るので、
  # 「どちらが先か」では読めない（後の回だけが見た区画が普通にできる）
  defp seen_note([first, second | _rest]),
    do: "薄い緑が「#{first}」か「#{second}」の片方、濃い緑が両方"

  defp seen_note([only]), do: "「#{only}」が見終わったぶん"
  defp seen_note(_sweeps), do: "見終わったぶん"
end
