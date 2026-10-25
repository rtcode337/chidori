// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/chidori"
// 図を引きずって動かし、つまんで拡大するところ。**画面をまたいで同じ操作**にする
// ため、テンプレートの中ではなくここに置く（中身は共通の ./pan_zoom で、
// 倍率の幅や札の留め方といった図ごとの事情だけをそれぞれが足す）
import PartitionMap from "./partition_map"
import PrefectureMap from "./prefecture_map"
import AreaDraw from "./area_draw"
import RelationMap from "./relation_map"
import DownloadLink from "./download_link"
// 全画面の要約を左右に払って前後へ動かす
import DigestSwipe from "./digest_swipe"
import PanelSwipe from "./panel_swipe"
// トピックの網を関連図と同じ操作で動かす
import TopicMap from "./topic_map"
import ScrollTabs from "./scroll_tabs"
import AutoHeight from "./auto_height"
// 中身（main）だけをスクロールさせる骨組みで、タブの切り替えと戻る・進むの位置を受け持つ
import PageScroll from "./page_scroll"
// 映画の札の「近くの上映館を Gemini に聞く」。押したときに現在地を添える
import AskNearby from "./ask_nearby"
// 映画の画面の「現在地の近くを探す」（映画館）。押したときに現在地をサーバーへ送る
import TheaterNearby from "./theater_nearby"
// 設定の「通知」タブの「この端末に通知を送る」（Web Push の購読）
import WebPush from "./web_push"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, PartitionMap, PrefectureMap, AreaDraw, RelationMap, DownloadLink, DigestSwipe, PanelSwipe, TopicMap, ScrollTabs, AutoHeight, PageScroll, AskNearby, TheaterNearby, WebPush},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// 通知（Web Push）を受けて出す service worker。**どの画面からも入れておく** ——
// 通知を押して開いた画面を、すでに開いている Chidori へ移すには、その画面を
// service worker が受け持っている必要がある。https（か localhost）でないと入らない
if ("serviceWorker" in navigator && window.isSecureContext) {
  navigator.serviceWorker.register("/sw.js").catch(() => {})

  // 通知を押したとき、service worker から「ここへ移って」と頼まれたら**自分で移る**（sw.js の askToGo）。
  // iPhone のホーム画面アプリでは service worker の側から画面を移せないことがあり、アプリが
  // 前に出るだけで前の画面のままだった。行き先は同じサイトの中だけ。同じ画面でも読み直す
  // （まとめの通知は「いちばん新しいまとめを開く」なので、開き直さないと出ない）
  navigator.serviceWorker.addEventListener("message", async event => {
    const data = event.data || {}
    if (data.type !== "chidori:navigate" || typeof data.url !== "string") return
    const url = new URL(data.url, window.location.origin)
    if (url.origin !== window.location.origin) return
    if (event.ports && event.ports[0]) event.ports[0].postMessage({ok: true})
    // 書き置きは使ったので消す（移った先で、同じ行き先へもう一度移らないように）
    await dropNavigationNote()
    window.location.assign(url.href)
  })
  navigator.serviceWorker.startMessages()

  // **画面が前に出たら、通知の書き置きを読んで移る**（sw.js の leaveNote）。iPhone のホーム画面アプリは
  // 裏で止まっていて「ここへ移って」の頼みを受け取れないことがあり、通知を押してもアプリが前に
  // 出るだけだった。開いたとき・裏から戻ったときに読む
  window.addEventListener("pageshow", takeNavigation)
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") takeNavigation()
  })
}

// 通知の行き先の書き置き（sw.js と同じ名前）。2 分より古いものは使わない（押してから時間が経った書き置きで、
// 別の用事で開いた画面を勝手に移さない）
const NAV_CACHE = "chidori-nav"
const NAV_KEY = "/__chidori_nav"
const NAV_FRESH_MS = 2 * 60 * 1000

async function dropNavigationNote() {
  try {
    const cache = await caches.open(NAV_CACHE)
    await cache.delete(NAV_KEY)
  } catch (_error) {
    // 読めない端末では書き置きも無い
  }
}

async function takeNavigation() {
  if (!("caches" in window)) return
  try {
    const cache = await caches.open(NAV_CACHE)
    const found = await cache.match(NAV_KEY)
    if (!found) return
    const note = await found.json()
    await cache.delete(NAV_KEY)
    if (!note || typeof note.url !== "string" || Date.now() - note.at > NAV_FRESH_MS) return
    const url = new URL(note.url, window.location.origin)
    if (url.origin !== window.location.origin) return
    // いまの画面がちょうど行き先なら移らない（通知から新しく開いたときは、もう着いている）
    if (url.pathname + url.search === window.location.pathname + window.location.search) return
    window.location.assign(url.href)
  } catch (_error) {
    // 書き置きが読めなければ、何もしない
  }
}

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
