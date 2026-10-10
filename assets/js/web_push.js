// この端末で通知（Web Push）を受け取るかを切り替える（設定の「通知」タブ）。
//
// 送り手の公開鍵は data-key で受け取り、ブラウザが作った宛先（PushSubscription）を
// LiveView へ渡す（push_subscribe）。**暗号と送信はサーバーがする**（Chidori.WebPush）。
//
// **通知の許可は、押したその場で聞く。** 押した操作から離れて聞くと、ブラウザ
// （とくに iPhone）は聞かずに断る。だから押した直後の最初の待ちを requestPermission にする。
//
// iPhone は**ホーム画面に入れて、そこから開いた Chidori にだけ**通知を許す
// （Safari のタブのままでは PushManager が無い）。その場合は手順を出す。

function base64UrlToBytes(text) {
  const padded = (text + "===".slice((text.length + 3) % 4)).replace(/-/g, "+").replace(/_/g, "/")
  return Uint8Array.from(atob(padded), c => c.charCodeAt(0))
}

function sameBytes(buffer, bytes) {
  if (!buffer) return false
  const a = new Uint8Array(buffer)
  return a.length === bytes.length && a.every((value, i) => value === bytes[i])
}

function isIos() {
  return /iPhone|iPad|iPod/.test(navigator.userAgent) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
}

function isStandalone() {
  return window.navigator.standalone === true || window.matchMedia("(display-mode: standalone)").matches
}

export default {
  mounted() {
    this.state = this.el.querySelector("[data-role=state]")
    this.enableButton = this.el.querySelector("[data-role=enable]")
    this.disableButton = this.el.querySelector("[data-role=disable]")

    this.onEnable = () => this.enable()
    this.onDisable = () => this.disable()
    this.enableButton.addEventListener("click", this.onEnable)
    this.disableButton.addEventListener("click", this.onDisable)

    // 一覧から外したときは、この端末の様子も確かめ直す（外したのがこの端末かもしれない）
    this.handleEvent("web_push:refresh", () => this.refresh())
    this.refresh()
  },

  destroyed() {
    this.enableButton.removeEventListener("click", this.onEnable)
    this.disableButton.removeEventListener("click", this.onDisable)
  },

  show(text, {enable = false, disable = false} = {}) {
    this.state.textContent = text
    this.enableButton.hidden = !enable
    this.disableButton.hidden = !disable
  },

  unsupportedText() {
    if (!window.isSecureContext) return "https で開いたときだけ使えます。"
    if (isIos() && !isStandalone()) {
      return "iPhone では、Safari の共有メニューから「ホーム画面に追加」し、ホーム画面の Chidori から開くと受け取れます（iOS 16.4 以降）。開いたら、ここでもう一度押してください。"
    }
    return "このブラウザは通知（Web Push）に対応していません。"
  },

  supported() {
    return window.isSecureContext && "serviceWorker" in navigator && "PushManager" in window && "Notification" in window
  },

  async registration() {
    await navigator.serviceWorker.register("/sw.js")
    return navigator.serviceWorker.ready
  },

  // いまの様子を出す。**ブラウザが宛先を持っていても、Chidori が知らなければ未登録**として出す
  // （別の端末から一覧で外したとき・DB を作り直したとき）
  async refresh() {
    if (!this.supported()) return this.show(this.unsupportedText())
    if (Notification.permission === "denied") {
      return this.show("この端末では通知が拒否されています。端末（ブラウザ）の設定で Chidori の通知を許可してください。")
    }

    try {
      const registration = await this.registration()
      const subscription = await registration.pushManager.getSubscription()
      if (!subscription) return this.show("この端末はまだ受け取っていません。", {enable: true})

      this.pushEvent("push_check", {endpoint: subscription.endpoint}, ({registered}) => {
        if (registered) this.show("この端末は通知を受け取ります。", {disable: true})
        else this.show("この端末はまだ受け取っていません。", {enable: true})
      })
    } catch (error) {
      this.show("この端末の様子を確かめられませんでした（" + error.message + "）。", {enable: true})
    }
  },

  async enable() {
    // **最初の待ちを許可にする**（押した操作の中で聞かないと、聞かずに断られる）
    const permission = await Notification.requestPermission()
    if (permission !== "granted") {
      return this.show("通知が許可されませんでした。端末（ブラウザ）の設定で Chidori の通知を許可してください。")
    }

    this.show("登録しています…")
    try {
      const key = base64UrlToBytes(this.el.dataset.key)
      const registration = await this.registration()
      let subscription = await registration.pushManager.getSubscription()

      // 送り手の鍵が替わっていたら（DB を作り直したなど）、古い宛先では受け取れない
      if (subscription && !sameBytes(subscription.options.applicationServerKey, key)) {
        await subscription.unsubscribe()
        subscription = null
      }
      if (!subscription) {
        subscription = await registration.pushManager.subscribe({userVisibleOnly: true, applicationServerKey: key})
      }

      this.pushEvent("push_subscribe", {subscription: subscription.toJSON(), user_agent: navigator.userAgent}, ({ok}) => {
        if (ok) this.show("この端末は通知を受け取ります。", {disable: true})
        else this.show("登録できませんでした。", {enable: true})
      })
    } catch (error) {
      this.show("登録できませんでした（" + error.message + "）。", {enable: true})
    }
  },

  async disable() {
    try {
      const registration = await this.registration()
      const subscription = await registration.pushManager.getSubscription()
      if (subscription) {
        const endpoint = subscription.endpoint
        await subscription.unsubscribe()
        this.pushEvent("push_unsubscribe", {endpoint})
      }
      this.show("この端末では受け取りません。", {enable: true})
    } catch (error) {
      this.show("止められませんでした（" + error.message + "）。", {disable: true})
    }
  },
}
