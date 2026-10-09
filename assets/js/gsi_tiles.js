// 地理院タイル（国土地理院の標準地図）を、図（svg）の下に敷く。
//
// 区画の地図と食事処の範囲の地図で同じものを使う。図の器に `.tile-layer` の層を置き、
// 当て直すたび（`painted()`）に `paintTiles(hook, 層, ppu)` を呼ぶ。図の svg には
// 投影の枠（`data-west` / `data-top` / `data-scale`。`Chidori.Datasets.Map` の `frame`）を
// 書いておく。
//
// **参照元は送らない**（画面のアドレスを外へ出さない）。タイルを出しているあいだは
// 器に `has-tiles` を付ける（白地図の陸地を透かすため。CSS の側で見る）。

// 図と同じメルカトルなので、図の座標へそのまま 1 次で重なる
const TILE_URL = "https://cyberjapandata.gsi.go.jp/xyz/std/{z}/{x}/{y}.png"
// 標準地図が配っている段。これより粗い段（日本全体を見ているとき）は白地図だけにする
const TILE_MIN_Z = 5
const TILE_MAX_Z = 18
// 1 枚のタイルを画面で何 px くらいに見せるか（256 が等倍）
const TILE_PX = 256
// 一度に並べる枚数の上限（大きな画面で寄ると増える。これを超えたら 1 段粗くする）
const TILE_MAX = 120

// 見えている範囲にタイルを並べる。**図の座標で位置を出し、画面の座標へ直して置く**
// （図の変換をそのまま使うので、引きずりにも拡大にもずれずに付いてくる）
export function paintTiles(hook, layer, ppu) {
  if (!layer || !hook.svg || !(ppu > 0)) { return }
  const west = parseFloat(hook.svg.dataset.west)
  const top = parseFloat(hook.svg.dataset.top)
  const scale = parseFloat(hook.svg.dataset.scale)
  // 1 枚が画面で TILE_PX くらいになる段
  let z = Math.round(Math.log2(360 * scale * ppu / TILE_PX))
  if (z < TILE_MIN_Z) { return clearTiles(hook, layer) }
  z = Math.min(z, TILE_MAX_Z)

  const ctm = hook.svg.getScreenCTM()
  if (!ctm) { return }
  const inverse = ctm.inverse()
  const box = hook.el.getBoundingClientRect()
  const corner = (x, y) => {
    const p = hook.svg.createSVGPoint()
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
      const p = hook.svg.createSVGPoint()
      p.x = sx
      p.y = sy
      const q = hook.svg.createSVGPoint()
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
  hook.el.classList.toggle("has-tiles", wanted.size > 0)
}

function clearTiles(hook, layer) {
  layer.replaceChildren()
  hook.el.classList.remove("has-tiles")
}
