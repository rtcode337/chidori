// 食事処の範囲を描く地図の操作。**共通の仕組み**（`./pan_zoom`）に、四角を描く口を足したもの。
//
// 「四角を描く」を押しているあいだは、引きずりが図の移動ではなく四角の描画になります
// （器に `is-drawing` を付け、共通の仕組みの `skip` に当てて移動を止める）。
// 描き終えたら緯度経度に直してサーバーへ送り、描く状態を抜けます。
import {panZoom} from "./pan_zoom"

// 区や駅の細かさまで寄れるようにする（日本全体の図で 1 km はおよそ 0.04 単位）
const MAX_SCALE = 2000
const MIN_SCALE = 0.2
// 地名で探した場所へ寄るときの倍率（市区町村が見分けられるくらい）
const FOCUS_SCALE = 200
// ピンを、画面の上で何倍に見せるか
const PIN_PX = 1.4

// 地理院タイル（標準地図）。**図と同じメルカトル**なので、図の座標へそのまま 1 次で重なる
const TILE_URL = "https://cyberjapandata.gsi.go.jp/xyz/std/{z}/{x}/{y}.png"
// 標準地図が配っている段。これより粗い段（日本全体を見ているとき）は白地図だけにする
const TILE_MIN_Z = 5
const TILE_MAX_Z = 18
// 1 枚のタイルを画面で何 px くらいに見せるか（256 が等倍）
const TILE_PX = 256
// 一度に並べる枚数の上限（大きな画面で寄ると増える。これを超えたら 1 段粗くする）
const TILE_MAX = 120

// 取っ手の太さ（画面の px。倍率で割り戻して、寄っても引いても同じ太さに見せる）
const HANDLE_PX = 14
// 取っ手の種類 → 動かす辺（n = 北・s = 南・w = 西・e = 東）
const HANDLES = {n: "n", s: "s", w: "w", e: "e", nw: "nw", ne: "ne", sw: "sw", se: "se"}

// メルカトルの逆（`Tazuna.Datasets.Map` の `mercator/1` と対）
const latOf = (merc) => (2 * Math.atan(Math.exp(merc * Math.PI / 180)) - Math.PI / 2) * 180 / Math.PI

export default panZoom({
  // **描いているあいだは図を動かさない**（器ごと skip に当てる）
  // **取っ手をつかんだときも図を動かさない**（四角の大きさを変える操作になる）
  skip: "[data-zoom], .relation-find, .is-drawing, [data-handle]",
  minScale: MIN_SCALE,
  maxScale: MAX_SCALE,

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
      // **取っ手をつかんだら、その辺（隅なら 2 辺）を動かす**
      const handle = ev.target.closest("[data-handle]")
      if (handle && this.draftBox()) {
        ev.preventDefault()
        this.resizing = {edges: handle.dataset.handle, box: this.draftBox()}
        this.el.setPointerCapture && ev.pointerId !== undefined && this.el.setPointerCapture(ev.pointerId)
        return
      }
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
      if (this.resizing) {
        const p = this.toSvg(ev)
        const box = {...this.resizing.box}
        const edges = this.resizing.edges
        if (edges.includes("n")) { box.y0 = p.y }
        if (edges.includes("s")) { box.y1 = p.y }
        if (edges.includes("w")) { box.x0 = p.x }
        if (edges.includes("e")) { box.x1 = p.x }
        this.resizing.now = box
        this.showDraft(box)
        return
      }
      if (!this.start || !this.box) { return }
      const now = this.toSvg(ev)
      this.box.setAttribute("x", Math.min(this.start.x, now.x))
      this.box.setAttribute("y", Math.min(this.start.y, now.y))
      this.box.setAttribute("width", Math.abs(now.x - this.start.x))
      this.box.setAttribute("height", Math.abs(now.y - this.start.y))
    }
    this.onUp = (ev) => {
      if (this.resizing) {
        const box = this.resizing.now
        this.resizing_edges = this.resizing.edges
        this.resizing = null
        if (!box) { return }
        // **動かした辺だけを地図から読む。** 動かしていない辺は欄の値をそのまま送る ——
        // 図の座標を経由すると、丸めのぶんだけ触っていない辺までずれる
        const edges = this.resizing_edges
        const field = (name) => parseFloat(this.el.closest("section").querySelector(`[name="area[${name}]"]`).value)
        const a = this.toLatLon({x: box.x0, y: box.y0})
        const b = this.toLatLon({x: box.x1, y: box.y1})
        const north = edges.includes("n") ? a.lat : field("north")
        const south = edges.includes("s") ? b.lat : field("south")
        const west = edges.includes("w") ? a.lon : field("west")
        const east = edges.includes("e") ? b.lon : field("east")
        // 引っ張りすぎて裏返っても、南 < 北・西 < 東にそろえて送る（サーバー側でもそろえる）
        this.pushEvent("drawn", {
          south: Math.min(south, north), north: Math.max(south, north),
          west: Math.min(west, east), east: Math.max(west, east),
        })
        return
      }
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
    this.paintHandles()
    const button = this.el.querySelector("[data-zoom='draw']")
    if (button) {
      button.setAttribute("aria-pressed", on ? "true" : "false")
      button.textContent = on ? "描くのをやめる" : "四角を描く"
    }
  },

  layer() { return this.el.querySelector("#area-draw-layer") },

  // サーバーが描いた「いま決めている四角」（図の座標の `{x0, y0, x1, y1}`）。無ければ null
  draftBox() {
    const rect = this.svg && this.svg.querySelector(".draft-rect")
    if (!rect) { return null }
    const x = parseFloat(rect.getAttribute("x"))
    const y = parseFloat(rect.getAttribute("y"))
    const w = parseFloat(rect.getAttribute("width"))
    const h = parseFloat(rect.getAttribute("height"))
    return [x, y, w, h].every(isFinite) ? {x0: x, y0: y, x1: x + w, y1: y + h} : null
  },

  // 引っ張っている最中の四角を見せる（サーバーの四角をその場で動かす。離すと送り直す）
  showDraft(box) {
    const rect = this.svg.querySelector(".draft-rect")
    if (!rect) { return }
    rect.setAttribute("x", Math.min(box.x0, box.x1))
    rect.setAttribute("y", Math.min(box.y0, box.y1))
    rect.setAttribute("width", Math.abs(box.x1 - box.x0))
    rect.setAttribute("height", Math.abs(box.y1 - box.y0))
    this.paintHandles()
  },

  // 取っ手を、いまの四角と倍率に合わせて置き直す。四角が無ければ外す
  paintHandles() {
    const group = this.el.querySelector("#area-handles")
    if (!group) { return }
    const box = this.draftBox()
    const ppu = this.view && this.view.ppu
    if (!box || !(ppu > 0) || this.el.classList.contains("is-drawing")) {
      group.replaceChildren()
      return
    }
    const t = HANDLE_PX / ppu
    const [x0, x1, y0, y1] = [box.x0, box.x1, box.y0, box.y1]
    const w = x1 - x0
    const h = y1 - y0
    // 辺は四角の辺に沿った細長い当たり、隅は小さな正方形（隅を後に置いて上にする）
    const shapes = {
      n: [x0, y0 - t / 2, w, t], s: [x0, y1 - t / 2, w, t],
      w: [x0 - t / 2, y0, t, h], e: [x1 - t / 2, y0, t, h],
      nw: [x0 - t / 2, y0 - t / 2, t, t], ne: [x1 - t / 2, y0 - t / 2, t, t],
      sw: [x0 - t / 2, y1 - t / 2, t, t], se: [x1 - t / 2, y1 - t / 2, t, t],
    }
    for (const key of Object.keys(HANDLES)) {
      let el = group.querySelector(`[data-handle="${key}"]`)
      if (!el) {
        el = document.createElementNS("http://www.w3.org/2000/svg", "rect")
        el.dataset.handle = key
        el.setAttribute("class", `rect-handle is-${key.length === 2 ? "corner" : "edge"} at-${key}`)
        group.appendChild(el)
      }
      const [x, y, width, height] = shapes[key]
      el.setAttribute("x", x)
      el.setAttribute("y", y)
      el.setAttribute("width", Math.max(width, 0))
      el.setAttribute("height", Math.max(height, 0))
    }
  },

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

  // ピンを、倍率で割り戻した大きさに置き直す。タイルも置き直す
  painted() {
    const ppu = this.view && this.view.ppu
    if (!this.svg || !(ppu > 0)) { return }
    const scale = PIN_PX / ppu
    this.svg.querySelectorAll("[data-pin]").forEach(pin => {
      pin.setAttribute("transform", `translate(${pin.dataset.x} ${pin.dataset.y}) scale(${scale})`)
    })
    this.paintTiles(ppu)
    // 引っ張っている最中はサーバーの四角を動かしているので、取っ手もそれに合わせる
    if (!this.resizing) { this.paintHandles() }
  },

  // 見えている範囲に地理院タイルを並べる。**図の座標で位置を出し、画面の座標へ直して置く**
  // （図の変換をそのまま使うので、引きずりにも拡大にもずれずに付いてくる）
  paintTiles(ppu) {
    const layer = this.el.querySelector("#area-tiles")
    if (!layer) { return }
    const west = parseFloat(this.svg.dataset.west)
    const top = parseFloat(this.svg.dataset.top)
    const scale = parseFloat(this.svg.dataset.scale)
    // 1 枚が画面で TILE_PX くらいになる段
    let z = Math.round(Math.log2(360 * scale * ppu / TILE_PX))
    if (z < TILE_MIN_Z) { return this.clearTiles(layer) }
    z = Math.min(z, TILE_MAX_Z)

    const ctm = this.svg.getScreenCTM()
    if (!ctm) { return }
    const inverse = ctm.inverse()
    const box = this.el.getBoundingClientRect()
    const corner = (x, y) => {
      const p = this.svg.createSVGPoint()
      p.x = x
      p.y = y
      return p.matrixTransform(inverse)
    }
    // 器の隅を図の座標へ（viewBox より器のほうが広いことがあるので、器で測る）
    const a = corner(box.left, box.top)
    const b = corner(box.right, box.bottom)

    let n, x0, x1, y0, y1
    for (;;) {
      n = 2 ** z
      const tileX = (x) => Math.floor((west + x / scale + 180) / 360 * n)
      const tileY = (y) => Math.floor((180 - (top - y / scale)) / 360 * n)
      ;[x0, x1, y0, y1] = [tileX(a.x), tileX(b.x), tileY(a.y), tileY(b.y)]
      if ((x1 - x0 + 1) * (y1 - y0 + 1) <= TILE_MAX || z <= TILE_MIN_Z) { break }
      z -= 1
    }

    const unit = 360 / n * scale
    const wanted = new Set()
    for (let tx = Math.max(x0, 0); tx <= Math.min(x1, n - 1); tx++) {
      for (let ty = Math.max(y0, 0); ty <= Math.min(y1, n - 1); ty++) {
        const key = `${z}/${tx}/${ty}`
        wanted.add(key)
        let img = layer.querySelector(`img[data-key="${key}"]`)
        if (!img) {
          img = document.createElement("img")
          img.dataset.key = key
          img.alt = ""
          img.decoding = "async"
          img.referrerPolicy = "no-referrer"
          img.onerror = () => { img.style.visibility = "hidden" }
          img.src = TILE_URL.replace("{z}", z).replace("{x}", tx).replace("{y}", ty)
          layer.appendChild(img)
        }
        // タイルの左上と右下を図の座標で出し、画面の座標へ
        const sx = ((tx / n) * 360 - 180 - west) * scale
        const sy = (top - (180 - (ty / n) * 360)) * scale
        const p = this.svg.createSVGPoint()
        p.x = sx
        p.y = sy
        const q = this.svg.createSVGPoint()
        q.x = sx + unit
        q.y = sy + unit
        const s1 = p.matrixTransform(ctm)
        const s2 = q.matrixTransform(ctm)
        // 隣と端を合わせる（小数のまま置くと継ぎ目に細い隙間が出る）
        const left = Math.floor(s1.x - box.left)
        const topPx = Math.floor(s1.y - box.top)
        img.style.left = `${left}px`
        img.style.top = `${topPx}px`
        img.style.width = `${Math.ceil(s2.x - box.left) - left}px`
        img.style.height = `${Math.ceil(s2.y - box.top) - topPx}px`
      }
    }
    // 見えなくなったものは外す（段が変わったときも）
    layer.querySelectorAll("img").forEach(img => {
      if (!wanted.has(img.dataset.key)) { img.remove() }
    })
    this.el.classList.toggle("has-tiles", wanted.size > 0)
  },

  clearTiles(layer) {
    layer.replaceChildren()
    this.el.classList.remove("has-tiles")
  },
})
