defmodule ChidoriWeb.PrefectureMap do
  @moduledoc """
  県の地図（ご当地グルメ）。**県を押して選ぶ**口で、押した県は表の「選ぶ」と同じ状態になります
  （その県の数と「この区画で 1 回走らせる」が出る）。**押しただけでは走らせません**。

  **塗りの濃さは代表店ありの割合**（料理と店のうち、代表店が引き当たって地図に置けるもの）を
  段に分けて出し、**引き当てできずがある県には別の印**（丸）を置きます。**塗りは進み具合を優先します**:
  情報収集まで終わった県は薄い緑、ざっと見るが終わっていない県は料理も店もまだ無い県と同じ色
  （割合の塗りでは、どこまで回ったかが読めない）。色だけに頼らない ——
  県に指を置けば名前と数が出て（`title`）、押せば下に数が並び、表にも同じ数があります。

  **操作は区画の地図・関連図と同じ**（`pan_zoom.js`。引きずって移動、Ctrl+ホイール、
  指 2 本でつまむ）。狭い画面では小さい県を拡大して押します。

  **県の境目は塗りの一覧に、選んだ県は上に重ねる 1 本に分けてあります。** 選び直すたびに
  47 県ぶんの境目（6,700 点ほど）を送り直さないため —— 塗りの一覧は地図（`map`）だけで
  描くので、選び直しでは描き直されません。進み具合の塗りも同じ理由で、境目を重ねて描かず、
  県の番号（`pref-n<番号>`）を指す短い `<style>` だけで変えます。
  """

  use Phoenix.Component

  attr :map, :map, required: true, doc: "`Chidori.Datasets.Map.prefectures/1` が返すもの"
  attr :picked, :string, default: nil, doc: "いま選んでいる区画の鍵（`地域:<県>`）"

  attr :done, :any,
    default: MapSet.new(),
    doc: "情報収集まで終わった区画の鍵の集まり（薄い緑で塗る）"

  attr :scanned, :any,
    default: MapSet.new(),
    doc: "ざっと見るが見た区画の鍵の集まり（どちらにも無い県は、まだ無い県と同じ色）"

  def prefecture_map(assigns) do
    ~H"""
    <div class="prefecture-map">
      <style>
        <%= progress_css(@map, @done, @scanned) %>
      </style>
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
              :for={{shape, index} <- Enum.with_index(@map.shapes)}
              d={shape.d}
              class={["pref", step_class(shape.step), "pref-n#{index}"]}
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
        <li><span class="swatch pref-empty"></span>ざっと見るがまだ・料理も店もまだ無い</li>
        <li><span class="swatch pref-step-0"></span>0 %</li>
        <li><span class="swatch pref-step-1"></span>25 % 未満</li>
        <li><span class="swatch pref-step-2"></span>25〜50 %</li>
        <li><span class="swatch pref-step-3"></span>50〜75 %</li>
        <li><span class="swatch pref-step-4"></span>75 % 以上</li>
        <li><span class="flag-mark"></span>引き当てできずがある</li>
        <li><span class="swatch pref-done"></span>情報収集まで終わった</li>
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

  # 進み具合の塗り（`<style>` の中身）。色は app.css の変数で持つ（凡例と同じ色）
  defp progress_css(map, done, scanned) do
    indexed = Enum.with_index(map.shapes)

    done_rule =
      fill_rule(for {shape, index} <- indexed, MapSet.member?(done, shape.key), do: index)

    waiting =
      for {shape, index} <- indexed,
          not MapSet.member?(done, shape.key),
          not MapSet.member?(scanned, shape.key),
          do: index

    done_rule.("--pref-done-fill") <> fill_rule(waiting).("--pref-empty-fill")
  end

  defp fill_rule([]), do: fn _variable -> "" end

  defp fill_rule(indexes) do
    selectors = Enum.map_join(indexes, ",", &".prefecture-map path.pref-n#{&1}")
    fn variable -> "#{selectors}{fill:var(#{variable})}" end
  end

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
