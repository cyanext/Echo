#!/usr/bin/env python3
"""会话瘦身原型：Claude Code、Codex 会话 jsonl 写进备份前怎么改。正式应用用 Swift 重写（EchoSlim.swift），行为以本脚本为准。

用法：python3 slim.py <原会话.jsonl> <输出.jsonl>
环境变量 ECHO_NOW（ISO 时间）指定「现在」，测试用；不给就是当前时间。

规则（需求文档/版本需求/v0.7.0-会话备份和自动清理.html）：
- 只换内容，不删行（请求记录除外）；不用改的行原样写出，字节不变。
- 占位统一写成「[已清理：类别，原 大小]」。
- 图片、文档的 base64 一律不进备份；任意位置名为 base64 的长字符串清空。
- 思考过程、附件类系统记录、工具调用参数、工具结果按保留期限：0 天是不备份，-1 是永久，其余按这一行的时间算过没过期。
  Bash 里的 git 提交、合并命令和它的结果一直留着（要点栏的版本点从这里取）。
- 请求记录（api-request 三类）整行去掉。
- 密钥打码：留前 4 位和后 4 位，中间换成 8 个「•」；不到 12 位的只留前 2 位；私钥只留首尾两行标记。

Codex 的行（需求文档/版本需求/待定-多应用支持.html，每行是 {timestamp, type, payload}）同一套期限和占位：
- 对话消息（user、assistant）永久；思考（reasoning）、工具调用（function_call 参数、custom_tool_call 输入）、
  工具结果（*_output）按期限；git 提交、合并命令和它的结果一直留着。
- 系统记录：developer 消息、系统说明、工具清单、权限沙箱设置、world_state、压缩时存的整段历史副本、
  item_completed 事件（和正式记录重复）、thread_settings_applied，只换下面列的字段，别的字段（cwd、model、用量）留着。
- 图片：data:…;base64, 开头的长字符串、生成图片的 result 一律换成占位。
"""
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

# 请求记录：请求参数、哈希和对话的重复副本，浏览和恢复都用不到
DROP_TYPES = {"api-request", "api-request-blob", "api-request-shape"}
# 保留期限（天），和应用的默认值一致
DEFAULT_POLICY = {"tool_use": 30, "tool_result": 30, "thinking": 0, "system": 0}
CLEANED_KEY = "已清理"


def size_text(n):
    """按 1024 进位，不到 100 留一位小数"""
    if n < 1024:
        return f"{n} B"
    v = float(n)
    for u in ("KB", "MB", "GB"):
        v /= 1024
        if v < 1024 or u == "GB":
            return f"{v:.1f} {u}" if v < 100 else f"{v:.0f} {u}"


def placeholder(kind, n):
    return f"[{CLEANED_KEY}：{kind}，原 {size_text(n)}]"


def raw_len(v):
    """这个值写成 JSON 的字节数（和 Claude Code 写的格式一致：紧凑、中文不转义）"""
    return len(json.dumps(v, ensure_ascii=False, separators=(",", ":")).encode("utf-8", "surrogatepass"))


def parse_ts(s):
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except ValueError:
        return None


def expired(days, ts, now):
    if days < 0:
        return False
    if days == 0:
        return True
    return ts is not None and now - ts > timedelta(days=days)


def is_cleaned(v):
    return (isinstance(v, str) and v.startswith(f"[{CLEANED_KEY}：")) or (isinstance(v, dict) and CLEANED_KEY in v)


# 真的 git 提交、合并命令：在开头，或跟在 && || ; 换行后面
GIT_RE = re.compile(r"(?:^|&&|\|\||;|\n)\s*git\b(?:\s+-c\s+\S+)*\s+(?:commit|merge)\b")


def keeps_git(block):
    cmd = (block.get("input") or {}).get("command") if isinstance(block.get("input"), dict) else None
    return block.get("name") == "Bash" and isinstance(cmd, str) and GIT_RE.search(cmd) is not None


def strip_base64(node):
    """图片、文档块换成占位；名为 base64 的长字符串清空。返回 (新节点, 改没改)"""
    if isinstance(node, dict):
        src = node.get("source")
        if node.get("type") in ("image", "document") and isinstance(src, dict) and src.get("type") == "base64":
            data = src.get("data", "")
            kind = "图片" if node["type"] == "image" else "文件"
            return {"type": "text", "text": placeholder(kind, len(data) * 3 // 4)}, True
        out, changed = {}, False
        for k, v in node.items():
            if k == "base64" and isinstance(v, str) and len(v) > 1000:
                out[k] = ""
                out["slimmed"] = True
                changed = True
                continue
            nv, c = strip_base64(v)
            out[k] = nv
            changed = changed or c
        return out, changed
    if isinstance(node, list):
        out, changed = [], False
        for v in node:
            nv, c = strip_base64(v)
            out.append(nv)
            changed = changed or c
        return out, changed
    return node, False


def apply_policy(obj, policy, now, git_ids):
    """按保留期限换思考、工具数据、附件。返回改没改"""
    changed = False
    ts = parse_ts(obj.get("timestamp"))
    t = obj.get("type")
    content = (obj.get("message") or {}).get("content") if isinstance(obj.get("message"), dict) else None
    if t == "assistant" and isinstance(content, list):
        for i, b in enumerate(content):
            if not isinstance(b, dict):
                continue
            if b.get("type") in ("thinking", "redacted_thinking") and expired(policy["thinking"], ts, now):
                content[i] = {"type": "text", "text": placeholder("思考过程", raw_len(b))}
                changed = True
            elif b.get("type") == "tool_use":
                if keeps_git(b):
                    git_ids.add(b.get("id"))
                elif expired(policy["tool_use"], ts, now) and "input" in b and not is_cleaned(b["input"]):
                    b["input"] = {CLEANED_KEY: f"工具参数，原 {size_text(raw_len(b['input']))}"}
                    changed = True
    elif t == "user" and isinstance(content, list) and expired(policy["tool_result"], ts, now):
        hit = False
        for b in content:
            if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("tool_use_id") not in git_ids:
                hit = True
                if "content" in b and not is_cleaned(b["content"]):
                    b["content"] = placeholder("工具结果", raw_len(b["content"]))
                    changed = True
        if hit and "toolUseResult" in obj and not is_cleaned(obj["toolUseResult"]):
            obj["toolUseResult"] = placeholder("工具结果", raw_len(obj["toolUseResult"]))
            changed = True
    elif t == "attachment" and expired(policy["system"], ts, now):
        a = obj.get("attachment")
        if isinstance(a, dict) and CLEANED_KEY not in a:
            obj["attachment"] = {"type": a.get("type"), CLEANED_KEY: f"系统记录，原 {size_text(raw_len(a))}"}
            changed = True
    return changed


# ---------- 密钥打码 ----------
MASK = "•" * 8
SECRET_HINT = re.compile(r"Bearer|sk-|gh[pousr]_|github_pat_|AKIA|PRIVATE KEY|(?i:pass|secret|token|api_?key|access_?key)")
PRIVATE_KEY = re.compile(r"(-----BEGIN [A-Z ]*PRIVATE KEY-----)(.{40,}?)(-----END [A-Z ]*PRIVATE KEY-----)")
BEARER = re.compile(r"(Bearer\s+)([A-Za-z0-9._~+/=-]{16,})")
PREFIXED = re.compile(r"()(?<![A-Za-z0-9])(sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16})")
ASSIGN = re.compile(r"(?i)((?:password|passwd|secret|token|api_?key|access_?key)\\?[\"']?\s*[:=]\s*\\?[\"']?)([^\"'\\\s,;&<>]{8,})")
EXAMPLE_WORDS = ("xxx", "your", "example", "placeholder", "dummy", "changeme", "test", "redacted", "***")


def mask_value(v):
    return v[:4] + MASK + v[-4:] if len(v) >= 12 else v[:2] + MASK


def looks_real(v):
    """赋值里的值像不像真的密钥：字母数字都有，不是示例写法"""
    low = v.lower()
    if any(w in low for w in EXAMPLE_WORDS) or any(c in v for c in "${}•"):
        return False
    return re.search(r"[A-Za-z]", v) is not None and re.search(r"[0-9]", v) is not None


def mask_secrets(line):
    if not SECRET_HINT.search(line):
        return line
    line = PRIVATE_KEY.sub(lambda m: m.group(1) + MASK + m.group(3), line)
    line = BEARER.sub(lambda m: m.group(1) + mask_value(m.group(2)), line)
    line = PREFIXED.sub(lambda m: mask_value(m.group(2)), line)
    line = ASSIGN.sub(lambda m: m.group(1) + (mask_value(m.group(2)) if looks_real(m.group(2)) else m.group(2)), line)
    return line


# ---------- Codex ----------
CODEX_TYPES = {"session_meta", "response_item", "event_msg", "turn_context", "world_state", "compacted",
               "token_usage_record", "inter_agent_communication_metadata"}
# 系统记录：(type, payload.type) → 换成占位的字段
CODEX_SYSTEM = {
    ("session_meta", None): ["base_instructions"],
    ("turn_context", None): ["permission_profile", "file_system_sandbox_policy", "collaboration_mode"],
    ("world_state", None): ["state"],
    ("compacted", None): ["replacement_history", "guardian_history", "retained_context", "replacement_history_metadata"],
    ("event_msg", "item_completed"): ["item"],
    ("event_msg", "thread_settings_applied"): ["thread_settings"],
    ("response_item", "additional_tools"): ["tools"],
    ("response_item", "compaction"): ["encrypted_content"],
}
# Codex 的命令写在 JSON 字符串里（{"cmd":"git commit …"}），git 前面还可能是引号、字面的 \n
CODEX_GIT_RE = re.compile(r"(?:^|&&|\|\||;|\n|\\n|[\"'`])\s*git\b(?:\s+-c\s+\S+)*\s+(?:commit|merge)\b")


def is_codex(obj):
    return obj.get("type") in CODEX_TYPES and isinstance(obj.get("payload"), dict)


def strip_data_urls(node):
    """data:…;base64, 开头的长字符串换成占位。返回 (新节点, 改没改)"""
    if isinstance(node, str):
        if len(node) > 1000 and node.startswith("data:") and ";base64," in node[:100]:
            kind = "图片" if node.startswith("data:image/") else "文件"
            return placeholder(kind, (len(node) - node.index(",") - 1) * 3 // 4), True
        return node, False
    if isinstance(node, dict):
        changed = False
        for k, v in node.items():
            nv, c = strip_data_urls(v)
            if c:
                node[k] = nv
                changed = True
        return node, changed
    if isinstance(node, list):
        changed = False
        for i, v in enumerate(node):
            nv, c = strip_data_urls(v)
            if c:
                node[i] = nv
                changed = True
        return node, changed
    return node, False


def apply_codex(obj, policy, now, git_ids):
    p, t = obj["payload"], obj["type"]
    pt = p.get("type") if t in ("event_msg", "response_item") else None
    ts = parse_ts(obj.get("timestamp"))
    changed = False
    fields = CODEX_SYSTEM.get((t, pt), [])
    if t == "response_item" and pt == "message" and p.get("role") not in ("user", "assistant"):
        fields = ["content"]
    for f in fields:
        if p.get(f) is not None and not is_cleaned(p[f]) and expired(policy["system"], ts, now):
            p[f] = placeholder("系统记录", raw_len(p[f]))
            changed = True
    if t != "response_item":
        return changed
    if pt == "reasoning":
        keys = [k for k in ("summary", "content", "encrypted_content") if p.get(k)]
        if keys and not is_cleaned(p.get("encrypted_content")) and expired(policy["thinking"], ts, now):
            n = sum(raw_len(p[k]) for k in keys)
            for k in keys:
                if k != "encrypted_content":
                    p[k] = []
            p["encrypted_content"] = placeholder("思考过程", n)
            changed = True
    elif pt in ("function_call", "custom_tool_call"):
        k = "arguments" if pt == "function_call" else "input"
        v = p.get(k)
        if isinstance(v, str) and CODEX_GIT_RE.search(v):
            git_ids.add(p.get("call_id"))
        elif v is not None and not is_cleaned(v) and expired(policy["tool_use"], ts, now):
            p[k] = placeholder("工具参数", raw_len(v))
            changed = True
    elif pt in ("function_call_output", "custom_tool_call_output"):
        if p.get("call_id") not in git_ids and p.get("output") is not None and not is_cleaned(p["output"]) \
                and expired(policy["tool_result"], ts, now):
            p["output"] = placeholder("工具结果", raw_len(p["output"]))
            changed = True
    elif pt == "image_generation_call":
        r = p.get("result")
        if isinstance(r, str) and len(r) > 1000:
            p["result"] = placeholder("图片", len(r) * 3 // 4)
            changed = True
    return changed


def slim_line(line, policy, now, git_ids):
    """处理一行（含换行符），返回新的一行；None 表示整行去掉"""
    if '"api-request' in line:
        try:
            if json.loads(line).get("type") in DROP_TYPES:
                return None
        except (json.JSONDecodeError, AttributeError):
            pass
    if '"payload"' in line:
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            obj = None
        if isinstance(obj, dict) and is_codex(obj):
            obj, c0 = strip_data_urls(obj)
            obj, c1 = strip_base64(obj)
            c2 = apply_codex(obj, policy, now, git_ids)
            if c0 or c1 or c2:
                line = json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"
            return mask_secrets(line)
    if any(k in line for k in ('"base64"', '"thinking"', '"redacted_thinking"', '"type":"attachment"', '"tool_use"', '"tool_result"')):
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            obj = None   # 写到一半的最后一行等坏行原样保留
        if isinstance(obj, dict):
            obj, c1 = strip_base64(obj)
            c2 = apply_policy(obj, policy, now, git_ids)
            if c1 or c2:
                line = json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"
    return mask_secrets(line)


def now_from_env():
    s = os.environ.get("ECHO_NOW")
    return parse_ts(s) if s else datetime.now(timezone.utc)


def slim_file(src_path, dst_path, policy=DEFAULT_POLICY, now=None):
    now = now or now_from_env()
    git_ids = set()
    total_in = total_out = 0
    # Codex 压过的旧会话（.jsonl.zst）用 zstd 命令边解压边读
    if src_path.endswith(".zst"):
        import io, subprocess
        proc = subprocess.Popen(["zstd", "-dcq", src_path], stdout=subprocess.PIPE)
        fin_ctx = io.TextIOWrapper(proc.stdout, encoding="utf-8", errors="surrogateescape", newline="")
    else:
        fin_ctx = open(src_path, encoding="utf-8", errors="surrogateescape", newline="")
    with fin_ctx as fin, \
         open(dst_path, "w", encoding="utf-8", errors="surrogateescape", newline="") as fout:
        for line in fin:
            total_in += len(line.encode("utf-8", "surrogateescape"))
            out = slim_line(line, policy, now, git_ids)
            if out is None:
                continue
            fout.write(out)
            total_out += len(out.encode("utf-8", "surrogateescape"))
    return total_in, total_out


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    i, o = slim_file(sys.argv[1], sys.argv[2])
    print(f"原文件 {i/1e6:.1f}MB → 瘦身后 {o/1e6:.1f}MB")
