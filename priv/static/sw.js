// 通知を受けて出すだけの service worker（Chidori.WebPush が送る）。
//
// **サイトの根に置く**（/sw.js）。service worker が受け持てるのは自分の置き場より下だけで、
// /assets/ に置くと、押した通知から開く /news を受け持てない。
// **ページの取得には関わらない**（fetch を扱わない）。画面は LiveView が繋いで描くので、
// ここで写しを持つと古い画面を出すだけになる。

// 入れ替わったらすぐ受け持つ。**開いている画面も受け持つ**（claim）——
// 受け持っていない画面は、通知を押したときに行き先へ移せない
self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()))

// 届いた中身は JSON（{title, body, url, tag}）。読めなければ文字のまま本文に出す ——
// 何も出さずに捨てると、iPhone では「通知を出さない受け取り」が続いた端末の購読が切られる
self.addEventListener("push", event => {
  let data = {}
  try {
    data = event.data ? event.data.json() : {}
  } catch (_error) {
    data = {body: event.data ? event.data.text() : ""}
  }

  const title = data.title || "Chidori"
  const options = {
    body: data.body || "",
    icon: "/images/icon-192.png",
    badge: "/images/icon-192.png",
    data: {url: data.url || "/"},
    lang: "ja",
  }
  // 同じ話題の知らせは差し替える（古いまとめの通知を積み上げない）
  if (data.tag) options.tag = data.tag

  event.waitUntil(self.registration.showNotification(title, options))
})

// 画面が「移った」と返すのを待つ長さ（ミリ秒）。返事が無ければ、古い画面とみなして別の手で移す
const ASK_TIMEOUT_MS = 1500

// **開いている画面に、自分で行き先へ移ってもらう**（画面の側は app.js の "chidori:navigate"）。
// 移ると返事をくれたら true。iPhone のホーム画面アプリでは、こちらから移す `client.navigate` が
// 失敗も言わずに何もしないことがあり、通知を押してもアプリが前に出るだけで、前に見ていた画面の
// ままだった。画面の側で `location` を変えるなら、どの端末でも確かに移る
function askToGo(client, url) {
  return new Promise(resolve => {
    const channel = new MessageChannel()
    const timer = setTimeout(() => resolve(false), ASK_TIMEOUT_MS)
    channel.port1.onmessage = () => {
      clearTimeout(timer)
      resolve(true)
    }
    try {
      client.postMessage({type: "chidori:navigate", url}, [channel.port2])
    } catch (_error) {
      clearTimeout(timer)
      resolve(false)
    }
  })
}

// 押したら、**開いている Chidori があればそれを前に出して行き先へ移す**。
// 無ければ新しく開く（ホーム画面から入れた端末では、アプリとして開く）
self.addEventListener("notificationclick", event => {
  event.notification.close()
  const url = new URL((event.notification.data && event.notification.data.url) || "/", self.location.origin).href

  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({type: "window", includeUncontrolled: true})
    const same = windows.find(client => new URL(client.url).origin === self.location.origin)

    if (same) {
      try {
        await same.focus()
      } catch (_error) {
        // 前に出せなくても、移ってもらうことはできる
      }
      if (await askToGo(same, url)) return
      // 返事をくれない画面（この仕組みを持たない古い画面）は、こちらから移す
      if ("navigate" in same) {
        try {
          if (await same.navigate(url)) return
        } catch (_error) {
          // 受け持っていない画面は移せない。新しく開くほうへ倒す
        }
      }
    }
    await self.clients.openWindow(url)
  })())
})
