// 横にスクロールするタブの列（`.relation-tabs` と頭のメニュー）のところ。
//
// 1. **選んだものを見える位置まで寄せる。** 狭い画面ではタブを折り返さずに横へ
//    スクロールさせているので、右の端のほうのタブを選ぶと、描き直したあとに列が
//    先頭へ戻って選んだタブが画面の外に隠れる。開いたときと描き直したときに寄せる。
//    **列の中だけを動かす** —— `scrollIntoView` はページごと縦にも動かすので使わない。
// 2. **続きがある側に印を付ける**（`has-more-left` / `has-more-right`。CSS がその端を
//    ぼかす）。スクロールするたび・幅が変わるたびに付け直す。

// 端とみなす余り（px）。ぴったり 0 にならないことがある
const EDGE = 4

const mark = nav => {
  const more = nav.scrollWidth - nav.clientWidth
  nav.classList.toggle("has-more-left", more > EDGE && nav.scrollLeft > EDGE)
  nav.classList.toggle("has-more-right", more > EDGE && nav.scrollLeft < more - EDGE)
}

const reveal = nav => {
  const selected = nav.querySelector(".selected, .active")
  if (selected && nav.scrollWidth > nav.clientWidth) {
    const left = selected.offsetLeft - nav.offsetLeft - (nav.clientWidth - selected.offsetWidth) / 2
    nav.scrollLeft = Math.max(0, left)
  }
  mark(nav)
}

export default {
  mounted() {
    this.onScroll = () => mark(this.el)
    this.el.addEventListener("scroll", this.onScroll, { passive: true })
    this.resize = new ResizeObserver(() => mark(this.el))
    this.resize.observe(this.el)
    reveal(this.el)
  },
  updated() { reveal(this.el) },
  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll)
    this.resize && this.resize.disconnect()
  }
}
