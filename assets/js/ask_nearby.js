// 近くで上映している映画館を Gemini（Google 検索の AI モード）に聞く口（映画の詳細）。
//
// **地域の欄に書いてあればその近くを、空なら現在地（取れていれば）の近くを聞きます。**
// - 地域: `data-region-question` の `{region}` を書いた地域に置き換えて開く
// - 現在地: 「現在地を使う」を押したとき（位置情報を許可済みなら開いたとき）に取っておき、
//   質問文の「いまいる場所」を置き換える。取れていなければ場所を書かない質問のまま開く ——
//   AI モードの側でもおおよその場所は分かるので、聞けないよりはよい
//
// **リンクはいつも普通のリンクとして開きます。** 以前は、押したその場で空のタブを開き、
// 現在地が取れてから行き先を入れていた（押した操作から離れて開くと止められるため）。
// ところがホーム画面から開いた PWA（iPhone）では、開いたタブにあとから行き先を入れられず、
// 真っ白なタブが残った。現在地は押す前に取っておき、押したら行き先の決まったリンクを開く。
//
// 書いた地域はブラウザに覚えておき、次に開いたときに入れておく（同じ街で観ることが多い）。

const TIMEOUT_MS = 8000
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
    this.here = this.el.querySelector("button[data-here]")
    this.status = this.el.querySelector("[data-status]")
    this.coords = null
    if (!this.link) return
    if (this.input && !this.input.value) this.input.value = storedRegion()

    // 行き先を、いま分かっていることから組み直す（押す前にいつも決まっている）
    this.refresh = () => {
      const question = this.el.dataset.question
      if (!question) return
      const region = this.input ? this.input.value.trim() : ""
      const template = this.el.dataset.regionQuestion
      if (region && template) {
        this.link.href = aiModeUrl(template.replace("{region}", region))
      } else if (this.coords) {
        this.link.href = aiModeUrl(question.replace("いまいる場所", `現在地（${this.coords}）`))
      } else {
        this.link.href = aiModeUrl(question)
      }
    }

    this.locate = () => {
      if (!navigator.geolocation) {
        if (this.status) this.status.textContent = "この端末では現在地を取れません"
        return
      }
      if (this.status) this.status.textContent = "現在地を取っています…"
      navigator.geolocation.getCurrentPosition(
        ({coords}) => {
          this.coords = `${coords.latitude.toFixed(4)},${coords.longitude.toFixed(4)}`
          if (this.status) this.status.textContent = "現在地で聞きます"
          this.refresh()
        },
        () => {
          if (this.status) this.status.textContent = "現在地を取れませんでした（場所を書かずに聞きます）"
        },
        {timeout: TIMEOUT_MS, maximumAge: 10 * 60 * 1000}
      )
    }

    this.onInput = () => {
      storeRegion(this.input.value.trim())
      this.refresh()
    }
    // 欄で Enter を押したら、そのまま聞く
    this.onKey = event => {
      if (event.key === "Enter") {
        event.preventDefault()
        this.refresh()
        this.link.click()
      }
    }

    if (this.input) {
      this.input.addEventListener("input", this.onInput)
      this.input.addEventListener("keydown", this.onKey)
    }
    if (this.here) this.here.addEventListener("click", this.locate)
    this.refresh()

    // **位置情報を許可済みなら、開いたときに取っておく**（聞かれないので押す手間が要らない）
    if (navigator.permissions && navigator.permissions.query) {
      navigator.permissions.query({name: "geolocation"})
        .then(state => { if (state.state === "granted") this.locate() })
        .catch(() => {})
    }
  },

  destroyed() {
    if (this.input) {
      this.input.removeEventListener("input", this.onInput)
      this.input.removeEventListener("keydown", this.onKey)
    }
    if (this.here) this.here.removeEventListener("click", this.locate)
  }
}
