// 总览（设计稿 设计/总览/，口径见那里的说明.md「数怎么算」）。
// 数据来自 echo://app/overview.json（EchoStats.swift 整理）：每个会话每天的我的消息、AI 干活、各模型 Token，和 Git 提交；
// 这里按周汇总、算同期比、按 prices.json 折合美元。点会话交给 Swift 打开。
(function () {
  const $ = (id) => document.getElementById(id);
  const WD = "日一二三四五六";
  const IC = {
    commit: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3.5"/><path d="M3 12h5.5M15.5 12H21"/></svg>',
    msg: '<svg viewBox="0 0 24 24"><path d="M5 18.5V7a2.5 2.5 0 0 1 2.5-2.5h9A2.5 2.5 0 0 1 19 7v6a2.5 2.5 0 0 1-2.5 2.5H9z"/></svg>',
  };
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const fmtN = (n) => Math.round(n).toLocaleString("en-US");
  // Token 一律用 M：和 API 每百万 Token 计价对得上
  const fmtM = (n) => { const m = n / 1e6; return (m >= 100 ? fmtN(m) : m >= 1 ? m.toFixed(1) : m.toFixed(2)) + "M"; };
  const fmtU = (n) => n >= 10 ? "$" + fmtN(n) : n >= 1 ? "$" + n.toFixed(1) : "$" + n.toFixed(2);
  const md = (d) => `${d.getMonth() + 1}月${d.getDate()}日`;
  const key = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  const parse = (k) => { const [y, m, d] = k.split("-").map(Number); return new Date(y, m - 1, d); };
  const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
  const wname = (w) => { const e = addDays(w.start, 6); return `${md(w.start)}至${e.getMonth() === w.start.getMonth() ? e.getDate() + "日" : md(e)}`; };

  // 带版本号的提交算发版：说明开头（可带模块名、冒号）是 0.14.3 / v0.14.3 这样的号
  const VER = /^(?:[^\s:：]{1,12}[\s:：]+)?v?(\d+\.\d+\.\d+)\b[\s:：,，、-]*/;
  // 模型显示名：claude-opus-5-5 → Opus 5.5
  const modelName = (id) => {
    const m = /^claude-([a-z]+)-(\d+)(?:-(\d+))?/.exec(id);
    return m ? m[1][0].toUpperCase() + m[1].slice(1) + " " + m[2] + (m[3] && m[3].length < 3 ? "." + m[3] : "") : id;
  };

  let prices = {}, TODAY, weeks = [], cur = 0, open = new Set();

  function price(model) {
    let best = null;
    for (const k of Object.keys(prices)) if (model.startsWith(k) && (!best || k.length > best.length)) best = k;
    return best ? prices[best] : null;
  }

  // 一次回复的四项 Token 折合美元：[输入, 输出, 读缓存, 写缓存 5 分钟, 写缓存 1 小时]
  function cost(model, t) {
    const p = price(model);
    if (!p) return [0, 0, 0, 0];
    return [t[0] * p[0], t[1] * p[1], t[2] * p[2], t[3] * p[0] * 1.25 + t[4] * p[0] * 2].map((x) => x / 1e6);
  }

  function build(data) {
    TODAY = parse(data.today);
    const days = new Map();   // 日期 → 当天的数
    const day = (k) => {
      if (!days.has(k)) days.set(k, { tot: 0, out: 0, usd: 0, msg: 0, ms: 0, lg: 0, sess: [], parts: [0, 0, 0, 0], models: {}, commits: [] });
      return days.get(k);
    };
    for (const s of data.sessions) {
      for (const [k, v] of Object.entries(s.days)) {
        const d = day(k);
        let tot = 0, usd = 0;
        for (const [m, t] of Object.entries(v.k || {})) {
          const c = cost(m, t), u = c.reduce((a, b) => a + b, 0), name = modelName(m);
          tot += t[0] + t[1] + t[2] + t[3] + t[4];
          d.out += t[1];
          usd += u;
          c.forEach((x, i) => (d.parts[i] += x));
          d.models[name] = (d.models[name] || 0) + u;
        }
        d.tot += tot; d.usd += usd; d.msg += v.m; d.ms += v.ms; d.lg = Math.max(d.lg, v.lg);
        if (tot || v.m) d.sess.push({ id: s.id, t: s.t, p: s.p, tot, usd, msg: v.m });
      }
    }
    for (const c of data.commits) {
      const dt = new Date(c.d), m = VER.exec(c.s);
      day(key(dt)).commits.push({ p: c.p, s: m ? c.s.slice(m[0].length) || c.s : c.s, ver: m ? m[1] : "", a: c.a, r: c.r, f: c.f, time: +dt });
    }
    // 从第一个有会话的周起，到这周
    const keys = [...days.keys()].filter((k) => days.get(k).sess.length).sort();
    if (!keys.length) { weeks = []; return; }
    const first = parse(keys[0]), mon = (d) => addDays(d, -((d.getDay() + 6) % 7));
    weeks = [];
    for (let st = mon(first), wi = 0; st <= TODAY; st = addDays(st, 7), wi++) {
      const w = { wi, start: st, days: [], tot: 0, out: 0, usd: 0, msg: 0, ms: 0, lg: 0, commits: 0, add: 0, del: 0, files: new Set(), sids: new Set(), projs: new Set(), parts: [0, 0, 0, 0], models: {} };
      for (let i = 0; i < 7; i++) {
        const date = addDays(st, i), k = key(date), d = days.get(k) || { tot: 0, out: 0, usd: 0, msg: 0, ms: 0, lg: 0, sess: [], parts: [0, 0, 0, 0], models: {}, commits: [] };
        const x = { ...d, date, fut: date > TODAY };
        x.sess = [...d.sess].sort((a, b) => b.tot - a.tot);
        w.days.push(x);
        w.tot += d.tot; w.out += d.out; w.usd += d.usd; w.msg += d.msg; w.ms += d.ms; w.lg = Math.max(w.lg, d.lg);
        d.parts.forEach((v, j) => (w.parts[j] += v));
        for (const [m, v] of Object.entries(d.models)) w.models[m] = (w.models[m] || 0) + v;
        d.sess.forEach((s) => { w.sids.add(s.id); w.projs.add(s.p); });
        d.commits.forEach((c) => { w.commits++; w.add += c.a; w.del += c.r; c.f.forEach((f) => w.files.add(f)); });
      }
      weeks.push(w);
    }
  }

  // 数字卡：近 8 周小柱子，选中的周用主色；右上和前 4 周同期（周一到同一天）平均比
  const KPI = [
    { l: "Token", f: (w) => w.tot, big: (w) => [fmtM(w.tot), ""], s: (w) => `其中输出 ${fmtM(w.out)} · 折合 ${fmtU(w.usd)}` },
    { l: "我的消息", f: (w) => w.msg, big: (w) => [fmtN(w.msg), "条"], s: (w) => `在 ${w.sids.size} 个会话里` },
    { l: "AI 干活", f: (w) => w.ms / 3.6e6, big: (w) => [(w.ms / 3.6e6).toFixed(1), "小时"], s: (w) => `最长一轮 ${Math.round(w.lg / 6e4)} 分钟` },
    { l: "Git", f: (w) => w.commits, big: (w) => [fmtN(w.commits), "次提交"], s: (w) => `+${fmtN(w.add)} −${fmtN(w.del)} 行 · ${fmtN(w.files.size)} 个文件` },
  ];
  const SPAN = 8;
  // 同期：前几周只取周一到「今天是周几」那天
  function upto(w, n, f) { return w.days.slice(0, n).reduce((a, x) => a + f(x), 0); }
  const DAYF = [(x) => x.tot, (x) => x.msg, (x) => x.ms / 3.6e6, (x) => x.commits.length];

  function hero() {
    const w = weeks[cur], isNow = cur === weeks.length - 1, prev = weeks.slice(Math.max(0, cur - 4), cur);
    $("wkName").innerHTML = wname(w) + (isNow ? `<span class="now">本周</span>` : "");
    $("next").classList.toggle("off", isNow); $("prev").classList.toggle("off", cur === 0);
    const n = isNow ? w.days.filter((x) => !x.fut).length : 7;
    const from = Math.max(0, cur - SPAN + 1), win = weeks.slice(from, from + SPAN);
    $("kpis").innerHTML = KPI.map((k, ki) => {
      const val = k.f(w), avg = prev.reduce((a, x) => a + upto(x, n, DAYF[ki]), 0) / (prev.length || 1), d = avg ? Math.round((val / avg - 1) * 100) : null;
      const [num, unit] = k.big(w), mx = Math.max(...win.map(k.f)) || 1;
      return `<div class="card kpi"><div class="l">${k.l}${d === null ? "" : `<span class="dl" title="比前 ${prev.length} 周同期平均">${d >= 0 ? "↑" : "↓"} ${Math.abs(d)}%</span>`}</div>
        <div class="v">${num}${unit ? `<small>${unit}</small>` : ""}</div><div class="s">${k.s(w)}</div>
        <div class="spark">${win.map((x) => `<i class="${x === w ? "on" : ""}" data-i="${x.wi}" title="${wname(x)}" style="height:${Math.max(2, k.f(x) / mx * 24)}px"></i>`).join("")}</div></div>`;
    }).join("");
  }

  // 四分位切 4 档
  function levels(vals) {
    const v = vals.filter(Boolean).sort((a, b) => a - b), q = (p) => v[Math.floor(v.length * p)];
    return (t) => !t ? 0 : t < q(.25) ? 1 : t < q(.5) ? 2 : t < q(.75) ? 3 : 4;
  }

  // 日历：一行一个月、一格一天，从第一个有会话的月起最多 6 个月；选中的周用主色框框成一段；点一格切到那周，时间线滚到那天
  function cal() {
    const all = weeks.flatMap((w) => w.days).filter((x) => !x.fut), first = all.find((x) => x.tot || x.msg);
    const days = all.filter((x) => x.date >= first.date), lv = levels(days.map((x) => x.tot)), wk = weeks[cur].days;
    const months = [...new Set(days.map((x) => x.date.getFullYear() * 12 + x.date.getMonth()))].slice(-6);
    let h = `<h2>日历<span class="leg">少<i class="q0"></i><i class="q1"></i><i class="q2"></i><i class="q3"></i><i class="q4"></i>多</span></h2><div class="calwrap"><div class="mcal"><div class="mr hd"><span></span>${[...Array(31)].map((_, d) => `<b>${[1, 5, 10, 15, 20, 25, 31].includes(d + 1) ? d + 1 : ""}</b>`).join("")}</div>`;
    months.forEach((ym) => {
      const y = Math.floor(ym / 12), m = ym % 12, nd = new Date(y, m + 1, 0).getDate();
      h += `<div class="mr"><span>${m + 1}月</span>` + [...Array(31)].map((_, d) => {
        if (d >= nd) return `<i class="c no"></i>`;
        const x = days.find((z) => z.date.getFullYear() === y && z.date.getMonth() === m && z.date.getDate() === d + 1);
        if (!x) return `<i class="c ${new Date(y, m, d + 1) > TODAY ? "no" : "l0"}"></i>`;
        return `<i class="c l${lv(x.tot)}${+x.date === +TODAY ? " today" : ""}" data-t="${+x.date}" title="${md(x.date)} ${x.tot ? fmtM(x.tot) : "没有会话"}"></i>`;
      }).join("") + (() => {
        const ds = wk.filter((x) => x.date.getFullYear() === y && x.date.getMonth() === m).map((x) => x.date.getDate() - 1);
        return ds.length ? `<span class="wkbox" style="left:${36 + Math.min(...ds) * 26 - 3}px;width:${(Math.max(...ds) - Math.min(...ds) + 1) * 26 + 2}px"></span>` : "";
      })() + `</div>`;
    });
    $("cal").innerHTML = h + `</div></div>`;
  }

  // 本周：按天的竖线时间线，从今天往前排；一天先列提交（一个项目一行），再把会话排成一行（最多 4 个）
  function week() {
    const w = weeks[cur], el = $("week");
    if (!w.sids.size) { el.innerHTML = `<h2>本周</h2><div class="empty">这周没有会话</div>`; return; }
    const lv = levels(w.days.map((x) => x.tot));
    let h = `<h2>本周<span class="note">${w.projs.size} 个项目 · ${w.sids.size} 个会话 · ${w.commits} 次提交</span></h2><div class="tl">`;
    w.days.map((x, i) => [x, i]).reverse().forEach(([x, i]) => {
      if (x.fut) return;
      const isToday = +x.date === +TODAY;
      const head = `<div class="th"><i class="nd l${lv(x.tot)}${isToday ? " today" : ""}"></i><b>周${WD[x.date.getDay()]} ${x.date.getDate()}</b>${isToday ? `<span class="tdy">今天</span>` : ""}<span class="tm">${x.tot || x.msg ? `${fmtM(x.tot)} · ${fmtU(x.usd)} · ${x.msg} 条消息` : "没有会话"}</span></div>`;
      if (!x.sess.length && !x.commits.length) { h += `<div class="td empty-day" data-t="${+x.date}">${head}</div>`; return; }
      // 提交按项目并成一行：有版本写版本号，说明取发版那条或最近一条
      const by = new Map();
      [...x.commits].sort((a, b) => b.time - a.time).forEach((c) => {
        const g = by.get(c.p) || { p: c.p, n: 0, ver: [], s: "" };
        g.n++;
        if (c.ver && !g.ver.includes(c.ver)) { g.ver.push(c.ver); if (g.ver.length === 1) g.s = c.s; }
        if (!g.s) g.s = c.s;
        by.set(c.p, g);
      });
      const cs = [...by.values()].sort((a, b) => b.ver.length - a.ver.length || b.n - a.n);
      const all = open.has(i), ss = all ? x.sess : x.sess.slice(0, 4);
      h += `<div class="td" data-t="${+x.date}">${head}` +
        (cs.length ? `<div class="cm">${cs.map((c) => `<div class="ci">${IC.commit}<span class="t">${c.ver.length ? `<b title="${c.ver.join("、")}">${c.ver.slice(0, 3).join(" · ")}${c.ver.length > 3 ? ` 等 ${c.ver.length} 个版本` : ""}</b>` : ""}${esc(c.s)}<em>${esc(c.p)} · ${c.n} 次提交</em></span></div>`).join("")}</div>` : "") +
        (ss.length ? `<div class="ss"><div class="sl">${ss.map((s) => `<span class="si" data-id="${esc(s.id)}" title="${esc(s.p)}">${IC.msg}${esc(s.t)}<em>${fmtM(s.tot)}</em></span>`).join("")}` +
          (x.sess.length > 4 ? `<span class="sm" data-d="${i}">${all ? "收起" : `还有 ${x.sess.length - 4} 个`}</span>` : "") + `</div></div>` : "") + `</div>`;
    });
    el.innerHTML = h + `</div>`;
  }

  // 用量：按用途（金额多的深）、按模型（主色深浅，不到 2% 的并成其他用灰）
  function money() {
    const w = weeks[cur], t = w.usd || 1;
    if (!w.usd) { $("money").innerHTML = `<h2>用量</h2><div class="empty">这周没有会话</div>`; return; }
    const parts = ["输入", "输出", "读缓存", "写缓存"].map((n, i) => [n, w.parts[i]]).sort((a, b) => b[1] - a[1]).map(([n, v], i) => [n, "s" + (4 - i), v]);
    const ms = Object.entries(w.models).sort((a, b) => b[1] - a[1]);
    const big = ms.filter((x) => x[1] / t >= .02), rest = ms.filter((x) => x[1] / t < .02).reduce((a, x) => a + x[1], 0);
    const models = [...big.map(([n, v], i) => [n, ["s3", "s1", "s2", "s4"][i] || "s1", v]), ...(rest ? [["其他", "s0", rest]] : [])];
    const row = (label, list) => `<div class="up"><div class="uh"><span>${label}</span></div><div class="sbar">${list.map(([n, c, v]) => `<i class="${c}" style="flex:${v}" title="${n} ${fmtU(v)}"></i>`).join("")}</div>
      <div class="ulg">${list.map(([n, c, v]) => `<span><i class="${c}"></i>${n}<b>${fmtU(v)}</b><em>${v / t < .01 ? "<1" : Math.round(v / t * 100)}%</em></span>`).join("")}</div></div>`;
    $("money").innerHTML = `<h2>用量<span class="note">这周折合 ${fmtU(w.usd)}</span></h2>` + row("按用途", parts) + row("按模型", models);
  }

  function draw() {
    if (!weeks.length) {
      document.querySelector(".page").innerHTML = `<section class="card"><div class="empty">还没有会话</div></section>`;
      return;
    }
    hero(); cal(); week(); money();
  }

  async function load(keepWeek) {
    const [d, p] = await Promise.all([fetch("overview.json").then((r) => r.json()), fetch("prices.json").then((r) => r.json())]);
    prices = p.models;
    const was = weeks[cur] && +weeks[cur].start;
    build(d);
    const i = keepWeek && was ? weeks.findIndex((w) => +w.start === was) : -1;
    cur = i >= 0 ? i : weeks.length - 1;
    draw();
  }
  window.echoReload = () => load(true);

  const post = (m) => window.webkit && window.webkit.messageHandlers.echo.postMessage(m);
  $("prev").onclick = () => { if (cur > 0) { cur--; open.clear(); draw(); } };
  $("next").onclick = () => { if (cur < weeks.length - 1) { cur++; open.clear(); draw(); } };
  $("kpis").onclick = (e) => { const b = e.target.closest(".spark i"); if (b) { cur = +b.dataset.i; open.clear(); draw(); } };
  $("week").onclick = (e) => {
    const s = e.target.closest(".si");
    if (s) { post({ open: s.dataset.id }); return; }
    const m = e.target.closest(".sm");
    if (m) { const i = +m.dataset.d; open.has(i) ? open.delete(i) : open.add(i); week(); }
  };
  $("cal").onclick = (e) => {
    const c = e.target.closest(".c[data-t]");
    if (!c) return;
    const t = +c.dataset.t;
    cur = weeks.findIndex((w) => w.days.some((x) => +x.date === t));
    open.clear(); draw();
    const d = document.querySelector(`.td[data-t="${t}"]`);
    if (d) { d.scrollIntoView({ block: "center" }); d.classList.add("flash"); setTimeout(() => d.classList.remove("flash"), 1200); }
  };
  load(false);
})();
