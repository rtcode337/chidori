// 県の地図（ご当地グルメ）の操作。**共通の仕組み**（`./pan_zoom`）に、この図だけの事情を足したもの。
//
// 足しているのは倍率の幅と、引き当てできずの印の大きさだけです。地理院タイルは敷きません ——
// 見たいのは県ごとの進み具合で、駅や道の細かさまで寄る図ではないので。
import {panZoom} from "./pan_zoom"

// **小さい県まで指で押せる倍率まで寄れるようにする。** 幅 390px の画面で全体を出すと、
// いちばん小さい香川県が 10px ほど、沖縄本島が 17px ほどになります。24 倍なら
// 離れた小さな島（小笠原・大東）も指の幅に届きます
const MAX_SCALE = 24

// 縮む側は区画の地図と同じ（図は縦に長いので、全体を出すには 1 倍より縮める）
const MIN_SCALE = 0.2

// 引き当てできずの印を、画面の上で何 px の半径に見せるか。**倍率で割り戻して、
// 寄っても引いても同じ大きさに見せる** —— 図の座標のままだと、寄るほど県を覆う
const FLAG_PX = 4

export default panZoom({
  minScale: MIN_SCALE,
  maxScale: MAX_SCALE,

  painted() {
    const ppu = this.view && this.view.ppu
    if (!this.svg || !(ppu > 0)) { return }
    const r = FLAG_PX / ppu
    this.svg.querySelectorAll("[data-flag]").forEach(flag => flag.setAttribute("r", r))
  },
})
