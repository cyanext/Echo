#!/usr/bin/env python3
"""把一个会话 jsonl 整理成浏览界面用的数据，写成 data.js 供 viewer/index.html 读取。

用法：python3 export.py <会话.jsonl> <输出 data.js> [电脑名]
整理规则见 ../方案.md「消息显示规则」。正式应用用 Swift 重写，行为以本脚本为准。
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
    "[Image:", "Caveat:",
)


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


def export(path, computer):
    meta = {"id": os.path.basename(path)[:-6], "title": "", "aiTitle": "", "cwd": "",
            "gitBranch": "", "start": "", "end": "", "computer": computer}
    turns = []          # 显示用的消息列表
    tools = {}          # tool_use_id -> 工具块，用来挂工具结果
    seen = set()        # 已处理的 uuid，去重

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
                if bt == "text" and b.get("text", "").strip():
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
            turns.append({"role": "summary", "ts": ts, "text": text})
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
