// 映画の画面の「現在地の近くを探す」（`ChidoriWeb.TheaterPanel`）。押したときにブラウザから
// 現在地を取って、サーバーへ送る（座標は送るだけで、どこにも残さない）。
// 取れなければ（断られた・時間切れ・https でない）そう送り、画面に理由を出してもらう。

const TIMEOUT_MS = 8000

export default {
  mounted() {
    this.button = this.el.querySelector("button")
    this.status = this.el.querySelector("[data-status]")
    if (!this.button) return

    this.onClick = () => {
      if (!navigator.geolocation) {
        this.pushEvent("theaters_near", {})
        return
      }
      this.button.disabled = true
      if (this.status) this.status.textContent = "現在地を取っています…"
      const done = () => {
        this.button.disabled = false
        if (this.status) this.status.textContent = ""
      }
      navigator.geolocation.getCurrentPosition(
        ({coords}) => {
          done()
          this.pushEvent("theaters_near", {lat: coords.latitude, lon: coords.longitude})
        },
        () => {
          done()
          this.pushEvent("theaters_near", {})
        },
        {timeout: TIMEOUT_MS, maximumAge: 10 * 60 * 1000}
      )
    }
    this.button.addEventListener("click", this.onClick)
  },

  destroyed() {
    if (this.button) this.button.removeEventListener("click", this.onClick)
  }
}
