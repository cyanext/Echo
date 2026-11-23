// 对话正文。数据格式见 EchoExport.swift（规则以 代码/原型/export.py 为准）。
// 应用里数据来自 echo://app/session.json（EchoWeb.swift 的 EchoScheme），复制恢复命令交给 Swift 写剪贴板；
// 设计稿 设计/浏览窗口/ 先放好 window.SESSION 再引用本文件。
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
    msgs: '<svg viewBox="0 0 24 24"><path d="M4.5 16V6.5A2 2 0 0 1 6.5 4.5h8A2 2 0 0 1 16.5 6.5v5a2 2 0 0 1-2 2H8z"/><path d="M19.5 9.5v10l-3-2.5h-6.5a2 2 0 0 1-2-2"/></svg>',
  };

  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  // 备份里清理掉的内容（占位「[已清理：类别，原 大小]」，旧版的「[图片已移除]」）显示成灰色小标签。用在转义之后的 HTML 上
  const CLEANED = /\[已清理：([^，\]]+)，原 ([^\]]+)\]|\[(图片|文件)已移除\]/g;
  const chips = (html) => html.replace(CLEANED, (_, kind, size, old) => `<span class="cleaned">${kind || old}已清理${size ? " · " + size : ""}</span>`);
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
    return `<div class="md">${chips(out.join(""))}</div>`;
  }

  // 工具调用的一行说明：优先取说明，其次命令、文件路径
  function toolSummary(b) {
    const x = b.input || {};
    const s = x.description || x.command || x.file_path || x.skill || x.pattern || x.url || x.query || x.prompt || "";
    return String(s).split("\n")[0].slice(0, 200);
  }

  // 思考和工具的内容可能很长，先只记下来，点开（或查找命中）时才生成，几千条的会话也不卡
  const STEPS = [];
  function stepInput(b) {
    const x = b.input || {};
    if (typeof x["已清理"] === "string") return `[已清理：${x["已清理"]}]`;
    return x.command ? x.command : JSON.stringify(x, null, 2);
  }
  function stepText(b) { return b.kind === "thinking" ? b.text : stepInput(b) + "\n" + (b.result == null ? "" : b.result); }
  function stepBody(b) {
    if (b.kind === "thinking") return esc(b.text);
    const result = b.result == null ? "（没有返回）" : b.result;
    return `<div class="label">输入</div><pre>${chips(esc(stepInput(b)))}</pre><div class="label">${b.isError ? "输出（出错）" : "输出"}</div><pre>${chips(esc(result))}</pre>`;
  }
  function fillStep(det) {
    const io = det.querySelector(":scope > .io");
    if (io && !io.dataset.done) { io.innerHTML = stepBody(STEPS[det.dataset.i]); io.dataset.done = "1"; }
  }
  function renderStep(b) {
    const i = STEPS.push(b) - 1;
    const kid = b._kid ? ` id="${b._kid}"` : "";
    if (b.kind === "thinking" && b.cleaned) {
      return `<li class="step thinking"><div class="static"><span class="name">思考过程</span><span class="cleaned">已清理 · ${esc(b.cleaned)}</span></div></li>`;
    }
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
    // 出错只在点开后那一步标红，收起的这一行不写（外部不用显示出错）
    return `<details class="steps"><summary>${ICON.chev}<span class="sum">${head}${names ? "：" + esc(names) : ""}</span></summary>
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
  // 认说明开头的「模块 v版本号」，开头可以先有一个「方案：」这类短前缀（前缀不能是版本号本身，「0.3.0：…」直接认 0.3.0）；三段的 0.1.0 带不带 v 都行，两段的必须写成 v0.1。
  // 版本号在句子中间时：三段的照样认（没有模块），两段的不认，免得把「3.5」这类数字当版本
  const HEAD_VER = /^\s*(?:(?!v?\d)[^\s:：]{1,6}[:：]\s*)?([\p{L}\p{N}_ -]{0,12}?)\s*(?:v?(\d+\.\d+\.\d+)|v(\d+\.\d+))(?![\d.])/iu;
  function versionKey(label) {
    const head = label.match(HEAD_VER);
    if (head) return (head[1].replace(/[\s_-]*v?$/i, "").trim() + " " + (head[2] || head[3])).trim();
    const any = label.match(/(\d+\.\d+\.\d+)/);
    return any ? any[1] : null;
  }

  // 要点栏的要点（方案 需求文档/版本需求/v0.3.0-浏览窗口改版.html）：标四类
  // 1. 手动压缩：阶段总结的 trigger 是 manual；自动压缩不标
  // 2. 版本提交：同一个「模块 + 版本号」只标最后一次；会话里一次版本提交都没有时，每次提交都标
  // 3. 合集里每个会话的开头
  // 4. 回顾（Claude 的 recap）：隔 2 小时以上算新的一段，每段留最后一条；手动压缩前 1 小时内有回顾时，压缩那一行用回顾的话，这条回顾不再单列
  const RECAP_GAP = 2 * 3600e3, RECAP_NEAR = 3600e3;
  // 回顾的第一句：到第一个句号或分号为止
  const firstSentence = (s) => { const m = s.replace(/\s+/g, " ").trim().match(/^.+?[。；;!！?？]/); return (m ? m[0] : s).replace(/[。；;]$/, "").slice(0, 80); };
  function keyPoints(turns) {
    const found = [];
    let lastAsk = "", lastShort = "", lastRecap = null;
    const used = new Set();
    turns.forEach((t, i) => {
      if (t.role === "recap") { lastRecap = { t, i }; return; }
      // 手动压缩的说明：压缩前最后一条 10 个字以上的消息（「做吧」这类短确认往前找，跳过 / 命令）
      if (t.role === "user" && !/^\//.test(t.text.trim())) {
        const x = t.text.replace(/\s+/g, " ").trim();
        if (x.length >= 10) lastAsk = x;
        else if (!lastAsk) lastShort = x;
      } else if (t.role === "summary" && t.trigger === "manual") {
        const r = lastRecap && t.ts && lastRecap.t.ts && new Date(t.ts) - new Date(lastRecap.t.ts) <= RECAP_NEAR ? lastRecap : null;
        if (r) used.add(r.i);
        found.push({ obj: t, turn: i, kind: "compact", ts: t.ts, label: "手动压缩", sub: r ? firstSentence(r.t.text) : lastAsk || lastShort || summaryLine(t.text), full: r ? r.t.text : "" });
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
    // 回顾按 2 小时分段，每段留最后一条（已经用在压缩那一行的不再单列），按位置插回去
    const recaps = turns.map((t, i) => (t.role === "recap" ? { t, i } : null)).filter(Boolean);
    recaps.forEach((r, n) => {
      const next = recaps[n + 1];
      const lastOfRun = !next || !r.t.ts || !next.t.ts || new Date(next.t.ts) - new Date(r.t.ts) > RECAP_GAP;
      if (lastOfRun && !used.has(r.i)) found.push({ obj: r.t, turn: r.i, kind: "recap", ts: r.t.ts, label: firstSentence(r.t.text), full: r.t.text });
    });
    found.sort((a, b) => a.turn - b.turn);
    // 同一个版本标在它最后一次提交的位置：提交是这一版的终点。版本之后没带版本号的提交（「方案：按反馈改…」、小修）
    // 并进这个版本，位置延到下一个版本之前的最后一次提交；说明取这一版第一次提交那句
    const anyVer = found.some((k) => k.ver);
    const last = new Map(), first = new Map();
    let curVer = null;
    found.forEach((k, i) => {
      if (k.kind !== "commit") return;
      if (k.ver) { curVer = k.ver; if (!first.has(k.ver)) first.set(k.ver, k.label); }
      if (curVer) last.set(curVer, i);
    });
    const at = new Map([...last].map(([v, i]) => [i, v]));
    const keys = found.filter((k, i) => k.kind !== "commit" || !anyVer || at.has(i));
    keys.forEach((k) => { if (k.kind === "commit" && anyVer) { k.ver = at.get(found.indexOf(k)); k.label = first.get(k.ver); } });
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
    // 文字块前放一个空的时间标记（不占位置），左栏搜索结果进来时按时间找到这一条
    blocks.forEach((b) => { if (b.kind === "text") { flush(); out.push(tsMark(b._ts) + md(b.text)); } else run.push(b); });
    flush();
    return `<div class="msg ai">${out.join("")}</div>`;
  }

  const tsMark = (ts) => (ts ? `<i class="ts" data-ts="${esc(ts)}"></i>` : "");

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
        t.blocks.forEach((b) => { b._ts = t.ts; });
        let blocks = t.blocks.slice();
        while (turns[i + 1] && turns[i + 1].role === "assistant") {
          const n = turns[++i];
          n.blocks.forEach((b) => { b._ts = n.ts; });
          blocks = blocks.concat(n.blocks); partOf[i] = out.length;
        }
        out.push(renderAI(blocks));
      } else if (t.role === "user") {
        const long = t.text.length > 1200 || t.text.split("\n").length > 16;
        out.push(tsMark(t.ts) + `<div class="msg user${long ? " long" : ""}"${t._uid ? ` id="${t._uid}"` : ""}><div class="bubble">${esc(t.text)}</div>${long ? '<button class="more" type="button">展开全部</button>' : ""}<div class="stamp">${d ? hm(d) : ""}</div></div>`);
      } else if (t.role === "session") {
        // 合集里每个会话的开头
        out.push(`<div class="divider part" id="${t._kid}"><span><b>${esc(t.text)}</b>${t.computer ? "　" + esc(t.computer) : ""}</span></div>`);
      } else if (t.role === "command") {
        out.push(`<div class="event">${ICON.cmd}<code>${esc(t.text)}</code></div>`);
      } else if (t.role === "recap") {
        // 回顾：Claude 在你离开一阵后写的阶段小结，淡色小卡片，留在原来的位置
        out.push(tsMark(t.ts) + `<div class="recap"${t._kid ? ` id="${t._kid}"` : ""}><span class="recap-tag">回顾</span><span class="recap-text">${esc(t.text)}</span><span class="recap-time">${d ? hm(d) : ""}</span></div>`);
      } else if (t.role === "summary") {
        out.push(tsMark(t.ts) + `<details class="compact"${t._kid ? ` id="${t._kid}"` : ""}><summary><div class="divider"><span>会话在这里压缩过，点开看摘要</span></div></summary>${md(t.text)}</details>`);
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
    const meta = [span, m.kind === "collection" ? `合并查看 ${m.count} 个会话` : "", m.computer, m.gitBranch && m.gitBranch !== "HEAD" ? m.gitBranch : "", `${asks} 次提问`].filter(Boolean);

    root.innerHTML = `
      <header class="c-head"><div class="c-head-in">
        <div class="c-tt"><h1 id="h-title">${esc(m.title)}</h1><div class="c-meta" id="h-meta" data-tip="${esc(m.cwd + "\n" + m.id)}">${m.kind === "collection" ? "" : `<img class="c-app" src="app-${m.app || "claude"}.svg" alt="">`}${meta.map((x) => `<span>${esc(x)}</span>`).join("")}</div></div>
        <div class="c-actions">
          <label class="c-find" data-tip="查找（⌘F）">${ICON.find}<input id="search" type="search" placeholder="查找" autocomplete="off"><span class="hits" id="hits"></span></label>
          <div class="c-menu-wrap">
            <button class="c-btn icon" id="view-btn" type="button" data-tip="显示">${ICON.view}</button>
            <div class="c-menu" id="view-menu" hidden>
              <label><input type="checkbox" id="show-thinking" checked>思考过程</label>
              <label><input type="checkbox" id="show-tools" checked>工具调用</label>
              <label><input type="checkbox" id="show-system">系统消息</label>
              <hr><button type="button" id="expand-all">全部展开</button>
            </div>
          </div>
          <button class="c-btn icon${m.kind === "collection" ? " hidden" : ""}" id="copy-resume" type="button" data-tip="复制恢复命令">${ICON.copy}</button>
          <button class="c-btn hidden" id="utoggle" type="button" data-tip="展开我的消息（⌘⇧F）">${ICON.msgs}<span class="lbl">我的消息</span></button>
        </div>
      </div></header>
      <div class="c-body"><nav class="c-rail left" id="rail"></nav><main class="c-main" id="turns"></main><nav class="c-rail right" id="urail"></nav></div>
      <div class="toast" id="toast"></div>`;

    const $ = (id) => document.getElementById(id);
    const all = (sel) => root.querySelectorAll(sel);

    // 先画前 80 段，滚到底再接着画
    const keys = keyPoints(S.turns);
    const myMsgs = [];   // 你的消息，右边我的消息栏用
    S.turns.forEach((t, i) => { if (t.role === "user") { t._uid = "u" + i; myMsgs.push({ id: t._uid, turn: i, text: t.text, ts: t.ts }); } });
    const partOf = [];
    const parts = render(S.turns, partOf);
    let drawn = 0;
    const sentinel = document.createElement("div");
    function draw(n) {
      if (drawn >= parts.length) return;
      const end = Math.min(parts.length, drawn + n);
      sentinel.remove();
      // 每段前放一个锚点 p<段号>：要点栏点一条时跳到这一段的开头
      $("turns").insertAdjacentHTML("beforeend", parts.slice(drawn, end).map((h, j) => `<i class="pa" id="p${drawn + j}"></i>${h}`).join(""));
      drawn = end;
      if (drawn < parts.length) $("turns").appendChild(sentinel);
      applyToggles();
    }
    const drawAll = () => draw(parts.length);
    new IntersectionObserver((es) => { if (es.some((e) => e.isIntersecting)) draw(80); }, { rootMargin: "1200px" }).observe(sentinel);
    // 要点栏（左，常驻）和我的消息（右，可收起），规范 需求文档/设计规范/设计规范.md「布局」「组件」。两栏共用 makeRail：
    // 栏名一行，下面一行一项；点了跳过去；滚动对话时当前那项变浅蓝，栏跟着把它滚到中间。
    // 窗口窄时要点栏只剩一列短横线，悬停浮出说明；我的消息收起时什么都不显示
    let LINE = 120;   // 标题栏下面那条线，判断读到哪用它；标题换行变高时跟着改（measureHead）
    const posOf = (id) => {
      const el = document.getElementById(id);
      return el ? (el.closest("details.steps:not([open])") || el).getBoundingClientRect().top : Infinity;   // 还没画出来的算在下面
    };
    // 量标题栏高度：写进 --head-h（窄模式的起点、跳转停的位置），读到哪的那条线放在标题栏下 48
    const measureHead = () => {
      const h = root.querySelector(".c-head").offsetHeight;
      root.style.setProperty("--head-h", h + "px");
      document.documentElement.style.setProperty("--head-h", h + "px");
      LINE = h + 48;
    };
    let pinned = null;   // 刚点过的那一栏和当时的滚动位置，页面没动时保持点中的那项
    // 两栏固定在窗口两边，正文栏用左右内边距让开：要点栏 240（窗口窄于 1000 时只剩 44 宽的横线）；
    // 我的消息展开 260，正文剩下不到 560 时浮在正文上，收起时什么都不显示
    const layout = () => {
      const W = document.documentElement.clientWidth, L = $("rail"), R = $("urail");
      let lw = 0, rw = 0;
      if (keys.length) { const slim = W < 1000; L.classList.toggle("slim", slim); lw = slim ? 44 : 240; }
      if (myMsgs.length) {
        const open = R.classList.contains("open"), dock = open && W - lw - 260 >= 560;
        R.classList.toggle("float", open && !dock);
        rw = dock ? 260 : 0;
      }
      root.style.paddingLeft = lw + "px";
      root.style.paddingRight = rw + "px";
    };
    // 跳转统一平滑滚动（点我的消息时正文是瞬间跳过去的）。离得超过两屏的先瞬移到目标前一屏再滚，长会话里不会滚很久；
    // 系统开了「减少动态效果」就直接跳
    const calm = window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches;
    const glide = (el, block) => {
      if (calm) return el.scrollIntoView({ block });
      const H = window.innerHeight, d = el.getBoundingClientRect().top - (block === "center" ? H / 2 : 0);
      if (Math.abs(d) > 2 * H) window.scrollBy(0, d - Math.sign(d) * H);
      el.scrollIntoView({ block, behavior: "smooth" });
    };
    // 画到第 part 段，滚到 id 那里（停在标题栏下），闪一下
    const goTo = (part, id) => {
      if (part >= drawn) draw(part - drawn + 1);
      const el = document.getElementById(id);
      if (!el) return;
      const g = el.closest("details.steps");
      if (g) g.open = true;
      glide(el, "start");
      // 段的锚点闪它后面那一条；跳过不显示的时间标记 .ts
      let fl = el.classList.contains("pa") ? el.nextElementSibling : el;
      while (fl && fl.classList.contains("ts")) fl = fl.nextElementSibling;
      if (fl) { fl.classList.remove("flash"); void fl.offsetWidth; fl.classList.add("flash"); }
    };

    function makeRail(nav, items, o) {
      let html = "", lastGroup;
      items.forEach((it) => {
        if (it.group !== lastGroup) { html += `<div class="r-group">${it.group && o.groupIcon ? o.groupIcon : ""}${esc(it.group || "")}</div>`; lastGroup = it.group; }
        html += `<div class="k-row ${it.cls}" role="button" data-k="${it.id}"><i></i>${it.icon ? `<span class="ic">${it.icon}</span>` : ""}<div class="note">${it.row}</div></div>`;
      });
      nav.innerHTML = `${o.head}<div class="r-scroll"><div class="r-list">${html}</div></div><div class="tip"></div>`;
      const scroller = nav.querySelector(".r-scroll"), tip = nav.querySelector(".tip");
      // 在栏里滚动只滚栏，不带着正文滚：栏滚到头就停；栏名、搜索框这些不能滚的地方滚轮不起作用
      if (!nav.dataset.trap) {
        nav.dataset.trap = "1";
        nav.addEventListener("wheel", (e) => {
          const sc = e.target.closest(".r-scroll");
          if (!sc) { e.preventDefault(); return; }
          const up = e.deltaY < 0;
          if ((up && sc.scrollTop <= 0) || (!up && sc.scrollTop + sc.clientHeight >= sc.scrollHeight - 1)) e.preventDefault();
        }, { passive: false });
      }
      const rows = [...nav.querySelectorAll(".k-row")];
      const byId = Object.fromEntries(items.map((it) => [it.id, it]));
      // 悬停浮出全文：要点栏的一行会截断，鼠标移上去在栏右边浮出这一条的全文；我的消息栏的气泡已经写全，不浮
      const hasTip = () => nav.classList.contains("left");
      let over = false, current;
      // 当前那项变浅蓝；它不在栏中间 60% 的范围里时滚到中间；鼠标在栏上时不滚，免得和用户自己滚冲突
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
        o.jump(byId[t.dataset.k]);   // 栏名、搜索框不带 data-k，不会走到这里
        mark(t.dataset.k);
        pinned = { rail: nav, y: window.scrollY };
        spot();
      });
      nav.addEventListener("mouseover", (e) => {
        const t = e.target.closest(".k-row");
        if (!t || !hasTip()) { tip.classList.remove("show"); return; }
        const it = byId[t.dataset.k];
        const d = it.ts ? new Date(it.ts) : null;
        tip.innerHTML = `<div class="tip-label">${it.tip}</div><div class="tip-time">${d ? md0(d) + " " + hm(d) : ""}</div>`;
        tip.style.top = t.offsetTop - scroller.scrollTop + scroller.offsetTop + t.offsetHeight / 2 + "px";
        tip.style.left = nav.offsetWidth + 4 + "px";   // 贴着栏的右边
        tip.classList.add("show");
      });
      return { nav, mark, cur: o.cur, rows, byId };
    }

    const rails = [];

    // 要点栏：版本、手动压缩、合集里的会话开头。一个要点是它前面那一段的终点（提交「0.1.0」之前的对话都属于 0.1.0），
    // 所以读到哪，就看前面遇到的下一个要点；合集里的会话开头相反，是后面那一段的起点
    if (keys.length) {
      root.classList.add("has-rail");
      const verOf = (k) => (k.ver || "").split(" ").pop();
      // 分组名：版本提交是模块名；没有版本号的提交是冒号前的短前缀（「方案：…」的「方案」），写一次在上面，每行不再重复
      const PREFIX = /^([^\s:：]{1,6})[:：]\s*/;
      const moduleOf = (k) => {
        if (k.kind !== "commit") return "";
        if (k.ver) return k.ver.split(" ").slice(0, -1).join(" ");
        const p = k.label.match(PREFIX);
        return p ? p[1] : "";
      };
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
        if (k.kind === "recap") return `<span class="n-tag">回顾</span><span class="n-text">${esc(k.label)}</span>`;
        if (k.kind === "part") return `<span class="n-text"><b>${esc(k.label)}</b></span>`;
        if (!k.ver) return `<span class="n-text">${esc(k.label.replace(PREFIX, ""))}</span>`;
        return `<span class="n-ver">${esc(verOf(k))}</span><span class="n-text">${esc(brief(k))}</span>`;
      };
      const full = (k) => (k.kind === "compact" ? `手动压缩：${esc(k.full || k.sub || "")}` : k.kind === "recap" ? `回顾：${esc(k.full)}` : k.kind === "part" ? esc(k.label) : esc(k.label).replace(/(v\d+\.\d+(?:\.\d+)?|\d+\.\d+\.\d+)/i, '<b class="ver">$1</b>'));

      // 标题跟着当前段换：标题写这一段的要点，小字写会话标题和时间；后面没有要点时恢复会话标题
      const homeTitle = $("h-title").innerHTML, homeMeta = $("h-meta").innerHTML;
      const setHead = (k) => {
        const d = k && k.ts ? new Date(k.ts) : null;
        // 回顾、手动压缩是一整句话：照要点栏的样子写主色小字标签加常规字重的正文，不用标题的粗体；版本、分段照旧当标题
        const note = k && (k.kind === "recap" || k.kind === "compact");
        $("h-title").innerHTML = !k ? homeTitle : note ? `<span class="h-tag">${k.kind === "recap" ? "回顾" : "手动压缩"}</span>${esc(k.kind === "recap" ? k.full : k.full || k.sub || "")}` : full(k);
        $("h-title").classList.toggle("note", !!note);
        $("h-meta").innerHTML = k ? `<span>${esc(m.title)}</span>${d ? `<span>${md0(d)} ${hm(d)}</span>` : ""}` : homeMeta;
        ["h-title", "h-meta"].forEach((x) => { $(x).classList.remove("swap"); void $(x).offsetWidth; $(x).classList.add("swap"); });
        measureHead();
      };

      rails.push(makeRail($("rail"), keys.map((k) => ({
        id: k.id, ts: k.ts, cls: "t-" + k.kind, group: moduleOf(k), row: noteText(k), tip: full(k),
      })), {
        head: "",
        onChange: (it) => setHead(it && keys.find((k) => k.id === it.id)),
        // 点一项跳到这一段的开头：上一个要点之后；会话开头就跳到它自己
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

    // 我的消息（右，可收起）：顶上搜索框，按天列你的消息，一条一个气泡、内容写全；打字只留下命中的。
    // 消息是一段对话的起点，读到哪就看读过的最后一条；展开收起记在本机，下次照旧
    if (myMsgs.length) {
      root.classList.add("has-urail");
      const dayOf = (ts) => (ts ? day(new Date(ts)) : "");
      const oneLine = (x) => x.replace(/\s+/g, " ").trim();
      // 气泡里写全文；超过 1000 字的截断并写总字数，免得一条占满整栏；搜索命中的字高亮
      const CAP = 1000;
      const msgText = (t, q) => {
        let h = esc(t.length > CAP ? t.slice(0, CAP) : t);
        if (q) h = h.replace(new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/[&<>"]/g, (c) => esc(c)), "gi"), (x) => `<mark>${x}</mark>`);
        return h + (t.length > CAP ? `<span class="n-more">…共 ${t.length} 字</span>` : "");
      };
      const r = makeRail($("urail"), myMsgs.map((a) => ({
        id: a.id, ts: a.ts, cls: "t-ask" + (a.text.trim().length <= 6 ? " short" : ""), group: dayOf(a.ts),   // 「发布」「继续」这种短确认淡一些
        row: `<span class="n-text">${msgText(a.text.trim(), "")}</span><span class="n-time">${a.ts ? hm(new Date(a.ts)) : ""}</span>`,
        tip: esc(oneLine(a.text).slice(0, 200)),
      })), {
        head: `<div class="r-hd">我的消息<span class="c">${myMsgs.length}</span><button class="c-btn icon" id="uclose" type="button" data-tip="收起">${ICON.close}</button></div>
          <label class="r-findw">${ICON.find}<input class="r-find" id="ufind" type="search" placeholder="搜我的消息" autocomplete="off"><span class="r-count" id="ucount"></span></label>`,
        jump: (it) => goTo(partOf[myMsgs.find((a) => a.id === it.id).turn], it.id),
        cur: () => {
          let cur = null;
          for (const a of myMsgs) { const y = posOf(a.id); if (y > LINE) break; cur = a.id; }
          return cur;
        },
      });
      rails.push(r);
      const nav = r.nav;
      $("utoggle").classList.remove("hidden");
      const setOpen = (open) => {
        nav.classList.toggle("open", open);
        $("utoggle").dataset.tip = open ? "收起我的消息" : "展开我的消息（⌘⇧F）";
        $("utoggle").classList.toggle("on", open);
        try { localStorage.setItem("echo.urail.open", open ? "1" : ""); } catch (e) {}
        layout();
        measureHead();
        if (open) setTimeout(() => $("ufind").focus(), 0);
      };
      let saved = "";
      try { saved = localStorage.getItem("echo.urail.open") || ""; } catch (e) {}
      nav.classList.toggle("open", saved === "1");
      $("utoggle").classList.toggle("on", saved === "1");
      $("utoggle").addEventListener("click", (e) => { e.stopPropagation(); setOpen(!nav.classList.contains("open")); });
      $("uclose").addEventListener("click", () => setOpen(false));
      document.addEventListener("keydown", (e) => { if (e.metaKey && e.shiftKey && (e.key === "f" || e.key === "F")) { e.preventDefault(); setOpen(true); } });
      // 检索：只留下包含关键词的消息，命中的字高亮；没有命中的日期组一起藏起来
      const texts = Object.fromEntries(myMsgs.map((a) => [a.id, a.text.trim()]));
      $("ufind").addEventListener("input", (e) => {
        const raw = e.target.value.trim(), q = raw.toLowerCase();
        let n = 0;
        r.rows.forEach((row) => {
          const t = texts[row.dataset.k], hit = !q || t.toLowerCase().includes(q);
          row.classList.toggle("miss", !hit);
          if (hit && q) n++;
          row.querySelector(".n-text").innerHTML = msgText(t, hit ? raw : "");
        });
        nav.querySelectorAll(".r-group").forEach((g) => {
          let x = g.nextElementSibling, any = false;
          while (x && !x.classList.contains("r-group")) { if (!x.classList.contains("miss")) any = true; x = x.nextElementSibling; }
          g.classList.toggle("miss", !any);
        });
        $("ucount").textContent = q ? `${n} 条` : "";
        let none = nav.querySelector(".r-none");   // 一条都没搜到：缺省页
        if (!none) { none = document.createElement("div"); none.className = "r-none"; none.innerHTML = Blank.html("search", "没有找到", "换个词再搜", true); nav.querySelector(".r-scroll").appendChild(none); }
        none.hidden = !(q && n === 0);
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
      const cmd = `cd '${m.cwd.replace(/'/g, "'\\''")}' && ${m.app === "codex" ? "codex resume" : "claude --resume"} ${m.id}`;
      if (window.webkit && window.webkit.messageHandlers.echo) window.webkit.messageHandlers.echo.postMessage({ copy: cmd });
      else if (navigator.clipboard) navigator.clipboard.writeText(cmd);
      toast("已复制恢复命令");
    });

    // 会话内查找：只找对话（见 search 里的 SAID），高亮所有命中，回车跳到下一个，命中在折叠的阶段总结里时自动展开
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
      // 只在对话里找：你的消息、AI 回复的正文、回顾、阶段总结；思考过程、工具调用、系统消息不找
      const SAID = ".msg.user .bubble, .msg.ai > .md, .recap-text, details.compact > .md";
      const walker = document.createTreeWalker($("turns"), NodeFilter.SHOW_TEXT, {
        acceptNode: (n) => (n.parentElement && n.parentElement.closest(SAID) && !n.parentElement.closest(".step, summary") ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT),
      });
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
      glide(mk, "center");
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

    // 从总览点版本或提交进来时带 ?at=毫秒、&v=版本号：先找这个版本的要点（版本要点标在这一版最后一次提交的位置，
    // 往往比打版本号那次提交晚，只按时间找会停到别的版本上）；没带版本号或没找到，跳到离那个时间最近的提交要点（15 分钟内），再没有就跳到那时候正在进行的那一段
    window.echoJump = (at, ver) => {
      const mine = ver && keys.find((k) => k.kind === "commit" && k.ver && (k.ver === ver || k.ver.endsWith(" " + ver)));
      if (mine) return goTo(partOf[mine.turn], mine.id);
      const near = keys.filter((k) => k.kind === "commit" && k.ts).map((k) => [Math.abs(new Date(k.ts) - at), k]).sort((a, b) => a[0] - b[0])[0];
      if (near && near[0] < 15 * 60e3) return goTo(partOf[near[1].turn], near[1].id);
      let i = -1;
      S.turns.forEach((t, j) => { if (t.ts && new Date(t.ts) <= at) i = j; });
      if (i >= 0) goTo(partOf[i], "p" + partOf[i]);
    };

    // 从左栏搜索结果进来：查找关键词，停在 at（命中那一条的时间）那条消息里的第一个命中。
    // 左栏只搜对话，工具调用和思考过程里的命中跳过；找不到时退到那一段之后的第一个
    window.echoFind = (q, at) => {
      $("search").value = q;
      $("search").parentElement.classList.toggle("has", !!q);
      search(q);
      if (!at || !marks.length) return;
      const after = (a) => (mk) => a.compareDocumentPosition(mk) & Node.DOCUMENT_POSITION_FOLLOWING;
      const said = (mk) => !mk.closest(".step");
      const tm = [...all("#turns i.ts")].find((x) => Date.parse(x.dataset.ts) >= at - 2);
      let k = tm ? marks.findIndex((mk) => after(tm)(mk) && said(mk)) : -1;
      if (k < 0) {
        let i = -1;
        S.turns.forEach((t, j) => { if (t.ts && new Date(t.ts) <= at) i = j; });
        const a = i >= 0 && $("p" + partOf[i]);
        k = a ? marks.findIndex(after(a)) : -1;
      }
      if (k > 0) { marks[cur].classList.remove("current"); cur = k - 1; next(); }
    };

    const params = new URLSearchParams(location.search);
    const at0 = +params.get("at"), q0 = params.get("q"), v0 = params.get("v");
    if (q0) setTimeout(() => window.echoFind(q0, at0), 0);
    else if (at0) setTimeout(() => window.echoJump(at0, v0), 0);
  }

  // 回归测试（tests/timeline_test.js）在 node 里加载本文件，取时间轴的规则
  if (typeof module !== "undefined") { module.exports = { commitMessage, summaryLine, keyPoints, versionKey }; return; }
  if (window.SESSION) start(window.SESSION);
  else fetch("session.json" + location.search).then((r) => r.json()).then(start)
    .catch(() => { document.body.innerHTML = Blank.html("error", "这个会话读不出来", "备份文件可能正在写入或已损坏，稍后再打开试试"); });
})();
