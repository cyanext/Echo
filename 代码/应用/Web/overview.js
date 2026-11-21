// 总览（设计稿 设计/总览/，口径见那里的说明.md「数怎么算」）。
// 数据来自 echo://app/overview.json（EchoStats.swift 整理）：每个会话每天的我的消息、AI 干活、各模型 Token，和 Git 提交；
// 这里按周汇总、算同期比、按 prices.json 折合美元。点会话交给 Swift 打开。
(function () {
  const $ = (id) => document.getElementById(id);
  const WD = "日一二三四五六";
  const IC = {
    tok: '<svg viewBox="0 0 24 24"><path d="M13 3 5 13.5h6L10.5 21 19 10.5h-6z"/></svg>',
    usd: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5"/><path d="M14.8 9.2c-.5-.9-1.6-1.4-2.8-1.4-1.6 0-2.8.8-2.8 2.1 0 2.9 5.8 1.5 5.8 4.3 0 1.3-1.3 2.1-3 2.1-1.3 0-2.5-.6-3-1.5M12 6v1.8M12 16.3V18"/></svg>',
    time: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/></svg>',
    tag: '<svg viewBox="0 0 24 24"><path d="M4 12.6V5.5A1.5 1.5 0 0 1 5.5 4h7.1l7.4 7.4a1.5 1.5 0 0 1 0 2.1l-6.5 6.5a1.5 1.5 0 0 1-2.1 0z"/><circle cx="8.5" cy="8.5" r="1.4"/></svg>',
    commit: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3.5"/><path d="M3 12h5.5M15.5 12H21"/></svg>',
    msg: '<svg viewBox="0 0 24 24"><path d="M5 18.5V7a2.5 2.5 0 0 1 2.5-2.5h9A2.5 2.5 0 0 1 19 7v6a2.5 2.5 0 0 1-2.5 2.5H9z"/></svg>',
  };
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const fmtN = (n) => Math.round(n).toLocaleString("en-US");
  // Token 一律用 M：和 API 每百万 Token 计价对得上
  const fmtM = (n) => { const m = n / 1e6; return n > 0 && m < .01 ? "<0.01M" : (m >= 100 ? fmtN(m) : m >= 1 ? m.toFixed(1) : m.toFixed(2)) + "M"; };
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

  let prices = {}, TODAY, weeks = [], cur = 0, open = new Set(), dayView = null;   // dayView：只看某一天时是那天的时间戳

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
        if (tot || v.m) d.sess.push({ id: s.id, t: s.t, p: s.p, dir: s.d || s.p, tot, usd, msg: v.m, ms: v.ms, a: (v.a || 0) * 1000, b: (v.b || 0) * 1000, commits: [] });
      }
    }
    for (const c of data.commits) {
      const dt = new Date(c.d), m = VER.exec(c.s);
      day(key(dt)).commits.push({ p: c.p, s: m ? c.s.slice(m[0].length) || c.s : c.s, ver: m ? m[1] : "", a: c.a, r: c.r, f: c.f, time: +dt });
    }
    // 提交归到会话：同一项目、提交时间落在会话这天的起止之间（前后各放宽 10 分钟），几个都对得上取 Token 多的；对不上的算「其他提交」
    for (const d of days.values()) {
      d.other = [];
      for (const c of d.commits) {
        const hit = d.sess.filter((s) => s.p === c.p && c.time >= s.a - 6e5 && c.time <= s.b + 6e5).sort((a, b) => b.tot - a.tot)[0];
        (hit ? hit.commits : d.other).push(c);
      }
    }
    // 从第一个有会话的周起，到这周
    const keys = [...days.keys()].filter((k) => days.get(k).sess.length).sort();
    if (!keys.length) { weeks = []; return; }
    const first = parse(keys[0]), mon = (d) => addDays(d, -((d.getDay() + 6) % 7));
    weeks = [];
    for (let st = mon(first), wi = 0; st <= TODAY; st = addDays(st, 7), wi++) {
      const w = { wi, start: st, days: [], tot: 0, out: 0, usd: 0, msg: 0, ms: 0, lg: 0, commits: 0, add: 0, del: 0, files: new Set(), sids: new Set(), projs: new Set(), parts: [0, 0, 0, 0], models: {} };
      for (let i = 0; i < 7; i++) {
        const date = addDays(st, i), k = key(date), d = days.get(k) || { tot: 0, out: 0, usd: 0, msg: 0, ms: 0, lg: 0, sess: [], parts: [0, 0, 0, 0], models: {}, commits: [], other: [] };
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
        return `<i class="c l${lv(x.tot)}${+x.date === +TODAY ? " today" : ""}${+x.date === dayView ? " pick" : ""}" data-t="${+x.date}" title="${md(x.date)} ${x.tot ? fmtM(x.tot) : "没有会话"}"></i>`;
      }).join("") + (() => {
        const ds = wk.filter((x) => x.date.getFullYear() === y && x.date.getMonth() === m).map((x) => x.date.getDate() - 1);
        return ds.length ? `<span class="wkbox" style="left:${36 + Math.min(...ds) * 26 - 3}px;width:${(Math.max(...ds) - Math.min(...ds) + 1) * 26 + 2}px"></span>` : "";
      })() + `</div>`;
    });
    $("cal").innerHTML = h + `</div></div>`;
  }

  // 一组提交并成一行：有版本写版本号（最多 3 个），说明取发版那条或最近一条，后面写几次提交
  function commitLine(list, label) {
    const cs = [...list].sort((a, b) => b.time - a.time), ver = [];
    let msg = "";
    cs.forEach((c) => { if (c.ver && !ver.includes(c.ver)) { ver.push(c.ver); if (ver.length === 1) msg = c.s; } });
    if (!msg) msg = cs[0].s;
    return `<div class="ci">${IC.commit}<span class="t">${ver.length ? `<b title="${ver.join("、")}">${ver.slice(0, 3).join(" · ")}${ver.length > 3 ? ` 等 ${ver.length} 个版本` : ""}</b>` : ""}${esc(msg)}</span><span class="x">${label ? esc(label) + " · " : ""}${cs.length} 次提交</span></div>`;
  }

  // 本周：上面一张卡写「本周」和这周几个项目、会话、提交；下面从今天往前一天一段：
  // 日期一行（点了只看那天）和当天的量，下面当天的会话卡两列排，按 Token 取前 4 张（每张最多 2 次提交），多了写「还有 N 个会话」点进那天
  function week() {
    if (dayView) return dayCard();
    const w = weeks[cur], el = $("week");
    el.classList.remove("card"); el.classList.add("dayv");
    let h = `<div class="wtitle"><h2>本周<span class="note">${w.projs.size} 个项目 · ${w.sids.size} 个会话 · ${w.commits} 次提交 · 点日期只看那天</span></h2></div>`;
    if (!w.sids.size) { el.innerHTML = h; return; }
    w.days.map((x, i) => [x, i]).reverse().forEach(([x]) => {
      if (x.fut) return;
      const isToday = +x.date === +TODAY, other = x.other || [];
      h += `<section class="card wday"><div class="wdh"><b class="dl" data-t="${+x.date}">${md(x.date)} 周${WD[x.date.getDay()]}</b>${isToday ? `<span class="tdy">今天</span>` : ""}<span class="tm">${x.tot || x.msg ? `${fmtM(x.tot)} · ${fmtU(x.usd)} · ${x.msg} 条消息 · ${x.sess.length} 个会话${x.commits.length ? ` · ${x.commits.length} 次提交` : ""}` : "没有会话"}</span></div>`;
      if (x.sess.length) {
        const top = x.sess.slice(0, 4), rest = x.sess.length - top.length;
        h += `<div class="sgrid">${top.map((s) => sessCard(s)).join("")}</div>` + (rest > 0 ? `<div class="wmore dl" data-t="${+x.date}">还有 ${rest} 个会话，看这一天</div>` : "");
      }
      if (other.length) {
        const byP = new Map();
        other.forEach((c) => byP.set(c.p, [...(byP.get(c.p) || []), c]));
        h += `<div class="wother">${[...byP.entries()].map(([p, cs]) => commitLine(cs, p)).join("")}</div>`;
      }
      h += `</section>`;
    });
    el.innerHTML = h;
  }

  // 只看一天：顶上左右切天、「看整周」回去；一行几个数；会话全列（时间段、标题、项目、Token、折合、消息、AI 干活），
  // 会话下面一条条列它的提交（时间、版本号、说明、增删行）；对不上会话的提交列在最后
  const hm = (t) => { const d = new Date(t); return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`; };
  const dur = (ms) => ms >= 3.6e6 ? (ms / 3.6e6).toFixed(1) + " 小时" : Math.max(1, Math.round(ms / 6e4)) + " 分钟";
  function commitRow(c, label, sid) {
    return `<div class="cr2"${sid ? ` data-sid="${esc(sid)}" data-at="${c.time}"` : ""}>${IC.commit}<span class="tm2">${hm(c.time)}</span><span class="t">${c.ver ? `<b>${c.ver}</b>` : ""}${esc(c.s)}${label ? `<em>${esc(label)}</em>` : ""}</span><span class="x">+${fmtN(c.a)} −${fmtN(c.r)}</span></div>`;
  }
  // 只看一天：上面一张卡写日期、左右切天、「看整周」和六个数；下面一个会话一张卡，两列瀑布排，按 Token 从多到少。
  // 会话卡：一个会话一张，占满一行。左边标题，下面一行灰字写项目路径和时间段；右边文字标签写 Token、折合、消息、AI 干活、提交次数；
  // 这天发的版本做成主色标签，悬停看提交说明，点了打开会话跳到那次提交。提交不逐条列，要看就点「N 次提交」跳到会话里最近那次
  function sessCard(s) {
    const cs = [...s.commits].sort((a, b) => b.time - a.time), vs = [];
    cs.forEach((c) => { if (c.ver && !vs.some((v) => v.ver === c.ver)) vs.push(c); });
    // 标题右侧紧跟一排「图标 + 值」：Token、消息、AI 干活、提交（主色，点了跳到最近一次提交）；悬停提示是什么
    const cell = (ic, tip, val, cls = "", attr = "") => `<span class="${cls}" title="${tip}"${attr}>${ic}<b>${val}</b></span>`;
    const tags = [cell(IC.tok, "Token", fmtM(s.tot), "k"), cell(IC.msg, "我的消息", s.msg + " 条"),
      s.ms ? cell(IC.time, "AI 干活", dur(s.ms)) : "",
      cs.length ? cell(IC.commit, "跳到会话里最近一次提交", cs.length + " 次提交", "cm", ` data-sid="${esc(s.id)}" data-at="${cs[0].time}"`) : ""].join("");
    return `<article class="scard" data-id="${esc(s.id)}">
      <div class="sh"><div class="st">${esc(s.t)}</div><div class="tg2">${tags}</div></div><div class="sp">${esc(s.dir)}${s.a ? ` · ${hm(s.a)}–${hm(s.b)}` : ""}</div>
      ${vs.length ? `<div class="vs">${vs.slice(0, 8).map((c) => `<span class="vt" data-sid="${esc(s.id)}" data-at="${c.time}" data-tip="${esc(c.ver)}|${hm(c.time)}|${esc(c.s)}|+${c.a} −${c.r}">${IC.tag}${c.ver}</span>`).join("")}${vs.length > 8 ? `<span class="vm">等 ${vs.length} 个版本</span>` : ""}</div>` : ""}
    </article>`;
  }
  function dayCard() {
    const el = $("week"), all = weeks.flatMap((w) => w.days).filter((x) => !x.fut);
    const i = all.findIndex((x) => +x.date === dayView), x = all[i];
    const isToday = +x.date === +TODAY, nc = x.commits.length;
    el.classList.remove("card");
    el.classList.add("dayv");
    const nav = `<span class="dn"><span class="ib${i <= 0 ? " off" : ""}" data-go="${i > 0 ? +all[i - 1].date : ""}"><svg viewBox="0 0 24 24"><path d="m15 6-6 6 6 6"/></svg></span><span class="ib${i >= all.length - 1 ? " off" : ""}" data-go="${i < all.length - 1 ? +all[i + 1].date : ""}"><svg viewBox="0 0 24 24"><path d="m9 6 6 6-6 6"/></svg></span></span>`;
    let h = `<div class="card dhead"><h2>${md(x.date)} 周${WD[x.date.getDay()]}${isToday ? `<span class="tdy">今天</span>` : ""}${nav}<span class="note back" data-back="1">看整周</span></h2>` +
      `<div class="dsum">${[["Token", fmtM(x.tot)], ["折合", fmtU(x.usd)], ["我的消息", x.msg + " 条"], ["AI 干活", x.ms ? dur(x.ms) : "—"], ["会话", x.sess.length + " 个"], ["提交", nc + " 次"]]
        .map(([l, v]) => `<div><span>${l}</span><b>${v}</b></div>`).join("")}</div></div>`;
    if (!x.sess.length && !nc) { el.innerHTML = h + `<div class="card"><div class="empty">这天没有会话</div></div>`; return; }
    const other = (x.other || []).sort((a, b) => b.time - a.time);
    // 用得很少（不到 1M Token）又没有提交的会话，合成一张「其他会话」卡，一行一个
    const small = x.sess.filter((s) => s.tot < 1e6 && !s.commits.length), big = x.sess.filter((s) => !small.includes(s));
    const smallCard = small.length ? `<article class="scard oc3"><header><div class="st">其他 ${small.length} 个会话</div><div class="sp"><span>用得少、没有提交</span></div></header>${small.map((s) => `<div class="sr3" data-id="${esc(s.id)}">${IC.msg}<span class="t">${esc(s.t)}<em>${esc(s.dir)}</em></span><span class="v">${s.msg} 条</span></div>`).join("")}</article>` : "";
    h = h.replace(/<\/div>$/, "");   // 会话接着放进日期那张卡
    h += `<div class="sgrid">${big.map(sessCard).join("")}${smallCard}` +
      (other.length ? `<article class="scard oc3"><header><div class="st">没对上会话的提交</div><div class="sp"><span>${other.length} 次</span></div></header><div class="cl">${other.map((c) => commitRow(c, c.p)).join("")}</div></article>` : "") + `</div></div>`;
    el.innerHTML = h;
  }
  function showDay(t) { dayView = t; cur = weeks.findIndex((w) => w.days.some((x) => +x.date === t)); open.clear(); draw(); $("week").scrollIntoView({ block: "start", behavior: "smooth" }); }

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
  $("prev").onclick = () => { if (cur > 0) { cur--; open.clear(); dayView = null; draw(); } };
  $("next").onclick = () => { if (cur < weeks.length - 1) { cur++; open.clear(); dayView = null; draw(); } };
  $("kpis").onclick = (e) => { const b = e.target.closest(".spark i"); if (b) { cur = +b.dataset.i; open.clear(); dayView = null; draw(); } };
  $("week").onclick = (e) => {
    const j = e.target.closest("[data-at]");
    if (j) { post({ open: j.dataset.sid, at: +j.dataset.at }); return; }
    const g = e.target.closest("[data-go]");
    if (g) { if (g.dataset.go) showDay(+g.dataset.go); return; }
    if (e.target.closest("[data-back]")) { dayView = null; draw(); return; }
    const cm = e.target.closest("[data-cm]");
    if (cm) { const k = cm.dataset.cm; open.has(k) ? open.delete(k) : open.add(k); week(); return; }
    const dl = e.target.closest(".dl[data-t]");
    if (dl) { showDay(+dl.dataset.t); return; }
    const s = e.target.closest(".sr, .sr3, .scard[data-id]");
    if (s) { post({ open: s.dataset.id }); return; }
    const m = e.target.closest(".sm");
    if (m) { const i = +m.dataset.d; open.has(i) ? open.delete(i) : open.add(i); week(); }
  };
  $("cal").onclick = (e) => { const c = e.target.closest(".c[data-t]"); if (c) showDay(+c.dataset.t); };
  // 版本标签悬停：气泡写版本号、时间、提交说明、增删行
  const tip = document.createElement("div");
  tip.className = "vtip";
  document.body.appendChild(tip);
  document.addEventListener("mouseover", (e) => {
    const v = e.target.closest(".vt[data-tip]");
    if (!v) { tip.style.display = "none"; return; }
    const [ver, t, msg, ln] = v.dataset.tip.split("|");
    tip.innerHTML = `<div class="h"><b>${ver}</b><span>${t} · ${ln}</span></div><div class="m">${msg}</div><div class="f">点一下跳到会话里这次提交</div>`;
    tip.style.display = "block";
    const r = v.getBoundingClientRect(), w = tip.offsetWidth;
    tip.style.left = Math.max(8, Math.min(r.left + r.width / 2 - w / 2, innerWidth - w - 8)) + scrollX + "px";
    tip.style.top = r.top + scrollY - tip.offsetHeight - 8 + "px";
  });
  load(false);
})();
