// 食事処の範囲を描く地図の操作。**共通の仕組み**（`./pan_zoom`）に、四角を描く口を足したもの。
//
// 「四角を描く」を押しているあいだは、引きずりが図の移動ではなく四角の描画になります
// （器に `is-drawing` を付け、共通の仕組みの `skip` に当てて移動を止める）。
// 描き終えたら緯度経度に直してサーバーへ送り、描く状態を抜けます。
import {panZoom} from "./pan_zoom"

// 区や駅の細かさまで寄れるようにする（日本全体の図で 1 km はおよそ 0.04 単位）
const MAX_SCALE = 2000
const MIN_SCALE = 0.2
// ここまで寄ったら駅の名前を出す（CSS の `.map-canvas.is-close`）
const CLOSE_AT = 60
// 地名で探した場所へ寄るときの倍率（市区町村が見分けられるくらい）
const FOCUS_SCALE = 200
// 目印とピンを、画面の上で何倍に見せるか
const PIN_PX = 1.4

// メルカトルの逆（`Tazuna.Datasets.Map` の `mercator/1` と対）
const latOf = (merc) => (2 * Math.atan(Math.exp(merc * Math.PI / 180)) - Math.PI / 2) * 180 / Math.PI

export default panZoom({
  // **描いているあいだは図を動かさない**（器ごと skip に当てる）
  skip: "[data-zoom], .relation-find, .is-drawing",
  minScale: MIN_SCALE,
  maxScale: MAX_SCALE,
  closeAt: CLOSE_AT,

  started() {
    this.handleEvent("map_focus", ({x, y}) => this.centerOn(x, y, FOCUS_SCALE))

    this.onToggle = (ev) => {
      const button = ev.target.closest("[data-zoom='draw']")
      if (!button) { return }
      ev.preventDefault()
      this.setDrawing(!this.el.classList.contains("is-drawing"))
    }
    this.el.addEventListener("click", this.onToggle)

    this.onDown = (ev) => {
      if (!this.el.classList.contains("is-drawing") || ev.target.closest("[data-zoom], .relation-find")) { return }
      ev.preventDefault()
      this.start = this.toSvg(ev)
      this.layer().innerHTML = ""
      this.box = document.createElementNS("http://www.w3.org/2000/svg", "rect")
      this.box.setAttribute("class", "drawing-rect")
      this.layer().appendChild(this.box)
      this.el.setPointerCapture && ev.pointerId !== undefined && this.el.setPointerCapture(ev.pointerId)
    }
    this.onMove = (ev) => {
      if (!this.start || !this.box) { return }
      const now = this.toSvg(ev)
      this.box.setAttribute("x", Math.min(this.start.x, now.x))
      this.box.setAttribute("y", Math.min(this.start.y, now.y))
      this.box.setAttribute("width", Math.abs(now.x - this.start.x))
      this.box.setAttribute("height", Math.abs(now.y - this.start.y))
    }
    this.onUp = (ev) => {
      if (!this.start) { return }
      const end = this.toSvg(ev)
      const start = this.start
      this.start = null
      this.layer().innerHTML = ""
      this.box = null
      // 押しただけ（ほとんど動かしていない）なら描かない
      if (Math.abs(end.x - start.x) < 1e-4 || Math.abs(end.y - start.y) < 1e-4) { return }
      const [a, b] = [this.toLatLon(start), this.toLatLon(end)]
      this.pushEvent("drawn", {
        south: Math.min(a.lat, b.lat), north: Math.max(a.lat, b.lat),
        west: Math.min(a.lon, b.lon), east: Math.max(a.lon, b.lon),
      })
      this.setDrawing(false)
    }
    this.el.addEventListener("pointerdown", this.onDown)
    this.el.addEventListener("pointermove", this.onMove)
    this.el.addEventListener("pointerup", this.onUp)
    this.el.addEventListener("pointercancel", this.onUp)
  },

  stopped() {
    this.el.removeEventListener("click", this.onToggle)
    this.el.removeEventListener("pointerdown", this.onDown)
    this.el.removeEventListener("pointermove", this.onMove)
    this.el.removeEventListener("pointerup", this.onUp)
    this.el.removeEventListener("pointercancel", this.onUp)
  },

  setDrawing(on) {
    this.el.classList.toggle("is-drawing", on)
    const button = this.el.querySelector("[data-zoom='draw']")
    if (button) {
      button.setAttribute("aria-pressed", on ? "true" : "false")
      button.textContent = on ? "描くのをやめる" : "四角を描く"
    }
  },

  layer() { return this.el.querySelector("#area-draw-layer") },

  // 画面の座標 → 図の座標（いまの viewBox のまま）
  toSvg(ev) {
    const point = this.svg.createSVGPoint()
    point.x = ev.clientX
    point.y = ev.clientY
    return point.matrixTransform(this.svg.getScreenCTM().inverse())
  },

  // 図の座標 → 緯度経度（サーバーが渡した投影の枠で）
  toLatLon({x, y}) {
    const west = parseFloat(this.svg.dataset.west)
    const top = parseFloat(this.svg.dataset.top)
    const scale = parseFloat(this.svg.dataset.scale)
    return {lon: west + x / scale, lat: latOf(top - y / scale)}
  },

  // ピンと目印を、倍率で割り戻した大きさに置き直す
  painted() {
    const ppu = this.view && this.view.ppu
    if (!this.svg || !(ppu > 0)) { return }
    const scale = PIN_PX / ppu
    this.svg.querySelectorAll("[data-pin]").forEach(pin => {
      pin.setAttribute("transform", `translate(${pin.dataset.x} ${pin.dataset.y}) scale(${scale})`)
    })
  },
})
