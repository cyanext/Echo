// 对话页和总览共用：滚动条、自绘提示。都照 NAS 网站公共层（lib/core.js、lib/tip.js）
// 滚动条不动一会就藏（照 NAS 网站 lib/core.js）：正在滚的元素加 .scrolling，停 1 秒去掉；样子见 base.css
// 网页内核换了类名不重画滚动条，overflow 换一下再换回来让它重画（滚动位置不变，同一帧里看不出来）
(function () {
  const timers = new Map();
  function mark(t, on) {
    t.classList.toggle("scrolling", on);
    // 页面本身不做：根元素切成 overflow: hidden 时，内核会按切换那一刻的高度截短滚动范围，滑到最底下会被弹回离底部几千像素的地方
    if (t === document.documentElement) return;
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

// 自绘提示（照 NAS 网站 lib/tip.js）：元素写 data-tip，鼠标停留时显示；Tip.init(选择器) 传入的元素文字被截断时显示全文。
// 在元素上方 8px，放不下放下方；左右不出屏幕。滚动、按下时收起
window.Tip = (function () {
  let tip = null, truncSel = "";
  const cut = (n) => n.scrollWidth > n.clientWidth + 1 || n.scrollHeight > n.clientHeight + 1;
  function show(h, text) {
    tip.textContent = text;
    tip.classList.toggle("multi", text.includes("\n"));
    tip.hidden = false;
    const r = h.getBoundingClientRect(), w = tip.offsetWidth, ht = tip.offsetHeight;
    tip.style.left = Math.max(8, Math.min(r.left + r.width / 2 - w / 2, innerWidth - w - 8)) + "px";
    tip.style.top = (r.top - ht - 8 < 8 ? r.bottom + 8 : r.top - ht - 8) + "px";
  }
  function init(sel) {
    if (sel) truncSel = sel;
    if (tip) return;
    tip = document.createElement("div");
    tip.className = "ui-tip"; tip.hidden = true; tip.setAttribute("role", "tooltip");
    document.body.appendChild(tip);
    document.addEventListener("mouseover", (e) => {
      const t = e.target.closest ? e.target : e.target.parentElement;
      let h = t && t.closest("[data-tip]"), text = h && h.dataset.tip;
      if (!h && truncSel) { h = t && t.closest(truncSel); text = h && cut(h) ? h.textContent : ""; }
      if (!text) { tip.hidden = true; return; }
      show(h, text);
    });
    document.addEventListener("scroll", () => { tip.hidden = true; }, true);
    document.addEventListener("pointerdown", () => { tip.hidden = true; }, true);
  }
  return { init };
})();
document.addEventListener("DOMContentLoaded", () => Tip.init());

// 缺省页（照 NAS 网站 lib/blank.js）：插画 + 标题 + 一句说明，插画是 blank-<种类>.svg（empty 空、search 搜不到、error 出错），
// 照 NAS 的线稿换成回响的青绿。small 用在侧栏、卡片里
window.Blank = {
  html(kind, title, text, small) {
    const e = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
    return `<div class="ui-blank${small ? " sm" : ""}"><img class="art" alt="" src="blank-${kind}.svg"><strong>${e(title)}</strong>${text ? `<p>${e(text)}</p>` : ""}</div>`;
  },
};
