// 図を引きずって動かし、つまんで拡大するところ。**関連図も区画の地図もこれを使います**
// —— 図ごとに操作が違うと、画面を移るたびに覚え直すことになります。
//
// 図ごとの事情は `panZoom({...})` で足します（関連図は `relation_map.js`）。
// 足せる口は 4 つ ——
//
//   started()    起き上がったあと（サーバーからの知らせを受ける口を開けるなど）
//   painted()    当て直したあと（札を画面へ留める、見ている範囲を知らせる）
//   tapped(ev)   引きずりでも道具でもない押し込み
//   stopped()    片付け
//
// **素のホイールは横取りしません。** 図はページの中に埋まっているので、素で拡大に
// すると、読み進めようとスクロールしただけで図が動いてページが進まなくなります。
//
// **拡大は viewBox を動かして行います**（CSS の transform ではなく）。transform は
// 描いたものを引き伸ばすので、**寄るほど線が粗くなります** —— viewBox を狭めれば
// ブラウザが描き直すので、どこまで寄っても線は細いままです。

// これ以上動いたら「引きずった」とみなす（押したことにしない）
const DRAG_SLOP = 5

// 端を越えたあとの動きの重さ（1 が抵抗なし）と、伸びきるまでの px。
// **止まるのではなく重くする** —— 端で完全に動かなくなると、行き止まりなのか
// 操作が効いていないのかが指先から区別できない
const RUBBER = 0.45
const RUBBER_MAX = 110

// 収まっている軸は真ん中に置く（上や左に寄せると、余白が片側に溜まって壊れて見える）
const centre = (slack) => [slack / 2, slack / 2]

const base = {
  // 倍率の下限と上限。**下は 1 倍より小さくできる** —— 縦に長い図（日本の地図が
  // そうです）は、幅いっぱいに描くと縦が器に収まらないので、「全体」で全部を
  // 見せるには縮める必要があります
  minScale: 0.2,
  maxScale: 12,

  // 全体表示の倍率を下限にするか。**全体より小さくしても読めるものは増えない**
  // 図（関連図）で使う。縦に長い図では全体表示が 1 倍より小さくなるので、
  // 決まった値を下限にすると、開いたときに全体が収まらない
  fitFloor: false,

  // ここから始まった引きずりは図を動かさない（押す口・入力の口がこれに当たる）
  skip: "[data-zoom]",

  // この倍率まで寄ったら器に `is-close` を付ける。**近づいたときだけ見せたいもの**
  // （区画の境目のような、全体では画面を埋めてしまう線）を CSS 側で出すため。
  // 0 なら何もしない
  closeAt: 0,

  // 図ごとに足す口。何もしないのが既定
  started() {},
  painted() {},
  tapped() {},
  stopped() {},

  mounted() {
    this.scale = 1
    this.tx = 0
    this.ty = 0
    this.moved = 0
    this.pointers = new Map()
    this.pinch = null
    // **図は枠の直下の svg。** 道具のボタンにも svg（アイコン）が入っていて、
    // 枠の中から最初の svg を探すとそちらを掴み、図が動かず札も描かれなくなる
    this.svg = this.el.querySelector(":scope > svg")
    // **元の viewBox は覚えておく。** 動かすのはこれなので、動かしたあとに
    // 読み直すと、そのときの値が「元」になってしまう
    this.base = this.viewBox()
    this.bind()
    // **開いたら全体が見える。** 端から始めると、いちばん見たい真ん中へ
    // たどり着くのに引きずる必要があります
    this.fit()
    this.started()
  },

  updated() {
    // 描き直されると svg の要素が入れ替わるので、持ち直してから当て直す
    this.svg = this.el.querySelector(":scope > svg")
    const now = this.svg && this.svg.getAttribute("viewBox")
    // **自分が書いた値を「元」にしない** —— 動かしたぶんが元に化けると、
    // 描き直されるたびに図がそのぶんずれていく。サーバーが書き戻した値
    // （＝自分が書いたものと違う値）のときだけ取り直す
    if (now && now !== this.written) {
      const before = this.base
      this.base = this.viewBox() || this.base
      // **図の大きさが変わったら全体表示からやり直す。** 絞り込みで置き直すと
      // 高さが変わるので、前の倍率のままだと一部しか見えない（または余白だらけ）
      if (!before || before[2] !== this.base[2] || before[3] !== this.base[3]) {
        this.fit()
        return
      }
    }
    this.apply()
  },

  // いまの倍率の下限
  lowest() {
    return this.fitFloor && this.fitted > 0 ? Math.min(this.fitted, 1) : this.minScale
  },

  // いまの viewBox（`[x, y, 幅, 高さ]`）。読めなければ null
  viewBox() {
    const view = (this.svg && this.svg.getAttribute("viewBox") || "").split(/\s+/).map(parseFloat)
    return view.length === 4 && view.every((n) => isFinite(n)) ? view : null
  },

  destroyed() {
    this.stopped()
    this.unbind()
  },

  apply() {
    if (!this.svg || !this.base) { return }
    // 数でない値が 1 つでも混ざると viewBox ごと無効になり、**黙って動かなくなる**
    if (!isFinite(this.tx) || !isFinite(this.ty) || !isFinite(this.scale)) {
      this.tx = 0
      this.ty = 0
      this.scale = 1
    }
    const box = this.el.getBoundingClientRect()
    const ppu = this.perUnit(box)
    if (!(ppu > 0)) { return }
    // 器に映る範囲を、図の座標で書き直す。**寄るほど狭くなる** —— 描き直されるので
    // 線は細いまま
    const view = {
      x: this.base[0] - this.tx / ppu,
      y: this.base[1] - this.ty / ppu,
      w: box.width / ppu,
      h: box.height / ppu,
      ppu: ppu,
    }
    this.view = view
    this.written = `${view.x} ${view.y} ${view.w} ${view.h}`
    this.svg.setAttribute("viewBox", this.written)
    if (this.closeAt) { this.el.classList.toggle("is-close", this.scale >= this.closeAt) }
    this.painted()
  },

  // 図の 1 単位が画面の何 px か（器の幅に合わせた倍率 × いまの倍率）
  perUnit(box) {
    const width = this.base && this.base[2]
    return width > 0 && box.width > 0 ? (box.width / width) * this.scale : 0
  },

  // いま触れている 2 本の指の間隔と中点
  spread() {
    const [a, b] = Array.from(this.pointers.values())
    return {
      distance: Math.hypot(a.x - b.x, a.y - b.y),
      x: (a.x + b.x) / 2,
      y: (a.y + b.y) / 2,
    }
  },

  // いま画面に出ている図の大きさ（倍率こみ）と、器の大きさ。
  //
  // **SVG に offsetWidth は使えない。** SVGElement は HTMLElement ではないので
  // 値が undefined になり、掛けた先が NaN になって見え方ごと壊れる。
  metrics() {
    const box = this.el.getBoundingClientRect()
    const [, , vw, vh] = this.base || [0, 0, 0, 0]
    const width = box.width
    const height = vw > 0 && vh > 0 ? width * (vh / vw) : box.height
    return {box, width: width * this.scale, height: height * this.scale}
  },

  range() {
    const {box, width, height} = this.metrics()
    if (!isFinite(width) || !isFinite(height)) { return null }
    return {
      x: width <= box.width ? centre(box.width - width) : [box.width - width, 0],
      y: height <= box.height ? centre(box.height - height) : [box.height - height, 0],
    }
  },

  clamp() {
    const limit = this.range()
    if (!limit) { return }
    this.tx = Math.min(limit.x[1], Math.max(limit.x[0], this.tx))
    this.ty = Math.min(limit.y[1], Math.max(limit.y[0], this.ty))
  },

  overshoot(value, [min, max]) {
    if (value > max) { return value - max }
    if (value < min) { return value - min }
    return 0
  },

  drag(dx, dy) {
    const limit = this.range()
    if (!limit) { return }
    this.tx = this.pull(this.tx, dx, limit.x)
    this.ty = this.pull(this.ty, dy, limit.y)
  },

  pull(value, delta, bounds) {
    const out = Math.abs(this.overshoot(value, bounds))
    const give = out >= RUBBER_MAX ? 0 : RUBBER * (1 - out / RUBBER_MAX)
    const next = value + delta
    // 範囲へ戻る向きの動きには抵抗をかけない（戻すのが重いと直感に反する）
    const returning = Math.abs(this.overshoot(next, bounds)) < out
    return returning ? next : value + delta * (out > 0 ? give : 1)
  },

  settle() {
    const {tx, ty} = this
    this.clamp()
    if (this.tx === tx && this.ty === ty) { return }
    this.apply()
  },

  // 倍率を変える。**押した点を動かさない** —— 中心を固定して拡大すると、
  // 見ていたものが画面の外へ逃げる
  zoomAt(factor, clientX, clientY) {
    const next = Math.min(this.maxScale, Math.max(this.lowest(), this.scale * factor))
    if (next === this.scale) { return }
    const box = this.el.getBoundingClientRect()
    const px = clientX - box.left
    const py = clientY - box.top
    const ratio = next / this.scale
    this.tx = px - (px - this.tx) * ratio
    this.ty = py - (py - this.ty) * ratio
    this.scale = next
    this.clamp()
    this.apply()
  },

  // 図の座標 (x, y) を器の真ん中に置く。**倍率は器の大きさを知っている側で決める**
  // —— 何 px の器に映しているかはサーバーからは見えない
  centerOn(x, y, least) {
    const box = this.el.getBoundingClientRect()
    if (!(this.perUnit(box) > 0)) { return }
    this.scale = Math.min(this.maxScale, Math.max(this.scale, least || this.scale))
    const ppu = this.perUnit(box)
    this.tx = (this.base[0] - x) * ppu + box.width / 2
    this.ty = (this.base[1] - y) * ppu + box.height / 2
    this.clamp()
    this.apply()
  },

  // 全体を見せる。**器に収まる倍率**まで縮めて、真ん中に置く
  fit() {
    const box = this.el.getBoundingClientRect()
    const [, , vw, vh] = this.base || [0, 0, 0, 0]
    this.scale = 1
    this.tx = 0
    this.ty = 0

    if (vw > 0 && vh > 0 && box.width > 0 && box.height > 0) {
      const height = box.width * (vh / vw)
      this.scale = Math.max(this.minScale, Math.min(1, box.height / height))
    }
    // 全体表示の倍率を覚える（`fitFloor` の図ではこれが縮める下限になる）
    this.fitted = this.scale

    this.clamp()
    this.apply()
  },

  reset() {
    this.fit()
  },

  // 全画面。**使えない端末がある** —— iOS の Safari は動画以外を全画面にできない
  // ので、そこでは器に class を足して画面いっぱいに広げる（見た目は同じになる）
  fullscreen() {
    // **埋め込まれているときは、埋め込みの枠ごと画面いっぱいにする**（トップページの
    // 関連図）。器だけを広げても、広がるのは埋め込みの枠の中まで —— スマホでは
    // 本物の全画面が使えず、器を広げる代わりの手が枠の中で止まっていた
    const frame = embeddingFrame()
    if (frame) {
      this.frameFullscreen(frame)
      return
    }
    if (document.fullscreenElement) {
      document.exitFullscreen()
      return
    }
    if (this.el.classList.contains("faux-fullscreen")) {
      this.el.classList.remove("faux-fullscreen")
      this.onFullscreen()
      return
    }
    if (this.el.requestFullscreen) {
      this.el.requestFullscreen().catch(() => this.fauxFullscreen())
    } else {
      this.fauxFullscreen()
    }
  },

  fauxFullscreen() {
    this.el.classList.add("faux-fullscreen")
    this.onFullscreen()
  },

  // 埋め込みの枠（親の画面の iframe）を画面いっぱいにする・戻す。器は枠の中で
  // いっぱいに広げる。使える端末では親の画面で本物の全画面にもする。
  // **器の印は <html> に付ける** —— 器そのものに付けると、LiveView が描き直す
  // たびに消える（器の class は画面の側が持っている）
  frameFullscreen(frame) {
    const parentDoc = frame.ownerDocument
    const root = document.documentElement
    const on = frame.classList.contains("frame-fullscreen")
    if (on) {
      if (parentDoc.fullscreenElement === frame) parentDoc.exitFullscreen().catch(() => {})
      frame.classList.remove("frame-fullscreen")
      root.classList.remove("in-frame-fullscreen")
    } else {
      frame.classList.add("frame-fullscreen")
      root.classList.add("in-frame-fullscreen")
      if (frame.requestFullscreen) frame.requestFullscreen().catch(() => {})
    }
    // 大きさが変わってから測り直す
    requestAnimationFrame(() => this.onFullscreen())
  },

  bind() {
    this.onWheel = (ev) => {
      // トラックパッドのつまむ操作は ctrlKey 付きの wheel として届くので、
      // この分岐だけで指の操作も拾える
      if (!ev.ctrlKey && !ev.metaKey) { return }
      ev.preventDefault()
      this.zoomAt(ev.deltaY < 0 ? 1.15 : 1 / 1.15, ev.clientX, ev.clientY)
    }

    this.onPointerDown = (ev) => {
      // 道具や入力の口は図の操作にしない（押しただけで図が動くと驚くし、
      // 既定の動きを止めると字が打てなくなる）
      if (this.skip && ev.target.closest(this.skip)) {
        this.moved = 0
        return
      }
      // **引きずりはいつでも画面移動。** 図の要素の上から始めても動く ——
      // 押せるものの上だけ動かないと、込み合ったところで掴む場所を探すことになる。
      // 既定の動き（字の選択・画像の持ち出し）はここで止める。**click は止まらない**
      // ので、動かさずに離したときは今までどおり選べる
      ev.preventDefault()
      // **指は何本でも来る。** 1 本ぶんしか覚えないと、2 本目を置いた瞬間に
      // 座標が飛び、つまむ操作が引きずりとして扱われる
      this.pointers.set(ev.pointerId, {x: ev.clientX, y: ev.clientY})
      this.dragging = true
      this.moved = 0
      this.lastX = ev.clientX
      this.lastY = ev.clientY
      this.pinch = this.pointers.size >= 2 ? this.spread() : null
      // **ここでは捕まえない。** ポインタを捕捉すると、続く click の宛先が
      // 捕捉した要素へ付け替えられ、図の phx-click に届かなくなる
    }

    this.onPointerMove = (ev) => {
      if (!this.dragging) { return }
      if (this.pointers.has(ev.pointerId)) {
        this.pointers.set(ev.pointerId, {x: ev.clientX, y: ev.clientY})
      }
      // 指 2 本ならつまむ拡大。**ホイールの無い端末ではこれが唯一の拡大手段**
      if (this.pointers.size >= 2) {
        const now = this.spread()
        if (this.pinch && this.pinch.distance > 0 && now.distance > 0) {
          this.moved = Infinity
          this.zoomAt(now.distance / this.pinch.distance, now.x, now.y)
        }
        this.pinch = now
        return
      }

      const dx = ev.clientX - this.lastX
      const dy = ev.clientY - this.lastY
      this.moved += Math.abs(dx) + Math.abs(dy)
      this.lastX = ev.clientX
      this.lastY = ev.clientY
      // 引きずりだと分かった時点で捕まえる。指が図の外へ出ても追い続けるため
      if (this.moved > DRAG_SLOP && !this.el.hasPointerCapture(ev.pointerId)) {
        this.el.setPointerCapture(ev.pointerId)
      }
      this.drag(dx, dy)
      this.apply()
    }

    this.onPointerUp = (ev) => {
      this.pointers.delete(ev.pointerId)
      this.pinch = this.pointers.size >= 2 ? this.spread() : null
      if (!this.dragging) { return }
      if (this.pointers.size > 0) { return }
      this.dragging = false
      if (this.el.hasPointerCapture(ev.pointerId)) {
        this.el.releasePointerCapture(ev.pointerId)
      }
      this.settle()
    }

    // 引きずった直後の click は捨てる（動かしただけで選ばれてしまう）
    this.onClickCapture = (ev) => {
      if (this.moved > DRAG_SLOP) {
        ev.stopPropagation()
        ev.preventDefault()
        this.moved = 0
        return
      }
      const button = ev.target.closest("[data-zoom]")
      if (!button) {
        this.tapped(ev)
        return
      }
      ev.preventDefault()
      const box = this.el.getBoundingClientRect()
      const middle = [box.left + box.width / 2, box.top + box.height / 2]
      const how = button.dataset.zoom
      if (how === "in") { this.zoomAt(1.4, ...middle) }
      if (how === "out") { this.zoomAt(1 / 1.4, ...middle) }
      if (how === "reset") { this.reset() }
      if (how === "full") { this.fullscreen() }
    }

    // 全画面に入る・出ると器の大きさが変わるので、はみ出しを測り直す
    this.onFullscreen = () => { this.clamp(); this.apply() }

    // **子より先に受け取る**（capture）—— 図の要素が握っていても、引きずりは
    // 画面移動として先に効く
    this.el.addEventListener("wheel", this.onWheel, {passive: false})
    this.el.addEventListener("pointerdown", this.onPointerDown, true)
    this.el.addEventListener("pointermove", this.onPointerMove, true)
    this.el.addEventListener("pointerup", this.onPointerUp, true)
    this.el.addEventListener("pointercancel", this.onPointerUp, true)
    this.el.addEventListener("click", this.onClickCapture, true)
    document.addEventListener("fullscreenchange", this.onFullscreen)
    // 親の画面が本物の全画面を抜けたとき（Esc など）は、器も戻す
    this.onFrameExit = () => {
      document.documentElement.classList.remove("in-frame-fullscreen")
      this.onFullscreen()
    }
    window.addEventListener("chidori:frame-fullscreen-exit", this.onFrameExit)
  },

  unbind() {
    this.el.removeEventListener("wheel", this.onWheel)
    this.el.removeEventListener("pointerdown", this.onPointerDown, true)
    this.el.removeEventListener("pointermove", this.onPointerMove, true)
    this.el.removeEventListener("pointerup", this.onPointerUp, true)
    this.el.removeEventListener("pointercancel", this.onPointerUp, true)
    this.el.removeEventListener("click", this.onClickCapture, true)
    document.removeEventListener("fullscreenchange", this.onFullscreen)
    window.removeEventListener("chidori:frame-fullscreen-exit", this.onFrameExit)
  },
}

// 同じサイトの画面に埋め込まれていれば、その枠（iframe）。そうでなければ null
const embeddingFrame = () => {
  try {
    return window.self !== window.top ? window.frameElement : null
  } catch (_e) {
    return null
  }
}

// 図ごとの事情を足したフックを作る。**素のままでは使いません** ——
// 倍率の幅は図によって違う（関連図は 1〜8 倍、区画の地図は 0.2〜400 倍）
export function panZoom(extra = {}) {
  return Object.assign({}, base, extra)
}
