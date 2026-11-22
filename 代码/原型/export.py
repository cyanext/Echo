#!/usr/bin/env python3
"""把一个会话 jsonl（Claude Code 或 Codex）整理成浏览界面用的数据，写成 data.js 供 viewer/index.html 读取。

用法：python3 export.py <会话.jsonl> <输出 data.js> [电脑名]
整理规则见 ../../需求文档/归档/方案.md「消息显示规则」。正式应用用 Swift 重写，行为以本脚本为准。
"""
import json
import os
import re
import socket
import sys

# 用户消息里由系统注入、不是人打的字，按前缀识别
SYSTEM_PREFIXES = (
    "<system-reminder>", "<command-name>", "<command-message>", "<local-command-stdout>",
    "<local-command-stderr>", "<task-notification>", "<user-prompt-submit-hook>",
    "[Image:", "Caveat:", "[Request interrupted",
)


# 备份里思考过程的占位（见 slim.py）
THINKING_CLEANED = re.compile(r"^\[已清理：思考过程，原 (.+)\]$")


def text_of(content):
    if isinstance(content, str):
        return content
    parts = []
    for b in content or []:
        if b.get("type") == "text":
            parts.append(b.get("text", ""))
    return "\n".join(parts)


def tool_result_text(block):
    c = block.get("content")
    if isinstance(c, str):
        return c
    out = []
    for b in c or []:
        if b.get("type") == "text":
            out.append(b.get("text", ""))
        elif b.get("type") == "image":
            out.append("[图片]")
    return "\n".join(out)


def command_label(text):
    m = re.search(r"<command-name>(.*?)</command-name>", text, re.S)
    args = re.search(r"<command-args>(.*?)</command-args>", text, re.S)
    if m:
        return (m.group(1).strip() + " " + (args.group(1).strip() if args else "")).strip()
    return None


def open_lines(path):
    """按行读；Codex 压过的旧会话（.jsonl.zst）用 zstd 命令边解压边读"""
    if path.endswith(".zst"):
        import io, subprocess
        proc = subprocess.Popen(["zstd", "-dcq", path], stdout=subprocess.PIPE)
        return io.TextIOWrapper(proc.stdout, encoding="utf-8", errors="surrogateescape", newline="")
    return open(path, encoding="utf-8", newline="")


def is_codex_file(path):
    with open_lines(path) as f:
        for line in f:
            try:
                return json.loads(line).get("type") == "session_meta"
            except (json.JSONDecodeError, AttributeError):
                return False
    return False


# ---------- Codex ----------
# 备份里清理掉的内容：「[已清理：工具参数，原 3.4 KB]」
CLEANED_TEXT = re.compile(r"^\[已清理：(.+)\]$")
# 用户消息里由 Codex 注入、不是人打的段落（老会话没有来源标记时按开头认）
CODEX_SYSTEM_PREFIXES = ("<", "# AGENTS.md", "Host notice:")
# 提到文件时 Codex 把文件清单拼在前面，「## My request:」（也见过 for Codex）后面才是人打的字；文件清单算系统注入
CODEX_REQUEST = re.compile(r"\n## My request[^\n]*:\n")


def codex_title(path, sid):
    """从会话文件往上找 session_index.jsonl（Codex 改名、起名都记在这里），取这个会话最后一次的名字"""
    d = os.path.dirname(os.path.abspath(path))
    for _ in range(5):
        f = os.path.join(d, "session_index.jsonl")
        if os.path.exists(f):
            name = ""
            for line in open(f, encoding="utf-8"):
                try:
                    o = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if o.get("id") == sid and o.get("thread_name"):
                    name = o["thread_name"]
            return name
        d = os.path.dirname(d)
    return ""


def codex_user_parts(p):
    """一条 user 消息拆成（人打的字，系统注入的段落）"""
    kinds = ((p.get("internal_chat_message_metadata_passthrough") or {}).get("content_item_kinds")) or []
    human, system = [], []
    for i, c in enumerate(p.get("content") or []):
        if not isinstance(c, dict) or c.get("type") != "input_text":
            continue
        text = c.get("text") or ""
        kind = kinds[i] if i < len(kinds) else None
        is_user = kind == "user.text" if kind else not text.lstrip().startswith(CODEX_SYSTEM_PREFIXES)
        m = CODEX_REQUEST.search(text) if is_user else None
        if m:
            system.append(text[:m.start()].strip())
            text = text[m.end():]
        (human if is_user else system).append(text.strip())
    return "\n".join(t for t in human if t), "\n\n".join(t for t in system if t)


def codex_input(v):
    """工具参数：JSON 字符串解开；清理掉的写成和 Claude 一样的 {已清理: …}"""
    if isinstance(v, str):
        m = CLEANED_TEXT.match(v)
        if m:
            return {"已清理": m.group(1)}
        try:
            o = json.loads(v)
            return o if isinstance(o, dict) else {"input": v}
        except json.JSONDecodeError:
            return {"input": v}
    return v if isinstance(v, dict) else {"input": v}


def codex_output(v):
    if isinstance(v, str):
        return v
    out = []
    for b in v or []:
        if isinstance(b, dict) and b.get("type") in ("input_text", "output_text"):
            out.append(b.get("text", ""))
        elif isinstance(b, dict) and b.get("type") == "input_image":
            out.append("[图片]")
    return "\n".join(out)


def export_codex(path, computer):
    meta = {"id": "", "title": "", "aiTitle": "", "cwd": "", "gitBranch": "", "start": "", "end": "", "computer": computer, "app": "codex"}
    turns, tools = [], {}
    cur = None   # 正在拼的这一轮回复：连着的思考、回复文字、工具调用合成一轮

    def reply(ts):
        nonlocal cur
        if cur is None:
            cur = {"role": "assistant", "ts": ts, "blocks": []}
            turns.append(cur)
        return cur

    with open_lines(path) as f:
        for line in f:
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            t, p, ts = d.get("type"), d.get("payload"), d.get("timestamp", "")
            if not isinstance(p, dict):
                continue
            if t == "session_meta":
                meta["id"] = meta["id"] or p.get("id", "")
                meta["cwd"] = meta["cwd"] or p.get("cwd", "")
                g = p.get("git")
                if isinstance(g, dict):
                    meta["gitBranch"] = meta["gitBranch"] or g.get("branch") or ""
                continue
            if t == "compacted":
                if (p.get("message") or "").strip():
                    turns.append({"role": "summary", "ts": ts, "text": p["message"].strip(), "trigger": "auto"})
                    cur = None
                continue
            if t != "response_item":
                continue
            pt = p.get("type")
            if pt == "message" and p.get("role") == "user":
                human, system = codex_user_parts(p)
                if system:
                    turns.append({"role": "system", "ts": ts, "text": system})
                if human:
                    turns.append({"role": "user", "ts": ts, "text": human})
                if human or system:
                    meta["start"] = meta["start"] or ts
                    meta["end"] = ts
                    cur = None
                continue
            if pt == "message" and p.get("role") == "assistant":
                texts = [c.get("text", "") for c in p.get("content") or [] if isinstance(c, dict) and c.get("type") == "output_text"]
                for x in texts:
                    if x.strip():
                        reply(ts)["blocks"].append({"kind": "text", "text": x})
                meta["end"] = ts or meta["end"]
            elif pt == "reasoning":
                enc = p.get("encrypted_content")
                m = CLEANED_TEXT.match(enc) if isinstance(enc, str) else None
                if m and m.group(1).startswith("思考过程，原 "):
                    reply(ts)["blocks"].append({"kind": "thinking", "text": "", "cleaned": m.group(1)[len("思考过程，原 "):]})
                else:
                    text = "\n\n".join(s.get("text", "") for s in p.get("summary") or [] if isinstance(s, dict))
                    if text.strip():
                        reply(ts)["blocks"].append({"kind": "thinking", "text": text})
            elif pt in ("function_call", "custom_tool_call", "web_search_call", "tool_search_call"):
                if pt == "function_call":
                    name, inp = p.get("name", ""), codex_input(p.get("arguments"))
                elif pt == "custom_tool_call":
                    name, inp = p.get("name", ""), codex_input(p.get("input"))
                else:
                    name, inp = pt[:-5], p.get("action") or {}
                tb = {"kind": "tool", "name": name, "input": inp, "result": None, "isError": False}
                if p.get("call_id"):
                    tools[p["call_id"]] = tb
                reply(ts)["blocks"].append(tb)
            elif pt in ("function_call_output", "custom_tool_call_output"):
                tb = tools.get(p.get("call_id"))
                if tb is not None:
                    tb["result"] = codex_output(p.get("output"))

    turns = [x for x in turns if x["role"] != "assistant" or x["blocks"]]
    meta["title"] = codex_title(path, meta["id"]) or next((x["text"][:40] for x in turns if x["role"] == "user"), meta["id"])
    return {"meta": meta, "turns": turns}


def export(path, computer):
    if is_codex_file(path):
        return export_codex(path, computer)
    meta = {"id": os.path.basename(path)[:-6], "title": "", "aiTitle": "", "cwd": "",
            "gitBranch": "", "start": "", "end": "", "computer": computer}
    turns = []          # 显示用的消息列表
    tools = {}          # tool_use_id -> 工具块，用来挂工具结果
    seen = set()        # 已处理的 uuid，去重
    trigger = ""        # 上一条压缩记录的触发方式（auto 自动、manual 手动 /compact），记到紧跟着的阶段总结上

    for line in open(path, encoding="utf-8"):
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = d.get("type")
        if t == "custom-title":
            meta["title"] = d.get("customTitle", "")
        elif t == "ai-title":
            meta["aiTitle"] = d.get("aiTitle", "")
        if t == "system" and d.get("subtype") == "compact_boundary":
            trigger = (d.get("compactMetadata") or {}).get("trigger", "")
            continue
        if t not in ("user", "assistant"):
            continue
        uid = d.get("uuid")
        if uid in seen:
            continue
        seen.add(uid)
        ts = d.get("timestamp", "")
        meta["start"] = meta["start"] or ts
        meta["end"] = ts or meta["end"]
        meta["cwd"] = meta["cwd"] or d.get("cwd", "")
        meta["gitBranch"] = meta["gitBranch"] or d.get("gitBranch", "")
        content = d.get("message", {}).get("content")

        if t == "assistant":
            msg_id = d["message"].get("id")
            # 同一条回复会拆成多行写入，按 message.id 合并
            if turns and turns[-1]["role"] == "assistant" and turns[-1].get("msgId") == msg_id:
                turn = turns[-1]
            else:
                turn = {"role": "assistant", "ts": ts, "msgId": msg_id, "blocks": []}
                turns.append(turn)
            for b in content or []:
                bt = b.get("type")
                if bt == "text" and THINKING_CLEANED.match(b.get("text", "")):
                    # 备份里清理掉的思考过程：还原成思考块，只记原来多大
                    turn["blocks"].append({"kind": "thinking", "text": "", "cleaned": THINKING_CLEANED.match(b["text"]).group(1)})
                elif bt == "text" and b.get("text", "").strip():
                    turn["blocks"].append({"kind": "text", "text": b["text"]})
                elif bt == "thinking" and b.get("thinking", "").strip():
                    turn["blocks"].append({"kind": "thinking", "text": b["thinking"]})
                elif bt == "tool_use":
                    tb = {"kind": "tool", "name": b.get("name", ""), "input": b.get("input", {}),
                          "result": None, "isError": False}
                    tools[b.get("id")] = tb
                    turn["blocks"].append(tb)
            continue

        # user
        if isinstance(content, list) and any(b.get("type") == "tool_result" for b in content):
            for b in content:
                if b.get("type") == "tool_result" and b.get("tool_use_id") in tools:
                    tb = tools[b["tool_use_id"]]
                    tb["result"] = tool_result_text(b)
                    tb["isError"] = bool(b.get("is_error"))
            continue
        text = text_of(content).strip()
        if not text:
            continue
        if d.get("isCompactSummary"):
            turns.append({"role": "summary", "ts": ts, "text": text, "trigger": trigger})
            trigger = ""
            continue
        cmd = command_label(text)
        if cmd:
            turns.append({"role": "command", "ts": ts, "text": cmd})
            continue
        human = (d.get("origin") or {}).get("kind") == "human"
        if d.get("isMeta") or text.startswith(SYSTEM_PREFIXES) or not human and text.startswith("<"):
            turns.append({"role": "system", "ts": ts, "text": text})
            continue
        turns.append({"role": "user", "ts": ts, "text": text})

    for t in turns:
        t.pop("msgId", None)
    turns = [t for t in turns if t["role"] != "assistant" or t["blocks"]]
    if not meta["title"]:
        meta["title"] = meta["aiTitle"] or next(
            (t["text"][:40] for t in turns if t["role"] == "user"), meta["id"])
    return {"meta": meta, "turns": turns}


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    computer = sys.argv[3] if len(sys.argv) > 3 else socket.gethostname().split(".")[0]
    data = export(sys.argv[1], computer)
    with open(sys.argv[2], "w", encoding="utf-8") as f:
        f.write("window.SESSION = ")
        json.dump(data, f, ensure_ascii=False)
        f.write(";\n")
    roles = {}
    for t in data["turns"]:
        roles[t["role"]] = roles.get(t["role"], 0) + 1
    print(data["meta"]["title"], roles)
