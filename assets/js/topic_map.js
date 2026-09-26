// トピックの網の操作。**関連図と同じ仕組み**（`./pan_zoom`）に、この図だけの事情を足す。
//
// 足しているのは 2 つ ——
//
//   ・開いたときは、いちばん動いている話題を真ん中に置く（`data-focus-x/y`）。
//     全体を収めると 100 を超える札が豆粒になり、名前が 1 つも読めない。
//     等倍（図の 1 単位 = 画面 1px）で寄せ、そこから引きずって周りを見に行く
//   ・札を押したら、その話題の線だけを濃く残し（ふだんは全部の線を薄く出す）、
//     サーバーへ知らせて、その話題の記事を図の下に並べさせる。
//     もう一度押すか余白を押すと戻る
//   ・余白を押したら全画面（指で触る画面だけ。関連図と同じ）
import {panZoom} from "./pan_zoom"

// 開いたときの倍率。図の 1 単位を画面の何 px にするか（名前が読める大きさ）
const START_PPU = 1

// 指で触る画面か。**画面の幅ではなく入力の種類で見る**（関連図と同じ）
const touchLike = () =>
  window.matchMedia && window.matchMedia("(pointer: coarse)").matches

export default panZoom({
  // 全体より小さくしても読めるものは増えないので、下は全体表示の倍率
  minScale: 0.02,
  fitFloor: true,
  maxScale: 8,

  skip: "[data-zoom], .relation-tools, .relation-find",

  started() {
    const x = Number(this.el.dataset.focusX)
    const y = Number(this.el.dataset.focusY)
    const box = this.el.getBoundingClientRect()
    const width = this.base && this.base[2]
    if (!Number.isFinite(x) || !Number.isFinite(y) || !(width > 0) || !(box.width > 0)) { return }
    // perUnit = 器の幅 / 図の幅 × scale なので、等倍にする scale はその逆数
    this.centerOn(x, y, (START_PPU * width) / box.width)
    // **探す欄で選んだ札へ寄る**（画家の図と同じ）。寄った札は押したのと同じ印を付ける
    this.handleEvent("focus", ({x, y, name}) => {
      const now = this.el.getBoundingClientRect()
      this.centerOn(x, y, (START_PPU * this.base[2]) / (now.width || box.width))
      this.picked = name
      this.mark()
    })
  },

  // 描き直されると付けた印が消えるので、当て直すたびに付け直す
  painted() {
    this.mark()
  },

  tapped(ev) {
    const node = ev.target.closest(".topic-node")
    if (node) {
      this.pick(this.picked === node.dataset.name ? null : node.dataset.name)
      return
    }
    // 選んでいる間の余白は「選ぶのをやめる」。全画面へは飛ばない
    if (this.picked) {
      this.pick(null)
      return
    }
    if (touchLike() && !document.fullscreenElement) {
      this.fullscreen()
    }
  },

  // 選ぶ。**印はその場で付け**、サーバーへは記事を引かせるために知らせる
  // （届いた記事は図の下に並ぶ。描き直しの後の印はサーバーが持つ）
  pick(name) {
    this.picked = name
    this.mark()
    this.pushEvent("pick_theme", {name: name || ""})
  },

  // 選んだ話題の線と、その相手の札に印を付ける
  mark() {
    const name = this.picked
    this.el.classList.toggle("has-pick", !!name)
    const near = new Set()
    this.el.querySelectorAll(".topic-edges line").forEach(line => {
      const lit = !!name && (line.dataset.from === name || line.dataset.to === name)
      line.classList.toggle("is-lit", lit)
      if (lit) { near.add(line.dataset.from); near.add(line.dataset.to) }
    })
    this.el.querySelectorAll(".topic-node").forEach(node => {
      node.classList.toggle("is-picked", node.dataset.name === name)
      node.classList.toggle("is-near", near.has(node.dataset.name))
    })
  },
})
