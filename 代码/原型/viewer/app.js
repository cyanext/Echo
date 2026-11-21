// 会话浏览原型：读取 data.js 里的 window.SESSION 渲染对话。
// 正式应用的对话栏用 WKWebView 加载这套页面，数据由 Swift 注入。
(function () {
  const S = window.SESSION;
  const $ = (id) => document.getElementById(id);

  function esc(s) {
    return String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  }

  function fmtTime(ts) {
    if (!ts) return "";
    const d = new Date(ts);
    const p = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  // 简易 Markdown：代码块、标题、表格、引用、列表、段落，行内代码、加粗、链接
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
    while (i < lines.length) {
      const line = lines[i];
      if (/^```/.test(line)) {
        const buf = [];
        i++;
        while (i < lines.length && !/^```/.test(lines[i])) buf.push(lines[i++]);
        i++;
        out.push(`<pre><code>${esc(buf.join("\n"))}</code></pre>`);
        continue;
      }
      if (/^\s*\|/.test(line)) {
        const rows = [];
        while (i < lines.length && /^\s*\|/.test(lines[i])) rows.push(lines[i++]);
        const cells = (r) => r.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
        const body = rows.filter((r) => !/^\s*\|[\s:|-]+\|\s*$/.test(r));
        const html = body.map((r, n) => {
          const tag = n === 0 ? "th" : "td";
          return "<tr>" + cells(r).map((c) => `<${tag}>${inline(c)}</${tag}>`).join("") + "</tr>";
        });
        out.push(`<table>${html.join("")}</table>`);
        continue;
      }
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
      while (i < lines.length && lines[i].trim() && !/^(```|\s*\||#{1,4}\s|>|\s*([-*]|\d+\.)\s)/.test(lines[i])) {
        buf.push(inline(lines[i++]));
      }
      out.push(`<p>${buf.join("<br>")}</p>`);
    }
    return `<div class="md">${out.join("")}</div>`;
  }

  // 工具调用的一行摘要：优先取说明，其次命令、文件路径
  function toolSummary(b) {
    const x = b.input || {};
    const s = x.description || x.command || x.file_path || x.skill || x.pattern || x.url || x.query || x.prompt || "";
    return String(s).split("\n")[0].slice(0, 160);
  }

  function renderBlock(b) {
    if (b.kind === "text") return md(b.text);
    if (b.kind === "thinking") {
      return `<details class="block thinking"><summary>思考过程</summary><div class="inner">${esc(b.text)}</div></details>`;
    }
    const input = JSON.stringify(b.input, null, 2);
    const result = b.result == null ? "（没有返回）" : b.result;
    return `<details class="block tool${b.isError ? " error" : ""}">
      <summary><span class="tool-name">${esc(b.name)}</span>　${esc(toolSummary(b))}</summary>
      <div class="inner"><div class="label">输入</div><pre>${esc(input)}</pre>
      <div class="label">输出${b.isError ? "（出错）" : ""}</div><pre>${esc(result)}</pre></div></details>`;
  }

  // 连续的几条回复只在第一条显示时间
  function renderTurn(t, i, all) {
    const prev = all[i - 1];
    const sameRun = t.role === "assistant" && prev && prev.role === "assistant";
    const time = sameRun ? "" : `<div class="time">${fmtTime(t.ts)}</div>`;
    if (t.role === "user") return `<section class="turn user">${time}<div class="body">${esc(t.text)}</div></section>`;
    if (t.role === "assistant") {
      return `<section class="turn assistant">${time}<div class="body">${t.blocks.map(renderBlock).join("")}</div></section>`;
    }
    if (t.role === "command") return `<section class="turn command"><div class="body">命令 <code>${esc(t.text)}</code></div></section>`;
    if (t.role === "summary") {
      return `<section class="turn summary"><details><summary>会话在这里压缩过，点开看压缩摘要</summary><div class="md">${md(t.text)}</div></details></section>`;
    }
    return `<section class="turn system"><div class="body">${esc(t.text.slice(0, 300))}</div></section>`;
  }

  // 头部
  const m = S.meta;
  $("title").textContent = m.title;
  $("meta").innerHTML = [m.cwd, `${fmtTime(m.start)} 至 ${fmtTime(m.end)}`, `电脑 ${m.computer}`, m.gitBranch && m.gitBranch !== "HEAD" ? `分支 ${m.gitBranch}` : "", m.id]
    .filter(Boolean).map((x) => `<span>${esc(x)}</span>`).join("");
  $("turns").innerHTML = S.turns.map(renderTurn).join("");

  // 显示开关
  function applyToggles() {
    document.querySelectorAll("details.thinking").forEach((e) => e.classList.toggle("hidden", !$("show-thinking").checked));
    document.querySelectorAll("details.tool").forEach((e) => e.classList.toggle("hidden", !$("show-tools").checked));
    document.querySelectorAll(".turn.system").forEach((e) => e.classList.toggle("hidden", !$("show-system").checked));
  }
  ["show-thinking", "show-tools", "show-system"].forEach((id) => $(id).addEventListener("change", applyToggles));
  applyToggles();

  let expanded = false;
  $("expand-all").addEventListener("click", () => {
    expanded = !expanded;
    document.querySelectorAll("main details").forEach((d) => (d.open = expanded));
    $("expand-all").textContent = expanded ? "全部折叠" : "全部展开";
  });

  function toast(msg) {
    const el = $("toast");
    el.textContent = msg;
    el.classList.add("show");
    setTimeout(() => el.classList.remove("show"), 1600);
  }

  $("copy-resume").addEventListener("click", () => {
    const cmd = `cd '${m.cwd.replace(/'/g, "'\\''")}' && claude --resume ${m.id}`;
    navigator.clipboard.writeText(cmd).then(() => toast("已复制：" + cmd), () => prompt("复制下面的命令", cmd));
  });

  // 会话内搜索：高亮所有命中，回车跳到下一个，命中在折叠块里时自动展开
  let marks = [];
  let cur = -1;
  function clearMarks() {
    document.querySelectorAll("main mark").forEach((mk) => mk.replaceWith(document.createTextNode(mk.textContent)));
    $("turns").normalize();
    marks = [];
    cur = -1;
  }
  function search(q) {
    clearMarks();
    if (!q) { $("hits").textContent = ""; return; }
    const lower = q.toLowerCase();
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
    $("hits").textContent = marks.length ? `${marks.length} 处` : "没有结果";
    next();
  }
  function next() {
    if (!marks.length) return;
    if (cur >= 0) marks[cur].classList.remove("current");
    cur = (cur + 1) % marks.length;
    const mk = marks[cur];
    for (let p = mk.parentElement; p; p = p.parentElement) {
      if (p.tagName === "DETAILS") { p.open = true; p.classList.remove("hidden"); }
      if (p.classList && p.classList.contains("turn")) p.classList.remove("hidden");
    }
    mk.classList.add("current");
    mk.scrollIntoView({ block: "center" });
    $("hits").textContent = `${cur + 1} / ${marks.length}`;
  }
  let timer;
  $("search").addEventListener("input", (e) => { clearTimeout(timer); timer = setTimeout(() => search(e.target.value.trim()), 200); });
  $("search").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); next(); } });

  // 从全局搜索跳进来时带 ?q=关键词，打开就定位到第一个命中
  const q0 = new URLSearchParams(location.search).get("q");
  if (q0) { $("search").value = q0; search(q0); }
})();
