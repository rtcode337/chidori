// 関連図の操作。**共通の仕組み**（`./pan_zoom`）に、この図だけの事情を足したものです。
//
// 足しているのは 4 つ ——
//
//   ・年代と地域の札を画面の端に留める（図と一緒に流すと、少し引きずっただけで
//     年表が画面の外へ出て、いま何時代を見ているのか読めなくなる）
//   ・見ている範囲をサーバーへ知らせる（**サーバーはそこだけを描く**）
//   ・探して選んだ人へ寄る
//   ・札を目立たせている間に余白を押したら、目立たせるのをやめる
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

// 探した人へ寄るときの最低倍率。**全体表示のままでは寄った意味が無い**
// （周りの関連図を読むために探しているので、線の相手まで見える近さが要る）
const FOCUS_SCALE = 4

// 探した人の札を、画面の上でこの直径（px）以上にして見せる。**倍率を決め打ちにしない**
// —— 札は知られている度合いで大きさが違い、小さい札の人は 4 倍でも名前が読めず、
// 描く下限（サーバーの `@min_drawn_px`）にも届かずに何も出なかった
const FOCUS_PX = 32

// 拡大の上限。探した人の札を読める大きさにするのに、小さい札では 8 倍では足りない
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
    // 探して選んだ人を真ん中へ。**倍率はサーバーが決めない** —— 器が何 px かは
    // こちらしか知らないので、図の座標だけ受け取って寄せ方はここで決める
    this.handleEvent("focus", ({x, y, r}) => this.centerOn(x, y, this.focusScale(r)))
  },

  // 札（半径 r、図の座標）が画面の上で FOCUS_PX になる倍率。器の幅で変わるので、ここで測る
  focusScale(r) {
    const box = this.el.getBoundingClientRect()
    const width = this.base && this.base[2]
    if (!(r > 0) || !(width > 0) || !(box.width > 0)) { return FOCUS_SCALE }
    const needed = FOCUS_PX / (2 * r * (box.width / width))
    return Math.max(FOCUS_SCALE, needed)
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
