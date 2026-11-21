// 对话正文。数据格式见 EchoExport.swift（规则以 原型/export.py 为准）。
// 应用里数据来自 echo://app/session.json（EchoBrowser.swift 的 EchoScheme），复制恢复命令交给 Swift 写剪贴板；
// 设计稿 docs/设计稿/浏览窗口/ 先放好 window.SESSION 再引用本文件。
(function () {
  const root = typeof document === "undefined" ? null : document.getElementById("conv");

  const ICON = {
    find: '<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2"/></svg>',
    view: '<svg viewBox="0 0 24 24"><path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/></svg>',
    copy: '<svg viewBox="0 0 24 24"><rect x="8" y="8" width="12" height="12" rx="2.5"/><path d="M16 8V6.5A2.5 2.5 0 0 0 13.5 4h-7A2.5 2.5 0 0 0 4 6.5v7A2.5 2.5 0 0 0 6.5 16H8"/></svg>',
    chev: '<svg class="chev" viewBox="0 0 24 24"><path d="m9 6 6 6-6 6"/></svg>',
    cmd: '<svg viewBox="0 0 24 24"><path d="m5 8 4 4-4 4M12 17h7"/></svg>',
    sys: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/><path d="M12 11v5M12 8h.01"/></svg>',
    panel: '<svg viewBox="0 0 24 24"><rect x="3.5" y="4.5" width="17" height="15" rx="2.5"/><path d="M14.5 4.5v15"/></svg>',
    close: '<svg viewBox="0 0 24 24"><path d="m7 7 10 10M17 7 7 17"/></svg>',
  };

  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const p2 = (n) => String(n).padStart(2, "0");
  const WEEK = "日一二三四五六";
  const hm = (d) => `${p2(d.getHours())}:${p2(d.getMinutes())}`;
  const md0 = (d) => `${d.getMonth() + 1}月${d.getDate()}日`;
  const dayKey = (d) => `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
  const day = (d) => (d.getFullYear() === new Date().getFullYear() ? "" : `${d.getFullYear()}年`) + `${md0(d)} 周${WEEK[d.getDay()]}`;

  // 简易 Markdown：代码块、标题、表格、引用、列表、分隔线、段落，行内代码、加粗、链接
  function inline(s) {
    return esc(s)
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
      .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2">$1</a>');
  }
  function md(src) {
    const lines = src.split("\n");
    const out = [];
    let i = 0;
    const isBlock = (l) => /^(```|\s*\||#{1,4}\s|>|\s*([-*]|\d+\.)\s|\s*(-{3,}|\*{3,})\s*$)/.test(l);
    while (i < lines.length) {
      const line = lines[i];
      if (/^\s*```/.test(line)) {
        const buf = [];
        i++;
        while (i < lines.length && !/^\s*```/.test(lines[i])) buf.push(lines[i++]);
        i++;
        out.push(`<pre><code>${esc(buf.join("\n"))}</code></pre>`);
        continue;
      }
      if (/^\s*\|/.test(line)) {
        const rows = [];
        while (i < lines.length && /^\s*\|/.test(lines[i])) rows.push(lines[i++]);
        const cells = (r) => r.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
        const body = rows.filter((r) => !/^\s*\|[\s:|-]+\|\s*$/.test(r));
        out.push("<table>" + body.map((r, n) => {
          const tag = n === 0 ? "th" : "td";
          return "<tr>" + cells(r).map((c) => `<${tag}>${inline(c)}</${tag}>`).join("") + "</tr>";
        }).join("") + "</table>");
        continue;
      }
      if (/^\s*(-{3,}|\*{3,})\s*$/.test(line)) { out.push("<hr>"); i++; continue; }
      const h = line.match(/^(#{1,4})\s+(.*)/);
      if (h) { out.push(`<h${h[1].length}>${inline(h[2])}</h${h[1].length}>`); i++; continue; }
      if (/^>\s?/.test(line)) {
        const buf = [];
        while (i < lines.length && /^>\s?/.test(lines[i])) buf.push(lines[i++].replace(/^>\s?/, ""));
        out.push(`<blockquote>${buf.map(inline).join("<br>")}</blockquote>`);
        continue;
      }
      if (/^\s*([-*]|\d+\.)\s+/.test(line)) {
        const ordered = /^\s*\d+\./.test(line);
        const buf = [];
        while (i < lines.length && /^\s*([-*]|\d+\.)\s+/.test(lines[i])) {
          buf.push(`<li>${inline(lines[i++].replace(/^\s*([-*]|\d+\.)\s+/, ""))}</li>`);
        }
        out.push(ordered ? `<ol>${buf.join("")}</ol>` : `<ul>${buf.join("")}</ul>`);
        continue;
      }
      if (!line.trim()) { i++; continue; }
      const buf = [];
      while (i < lines.length && lines[i].trim() && !isBlock(lines[i])) buf.push(inline(lines[i++]));
      out.push(`<p>${buf.join("<br>")}</p>`);
    }
    return `<div class="md">${out.join("")}</div>`;
  }

  // 工具调用的一行说明：优先取说明，其次命令、文件路径
  function toolSummary(b) {
    const x = b.input || {};
    const s = x.description || x.command || x.file_path || x.skill || x.pattern || x.url || x.query || x.prompt || "";
    return String(s).split("\n")[0].slice(0, 200);
  }

  // 思考和工具的内容可能很长，先只记下来，点开（或查找命中）时才生成，几千条的会话也不卡
  const STEPS = [];
  function stepInput(b) { const x = b.input || {}; return x.command ? x.command : JSON.stringify(x, null, 2); }
  function stepText(b) { return b.kind === "thinking" ? b.text : stepInput(b) + "\n" + (b.result == null ? "" : b.result); }
  function stepBody(b) {
    if (b.kind === "thinking") return esc(b.text);
    const result = b.result == null ? "（没有返回）" : b.result;
    return `<div class="label">输入</div><pre>${esc(stepInput(b))}</pre><div class="label">${b.isError ? "输出（出错）" : "输出"}</div><pre>${esc(result)}</pre>`;
  }
  function fillStep(det) {
    const io = det.querySelector(":scope > .io");
    if (io && !io.dataset.done) { io.innerHTML = stepBody(STEPS[det.dataset.i]); io.dataset.done = "1"; }
  }
  function renderStep(b) {
    const i = STEPS.push(b) - 1;
    const kid = b._kid ? ` id="${b._kid}"` : "";
    if (b.kind === "thinking") {
      return `<li class="step thinking"><details data-i="${i}"><summary><span class="name">思考过程</span></summary><div class="io"></div></details></li>`;
    }
    return `<li class="step tool${b.isError ? " error" : ""}${b._kid ? " commit" : ""}"${kid}><details data-i="${i}"><summary><span class="name">${esc(b.name)}</span><span class="desc">${esc(toolSummary(b))}</span></summary><div class="io"></div></details></li>`;
  }

  // 一串连续的思考和工具调用收成一行：「思考过程、3 次工具调用：Bash 2、Read 1」
  function renderSteps(steps) {
    const tools = steps.filter((b) => b.kind === "tool");
    const thinking = steps.length - tools.length;
    const count = {};
    tools.forEach((b) => (count[b.name] = (count[b.name] || 0) + 1));
    const names = Object.entries(count).sort((a, b) => b[1] - a[1]).map(([n, c]) => (c > 1 ? `${n} ${c}` : n)).join("、");
    const head = [thinking ? "思考过程" : "", tools.length ? `${tools.length} 次工具调用` : ""].filter(Boolean).join("、");
    const errs = tools.filter((b) => b.isError).length;
    return `<details class="steps"><summary>${ICON.chev}<span class="sum">${head}${names ? "：" + esc(names) : ""}</span>${errs ? `<span class="err">${errs} 次出错</span>` : ""}</summary>
      <ol class="step-list">${steps.map(renderStep).join("")}</ol></details>`;
  }

  // git 提交：Bash 命令里有 git commit、没出错、不是「nothing to commit」。说明取 -m "…" 或 heredoc 的第一行。
  // heredoc 的内容先拿掉再找命令：Python 脚本里写到 git commit 的不算
  function commitMessage(b) {
    if (b.kind !== "tool" || b.name !== "Bash" || b.isError) return null;
    const cmd = (b.input && b.input.command) || "";
    if (!/git/.test(cmd) || !/commit/.test(cmd)) return null;
    const bodies = [];
    const bare = cmd.replace(/<<-?\s*['"]?(\w+)['"]?([^\n]*)\n([\s\S]*?)\n\s*\1(?=\s|\)|"|$)/g, (_, tag, tail, body) => { bodies.push(body); return `<<HEREDOC${bodies.length - 1}${tail}`; });
    // 只认真的命令：在开头，或跟在 && ; | 换行后面
    const at = bare.search(/(?:^|&&|\|\||;|\n)\s*git\b(?:\s+-c\s+\S+)*\s+commit\b/);
    if (at < 0) return null;
    if (/nothing to commit|no changes added/.test(b.result || "")) return null;
    const rest = bare.slice(at);
    let msg = "";
    const h = rest.match(/<<HEREDOC(\d+)/);
    const m = rest.match(/\s-[a-zA-Z]*m\s+"((?:[^"\\]|\\.)*)"/) || rest.match(/\s-[a-zA-Z]*m\s+'([^']*)'/);
    if (m && !/^\$\(cat/.test(m[1])) msg = m[1].replace(/\\(["\\$`])/g, "$1");
    else if (h) msg = bodies[+h[1]];
    const line = msg.split("\n").map((x) => x.trim()).find(Boolean);
    return line || "提交";
  }

  // 版本号和它前面的模块名：「后台接口 v0.14.2」→ 模块「后台接口」、版本「0.14.2」。
  // 只认说明开头的「模块 v版本号」（模块里可以有空格，如「NAS 网站」）；版本号在句子中间时没有模块，中文分不出词，往前取会取到半句话
  function versionKey(label) {
    const head = label.match(/^\s*([\p{L}\p{N}_ -]{0,12}?)\s*v?(\d+\.\d+\.\d+)/u);
    if (head) return (head[1].replace(/[\s_-]*v?$/i, "").trim() + " " + head[2]).trim();
    const any = label.match(/(\d+\.\d+\.\d+)/);
    return any ? any[1] : null;
  }

  // 定位条的关键点（方案 docs/versions/v0.3.0-会话定位条.html）：只标三类
  // 1. 手动压缩：阶段总结的 trigger 是 manual；自动压缩不标
  // 2. 版本提交：同一个「模块 + 版本号」只标最后一次；会话里一次版本提交都没有时，每次提交都标
  // 3. 合集里每个会话的开头
  function keyPoints(turns) {
    const found = [];
    let lastAsk = "", lastShort = "";
    turns.forEach((t, i) => {
      // 手动压缩的说明：压缩前最后一条 10 个字以上的消息（「做吧」这类短确认往前找，跳过 / 命令）
      if (t.role === "user" && !/^\//.test(t.text.trim())) {
        const x = t.text.replace(/\s+/g, " ").trim();
        if (x.length >= 10) lastAsk = x;
        else if (!lastAsk) lastShort = x;
      } else if (t.role === "summary" && t.trigger === "manual") {
        found.push({ obj: t, turn: i, kind: "compact", ts: t.ts, label: "手动压缩", sub: lastAsk || lastShort || summaryLine(t.text) });
        lastAsk = lastShort = "";
      } else if (t.role === "session") {
        found.push({ obj: t, turn: i, kind: "part", ts: t.ts, label: t.text });
      } else if (t.role === "assistant") {
        t.blocks.forEach((b) => {
          const msg = commitMessage(b);
          if (msg && !/^Merge\b/.test(msg)) found.push({ obj: b, turn: i, kind: "commit", ts: t.ts, label: msg, ver: versionKey(msg) });
        });
      }
    });
    // 同一个版本标最后一次提交：提交是这一版的终点，它前面的对话都属于这一版
    const anyVer = found.some((k) => k.ver);
    // 位置在最后一次提交，说明取第一次提交那句（最后一次多是「验收、更新记录」，第一次才写这一版做了什么）
    const last = new Map(), first = new Map();
    found.forEach((k, i) => { if (k.kind === "commit" && k.ver) { last.set(k.ver, i); if (!first.has(k.ver)) first.set(k.ver, k.label); } });
    const keys = found.filter((k, i) => k.kind !== "commit" || !anyVer || (k.ver && last.get(k.ver) === i));
    keys.forEach((k) => { if (k.kind === "commit" && k.ver) k.label = first.get(k.ver); });
    keys.forEach((k, n) => { k.id = "k" + n; k.obj._kid = k.id; delete k.obj; });
    return keys;
  }

  // 阶段总结没有压缩前的用户消息可用时，从摘要里取第一句像样的话（跳过开场白、系统标签、半截标题）
  function summaryLine(text) {
    let t = text.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, "").replace(/<[^>]+>/g, "");
    const at = t.search(/Summary:/);
    if (at >= 0) t = t.slice(at + 8);
    const clean = (x) => x.replace(/^[\s#>*\-•\d.、)）]+/, "").replace(/\*\*/g, "").trim();
    const good = (x) => x.length >= 10 && !/[:：]$/.test(x) && !/This session is being continued|^(Primary Request and Intent|主要需求和意图|Analysis)$/i.test(x);
    return (t.split("\n").map(clean).find(good) || "").slice(0, 80);
  }

  function renderAI(blocks) {
    const out = [];
    let run = [];
    const flush = () => { if (run.length) out.push(renderSteps(run)); run = []; };
    blocks.forEach((b) => { if (b.kind === "text") { flush(); out.push(md(b.text)); } else run.push(b); });
    flush();
    return `<div class="msg ai">${out.join("")}</div>`;
  }

  // 每段一个 HTML 片段：日期线、一条消息、一段回复
  function render(turns, partOf) {
    const out = [];
    let lastDay = "";
    for (let i = 0; i < turns.length; i++) {
      const t = turns[i];
      const d = t.ts ? new Date(t.ts) : null;
      if (d && dayKey(d) !== lastDay) {
        lastDay = dayKey(d);
        out.push(`<div class="divider"><span>${day(d)}</span></div>`);
      }
      partOf[i] = out.length;
      if (t.role === "assistant") {
        // 连着的几条回复合成一段
        let blocks = t.blocks.slice();
        while (turns[i + 1] && turns[i + 1].role === "assistant") { blocks = blocks.concat(turns[++i].blocks); partOf[i] = out.length; }
        out.push(renderAI(blocks));
      } else if (t.role === "user") {
        const long = t.text.length > 1200 || t.text.split("\n").length > 16;
        out.push(`<div class="msg user${long ? " long" : ""}"${t._uid ? ` id="${t._uid}"` : ""}><div class="bubble">${esc(t.text)}</div>${long ? '<button class="more" type="button">展开全部</button>' : ""}<div class="stamp">${d ? hm(d) : ""}</div></div>`);
      } else if (t.role === "session") {
        // 合集里每个会话的开头
        out.push(`<div class="divider part" id="${t._kid}"><span><b>${esc(t.text)}</b>${t.computer ? "　" + esc(t.computer) : ""}</span></div>`);
      } else if (t.role === "command") {
        out.push(`<div class="event">${ICON.cmd}<code>${esc(t.text)}</code></div>`);
      } else if (t.role === "summary") {
        out.push(`<details class="compact"${t._kid ? ` id="${t._kid}"` : ""}><summary><div class="divider"><span>会话在这里压缩过，点开看摘要</span></div></summary>${md(t.text)}</details>`);
      } else {
        out.push(`<div class="event system">${ICON.sys}<span>${esc(t.text.slice(0, 300))}</span></div>`);
      }
    }
    return out;
  }

  function start(S) {
    const m = S.meta;
    const s0 = m.start ? new Date(m.start) : null, s1 = m.end ? new Date(m.end) : null;
    let span = "";
    if (s0 && s1) span = `${md0(s0)} ${hm(s0)} 至 ${dayKey(s0) === dayKey(s1) ? "" : md0(s1) + " "}${hm(s1)}`;
    const asks = S.turns.filter((t) => t.role === "user").length;
    const meta = [span, m.kind === "collection" ? `${m.count} 个会话连起来` : "", m.computer, m.gitBranch && m.gitBranch !== "HEAD" ? m.gitBranch : "", `${asks} 次提问`].filter(Boolean);

    root.innerHTML = `
      <header class="c-head"><div class="c-head-in">
        <div class="c-bar"><div class="c-meta" id="h-meta" title="${esc(m.cwd + "\n" + m.id)}">${meta.map((x) => `<span>${esc(x)}</span>`).join("")}</div>
        <div class="c-actions">
          <label class="c-find">${ICON.find}<input id="search" type="search" placeholder="查找" autocomplete="off"><span class="hits" id="hits"></span></label>
          <div class="c-menu-wrap">
            <button class="c-btn" id="view-btn" type="button" title="显示">${ICON.view}<span class="lbl">显示</span></button>
            <div class="c-menu" id="view-menu" hidden>
              <label><input type="checkbox" id="show-thinking" checked>思考过程</label>
              <label><input type="checkbox" id="show-tools" checked>工具调用</label>
              <label><input type="checkbox" id="show-system">系统消息</label>
              <hr><button type="button" id="expand-all">全部展开</button>
            </div>
          </div>
          <button class="c-btn outline${m.kind === "collection" ? " hidden" : ""}" id="copy-resume" type="button">${ICON.copy}<span class="lbl">复制恢复命令</span></button>
          <button class="c-btn hidden" id="utoggle" type="button" title="展开你的消息">${ICON.panel}<span class="lbl">我的消息</span></button>
        </div></div>
        <h1 id="h-title">${esc(m.title)}</h1>
      </div></header>
      <div class="c-body"><nav class="c-rail" id="rail"></nav><main class="c-main" id="turns"></main><nav class="c-rail right" id="urail"></nav></div>
      <div class="toast" id="toast"></div>`;

    const $ = (id) => document.getElementById(id);
    const all = (sel) => root.querySelectorAll(sel);

    // 先画前 80 段，滚到底再接着画
    const keys = keyPoints(S.turns);
    const myMsgs = [];   // 你的消息，右边定位条用
    S.turns.forEach((t, i) => { if (t.role === "user") { t._uid = "u" + i; myMsgs.push({ id: t._uid, turn: i, text: t.text, ts: t.ts }); } });
    const partOf = [];
    const parts = render(S.turns, partOf);
    let drawn = 0;
    const sentinel = document.createElement("div");
    function draw(n) {
      if (drawn >= parts.length) return;
      const end = Math.min(parts.length, drawn + n);
      sentinel.remove();
      // 每段前放一个锚点 p<段号>：左边定位条点一条时跳到这一段的开头
      $("turns").insertAdjacentHTML("beforeend", parts.slice(drawn, end).map((h, j) => `<i class="pa" id="p${drawn + j}"></i>${h}`).join(""));
      drawn = end;
      if (drawn < parts.length) $("turns").appendChild(sentinel);
      applyToggles();
    }
    const drawAll = () => draw(parts.length);
    new IntersectionObserver((es) => { if (es.some((e) => e.isIntersecting)) draw(80); }, { rootMargin: "1200px" }).observe(sentinel);
    // 定位条：左边是关键点（版本、手动压缩、合集里的会话开头），右边是你的消息。两条共用 makeRail：
    // 一项一行、间距固定、排不下时自己滚动；空白够宽时写一行说明，不够宽时只画横线、悬停浮出说明；
    // 点了跳过去；滚动对话时当前那条变蓝，定位条跟着把它滚到中间
    let LINE = 120;   // 标题栏下面那条线，判断读到哪用它；标题换行变高时跟着改（measureHead）
    const posOf = (id) => {
      const el = document.getElementById(id);
      return el ? (el.closest("details.steps:not([open])") || el).getBoundingClientRect().top : Infinity;   // 还没画出来的算在下面
    };
    // 量标题栏高度：写进 --head-h（定位条起点、跳转停的位置），读到哪的那条线放在标题栏下 48
    const measureHead = () => {
      const h = root.querySelector(".c-head").offsetHeight;
      root.style.setProperty("--head-h", h + "px");
      document.documentElement.style.setProperty("--head-h", h + "px");
      LINE = h + 48;
    };
    let gutter = 0, pinned = null;   // pinned：刚点过的那条定位条和当时的滚动位置，页面没动时保持点中的那条
    const layout = () => {
      gutter = ((root.clientWidth || document.documentElement.clientWidth) - 840) / 2;   // 按对话区的宽度算，设计稿里对话区比窗口窄
      const left = $("rail"), right = $("urail");
      left.classList.toggle("wide", gutter >= 180);
      left.style.width = gutter >= 180 ? Math.min(gutter - 8, 300) + "px" : "";
      // 右边：展开时放在空白里，空白不够 280 就浮在正文上
      const open = right.classList.contains("open");
      right.classList.toggle("wide", open);
      right.classList.toggle("float", open && gutter - 8 < 280);
      right.style.width = open ? Math.max(280, Math.min(gutter - 8, 340)) + "px" : "";
    };
    // 画到第 part 段，滚到 id 那里（停在标题栏下），闪一下
    const goTo = (part, id) => {
      if (part >= drawn) draw(part - drawn + 1);
      const el = document.getElementById(id);
      if (!el) return;
      const g = el.closest("details.steps");
      if (g) g.open = true;
      el.scrollIntoView({ block: "start" });
      const fl = el.classList.contains("pa") ? el.nextElementSibling : el;
      if (fl) { fl.classList.remove("flash"); void fl.offsetWidth; fl.classList.add("flash"); }
    };

    function makeRail(nav, items, o) {
      let html = "", lastGroup;
      items.forEach((it) => {
        if (it.group !== lastGroup) { html += `<div class="r-group">${esc(it.group || "")}</div>`; lastGroup = it.group; }
        html += `<div class="k-row ${it.cls}" role="button" data-k="${it.id}"><i></i><div class="note">${it.row}</div></div>`;   // 检索时按 it.text 过滤
      });
      nav.innerHTML = `<div class="r-scroll"><div class="r-list">${html}</div></div><div class="tip"></div>`;
      const scroller = nav.querySelector(".r-scroll"), tip = nav.querySelector(".tip");
      const rows = [...nav.querySelectorAll(".k-row")];
      const byId = Object.fromEntries(items.map((it) => [it.id, it]));
      let over = false, current;
      // 当前那条变蓝；它不在定位条中间 60% 的范围里时滚到中间；鼠标在定位条上时不滚，免得和用户自己滚冲突
      const mark = (id) => {
        if (id !== current) {
          current = id;
          rows.forEach((x) => x.classList.toggle("on", x.dataset.k === id));
          if (o.onChange) o.onChange(id && byId[id]);
          if (!id && !over) scroller.scrollTo({ top: 0, behavior: "smooth" });
        }
        const row = id && rows.find((x) => x.dataset.k === id);
        if (!row || over) return;
        const y = row.offsetTop - scroller.scrollTop + row.offsetHeight / 2, h = scroller.clientHeight;
        if (y < h * 0.2 || y > h * 0.8) scroller.scrollTo({ top: row.offsetTop - h / 2 + row.offsetHeight / 2, behavior: "smooth" });
      };
      nav.addEventListener("mouseenter", () => (over = true));
      nav.addEventListener("mouseleave", () => { over = false; tip.classList.remove("show"); });
      nav.addEventListener("click", (e) => {
        const t = e.target.closest("[data-k]");
        if (!t) return;
        o.jump(byId[t.dataset.k]);   // 头部（检索框、按钮）不带 data-k，不会走到这里
        mark(t.dataset.k);
        pinned = { rail: nav, y: window.scrollY };
        spot();
      });
      nav.addEventListener("mouseover", (e) => {
        const t = e.target.closest(".k-row");
        if (!t || nav.classList.contains("wide")) { tip.classList.remove("show"); return; }
        const it = byId[t.dataset.k];
        const d = it.ts ? new Date(it.ts) : null;
        tip.style.maxWidth = Math.max(150, Math.min(280, gutter - 52)) + "px";
        tip.innerHTML = `<div class="tip-label">${it.tip}</div><div class="tip-time">${d ? md0(d) + " " + hm(d) : ""}</div>`;
        tip.style.top = t.offsetTop - scroller.scrollTop + scroller.offsetTop + t.offsetHeight / 2 + "px";
        tip.classList.add("show");
      });
      return { nav, mark, cur: o.cur, rows, byId };
    }

    const rails = [];

    // 左边：关键点。一个关键点是它前面那一段的终点（提交「0.1.0」之前的对话都属于 0.1.0），
    // 所以读到哪，就看前面遇到的下一个关键点；合集里的会话开头相反，是后面那一段的起点
    if (keys.length) {
      root.classList.add("has-rail");
      const verOf = (k) => (k.ver || "").split(" ").pop();
      const moduleOf = (k) => (k.kind === "commit" && k.ver ? k.ver.split(" ").slice(0, -1).join(" ") : "");
      // 一句做了什么：去掉模块和版本号、「需求：」这类前缀，到第一个括号或分号截住
      const brief = (k) => {
        const mod = moduleOf(k), ver = verOf(k);
        let t = k.label.replace(new RegExp((mod ? mod.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\s*" : "") + "v?" + ver.replace(/\./g, "\\.")), "");
        t = t.replace(/\s{2,}/g, " ").replace(/^[\s:：、,，-]+/, "").replace(/^[^\s:：]{1,6}[:：]\s*/, "");
        const cut = t.search(/[（(；;]/);
        if (cut >= 6) t = t.slice(0, cut);
        return t.trim();
      };
      const noteText = (k) => {
        if (k.kind === "compact") return `<span class="n-tag">压缩</span><span class="n-text">${esc(k.sub || "")}</span>`;
        if (k.kind === "part") return `<span class="n-text"><b>${esc(k.label)}</b></span>`;
        if (!k.ver) return `<span class="n-text">${esc(k.label)}</span>`;
        return `<span class="n-ver">${esc(verOf(k))}</span><span class="n-text">${esc(brief(k))}</span>`;
      };
      const full = (k) => (k.kind === "compact" ? `手动压缩：${esc(k.sub || "")}` : k.kind === "part" ? esc(k.label) : esc(k.label).replace(/(v?\d+\.\d+\.\d+)/, '<b class="ver">$1</b>'));

      // 左上角标题跟着当前段换：标题写这一段的关键点，小字写会话标题和时间；后面没有关键点时恢复会话标题
      const homeTitle = $("h-title").innerHTML, homeMeta = $("h-meta").innerHTML;
      const setHead = (k) => {
        const d = k && k.ts ? new Date(k.ts) : null;
        $("h-title").innerHTML = k ? full(k) : homeTitle;
        $("h-meta").innerHTML = k ? `<span>${esc(m.title)}</span>${d ? `<span>${md0(d)} ${hm(d)}</span>` : ""}` : homeMeta;
        ["h-title", "h-meta"].forEach((x) => { $(x).classList.remove("swap"); void $(x).offsetWidth; $(x).classList.add("swap"); });
        measureHead();
      };

      rails.push(makeRail($("rail"), keys.map((k) => ({
        id: k.id, ts: k.ts, cls: "t-" + k.kind, group: moduleOf(k), row: noteText(k), tip: full(k),
      })), {
        onChange: (it) => setHead(it && keys.find((k) => k.id === it.id)),
        // 点一条跳到这一段的开头：上一个关键点之后；会话开头就跳到它自己
        jump: (it) => {
          const n = keys.findIndex((k) => k.id === it.id), k = keys[n], prev = keys[n - 1];
          if (k.kind === "part") return goTo(partOf[k.turn], k.id);
          let start = prev ? partOf[prev.turn] + (prev.kind === "part" ? 0 : 1) : 0;
          start = Math.min(start, partOf[k.turn]);
          goTo(partOf[k.turn], "p" + start);
        },
        cur: () => {
          const next = keys.find((k) => posOf(k.id) > LINE);
          if (next && next.kind !== "part") return next.id;
          let part = null;
          keys.forEach((k) => { if (k.kind === "part" && posOf(k.id) <= LINE) part = k; });
          return part ? part.id : null;
        },
      }));
    }

    // 右边：对话检索。默认收起，只留横线和放大镜按钮；展开后顶上是搜索框，按天列你的消息，打字只留下命中的。
    // 消息是一段对话的起点，读到哪就看读过的最后一条；展开收起记在本机，下次照旧
    if (myMsgs.length) {
      root.classList.add("has-urail");
      const dayOf = (ts) => (ts ? day(new Date(ts)) : "");
      const oneLine = (x) => x.replace(/\s+/g, " ").trim();
      // 展开后一条消息一个气泡，内容写全、保留换行；超过 1000 字的截断并写总字数，免得一条占满面板
      const CAP = 1000;
      const bubbleText = (t, q) => {
        const body = t.length > CAP ? t.slice(0, CAP) : t;
        let h = esc(body);
        if (q) h = h.replace(new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/[&<>"]/g, (c) => esc(c)), "gi"), (x) => `<mark>${x}</mark>`);
        return h + (t.length > CAP ? `<span class="n-more">…共 ${t.length} 字</span>` : "");
      };
      const r = makeRail($("urail"), myMsgs.map((a) => ({
        id: a.id, ts: a.ts, cls: "t-ask" + (a.text.trim().length <= 6 ? " short" : ""), group: dayOf(a.ts),   // 「发布」「继续」这种短确认淡一些
        row: `<span class="n-text">${bubbleText(a.text.trim(), "")}</span><span class="n-time">${a.ts ? hm(new Date(a.ts)) : ""}</span>`,
        tip: esc(oneLine(a.text).slice(0, 200)),
      })), {
        jump: (it) => goTo(partOf[myMsgs.find((a) => a.id === it.id).turn], it.id),
        cur: () => {
          let cur = null;
          for (const a of myMsgs) { const y = posOf(a.id); if (y > LINE) break; cur = a.id; }
          return cur;
        },
      });
      rails.push(r);
      const nav = r.nav;
      nav.insertAdjacentHTML("afterbegin", `<div class="r-head"><input class="r-find" id="ufind" type="search" placeholder="搜你的消息" autocomplete="off"><span class="r-count" id="ucount"></span><button class="r-toggle" id="uclose" type="button" title="收起">${ICON.close}</button></div>`);
      $("utoggle").classList.remove("hidden");
      const setOpen = (open) => {
        nav.classList.toggle("open", open);
        $("utoggle").title = open ? "收起你的消息" : "展开你的消息";
        $("utoggle").classList.toggle("on", open);
        try { localStorage.setItem("echo.urail.open", open ? "1" : ""); } catch (e) {}
        layout();
        if (open) setTimeout(() => $("ufind").focus(), 0);
      };
      let saved = "";
      try { saved = localStorage.getItem("echo.urail.open") || ""; } catch (e) {}
      nav.classList.toggle("open", saved === "1");
      $("utoggle").title = saved === "1" ? "收起你的消息" : "展开你的消息";
      $("utoggle").classList.toggle("on", saved === "1");
      $("utoggle").addEventListener("click", (e) => { e.stopPropagation(); setOpen(!nav.classList.contains("open")); });
      $("uclose").addEventListener("click", () => setOpen(false));
      // 检索：只留下包含关键词的消息，命中的字高亮；没有命中的日期组一起藏起来
      const texts = Object.fromEntries(myMsgs.map((a) => [a.id, a.text.trim()]));
      $("ufind").addEventListener("input", (e) => {
        const raw = e.target.value.trim(), q = raw.toLowerCase();
        let n = 0;
        r.rows.forEach((row) => {
          const t = texts[row.dataset.k], hit = !q || t.toLowerCase().includes(q);
          row.classList.toggle("miss", !hit);
          if (hit && q) n++;
          row.querySelector(".n-text").innerHTML = bubbleText(t, hit ? raw : "");
        });
        nav.querySelectorAll(".r-group").forEach((g) => {
          let x = g.nextElementSibling, any = false;
          while (x && !x.classList.contains("r-group")) { if (!x.classList.contains("miss")) any = true; x = x.nextElementSibling; }
          g.classList.toggle("miss", !any);
        });
        $("ucount").textContent = q ? `${n} 条` : "";
      });
      $("ufind").addEventListener("keydown", (e) => {
        if (e.key === "Escape") { if (e.target.value) { e.target.value = ""; e.target.dispatchEvent(new Event("input")); } else setOpen(false); }
        if (e.key === "Enter") { const first = r.rows.find((x) => !x.classList.contains("miss")); if (first) first.click(); }
      });
    }

    function spot() {
      if (pinned && Math.abs(window.scrollY - pinned.y) >= 4) pinned = null;
      rails.forEach((r) => { if (!pinned || pinned.rail !== r.nav) r.mark(r.cur()); });
    }
    if (rails.length) {
      measureHead();
      layout();
      window.addEventListener("resize", () => { layout(); measureHead(); });
      let ticking = false;
      window.addEventListener("scroll", () => { if (!ticking) { ticking = true; setTimeout(() => { spot(); ticking = false; }, 60); } }, { passive: true });
      spot();
    }

    $("turns").addEventListener("toggle", (e) => { if (e.target.dataset && e.target.dataset.i && e.target.open) fillStep(e.target); }, true);

    // 显示开关：一组里的步骤全藏了，这一组也藏
    function applyToggles() {
      all(".step.thinking").forEach((e) => e.classList.toggle("hidden", !$("show-thinking").checked));
      all(".step.tool").forEach((e) => e.classList.toggle("hidden", !$("show-tools").checked));
      all(".event.system").forEach((e) => e.classList.toggle("hidden", !$("show-system").checked));
      all(".steps").forEach((g) => g.classList.toggle("hidden", !g.querySelector(".step:not(.hidden)")));
    }
    ["show-thinking", "show-tools", "show-system"].forEach((id) => $(id).addEventListener("change", applyToggles));
    draw(80);

    $("view-btn").addEventListener("click", (e) => { e.stopPropagation(); $("view-menu").hidden = !$("view-menu").hidden; $("view-btn").classList.toggle("on", !$("view-menu").hidden); });
    document.addEventListener("click", (e) => { if (!e.target.closest(".c-menu")) { $("view-menu").hidden = true; $("view-btn").classList.remove("on"); } });

    let expanded = false;
    $("expand-all").addEventListener("click", () => {
      expanded = !expanded;
      if (expanded) drawAll();
      all("#turns details").forEach((d) => { if (expanded && d.dataset.i) fillStep(d); d.open = expanded; });
      $("expand-all").textContent = expanded ? "全部折叠" : "全部展开";
    });

    $("turns").addEventListener("click", (e) => {
      const b = e.target.closest(".more");
      if (!b) return;
      const box = b.closest(".msg");
      box.classList.toggle("open");
      b.textContent = box.classList.contains("open") ? "收起" : "展开全部";
    });

    function toast(msg) {
      const el = $("toast");
      el.textContent = msg;
      el.classList.add("show");
      clearTimeout(toast.t);
      toast.t = setTimeout(() => el.classList.remove("show"), 1800);
    }

    // 只有本机的会话能恢复，另一台电脑的会话只提示在哪台电脑上
    $("copy-resume").addEventListener("click", () => {
      if (!m.local) { toast(`这个会话在 ${m.computer} 上`); return; }
      const cmd = `cd '${m.cwd.replace(/'/g, "'\\''")}' && claude --resume ${m.id}`;
      if (window.webkit && window.webkit.messageHandlers.echo) window.webkit.messageHandlers.echo.postMessage({ copy: cmd });
      else if (navigator.clipboard) navigator.clipboard.writeText(cmd);
      toast("已复制恢复命令");
    });

    // 会话内查找：高亮所有命中，回车跳到下一个，命中在折叠处时自动展开
    let marks = [];
    let cur = -1;
    function clearMarks() {
      all("#turns mark").forEach((mk) => mk.replaceWith(document.createTextNode(mk.textContent)));
      $("turns").normalize();
      marks = [];
      cur = -1;
    }
    function search(q) {
      clearMarks();
      if (!q) { $("hits").textContent = ""; return; }
      const lower = q.toLowerCase();
      drawAll();
      all("#turns details[data-i]").forEach((d) => { if (stepText(STEPS[d.dataset.i]).toLowerCase().includes(lower)) fillStep(d); });
      const walker = document.createTreeWalker($("turns"), NodeFilter.SHOW_TEXT);
      const nodes = [];
      while (walker.nextNode()) if (walker.currentNode.nodeValue.toLowerCase().includes(lower)) nodes.push(walker.currentNode);
      nodes.forEach((node) => {
        const text = node.nodeValue;
        const frag = document.createDocumentFragment();
        let pos = 0;
        let idx;
        while ((idx = text.toLowerCase().indexOf(lower, pos)) !== -1) {
          frag.appendChild(document.createTextNode(text.slice(pos, idx)));
          const mk = document.createElement("mark");
          mk.textContent = text.slice(idx, idx + q.length);
          frag.appendChild(mk);
          marks.push(mk);
          pos = idx + q.length;
        }
        frag.appendChild(document.createTextNode(text.slice(pos)));
        node.replaceWith(frag);
      });
      $("hits").textContent = marks.length ? "" : "无结果";
      next();
    }
    function next() {
      if (!marks.length) return;
      if (cur >= 0) marks[cur].classList.remove("current");
      cur = (cur + 1) % marks.length;
      const mk = marks[cur];
      for (let p = mk.parentElement; p; p = p.parentElement) {
        if (p.tagName === "DETAILS") { p.open = true; p.classList.remove("hidden"); }
        if (p.classList && (p.classList.contains("step") || p.classList.contains("event"))) p.classList.remove("hidden");
        if (p.classList && p.classList.contains("long")) p.classList.add("open");
      }
      mk.classList.add("current");
      mk.scrollIntoView({ block: "center" });
      $("hits").textContent = `${cur + 1}/${marks.length}`;
    }
    let timer;
    $("search").addEventListener("input", (e) => {
      e.target.parentElement.classList.toggle("has", !!e.target.value);
      clearTimeout(timer);
      timer = setTimeout(() => search(e.target.value.trim()), 200);
    });
    $("search").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); next(); } });
    document.addEventListener("keydown", (e) => { if ((e.metaKey || e.ctrlKey) && e.key === "f") { e.preventDefault(); $("search").focus(); $("search").select(); } });

    // 从全局搜索跳进来时带 ?q=关键词，打开就定位到第一个命中
    const q0 = new URLSearchParams(location.search).get("q");
    if (q0) { $("search").value = q0; $("search").parentElement.classList.add("has"); search(q0); }
  }

  // 回归测试（tests/timeline_test.js）在 node 里加载本文件，取时间轴的规则
  if (typeof module !== "undefined") { module.exports = { commitMessage, summaryLine, keyPoints, versionKey }; return; }
  if (window.SESSION) start(window.SESSION);
  else fetch("session.json" + location.search).then((r) => r.json()).then(start);
})();
