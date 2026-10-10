// 近くで上映している映画館を Gemini（Google 検索の AI モード）に聞くリンク（映画の札）。
//
// **押したときに現在地をブラウザから取り、質問文に添えて開きます。** 取れなければ
// （断られた・時間切れ・https でない）、現在地を書かない質問のまま開きます ——
// AI モードの側でもおおよその場所は分かるので、聞けないよりはよい。
//
// 現在地を待ってから新しいタブを開くと、押した操作から離れるのでブラウザに止められる。
// **押したその場で空のタブを開き、場所が分かってから行き先を入れます。**

const TIMEOUT_MS = 6000

function aiModeUrl(question) {
  return "https://www.google.com/search?" + new URLSearchParams({udm: "50", q: question})
}

export default {
  mounted() {
    this.onClick = event => {
      const question = this.el.dataset.question
      if (!navigator.geolocation || !question) return

      event.preventDefault()
      const tab = window.open("", "_blank")
      if (!tab) {
        window.location.href = this.el.href
        return
      }
      tab.opener = null

      const go = url => { tab.location.href = url }
      navigator.geolocation.getCurrentPosition(
        ({coords}) => {
          const where = `${coords.latitude.toFixed(4)},${coords.longitude.toFixed(4)}`
          go(aiModeUrl(question.replace("いまいる場所", `現在地（${where}）`)))
        },
        () => go(this.el.href),
        {timeout: TIMEOUT_MS, maximumAge: 10 * 60 * 1000}
      )
    }
    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  }
}
