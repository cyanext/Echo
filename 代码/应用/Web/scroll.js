// 滚动条不动一会就藏（照 NAS 网站 lib/core.js）：正在滚的元素加 .scrolling，停 1 秒去掉；样子见 scroll.css
// 网页内核换了类名不重画滚动条，overflow 换一下再换回来让它重画（滚动位置不变，同一帧里看不出来）
(function () {
  const timers = new Map();
  function mark(t, on) {
    t.classList.toggle("scrolling", on);
    const s = t.style, o = s.overflow;
    s.overflow = "hidden"; void t.offsetWidth; s.overflow = o;
  }
  document.addEventListener("scroll", (e) => {
    const t = e.target === document ? document.documentElement : e.target;
    if (!t || !t.classList) return;
    if (!timers.has(t)) mark(t, true);
    clearTimeout(timers.get(t));
    timers.set(t, setTimeout(() => { mark(t, false); timers.delete(t); }, 1000));
  }, true);
})();
