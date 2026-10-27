// 関連図の操作。**共通の仕組み**（`./pan_zoom`）に、この図だけの事情を足したものです。
//
// 足しているのは 6 つ ——
//
//   ・年代と地域の札を画面の端に留める（図と一緒に流すと、少し引きずっただけで
//     年表が画面の外へ出て、いま何時代を見ているのか読めなくなる）
//   ・見ている範囲をサーバーへ知らせる（**サーバーはそこだけを描く**）
//   ・探して選んだ人を真ん中に置く（倍率は変えない）
//   ・札を目立たせている間に余白を押したら、目立たせるのをやめる
//   ・札のすぐ近くの押し込みは、線より札を押したことにする
//   ・全画面の中で詳細を開いたら、詳細が見える形の全画面に切り替える
import {panZoom} from "./pan_zoom"

// 年代の札を画面のどれだけ内側に置くか（px）と、画面上での字の大きさ（px）
const LABEL_INSET = 8
const LABEL_PX = 11

// 帯の名前を貼り付ける高さ。**探す欄と道具の下**に出す —— 同じ高さに置くと、
// 左端の帯の名前が探す欄の裏に入って読めない
const LABEL_TOP = 52

// 見ている範囲を知らせるまでの落ち着き待ち（ミリ秒）。引きずっている最中に
// 毎フレーム送ると、往復のたびに描き直しが挟まってかえって固まる
const REPORT_DELAY = 140

// 札の縁からこれだけ離れた押し込みまでは、札を押したことにする（px）。指は線の当たり判定より
// 札を優先したい（線の当たり判定は指で触る画面で 34px）
const NODE_SLOP_TOUCH = 14
const NODE_SLOP_MOUSE = 4

// 拡大の上限。小さい札を読める大きさまで寄るには、8 倍では足りない
const MAX_SCALE = 40

// 指で触る画面か。**画面の幅ではなく入力の種類で見る** —— 幅で分けると、
// 窓を狭くしただけの PC が「スマホ扱い」になって、押すたびに全画面へ飛ぶ
const touchLike = () =>
  window.matchMedia && window.matchMedia("(pointer: coarse)").matches

export default panZoom({
  // 全体表示より小さくしても読めるものが増えないので、**下は全体表示の倍率**。
  // 画家の図は縦に長く、1 倍（幅いっぱい）を下限にしていた頃は、開いたときに
  // 下のほうが器からはみ出して全体が見えなかった
  minScale: 0.02,
  fitFloor: true,
  maxScale: MAX_SCALE,

  // 探す欄と道具の上では図を動かさない（字を打つ口・選ぶ口なので）
  skip: "[data-zoom], .relation-tools, .relation-find",

  started() {
    // 探して選んだ人を真ん中へ。**倍率は変えない**（いま見ている広さのまま、選んだ札を真ん中に置く）。
    // 札が読める大きさまで寄せていた頃は、選ぶたびに図が大きく寄って、周りとの位置関係が見えなくなった。
    // 小さい札も、選んだ札はサーバーが大きさに関わらず描く
    this.handleEvent("focus", ({x, y}) => this.centerOn(x, y))
    // 詳細を開いたとき。**本物の全画面の中では、全画面にした器の外は描かれない** —— 詳細は器の外に
    // 重ねて出すので、開いても見えなかった。見た目の同じ代わりの形（器を広げる）に切り替える。
    // 閉じても全画面のまま
    this.handleEvent("modal_open", () => {
      if (document.fullscreenElement === this.el) {
        document.exitFullscreen().then(() => this.fauxFullscreen()).catch(() => {})
      }
    })
  },

  painted() {
    this.pinLabels()
    this.report()
  },

  stopped() {
    clearTimeout(this.reportTimer)
  },

  // 図の余白を押したら全画面。**指で触る画面だけ**にする —— 狭い画面では図が
  // 小さすぎて全画面がないと読めないが、PC では窓のまま拡大すれば足りるので、
  // 押すたびに全画面へ飛ぶのは邪魔なだけ（ボタンからは PC でも入れる）。
  // 丸を押したときは代表作が開くので邪魔しない
  tapped(ev) {
    // **札のすぐ近くの押し込みは札を押したことにする。** 線の当たり判定は指で触る画面では 34px あり、
    // 線は札の真ん中へ入っていくので、小さな札の縁を押すと線の側に取られる（1 回目で立たせた札の
    // 線が、2 回目の押し込みを横取りして詳細が開かなかった）
    if (!ev.target.closest(".relation-node")) {
      const near = this.nodeNear(ev.clientX, ev.clientY)
      if (near) {
        ev.stopPropagation()
        ev.preventDefault()
        this.pushEvent("show_node", {name: near.getAttribute("phx-value-name")})
        return
      }
    }
    const onNode = ev.target.closest(".relation-node")
    // 札を目立たせている間の余白は「目立たせるのをやめる」。全画面へは飛ばない
    // （トピックの網と同じ）。札を押したときはサーバーが決める（1 回目は目立たせ、2 回目は詳細）
    if (!onNode && !ev.target.closest(".edge-target") && this.el.classList.contains("has-pick")) {
      this.pushEvent("unpick", {})
      return
    }
    // 全画面の中の余白は何もしない（代わりの形の全画面で押すと、全画面を抜けていた）
    if (touchLike() && !onNode && !this.inFullscreen()) {
      this.fullscreen()
    }
  },

  // 押した点から NODE_SLOP px 以内に縁がある札（いちばん近いもの）。札の外側の押し込みだけに使う
  nodeNear(x, y) {
    if (!this.svg || !(x >= 0) || !(y >= 0)) { return null }
    const slop = touchLike() ? NODE_SLOP_TOUCH : NODE_SLOP_MOUSE
    let best = null
    let bestGap = Infinity
    for (const node of this.svg.querySelectorAll(".relation-node")) {
      const r = node.getBoundingClientRect()
      const gap = Math.hypot(Math.max(r.left - x, 0, x - r.right), Math.max(r.top - y, 0, y - r.bottom))
      if (gap <= slop && gap < bestGap) {
        best = node
        bestGap = gap
      }
    }
    return best
  },

  // 年代の札を画面の左端に、帯の名前を上端に留める。
  //
  // **縦（年代）と横（地域）は図と一緒に動かす** —— そこがずれたら軸の意味が無い。
  // 留めるのは反対側だけ。字の大きさは倍率で割り戻して、拡大しても同じ大きさに見せる
  pinLabels() {
    const view = this.view
    if (!view || !(view.ppu > 0) || !this.svg) { return }

    const labels = this.svg.querySelector("[data-pinned-labels]")
    if (labels) {
      // 画面の左端（LABEL_INSET px 内側）に来る図の座標。札は x=8 に書いてあるので、
      // そこからの差を transform で足す
      const target = view.x + LABEL_INSET / view.ppu
      labels.setAttribute("transform", `translate(${target - 8}, 0)`)
      labels.style.fontSize = `${LABEL_PX / view.ppu}px`
    }

    const top = this.svg.querySelector("[data-pinned-top]")
    if (top) {
      top.setAttribute("transform", `translate(0, ${view.y + LABEL_TOP / view.ppu})`)
      top.style.fontSize = `${LABEL_PX / view.ppu}px`
    }
  },

  // いま見ている範囲を図の座標で知らせる。**サーバーはここだけを描く。**
  report() {
    const view = this.view
    if (!view) { return }
    clearTimeout(this.reportTimer)
    this.reportTimer = setTimeout(() => {
      this.pushEvent("viewport", {x: view.x, y: view.y, w: view.w, h: view.h, ppu: view.ppu})
    }, REPORT_DELAY)
  },
})
