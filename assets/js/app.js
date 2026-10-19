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
import SortableList from "./sortable_list"
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
  hooks: {...colocatedHooks, PartitionMap, PrefectureMap, AreaDraw, RelationMap, DownloadLink, DigestSwipe, PanelSwipe, TopicMap, SortableList, ScrollTabs, AutoHeight, PageScroll, AskNearby, TheaterNearby, WebPush},
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
}

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
