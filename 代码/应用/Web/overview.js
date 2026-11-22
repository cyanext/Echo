// 总览（设计稿 设计/总览/，口径见那里的说明.md「数怎么算」）。
// 数据来自 echo://app/overview.json（EchoStats.swift 整理）：每个会话每天的我的消息、AI 时长、各模型 Token，和 Git 提交；
// 这里按周汇总、算同期比、按 prices.json 折合美元。点会话交给 Swift 打开。
(function () {
  const $ = (id) => document.getElementById(id);
  const WD = "日一二三四五六";
  const IC = {
    tag: '<svg viewBox="0 0 24 24"><path d="M4 12.6V5.5A1.5 1.5 0 0 1 5.5 4h7.1l7.4 7.4a1.5 1.5 0 0 1 0 2.1l-6.5 6.5a1.5 1.5 0 0 1-2.1 0z"/><circle cx="8.5" cy="8.5" r="1.4"/></svg>',
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
    if (m) return m[1][0].toUpperCase() + m[1].slice(1) + " " + m[2] + (m[3] && m[3].length < 3 ? "." + m[3] : "");
    const g = /^gpt-([\d.]+)(?:-([a-z]+))?/.exec(id);   // gpt-6.1-sol → GPT-6.1 Sol
    return g ? "GPT-" + g[1] + (g[2] ? " " + g[2][0].toUpperCase() + g[2].slice(1) : "") : id;
  };

  let DATA = null;   // 这次整理好的数据（备份卡片要用 data.backup）
  let appF = "";     // 会话页只看某个应用（会话的 a：codex 等，没写的是 claude）；空是全部，不记上次
  let prices = {}, TODAY, weeks = [], cur = 0, open = new Set();   // open：展开了全部会话的那几天（时间戳）

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
    const sessions = data.sessions.filter((s) => !appF || (s.a || "claude") === appF);
    for (const s of sessions) {
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
        if (tot || v.m) d.sess.push({ id: s.id, x: !!s.x, t: s.t, p: s.p, dir: s.d || s.p, tot, usd, msg: v.m, ms: v.ms, a: (v.a || 0) * 1000, b: (v.b || 0) * 1000, commits: [] });
      }
    }
    for (const c of data.commits) {
      const dt = new Date(c.d), m = VER.exec(c.s);
      day(key(dt)).commits.push({ h: c.h || "", full: c.s, p: c.p, s: m ? c.s.slice(m[0].length) || c.s : c.s, ver: m ? m[1] : "", a: c.a, r: c.r, f: c.f, time: +dt });
    }
    // 提交归到会话：先看哪个会话里做了这次提交（会话的 g：git commit 输出里的提交号前 7 位，和「m:」加 git commit 命令里说明的第一行前 30 字），
    // 在别的文件夹里提交的也对得上；没有的，同一项目、提交时间落在会话这天的起止之间（前后各放宽 10 分钟），几个都对得上取 Token 多的；
    // 都对不上的只算进当天的提交次数（不单独列）
    const owner = new Map(), msgKey = (m) => "m:" + Array.from((m.split("\n")[0] || "").trim()).slice(0, 30).join("");
    for (const s of sessions) for (const h of s.g || []) owner.set(h.startsWith("m:") ? h : h.slice(0, 7), s.id);
    for (const d of days.values()) {
      for (const c of d.commits) {
        const sid = owner.get(c.h.slice(0, 7)) || owner.get(msgKey(c.full));
        const hit = (sid && d.sess.find((s) => s.id === sid))
          || d.sess.filter((s) => s.p === c.p && c.time >= s.a - 6e5 && c.time <= s.b + 6e5).sort((a, b) => b.tot - a.tot)[0];
        if (hit) hit.commits.push(c);
      }
      // 只看某个应用时，提交只算挂在这个应用会话上的
      if (appF) d.commits = d.commits.filter((c) => d.sess.some((s) => s.commits.includes(c)));
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
  // 小字只留一项、写短（「指标卡的文案要精简一下」）：上万的行数写成「万」
  const wan = (n) => n >= 1e4 ? (n / 1e4).toFixed(1).replace(/\.0$/, "") + " 万" : fmtN(n);
  const KPI = [
    { l: "Token", f: (w) => w.tot, big: (w) => [fmtM(w.tot), ""], s: (w) => `折合 <em class="usd">${fmtU(w.usd)}</em>` },
    { l: "我的消息", f: (w) => w.msg, big: (w) => [fmtN(w.msg), "条"], s: (w) => `${w.sids.size} 个会话` },
    { l: "AI 时长", f: (w) => w.ms / 3.6e6, big: (w) => [(w.ms / 3.6e6).toFixed(1), "小时"], s: (w) => `最长一轮 ${Math.round(w.lg / 6e4)} 分钟` },
    { l: "Git 提交", f: (w) => w.commits, big: (w) => [fmtN(w.commits), "次"], s: (w) => `<em class="add">+${wan(w.add)}</em> <em class="del">-${wan(w.del)}</em> 行` },
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
      return `<div class="card kpi"><div class="l">${k.l}${d === null ? "" : `<span class="dl ${d >= 0 ? "up" : "down"}" data-tip="比前 ${prev.length} 周同期平均">${d >= 0 ? "↑" : "↓"} ${Math.abs(d)}%</span>`}</div>
        <div class="v">${num}${unit ? `<small>${unit}</small>` : ""}</div><div class="s">${k.s(w)}</div>
        <div class="spark">${win.map((x) => `<i class="${x === w ? "on" : ""}" data-i="${x.wi}" data-tip="${wname(x)}" style="height:${Math.max(2, k.f(x) / mx * 24)}px"></i>`).join("")}</div></div>`;
    }).join("");
  }

  // 四分位切 4 档
  function levels(vals) {
    const v = vals.filter(Boolean).sort((a, b) => a - b), q = (p) => v[Math.floor(v.length * p)];
    return (t) => !t ? 0 : t < q(.25) ? 1 : t < q(.5) ? 2 : t < q(.75) ? 3 : 4;
  }

  // 日历：一行一个月、一格一天，从第一个有会话的月起最多 6 个月；选中的周用主色框框成一段，今天加主色框；
  // 点一格切到那周，下面本周里那天自动展开并滚过去
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
        return `<i class="c l${lv(x.tot)}${+x.date === +TODAY ? " today" : ""}" data-t="${+x.date}" data-tip="${md(x.date)} ${x.tot ? fmtM(x.tot) : "没有会话"}"></i>`;
      }).join("") + (() => {
        const ds = wk.filter((x) => x.date.getFullYear() === y && x.date.getMonth() === m).map((x) => x.date.getDate() - 1);
        return ds.length ? `<span class="wkbox" style="--a:${Math.min(...ds)};--n:${Math.max(...ds) - Math.min(...ds) + 1}"></span>` : "";
      })() + `</div>`;
    });
    $("cal").innerHTML = h + `</div></div>`;
  }

  // 会话表一行：会话（标题、灰字项目路径，有发版的第二行放版本标签）、Token、我的消息、AI 时长、时间、Git 提交
  const COLS = `<div class="row cols"><span>会话</span><span>Token</span><span>我的消息</span><span>AI 时长</span><span>时间</span><span>Git 提交</span></div>`;
  function sessRow(s) {
    const cs = [...s.commits].sort((a, b) => b.time - a.time), vs = [];
    cs.forEach((c) => { if (c.ver && !vs.some((v) => v.ver === c.ver)) vs.push(c); });
    const vers = vs.slice(0, 6).map((c) => `<span class="ver"${s.x ? "" : ` data-sid="${esc(s.id)}" data-at="${c.time}"`} data-tip="${esc(`${c.ver}  ${hm(c.time)} · +${c.a} -${c.r}\n${c.s}${s.x ? "" : "\n点一下跳到会话里这次提交"}`)}">${IC.tag}${c.ver}</span>`).join("") + (vs.length > 6 ? `<span class="more-ver">等 ${vs.length} 个版本</span>` : "");
    // 删掉的会话（s.x）：数照算，标「已删除」，点不开
    return `<div class="row sess${s.x ? " gone" : ""}"${s.x ? "" : ` data-id="${esc(s.id)}"`}>
      <div class="name"><div class="line"><span class="title">${esc(s.t)}</span>${s.x ? `<span class="gone-tag">已删除</span><span class="forget" data-forget="${esc(s.id.replace(/^deleted:/, ""))}" data-tip="备份已删除，统计数据仍计入总览">删除统计</span>` : ""}<span class="path">${esc(s.dir)}</span></div>${vers ? `<div class="vers">${vers}</div>` : ""}</div>
      <span class="num strong">${fmtM(s.tot)}</span><span class="num">${s.msg} 条</span><span class="num">${s.ms ? dur(s.ms) : ""}</span>
      <span class="num faint">${s.a ? `${hm(s.a)}–${hm(s.b)}` : ""}</span>
      <span class="num">${cs.length && s.x ? `${cs.length} 次` : cs.length ? `<a class="link" data-sid="${esc(s.id)}" data-at="${cs[0].time}" data-tip="跳到会话里最近一次提交">${cs.length} 次</a>` : ""}</span>
    </div>`;
  }

  // 本周：从今天往前一天一张卡。卡头日期（点了展开或收起）和当天的量；下面会话表，按 Token 先列 4 个，
  // 「还有 N 个会话」点开就地展开；对不上会话的提交不单独列，只算进合计。点日历某天也是展开那天
  const hm = (t) => { const d = new Date(t); return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`; };
  const dur = (ms) => ms >= 3.6e6 ? (ms / 3.6e6).toFixed(1) + " 小时" : Math.max(1, Math.round(ms / 6e4)) + " 分钟";
  function week() {
    const w = weeks[cur], el = $("week");
    let h = `<h2 class="sec">本周<span class="note">${w.projs.size} 个项目 · ${w.sids.size} 个会话 · ${w.commits} 次提交</span></h2>`;
    if (!w.sids.size) { el.innerHTML = h + `<div class="card"><div class="empty">这周没有会话</div></div>`; return; }
    w.days.slice().reverse().forEach((x) => {
      if (x.fut) return;
      const t = +x.date, isToday = t === +TODAY, all = open.has(t);
      // 卡头只写日期；当天的合计放在会话表底下一行「合计」，对齐各列（合计挤在卡头右边太丑，放卡头按列对齐也怪）
      const has = x.tot || x.msg, ms = x.sess.reduce((a, s) => a + (s.ms || 0), 0);
      h += `<section class="card day" data-t="${t}"><div class="day-head"><b class="date" data-t="${t}">${md(x.date)} 周${WD[x.date.getDay()]}</b>${isToday ? `<span class="today">今天</span>` : ""}${has ? "" : `<span class="cnt">没有会话</span>`}</div>`;
      if (x.sess.length) {
        const list = all ? x.sess : x.sess.slice(0, 4), rest = x.sess.length - 4;
        h += `<div class="table">${COLS}${list.map(sessRow).join("")}</div>` + (rest > 0 ? `<div class="toggle" data-t="${t}">${all ? "收起" : `还有 ${rest} 个会话`}</div>` : "")
          + `<div class="row sum"><div class="name"><b>合计</b><span class="cnt">${x.sess.length} 个会话</span></div><span class="num strong" data-tip="折合 ${fmtU(x.usd)}">${fmtM(x.tot)}</span><span class="num">${x.msg} 条</span><span class="num">${ms ? dur(ms) : ""}</span><span></span><span class="num">${x.commits.length ? `${x.commits.length} 次` : ""}</span></div>`;
      }
      h += `</section>`;
    });
    el.innerHTML = h;
  }
  // 展开某天并滚过去
  function showDay(t) {
    cur = weeks.findIndex((w) => w.days.some((x) => +x.date === t));
    open.add(t);
    draw();
    const d = document.querySelector(`.day[data-t="${t}"]`);
    if (d) { d.scrollIntoView({ block: "start", behavior: "smooth" }); d.classList.add("flash"); setTimeout(() => d.classList.remove("flash"), 1200); }
  }

  // 用量：按用途（金额多的深）、按模型（主色深浅，不到 2% 的并成其他用灰）
  function money() {
    const w = weeks[cur], t = w.usd || 1;
    if (!w.usd) { $("money").innerHTML = `<h2>用量</h2><div class="empty">这周没有会话</div>`; return; }
    const parts = ["输入", "输出", "读缓存", "写缓存"].map((n, i) => [n, w.parts[i]]).sort((a, b) => b[1] - a[1]).map(([n, v], i) => [n, "s" + (4 - i), v]);
    const ms = Object.entries(w.models).sort((a, b) => b[1] - a[1]);
    const big = ms.filter((x) => x[1] / t >= .02), rest = ms.filter((x) => x[1] / t < .02).reduce((a, x) => a + x[1], 0);
    const models = [...big.map(([n, v], i) => [n, ["s3", "s1", "s2", "s4"][i] || "s1", v]), ...(rest ? [["其他", "s0", rest]] : [])];
    const row = (label, list) => `<div class="use"><div class="use-name">${label}</div><div class="bar">${list.map(([n, c, v]) => `<i class="${c}" style="flex:${v}" data-tip="${n} ${fmtU(v)}"></i>`).join("")}</div>
      <div class="legend">${list.map(([n, c, v]) => `<span><i class="${c}"></i>${n}<b>${fmtU(v)}</b><em>${v / t < .01 ? "<1" : Math.round(v / t * 100)}%</em></span>`).join("")}</div></div>`;
    $("money").innerHTML = `<h2>用量<span class="note">这周折合 ${fmtU(w.usd)}</span></h2>` + row("按用途", parts) + row("按模型", models);
  }

  // 备份：累计（顶上三个数）、各应用（会话数、原会话 → 备份）、备份日志（一天一行，由每次备份追加的记录汇总）。
  // 数据由 Swift 整理时一并给 data.backup：{last, apps: [{app, sessions, src, bak, gone}], log: [{t, app, files, written, failed, in, out, cleanFreed, autoDel, autoDelBytes}]}
  // 顶上不放密钥打码数（「密钥不用了」）；Claude 里不活跃会话移进废纸篓叫「自动清理」，不写删除
  const APP = { claude: "Claude Code", codex: "Codex", workbuddy: "WorkBuddy" };
  const fmtB = (n) => { if (!n) return "0"; if (n < 1024) return n + " B"; let v = n; for (const u of ["KB", "MB", "GB", "TB"]) { v /= 1024; if (v < 1000 || u === "TB") return (v < 10 ? v.toFixed(1) : Math.round(v)) + " " + u; } };
  let logAll = false, trendBy = "day", logBy = "day";   // 备份趋势、备份日志按天还是按月，不记上次
  // 备份页（要更可视化、有成果感）：四张数字卡（已备份、已备份容量、累计节省、自动清理）；
  // 空间节省（各应用一行，同一把尺子）；备份容量分析（按类型、按应用两根分段条）；备份趋势（每周新备份多少，按应用堆起来）；备份日志表
  const KIND = [["对话消息", "q4"], ["工具调用", "q3"], ["工具结果", "q2"], ["思考过程", "mute"], ["系统记录", "mute2"]];
  const APPS = ["claude", "codex", "workbuddy"];
  function backup() {
    const b = DATA && DATA.backup, el = $("backup");
    if (!(b && b.apps && b.apps.length)) { el.innerHTML = `<div class="card"><div class="empty">还没有备份过</div></div>`; return; }
    const dayOf = (iso) => { const d = new Date(iso); return new Date(d.getFullYear(), d.getMonth(), d.getDate()); };
    const when = b.last ? `上次备份 ${+dayOf(b.last) === +TODAY ? "今天" : md(dayOf(b.last))} ${hm(+new Date(b.last))}` : "还没有备份过";
    const log = b.log || [], sum = (f) => log.reduce((a, x) => a + (x[f] || 0), 0);
    const apps = b.apps.slice().sort((x, y) => APPS.indexOf(x.app) - APPS.indexOf(y.app));
    const src = apps.reduce((a, x) => a + x.src, 0), bak = apps.reduce((a, x) => a + x.bak, 0), saved = Math.max(0, src - bak);
    const sessions = apps.reduce((a, x) => a + x.sessions, 0), gone = apps.reduce((a, x) => a + (x.gone || 0), 0);
    const pctSaved = src ? Math.round(saved / src * 100) : 0;
    const name = (a) => APP[a] || a;
    // 数字卡：累计节省的数字用主色，是这页的成果（进度条和小字说的是同一件事，去掉了）
    const card = (l, v, s, cls = "") => `<div class="card kpi bks${cls}"><div class="l">${l}</div><div class="v">${v}</div><div class="s">${s}</div></div>`;
    const split = `<div class="thin">${apps.map((x) => `<i class="a-${x.app}" style="flex:${x.sessions}" data-tip="${name(x.app)} ${fmtN(x.sessions)} 个会话"></i>`).join("")}</div>`
      + `<div class="mini">${apps.map((x) => `<span><i class="a-${x.app}"></i>${name(x.app)} ${fmtN(x.sessions)}</span>`).join("")}</div>`;
    let h = `<div class="kpis bkstats">`
      + card("已备份", `${fmtN(sessions)}<small>个会话</small>`, split)
      + card("已备份容量", fmtB(bak), `原会话 ${fmtB(src)}${gone ? `<br>${fmtN(gone)} 个会话的原文件已清理，仅保留备份` : ""}`)
      + card("累计节省", fmtB(saved), `较原会话减少 ${pctSaved}%`, " win")
      + card("自动清理", `${fmtN(sum("autoDel"))}<small>个会话</small>`, `释放 ${fmtB(sum("autoDelBytes"))}${sum("cleanFreed") ? `<br>清理备份释放 ${fmtB(sum("cleanFreed"))}` : ""}`)
      + `</div>`;
    // 空间节省：同一把尺子（最大的原会话占满），浅色整条是原会话、主色是备份；右边写省了多少
    const top = Math.max(...apps.map((x) => x.src), 1);
    h += `<section class="card"><h2>空间节省<span class="note">${when}</span></h2>` + apps.map((x) => {
      const pct = x.src ? Math.max(0, Math.round((1 - x.bak / x.src) * 100)) : 0;
      return `<div class="bk"><div class="bk-head"><img src="app-${x.app}.svg" alt=""><span>${name(x.app)}</span><span class="cnt">${fmtN(x.sessions)} 个会话</span>
        <span class="sz">${fmtB(x.src)} → <b>${fmtB(x.bak)}</b></span><em>节省 ${fmtB(Math.max(0, x.src - x.bak))} · ${pct}%</em></div>
        <div class="sbar" data-tip="${name(x.app)}：原会话 ${fmtB(x.src)}，备份 ${fmtB(x.bak)}"><i class="src" style="width:${x.src / top * 100}%"></i><i class="bak" style="width:${x.bak / top * 100}%"></i></div></div>`;
    }).join("") + `<div class="legend"><span><i class="q1"></i>原会话</span><span><i class="bright"></i>备份</span></div></section>`;
    // 备份容量分析：按类型（颜色同存储设置的占用条）、按应用，各一根 28 高的分段条，块里写占比，下面列名字、大小
    const kinds = (b.kinds || []).filter((k) => k.b > 0), kt = kinds.reduce((a, k) => a + k.b, 0);
    const seg = (parts, total) => `<div class="tbar">${parts.map((p) => { const r = p.v / total * 100; return `<i class="${p.c}" style="flex:${p.v}" data-tip="${p.n} ${fmtB(p.v)}（${r < 1 ? "<1" : Math.round(r)}%）">${r >= 8 ? Math.round(r) + "%" : ""}</i>`; }).join("")}</div>`
      + `<div class="legend grid">${parts.map((p) => `<span><i class="${p.c}"></i>${p.n}<b>${fmtB(p.v)}</b></span>`).join("")}</div>`;
    h += `<section class="card"><h2>备份容量分析<span class="note">共 ${fmtB(bak)}</span></h2>`
      + (kt ? `<div class="use-name">按类型</div>` + seg(kinds.map((k) => ({ n: k.k, v: k.b, c: (KIND.find((x) => x[0] === k.k) || [0, "mute"])[1] })), kt) : "")
      + `<div class="use-name gap">按应用</div>` + seg(apps.filter((x) => x.bak).map((x) => ({ n: name(x.app), v: x.bak, c: "a-" + x.app })), bak || 1)
      + `</section>`;
    // 备份趋势：按天（近 30 天）或按月（近 12 个月）新备份了多少。一个会话的备份大小按它每天的消息数分到各天，再按天或按月加起来；
    // 按应用堆起来（低饱和的橙、蓝），柱顶写数。标题右边切换按天、按月
    const tog = (id, cur) => `<span class="seg sm" data-tog="${id}"><b data-v="day"${cur === "day" ? ' class="on"' : ""}>按天</b><b data-v="month"${cur === "month" ? ' class="on"' : ""}>按月</b></span>`;
    const monthKey = (k) => k.slice(0, 7), mLabel = (mk) => `${+mk.slice(5)}月`;
    const thisMonth = monthKey(key(TODAY));
    const buckets = trendBy === "day"
      ? [...Array(30)].map((_, i) => { const d = addDays(TODAY, i - 29); return { k: key(d), label: md(d) }; })
      : [...Array(12)].map((_, i) => { const d = new Date(TODAY.getFullYear(), TODAY.getMonth() - 11 + i, 1); const mk = key(d).slice(0, 7); return { k: mk, label: `${d.getFullYear() === TODAY.getFullYear() ? "" : d.getFullYear() + "年"}${d.getMonth() + 1}月` }; });
    const idx = new Map(buckets.map((x, i) => [x.k, i])), vals = buckets.map(() => ({}));
    for (const s of DATA.sessions || []) {
      if (!s.z) continue;
      const ds = Object.entries(s.days || {}), m = ds.reduce((x, [, v]) => x + (v.m || 0), 0) || ds.length, a = s.a || "claude";
      for (const [k, v] of ds) { const i = idx.get(trendBy === "day" ? k : monthKey(k)); if (i !== undefined) vals[i][a] = (vals[i][a] || 0) + s.z * ((v.m || (m === ds.length ? 1 : 0)) / m); }
    }
    const tot = (d) => APPS.reduce((x, a) => x + (d[a] || 0), 0), mx = Math.max(...vals.map(tot), 1), allT = vals.reduce((x, d) => x + tot(d), 0);
    const used = APPS.filter((a) => vals.some((d) => d[a]));
    const short = (n) => n >= 1073741824 ? (n / 1073741824).toFixed(1) + "G" : n >= 1048576 ? Math.round(n / 1048576) + "M" : n >= 1024 ? Math.round(n / 1024) + "K" : "";
    const tnote = trendBy === "day" ? `近 30 天新增 ${fmtB(allT)}，日均 ${fmtB(allT / 30)}` : `近 12 个月新增 ${fmtB(allT)}，月均 ${fmtB(allT / 12)}`;
    h += `<section class="card"><h2>备份趋势<span class="note">${tnote}</span>${tog("trend", trendBy)}</h2><div class="wkcols${trendBy === "month" ? " months" : ""}">`
      + vals.map((d, i) => { const t = tot(d);
        const tip = `${buckets[i].label}：` + (t ? used.filter((a) => d[a]).map((a) => `${name(a)} ${fmtB(d[a])}`).join("，") : "无新增备份");
        return `<span class="wc" data-tip="${tip}"><span class="st" style="height:${t / mx * 100}%">${t ? `<b>${short(t)}</b>` : ""}${used.slice().reverse().map((a) => d[a] ? `<i class="a-${a}" style="flex:${d[a]}"></i>` : "").join("")}</span></span>`; }).join("")
      + `</div>` + (trendBy === "day"
        ? `<div class="axis30"><span>${buckets[0].label}</span><span>${buckets[15].label}</span><span>今天</span></div>`
        : `<div class="axis12">${buckets.map((x) => `<span>${x.k === thisMonth ? "本月" : x.label}</span>`).join("")}</div>`)
      + (used.length > 1 ? `<div class="legend">${used.map((a) => `<span><i class="a-${a}"></i>${name(a)}</span>`).join("")}</div>` : "") + `</section>`;
    // 备份日志：按天或按月并起来，新的在上；窄了藏掉清理、自动清理两列（悬停日期看）
    const groupKey = (x) => logBy === "day" ? +dayOf(x.t) : monthKey(key(dayOf(x.t)));
    const byG = new Map();
    for (const x of log) { const k = groupKey(x); byG.set(k, [...(byG.get(k) || []), x]); }
    const groups = [...byG.entries()].sort((a, b2) => (a[0] < b2[0] ? 1 : -1));
    if (groups.length) {
      const list = logAll ? groups : groups.slice(0, 7), unit = logBy === "day" ? "天" : "个月";
      const glabel = (k) => logBy === "day" ? (k === +TODAY ? "今天" : md(new Date(k))) : (k === thisMonth ? "本月" : `${k.slice(0, 4) === String(TODAY.getFullYear()) ? "" : k.slice(0, 4) + "年"}${+k.slice(5)}月`);
      h += `<section class="card bklog"><h2>备份日志<span class="note">共 ${groups.length} ${unit}、${new Set(log.map((x) => x.t)).size} 次</span>${tog("log", logBy)}</h2><div class="row bkrow cols"><span>${logBy === "day" ? "日期" : "月份"}</span><span>次数</span><span>写入</span><span>原 → 备份</span><span>清理释放</span><span>自动清理</span><span>结果</span></div>`
        + list.map(([k, xs]) => {
          const s2 = (f) => xs.reduce((a, x) => a + (x[f] || 0), 0), runs = new Set(xs.map((x) => x.t)).size, failed = s2("failed"), err = (xs.find((x) => x.error) || {}).error;
          const tip = [...new Set(xs.filter((x) => APP[x.app]).map((x) => APP[x.app]))].join("、") + (s2("autoDel") ? `；自动清理 ${s2("autoDel")} 个会话，释放 ${fmtB(s2("autoDelBytes"))}` : "") + (s2("cleanFreed") ? `；清理备份释放 ${fmtB(s2("cleanFreed"))}` : "");
          return `<div class="row bkrow"><span class="d" data-tip="${tip}">${glabel(k)}</span><span class="num">${runs} 次</span>
            <span class="num">${fmtN(s2("written"))} 个文件</span><span class="num">${s2("written") ? `${fmtB(s2("in"))} → ${fmtB(s2("out"))}` : ""}</span>
            <span class="num">${s2("cleanFreed") ? fmtB(s2("cleanFreed")) : ""}</span><span class="num">${s2("autoDel") ? `${s2("autoDel")} 个，${fmtB(s2("autoDelBytes"))}` : ""}</span>
            <span class="num ${failed || err ? "warn" : "ok"}"${err ? ` data-tip="${esc(err)}"` : ""}>${err ? "备份失败" : failed ? `${failed} 个文件备份失败` : "成功"}</span></div>`;
        }).join("")
        + (groups.length > 7 ? `<div class="toggle" id="bkmore">${logAll ? "收起" : `再显示 ${groups.length - 7} ${unit}`}</div>` : "") + `</section>`;
    }
    el.innerHTML = h;
    const more = $("bkmore");
    if (more) more.onclick = () => { logAll = !logAll; backup(); };
    el.querySelectorAll("[data-tog]").forEach((t) => t.onclick = (e) => {
      const b = e.target.closest("b"); if (!b) return;
      if (t.dataset.tog === "trend") trendBy = b.dataset.v; else { logBy = b.dataset.v; logAll = false; }
      backup();
    });
  }

  function draw() {
    const none = !weeks.length;
    $("blank").hidden = !none;
    document.querySelector(".main").classList.toggle("none", none);
    document.querySelector(".page").hidden = none;
    if (none) { $("blank").innerHTML = Blank.html("empty", "还没有会话", "备份完成后，这里按周显示 Token、消息、AI 时长和 Git 提交"); return; }
    const bk = view === "backup";
    document.querySelector(".main").classList.toggle("bkview", bk);
    document.querySelector(".page:not(.bkpage)").hidden = bk;
    $("backup").hidden = !bk;
    document.querySelectorAll("#view b").forEach((x) => x.classList.toggle("on", x.dataset.v === view));
    appPick();
    if (bk) backup(); else { hero(); cal(); week(); money(); }
  }
  // 应用筛选：会话页右上角一个图标按钮（全部是四宫格，选了一个是它的图标），点了出小菜单；只有一个应用有会话时不显示（设计稿 设计/多应用/）
  const GRID = '<svg viewBox="0 0 24 24"><rect x="4" y="4" width="6.5" height="6.5" rx="1.6"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.6"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.6"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.6"/></svg>';
  const appIcon = (a) => a ? `<img class="ai" src="app-${a}.svg" alt="">` : GRID;
  function appPick() {
    const el = $("appf"), apps = ["claude", "codex", "workbuddy"].filter((a) => DATA && DATA.sessions && DATA.sessions.some((s) => (s.a || "claude") === a));
    el.hidden = view === "backup" || apps.length < 2;
    if (el.hidden) return;
    const CK = '<svg class="ck" viewBox="0 0 24 24"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg>';
    el.innerHTML = `<span class="pb" data-tip="${appF ? APP[appF] : "全部应用"}">${appIcon(appF)}<svg class="dn" viewBox="0 0 24 24"><path d="m7 10 5 5 5-5"/></svg></span>`
      + `<div class="pmenu" hidden>${["", ...apps].map((a) => `<div class="mi${a === appF ? " on" : ""}" data-a="${a}"><span class="ic">${appIcon(a)}</span><span class="nm">${a ? APP[a] : "全部"}</span>${a === appF ? CK : ""}</div>`).join("")}</div>`;
  }
  $("appf").onclick = (e) => {
    const menu = $("appf").querySelector(".pmenu"), it = e.target.closest(".mi");
    if (it) { appF = it.dataset.a; menu.hidden = true; build(DATA); draw(); return; }
    if (e.target.closest(".pb")) { menu.hidden = !menu.hidden; e.stopPropagation(); }
  };
  document.addEventListener("click", (e) => { const m = document.querySelector("#appf .pmenu"); if (m && !e.target.closest("#appf")) m.hidden = true; });

  // 右上角切换：会话 / 备份，每次打开先看会话，不记上次
  let view = "sess";
  $("view").onclick = (e) => { const b = e.target.closest("b"); if (!b || b.dataset.v === view) return; view = b.dataset.v; draw(); };

  // 占位用的假数据：第一次整理总览要十几秒，先用它按真实版式画一遍，外面加 .ui-skel 变成灰块（照 NAS 网站公共层的自动占位）
  function fake() {
    const today = new Date(), sessions = [];
    const titles = ["整理会话的总览页面", "版本需求和更新说明", "目录树和左栏的样式", "备份和同步"];
    titles.forEach((t, i) => {
      const days = {};
      for (let n = 0; n < 56; n++) {
        if ((n + i) % 3 === 2) continue;
        const v = (3 + ((n * 7 + i * 5) % 11)) * 1e6;
        days[key(addDays(today, -n))] = { m: 20 + n % 30, ms: 3.6e6, lg: 9e5, a: 0, b: 0, k: { "claude-opus-5-5": [0, v / 200, v, v / 40, 0] } };
      }
      sessions.push({ id: "skel" + i, t, p: "项目", d: "项目代码/项目", c: "", days });
    });
    return { today: key(today), sessions, commits: [] };
  }

  async function load(keepWeek) {
    const [d, p] = await Promise.all([fetch("overview.json").then((r) => r.json()), fetch("prices.json").then((r) => r.json())]);
    prices = p.models;
    const skel = !d.sessions;   // Swift 还没整理好时给的是空对象
    const page = document.querySelector(".page");
    page.classList.toggle("ui-skel", skel);
    const was = weeks[cur] && +weeks[cur].start;
    DATA = skel ? null : d;
    build(skel ? fake() : d);
    const i = keepWeek && was ? weeks.findIndex((w) => +w.start === was) : -1;
    cur = i >= 0 ? i : weeks.length - 1;
    draw();
  }
  window.echoReload = () => load(true);

  const post = (m) => window.webkit && window.webkit.messageHandlers.echo.postMessage(m);
  const goWeek = (i) => { cur = i; open.clear(); draw(); };
  // 已删除会话的「删除统计」：交给应用确认并删除，删完总览重新整理
  document.addEventListener("click", (e) => {
    const f = e.target.closest(".forget");
    if (!f) return;
    e.stopPropagation();
    post({ forget: f.dataset.forget });   // 确认框由应用弹（WKWebView 里网页的 confirm 弹不出来）
  }, true);
  $("prev").onclick = () => { if (cur > 0) goWeek(cur - 1); };
  $("next").onclick = () => { if (cur < weeks.length - 1) goWeek(cur + 1); };
  $("kpis").onclick = (e) => { const b = e.target.closest(".spark i"); if (b) goWeek(+b.dataset.i); };
  $("cal").onclick = (e) => { const c = e.target.closest(".c[data-t]"); if (c) showDay(+c.dataset.t); };
  $("week").onclick = (e) => {
    const j = e.target.closest("[data-at]");                       // 版本号、「N 次」：打开会话跳到那次提交
    if (j) { post({ open: j.dataset.sid, at: +j.dataset.at }); return; }
    const t = e.target.closest(".date[data-t], .toggle[data-t]");   // 日期、「还有 N 个会话」：展开或收起这天
    if (t) { const k = +t.dataset.t; open.has(k) ? open.delete(k) : open.add(k); week(); return; }
    const s = e.target.closest(".sess[data-id]");                  // 会话：打开
    if (s) post({ open: s.dataset.id });
  };
  Tip.init(".name .title, .name .path");   // 被省略的会话名、路径，悬停看全文
  load(false);
})();
