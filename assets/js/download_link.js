// 押すと降ってくるリンクを、**待っている間も押したと分かる**ようにするところ。
//
// ただの `<a download>` だと、サーバーが中身を組み終えるまで（書き出しは十数秒）
// ブラウザは何も出さない。押せたのかどうか分からず、何度も押されて同じ組み立てが
// 重なる。ここでは自分で取りに行き、その間は経過秒数を出して、届いたら保存させる。
//
// 断られたときは**サーバーの言い分をそのまま出す**（Chiezo が落ちている、など）。
// 素のリンクだと、その 1 行だけの画面へ飛んでしまい、元の画面へ戻る手間がかかる。
//
// JS が動かない場合は素のリンクとして働く（href と download はそのまま残す）。

// 経過秒数を描き直す間隔（ミリ秒）
const TICK = 1000

// Content-Disposition からファイル名を拾う（無ければ URL の末尾）
const filenameOf = (response, url) => {
  const header = response.headers.get("content-disposition") || ""
  const encoded = header.match(/filename\*=UTF-8''([^;]+)/i)
  if (encoded) return decodeURIComponent(encoded[1])
  const plain = header.match(/filename="?([^";]+)"?/i)
  if (plain) return plain[1]
  return url.split("/").pop()
}

export default {
  mounted() {
    this.busy = false
    this.onClick = event => {
      event.preventDefault()
      if (!this.busy) this.start()
    }
    this.el.addEventListener("click", this.onClick)
  },

  // **画面が描き直されても、待っている印を消さない。** LiveView は他の欄が
  // 更新されるたびにこの要素も描き直すので、付けた属性が素の状態へ戻される
  updated() {
    this.paint()
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    clearInterval(this.timer)
  },

  status() {
    return document.getElementById(this.el.dataset.status)
  },

  paint() {
    this.el.toggleAttribute("aria-busy", this.busy)
    const status = this.status()
    if (!status) return
    // 状態は data- 属性で持つ（描き直しを止めた要素でも、class は素に戻されるが
    // data- 属性は残る）
    status.dataset.state = this.busy ? "busy" : this.error ? "error" : ""
    if (this.busy) {
      const seconds = Math.floor((Date.now() - this.startedAt) / 1000)
      status.textContent = `書き出し中… ${seconds} 秒`
    } else {
      status.textContent = this.error || ""
    }
  },

  async start() {
    this.busy = true
    this.error = null
    this.startedAt = Date.now()
    this.paint()
    this.timer = setInterval(() => this.paint(), TICK)

    const url = this.el.getAttribute("href")
    try {
      const response = await fetch(url)
      if (!response.ok) {
        this.error = (await response.text()) || `書き出せませんでした（${response.status}）`
        return
      }
      const blob = await response.blob()
      const link = document.createElement("a")
      link.href = URL.createObjectURL(blob)
      link.download = filenameOf(response, url)
      document.body.appendChild(link)
      link.click()
      link.remove()
      // 保存が始まる前に消すと落とせないブラウザがあるので、少し置いてから
      setTimeout(() => URL.revokeObjectURL(link.href), 60_000)
    } catch (_error) {
      this.error = "書き出せませんでした（tazuna に届きませんでした）"
    } finally {
      this.busy = false
      clearInterval(this.timer)
      this.paint()
    }
  },
}
