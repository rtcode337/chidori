defmodule ChidoriWeb.PrefectureMap do
  @moduledoc """
  県の地図（ご当地グルメ）。**県を押して選ぶ**口で、押した県は表の「選ぶ」と同じ状態になります
  （その県の数と「この区画で 1 回走らせる」が出る）。**押しただけでは走らせません**。

  **塗りの濃さは代表店ありの割合**（料理と店のうち、代表店が引き当たって地図に置けるもの）を
  段に分けて出し、**引き当てできずがある県には別の印**（丸）を置きます。色だけに頼らない ——
  県に指を置けば名前と数が出て（`title`）、押せば下に数が並び、表にも同じ数があります。

  **操作は区画の地図・関連図と同じ**（`pan_zoom.js`。引きずって移動、Ctrl+ホイール、
  指 2 本でつまむ）。狭い画面では小さい県を拡大して押します。

  **県の境目は塗りの一覧に、選んだ県は上に重ねる 1 本に分けてあります。** 選び直すたびに
  47 県ぶんの境目（6,700 点ほど）を送り直さないため —— 塗りの一覧は地図（`map`）だけで
  描くので、選び直しでは描き直されません。
  """

  use Phoenix.Component

  attr :map, :map, required: true, doc: "`Chidori.Datasets.Map.prefectures/1` が返すもの"
  attr :picked, :string, default: nil, doc: "いま選んでいる区画の鍵（`地域:<県>`）"

  def prefecture_map(assigns) do
    ~H"""
    <div class="prefecture-map">
      <div class="map-canvas pref-canvas" id="prefecture-canvas" phx-hook="PrefectureMap">
        <div class="map-tools">
          <button type="button" data-zoom="in" aria-label="拡大">＋</button>
          <button type="button" data-zoom="out" aria-label="縮小">−</button>
          <button type="button" data-zoom="reset" aria-label="全体を表示">全体</button>
          <ChidoriWeb.FullscreenButton.fullscreen_button />
        </div>
        <svg
          viewBox={"0 0 #{@map.width} #{@map.height}"}
          role="img"
          aria-label="県ごとの進み具合の地図"
        >
          <g class="pref-shapes">
            <path
              :for={shape <- @map.shapes}
              d={shape.d}
              class={["pref", step_class(shape.step)]}
              phx-click="pick_partition"
              phx-value-key={shape.key}
            >
              <title>{shape_title(shape)}</title>
            </path>
          </g>
          <%!-- **引き当てできずの印**。押す口ではない（下の県が受ける）。
               大きさは台本が倍率で割り戻す（寄っても引いても同じに見せる） --%>
          <g class="pref-flags" aria-hidden="true">
            <circle
              :for={shape <- @map.shapes}
              :if={shape.flag}
              data-flag
              data-x={shape.label.x}
              data-y={shape.label.y}
              cx={shape.label.x}
              cy={shape.label.y}
              r="4"
            />
          </g>
          <%!-- 選んだ県。**上に重ねる 1 本**（塗りの一覧を描き直さない）。押すと選びやめる --%>
          <path
            :for={shape <- picked_shapes(@map, @picked)}
            d={shape.d}
            class="pref-picked"
            phx-click="pick_partition"
            phx-value-key={shape.key}
          >
            <title>{shape_title(shape)}（選んでいます）</title>
          </path>
        </svg>
      </div>
      <ul class="pref-legend" aria-label="地図の凡例">
        <li class="legend-title">代表店ありの割合（料理と店のうち）</li>
        <li><span class="swatch pref-empty"></span>料理も店もまだ無い</li>
        <li><span class="swatch pref-step-0"></span>0 %</li>
        <li><span class="swatch pref-step-1"></span>25 % 未満</li>
        <li><span class="swatch pref-step-2"></span>25〜50 %</li>
        <li><span class="swatch pref-step-3"></span>50〜75 %</li>
        <li><span class="swatch pref-step-4"></span>75 % 以上</li>
        <li><span class="flag-mark"></span>引き当てできずがある</li>
      </ul>
      <p class="muted-note map-hint">
        <strong>県を押すと選ばれます</strong>（押しただけでは走りません）。
        <span class="only-touch">指で動かし、2 本の指でつまんで拡大縮小。</span><span class="only-mouse">引きずって移動、Ctrl+ホイールで拡大縮小。</span>
        小さい県や離れた島は、拡大するか下の表から選んでください（沖縄・小笠原も本当の位置と大きさで描いています）。
        県の境界は {Chidori.Geo.Prefectures.source()}。
      </p>
    </div>
    """
  end

  # 選んだ県（無ければ空）。`:for` で書くのは、無いときに要素ごと出さないため
  defp picked_shapes(_map, nil), do: []
  defp picked_shapes(map, key), do: Enum.filter(map.shapes, &(&1.key == key))

  defp step_class(nil), do: "pref-empty"
  defp step_class(step), do: "pref-step-#{step}"

  # 料理と店の内訳（店が無ければ書かない）
  defp shops_note(0), do: ""
  defp shops_note(shops), do: "（うち店 #{shops}）"

  @doc "県に指を置いたときの一言（県名と数）。色だけでは割合が読めないので、数で書く。"
  def shape_title(shape) do
    share =
      if shape.dishes > 0,
        do: "（#{round(shape.placed * 100 / shape.dishes)} %）",
        else: ""

    failed = if shape.unresolved, do: "（うち引き当てできず #{shape.unresolved}）", else: ""

    "#{shape.name}：料理・店 #{shape.dishes}#{shops_note(Map.get(shape, :shops, 0))}・代表店あり #{shape.placed}#{share}" <>
      "・代表店まだ #{shape.pending}#{failed}・代表店なし #{shape.no_shop}"
  end
end
