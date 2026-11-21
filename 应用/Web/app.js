// 对话正文。数据格式见 EchoExport.swift（规则以 原型/export.py 为准）。
// 应用里数据来自 echo://app/session.json（EchoBrowser.swift 的 EchoScheme），复制恢复命令交给 Swift 写剪贴板；
// 设计稿 docs/设计稿/浏览窗口/ 先放好 window.SESSION 再引用本文件。
(function () {
  const root = document.getElementById("conv");

  const ICON = {
    find: '<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2"/></svg>',
    view: '<svg viewBox="0 0 24 24"><path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/></svg>',
    copy: '<svg viewBox="0 0 24 24"><rect x="8" y="8" width="12" height="12" rx="2.5"/><path d="M16 8V6.5A2.5 2.5 0 0 0 13.5 4h-7A2.5 2.5 0 0 0 4 6.5v7A2.5 2.5 0 0 0 6.5 16H8"/></svg>',
    chev: '<svg class="chev" viewBox="0 0 24 24"><path d="m9 6 6 6-6 6"/></svg>',
    cmd: '<svg viewBox="0 0 24 24"><path d="m5 8 4 4-4 4M12 17h7"/></svg>',
    sys: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/><path d="M12 11v5M12 8h.01"/></svg>',
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
    if (b.kind === "thinking") {
      return `<li class="step thinking"><details data-i="${i}"><summary><span class="name">思考过程</span></summary><div class="io"></div></details></li>`;
    }
    return `<li class="step tool${b.isError ? " error" : ""}"><details data-i="${i}"><summary><span class="name">${esc(b.name)}</span><span class="desc">${esc(toolSummary(b))}</span></summary><div class="io"></div></details></li>`;
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

  function renderAI(blocks) {
    const out = [];
    let run = [];
    const flush = () => { if (run.length) out.push(renderSteps(run)); run = []; };
    blocks.forEach((b) => { if (b.kind === "text") { flush(); out.push(md(b.text)); } else run.push(b); });
    flush();
    return `<div class="msg ai">${out.join("")}</div>`;
  }

  // 每段一个 HTML 片段：日期线、一条消息、一段回复
  function render(turns) {
    const out = [];
    let lastDay = "";
    for (let i = 0; i < turns.length; i++) {
      const t = turns[i];
      const d = t.ts ? new Date(t.ts) : null;
      if (d && dayKey(d) !== lastDay) {
        lastDay = dayKey(d);
        out.push(`<div class="divider"><span>${day(d)}</span></div>`);
      }
      if (t.role === "assistant") {
        // 连着的几条回复合成一段
        let blocks = t.blocks.slice();
        while (turns[i + 1] && turns[i + 1].role === "assistant") blocks = blocks.concat(turns[++i].blocks);
        out.push(renderAI(blocks));
      } else if (t.role === "user") {
        const long = t.text.length > 1200 || t.text.split("\n").length > 16;
        out.push(`<div class="msg user${long ? " long" : ""}"><div class="bubble">${esc(t.text)}</div>${long ? '<button class="more" type="button">展开全部</button>' : ""}<div class="stamp">${d ? hm(d) : ""}</div></div>`);
      } else if (t.role === "session") {
        // 合集里每个会话的开头
        out.push(`<div class="divider part"><span><b>${esc(t.text)}</b>${t.computer ? "　" + esc(t.computer) : ""}</span></div>`);
      } else if (t.role === "command") {
        out.push(`<div class="event">${ICON.cmd}<code>${esc(t.text)}</code></div>`);
      } else if (t.role === "summary") {
        out.push(`<details class="compact"><summary><div class="divider"><span>会话在这里压缩过，点开看摘要</span></div></summary>${md(t.text)}</details>`);
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
        <div class="c-titles"><h1>${esc(m.title)}</h1><div class="c-meta" title="${esc(m.cwd + "\n" + m.id)}">${meta.map((x) => `<span>${esc(x)}</span>`).join("")}</div></div>
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
        </div>
      </div></header>
      <main class="c-main" id="turns"></main>
      <div class="toast" id="toast"></div>`;

    const $ = (id) => document.getElementById(id);
    const all = (sel) => root.querySelectorAll(sel);

    // 先画前 80 段，滚到底再接着画
    const parts = render(S.turns);
    let drawn = 0;
    const sentinel = document.createElement("div");
    function draw(n) {
      if (drawn >= parts.length) return;
      const end = Math.min(parts.length, drawn + n);
      sentinel.remove();
      $("turns").insertAdjacentHTML("beforeend", parts.slice(drawn, end).join(""));
      drawn = end;
      if (drawn < parts.length) $("turns").appendChild(sentinel);
      applyToggles();
    }
    const drawAll = () => draw(parts.length);
    new IntersectionObserver((es) => { if (es.some((e) => e.isIntersecting)) draw(80); }, { rootMargin: "1200px" }).observe(sentinel);
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

  if (window.SESSION) start(window.SESSION);
  else fetch("session.json" + location.search).then((r) => r.json()).then(start);
})();
