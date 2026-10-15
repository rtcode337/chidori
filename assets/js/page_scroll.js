// 画面の中身のスクロール（`main#page-scroll`）のところ。
//
// 頭のメニューとタブを画面の上に残すため、スクロールするのはページ全体ではなく
// main の中だけにしてある（root.html.heex）。LiveView が面倒を見るのはページ全体
// （window）のスクロールだけなので、その代わりをここで main に対してする。
//
// 1. タブを切り替えたら（patch）、先頭から見せる。タブは上に残っているので、
//    読み進めた途中でも押せる —— そのままだと、前のタブで読んでいた深さから
//    次のタブが始まり、見出しが見えない。この画面で patch を使っているのは
//    タブ（枠・話題・図の種類・設定）の切り替えと、関連図で別の図へ飛ぶ口だけ
// 2. 戻る・進むで来たら、そのとき読んでいた位置へ戻す（LiveView が window で
//    していたこと）。位置は履歴の項目（history.state）に書いておく
//
// 別の画面へ移ったとき（navigate）は main ごと作り直されるので、何もしなくても先頭から始まる。
// 頭のメニューは素のリンク（ページの読み込み直し）なので、そこから戻る・進むで来たときも
// 読み込み直しになる（ブラウザが前のページを取っておいても、LiveView が読み込み直す）。
// そのときも、開いた最初の 1 回だけ同じように位置を戻す。

// history.state に位置を書く名前（LiveView の書く `scroll` とは別にする）
const KEY = "pageScroll"

// 書き込みを間引く間隔（ms）。replaceState は回数に上限のあるブラウザがある
const SAVE_AFTER = 100

// 戻る・進むで来たときに、描き直しを待ってから戻す位置。描き直しが来ないとき
// （同じ中身だったとき）のために、しばらく待って戻す
const RESTORE_WAIT = 1500

let current = null
// 戻る・進むで来て、まだ戻していない位置（{y}）
let pending = null
let pendingTimer = null
// 戻る・進む（と読み込み直し）でページごと開き直したか（最初の main が付くまで）。
// 戻ったときの種別は reload になる —— 取っておいたページを LiveView が読み込み直すため
let reopened = (() => {
  try {
    const entry = performance.getEntriesByType("navigation")[0]
    return !!entry && (entry.type === "back_forward" || entry.type === "reload")
  } catch (_error) {
    return false
  }
})()

const savedPosition = () => {
  const y = history.state && history.state[KEY]
  return typeof y === "number" ? y : 0
}

const restore = hook => {
  if (!pending) return
  const {y} = pending
  pending = null
  clearTimeout(pendingTimer)
  requestAnimationFrame(() => { hook.el.scrollTop = y })
}

window.addEventListener("phx:navigate", ({detail}) => {
  if (detail.pop) {
    // 戻る・進む。patch なら同じ main が描き直され（updated）、別の画面なら新しい
    // main が作られる（mounted）。どちらも、この知らせのあとに起きる
    pending = {y: savedPosition()}
    clearTimeout(pendingTimer)
    pendingTimer = setTimeout(() => { if (current) restore(current) }, RESTORE_WAIT)
  } else if (detail.patch && current) {
    // タブの切り替え。この知らせは描き直しのあとに来る
    pending = null
    current.el.scrollTop = 0
  }
})

export default {
  mounted() {
    current = this
    if (reopened) {
      reopened = false
      if (!pending) pending = {y: savedPosition()}
    }
    this.timer = null
    this.onScroll = () => {
      clearTimeout(this.timer)
      this.timer = setTimeout(() => {
        // 別の画面へ移ったあとには書かない（移った先の履歴の項目に、前の画面の位置が入る）
        if (!this.el.isConnected) return
        history.replaceState({...(history.state || {}), [KEY]: this.el.scrollTop}, "", window.location.href)
      }, SAVE_AFTER)
    }
    this.el.addEventListener("scroll", this.onScroll, {passive: true})
    restore(this)
  },

  updated() {
    restore(this)
  },

  destroyed() {
    clearTimeout(this.timer)
    this.el.removeEventListener("scroll", this.onScroll)
    if (current === this) current = null
  },
}
