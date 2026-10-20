// トップページの枠を、**左右に払って隣のタブへ**移すところ。
//
// 左へ払う → 次の枠、右へ払う → 前の枠（カードをめくる向き。大きなタブをまたいで決めた順に）。
// 縦に読んでいる指を取らないよう、**横に大きく動いたときだけ**払ったことにする
// （`digest_swipe.js` と同じ物差し）。
//
// 払わないところ:
// - 全画面の要約を開いている間（そちらの払いは前後の要約へ動く）
// - 横に広い表・コード（指で横へずらして読む）
// - タブの列（横にスクロールさせて選ぶ）
// 関連図は iframe の中なので、そこでの指はこちらに届かない（図を動かす指と取り合わない）。
// 文字を選ぶ指（長押しから横へ引く）も払いにしない（`swipe_guard.js`）。

import {selectingText} from "./swipe_guard"

const SWIPE = 60
const RATIO = 1.5
const SKIP = ".report-table, pre, .relation-tabs, .digest-viewer, iframe"

export default {
  mounted() {
    this.start = null

    this.onStart = event => {
      const skip = event.target.closest && event.target.closest(SKIP)
      if (event.touches.length !== 1 || skip || document.body.classList.contains("digest-open")) {
        this.start = null
        return
      }
      const touch = event.touches[0]
      this.start = {x: touch.clientX, y: touch.clientY, at: Date.now()}
    }
    this.onEnd = event => {
      if (!this.start) return
      const touch = event.changedTouches[0]
      const dx = touch.clientX - this.start.x
      const dy = touch.clientY - this.start.y
      const selecting = selectingText(this.start)
      this.start = null
      if (selecting) return
      if (Math.abs(dx) < SWIPE || Math.abs(dx) < Math.abs(dy) * RATIO) return
      this.pushEvent("panel_step", {by: dx < 0 ? 1 : -1})
    }
    this.el.addEventListener("touchstart", this.onStart, {passive: true})
    this.el.addEventListener("touchend", this.onEnd, {passive: true})
  },

  destroyed() {
    this.el.removeEventListener("touchstart", this.onStart)
    this.el.removeEventListener("touchend", this.onEnd)
  },
}
