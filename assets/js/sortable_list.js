// つまんで並べ替える一覧（トップページに並べる枠の順番）。
//
// **動かすのは画面の中だけ**で、サーバーへは保存を押したときに順番ごと送る ——
// つまんで離すたびに送ると、動かしている途中の順番が次々に保存される。
// 順番は各行の hidden の欄（`data-order-input`）に書き込む。フォームはそれを送る。
//
// **マウスでも指でも動く**（pointer events）。つまむのは取っ手（`data-drag-handle`）
// だけにして、行のほかの場所では普通にスクロールできるようにする（取っ手は
// `touch-action: none`）。**キーボードでも動かせる** —— 取っ手にフォーカスして ↑↓。
//
// 一覧は `phx-update="ignore"` の中に置く。描き直されると、並べ替えた順番が
// サーバーの持っている順番に戻されるため。

const items = list => Array.from(list.querySelectorAll(":scope > [data-sortable-item]"))

// 並んでいる順に番号を振り直す（フォームが送る順番）
const renumber = list =>
  items(list).forEach((item, index) => {
    const input = item.querySelector("[data-order-input]")
    if (input) input.value = String(index + 1)
  })

export default {
  mounted() {
    const list = this.el
    renumber(list)

    this.onDown = event => {
      const handle = event.target.closest("[data-drag-handle]")
      if (!handle || !list.contains(handle)) return
      const item = handle.closest("[data-sortable-item]")
      event.preventDefault()
      item.classList.add("is-dragging")

      const onMove = move => {
        // 指の高さより下に中心がある最初の行の前へ入れる（無ければ末尾）
        const after = items(list)
          .filter(other => other !== item)
          .find(other => {
            const box = other.getBoundingClientRect()
            return move.clientY < box.top + box.height / 2
          })
        if (after) list.insertBefore(item, after)
        else list.appendChild(item)
      }

      // **動きは画面全体で受ける**（取っ手の上から指が外れても追いかける）
      const onUp = () => {
        item.classList.remove("is-dragging")
        window.removeEventListener("pointermove", onMove)
        window.removeEventListener("pointerup", onUp)
        window.removeEventListener("pointercancel", onUp)
        renumber(list)
      }

      window.addEventListener("pointermove", onMove)
      window.addEventListener("pointerup", onUp)
      window.addEventListener("pointercancel", onUp)
    }

    // キーボード: 取っ手で ↑↓
    this.onKey = event => {
      const handle = event.target.closest("[data-drag-handle]")
      if (!handle || !["ArrowUp", "ArrowDown"].includes(event.key)) return
      event.preventDefault()
      const item = handle.closest("[data-sortable-item]")
      if (event.key === "ArrowUp" && item.previousElementSibling) {
        list.insertBefore(item, item.previousElementSibling)
      } else if (event.key === "ArrowDown" && item.nextElementSibling) {
        list.insertBefore(item.nextElementSibling, item)
      }
      renumber(list)
      handle.focus()
    }

    list.addEventListener("pointerdown", this.onDown)
    list.addEventListener("keydown", this.onKey)
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this.onDown)
    this.el.removeEventListener("keydown", this.onKey)
  }
}
