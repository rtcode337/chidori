// ホーム画面から開いたとき（PWA）は、ページそのものの拡大縮小を止めます。
//
// 図（関連図・区画の地図など）は指の操作を自分で受ける（`pan_zoom.js`。器は touch-action: none）ので、
// ページをピンチで拡大して図が画面いっぱいになると、図の上ではページを動かせず、縮める手立ても無くなる。
// ブラウザで開いたときは止めない（アドレスバーがあり、拡大したページを戻す道が残る）。図の中の拡大縮小は
// 図の操作がそのまま受ける。
//
// iPhone の Safari は viewport の user-scalable=no を無視することがあるので、3 つを重ねる ——
// viewport の指定・iOS のピンチの合図（gesturestart）を止める・2 回押しての拡大を止める（CSS の touch-action）
export function lockPageZoom() {
  const standalone =
    window.navigator.standalone === true || window.matchMedia("(display-mode: standalone)").matches
  if (!standalone) { return }

  const meta = document.querySelector('meta[name="viewport"]')
  if (meta) {
    meta.setAttribute("content", "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no")
  }
  document.documentElement.classList.add("is-standalone")
  for (const type of ["gesturestart", "gesturechange", "gestureend"]) {
    document.addEventListener(type, (ev) => ev.preventDefault(), {passive: false})
  }
}
