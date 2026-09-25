// 全画面の要約を、**左右に払って前後の要約へ**動かすところ。
//
// **古いほうを左に置く**（上の帯のボタンも「← 古い / 新しい →」）。右へ払う ——
// 左にあるものを引き出す —— のはふだん「戻る」の動きなので、戻る先を古いほうに
// 揃える。新しいほうへは左へ払う。
// 縦に読んでいる指を取らないよう、**横に大きく動いたときだけ**払ったことにする。
// **表の中では払わない** —— 横に広い表は指で横へずらして読むので、そこで前後へ
// 動くと読めなくなる。
//
// 開いている間は後ろのページを止める（全画面の中だけがスクロールする）。
// 前後へ動いたら先頭から読ませる（前の要約の途中の位置で次が始まると、頭が見えない）。
// 目次の項目から開いたときは、その章まで送る（`data-section`）。

// ここまで横に動いたら払ったことにする（ピクセル）
const SWIPE = 60
// 横の動きが縦のこの倍以上あるときだけ（斜めの指は縦のスクロールとみなす）
const RATIO = 1.5

export default {
  mounted() {
    this.index = this.el.dataset.index
    this.start = null
    document.body.classList.add("digest-open")

    this.onStart = event => {
      const inTable = event.target.closest && event.target.closest(".report-table, pre")
      if (event.touches.length !== 1 || inTable) {
        this.start = null
        return
      }
      const touch = event.touches[0]
      this.start = {x: touch.clientX, y: touch.clientY}
    }
    this.onEnd = event => {
      if (!this.start) return
      const touch = event.changedTouches[0]
      const dx = touch.clientX - this.start.x
      const dy = touch.clientY - this.start.y
      this.start = null
      if (Math.abs(dx) < SWIPE || Math.abs(dx) < Math.abs(dy) * RATIO) return
      // 右へ払う → 古いほう（1）、左へ払う → 新しいほう（-1）
      this.pushEvent("digest_step", {by: dx > 0 ? 1 : -1})
    }
    this.el.addEventListener("touchstart", this.onStart, {passive: true})
    this.el.addEventListener("touchend", this.onEnd, {passive: true})
    this.toSection()
  },

  updated() {
    if (this.el.dataset.index !== this.index) {
      this.index = this.el.dataset.index
      this.el.scrollTop = 0
    }
  },

  destroyed() {
    document.body.classList.remove("digest-open")
  },

  // 目次から開いたときは、その章の頭へ（上の帯に隠れないぶん少し手前で止める）
  toSection() {
    const section = this.el.dataset.section
    if (!section) return
    const target = this.el.querySelector(`#digest-viewer-s${section}`)
    const bar = this.el.querySelector(".digest-viewer-bar")
    if (target) this.el.scrollTop = target.offsetTop - (bar ? bar.offsetHeight : 0) - 8
  },
}
