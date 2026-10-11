// 近くで上映している映画館を Gemini（Google 検索の AI モード）に聞く口（映画の詳細）。
//
// **地域の欄に書いてあればその近くを、空なら現在地の近くを聞きます。**
// - 地域: `data-region-question` の `{region}` を書いた地域に置き換えて開く
// - 現在地: 押したときにブラウザから取り、質問文の「いまいる場所」を置き換えて開く。
//   取れなければ（断られた・時間切れ・https でない）、場所を書かない質問のまま開く ——
//   AI モードの側でもおおよその場所は分かるので、聞けないよりはよい
//
// 書いた地域はブラウザに覚えておき、次に開いたときに入れておく（同じ街で観ることが多い）。
//
// 現在地を待ってから新しいタブを開くと、押した操作から離れるのでブラウザに止められる。
// **押したその場で空のタブを開き、場所が分かってから行き先を入れます。**

const TIMEOUT_MS = 6000
const REGION_KEY = "chidori.theaterRegion"

function aiModeUrl(question) {
  return "https://www.google.com/search?" + new URLSearchParams({udm: "50", q: question})
}

function storedRegion() {
  try { return localStorage.getItem(REGION_KEY) || "" } catch (_e) { return "" }
}

function storeRegion(region) {
  try {
    if (region) localStorage.setItem(REGION_KEY, region)
    else localStorage.removeItem(REGION_KEY)
  } catch (_e) { /* 覚えられなくても聞くことはできる */ }
}

export default {
  mounted() {
    this.link = this.el.querySelector("a")
    this.input = this.el.querySelector("input")
    if (!this.link) return
    if (this.input && !this.input.value) this.input.value = storedRegion()

    this.onChange = () => storeRegion(this.input.value.trim())
    // 欄で Enter を押したら、そのまま聞く
    this.onKey = event => {
      if (event.key === "Enter") {
        event.preventDefault()
        this.link.click()
      }
    }

    this.onClick = event => {
      const question = this.el.dataset.question
      if (!question) return
      const region = this.input ? this.input.value.trim() : ""

      if (region) {
        storeRegion(region)
        const template = this.el.dataset.regionQuestion
        if (template) this.link.href = aiModeUrl(template.replace("{region}", region))
        return  // ふつうのリンクとして開く（押したその場なので止められない）
      }

      // 地域で聞いたあとは href が書き換わっているので、場所を書かない質問から組み直す
      const fallback = aiModeUrl(question)
      this.link.href = fallback
      if (!navigator.geolocation) return
      event.preventDefault()
      const tab = window.open("", "_blank")
      if (!tab) {
        window.location.href = fallback
        return
      }
      tab.opener = null

      const go = url => { tab.location.href = url }
      navigator.geolocation.getCurrentPosition(
        ({coords}) => {
          const where = `${coords.latitude.toFixed(4)},${coords.longitude.toFixed(4)}`
          go(aiModeUrl(question.replace("いまいる場所", `現在地（${where}）`)))
        },
        () => go(fallback),
        {timeout: TIMEOUT_MS, maximumAge: 10 * 60 * 1000}
      )
    }

    this.link.addEventListener("click", this.onClick)
    if (this.input) {
      this.input.addEventListener("change", this.onChange)
      this.input.addEventListener("keydown", this.onKey)
    }
  },

  destroyed() {
    if (this.link) this.link.removeEventListener("click", this.onClick)
    if (this.input) {
      this.input.removeEventListener("change", this.onChange)
      this.input.removeEventListener("keydown", this.onKey)
    }
  }
}
