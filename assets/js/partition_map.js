// 区画の地図の操作。**共通の仕組み**（`./pan_zoom`）に、この図だけの事情を足したもの。
//
// 足しているのは倍率の幅と、境目を出す近さと、起点のピンの大きさと、寄ったときに敷く
// 地理院タイル（`./gsi_tiles`）です。
import {panZoom} from "./pan_zoom"
import {paintTiles} from "./gsi_tiles"

// **深く寄れるようにする。** 区画は件数が揃うように切られているので、
// 都心の区画は外海の区画の何万分の一の広さしかありません（実測で、いちばん細い
// 区画は図の 0.009 —— 12 倍までしか寄れないと、どれだけ寄っても 1px に届かず、
// 「拡大しても細かくならない」ことになります）。400 倍でおよそ 4px になります。
const MAX_SCALE = 400

// 縮む側は据え置き。図は縦に長いので、全体を出すには 1 倍より縮める必要があります
const MIN_SCALE = 0.2

// ここまで寄ったら区画の境目を描く（CSS の `.map-canvas.is-close`）。
// **全体では描けません** —— 8,000 を超える四角が隣り合うので、縁のほうが面を
// 覆って白く飛びます。寄ったときだけなら、画面に出るのは数十区画です
const CLOSE_AT = 4

// 起点のピンを、画面の上で何倍に見せるか（図の 1 単位 = 画面 1px のときの大きさが 1）。
// **倍率で割り戻して、寄っても引いても同じ大きさに見せる**
const PIN_PX = 1.6

// 地名で探した場所へ寄るときの倍率（市区町村が見分けられるくらい）
const FOCUS_SCALE = 30

export default panZoom({
  skip: "[data-zoom], .relation-find",
  minScale: MIN_SCALE,
  maxScale: MAX_SCALE,
  closeAt: CLOSE_AT,

  // **地名で探した場所へ寄る**（サーバーが図の座標に直して送る）。
  // 寄る倍率は下限だけ決める（既に深く寄っていれば、そのまま）
  started() {
    this.handleEvent("map_focus", ({x, y}) => this.centerOn(x, y, FOCUS_SCALE))
  },

  // ピン（起点と、探して寄った場所）を、倍率で割り戻した大きさに置き直す。タイルも置き直す
  painted() {
    const ppu = this.view && this.view.ppu
    if (!this.svg || !(ppu > 0)) { return }
    const scale = PIN_PX / ppu
    this.svg.querySelectorAll("[data-pin]").forEach(pin => {
      pin.setAttribute("transform", `translate(${pin.dataset.x} ${pin.dataset.y}) scale(${scale})`)
    })
    paintTiles(this, this.el.querySelector("#partition-tiles"), ppu)
  },
})
