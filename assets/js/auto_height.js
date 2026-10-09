// 埋め込んだ画面（iframe）の高さを、**中身の高さに合わせる**ところ（トップページの関連図）。
//
// 高さを決め打ちにすると、枠の中にもう 1 つスクロールができ、ページのスクロールと
// 二重になる（どちらを動かしているのか分からない）。同じサイトの画面なので中身の
// 高さはそのまま読める —— 読み込んだときと、中身の大きさが変わったときに合わせる
// （図は取り直すと描き直され、高さも変わる）。

const fit = frame => {
  // 画面いっぱいに広げている間は合わせない（中の図が枠いっぱいに広がっているので、
  // 測ると画面の高さになり、戻したときに縮んだままになる）
  if (frame.classList.contains("frame-fullscreen")) return
  const doc = frame.contentDocument
  if (!doc || !doc.documentElement) return
  frame.style.height = `${doc.documentElement.scrollHeight}px`
}

export default {
  mounted() {
    const frame = this.el
    this.onLoad = () => {
      fit(frame)
      const doc = frame.contentDocument
      if (!doc || !doc.body) return
      if (this.observer) this.observer.disconnect()
      this.observer = new ResizeObserver(() => fit(frame))
      this.observer.observe(doc.body)
    }
    frame.addEventListener("load", this.onLoad)
    // 本物の全画面を Esc などで抜けたら、枠も中の図も戻す
    this.onFullscreenChange = () => {
      if (document.fullscreenElement || !frame.classList.contains("frame-fullscreen")) return
      frame.classList.remove("frame-fullscreen")
      frame.contentWindow && frame.contentWindow.dispatchEvent(new Event("chidori:frame-fullscreen-exit"))
      fit(frame)
    }
    document.addEventListener("fullscreenchange", this.onFullscreenChange)
    // 先に読み終わっていることがある
    if (frame.contentDocument && frame.contentDocument.readyState === "complete") this.onLoad()
  },
  destroyed() {
    this.el.removeEventListener("load", this.onLoad)
    document.removeEventListener("fullscreenchange", this.onFullscreenChange)
    if (this.observer) this.observer.disconnect()
  }
}
