// 左右に払う指と、**文字を選ぶ指を取り合わない**ための物差し（`panel_swipe.js`・`digest_swipe.js`）。
//
// 文字を選ぶ指は、長押ししてから横へ引く（選んだ範囲の端をつまんで広げるのも同じ動き）。
// 横に大きく動くので、払ったのと見分けが付かない —— そこで次のどちらかなら払いにしない:
// - 指を置いていた時間が長い（払う指は短く、長押しから始まる指は長い）
// - 指を離したときに文字が選ばれている（選んだ範囲を広げ終えたところ）

// これより長く置いていた指は払いにしない（ミリ秒）。長押しで選び始めるのは 500 前後
const MAX_MS = 600

export function selectingText(start) {
  if (Date.now() - start.at > MAX_MS) return true
  const selection = window.getSelection && window.getSelection()
  return !!selection && !selection.isCollapsed && selection.toString().trim() !== ""
}
