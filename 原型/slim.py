#!/usr/bin/env python3
"""会话瘦身原型：把 Claude Code 会话 jsonl 里的 base64 图片和文件换成占位，去掉请求记录，其余原样保留。

用法：python3 slim.py <原会话.jsonl> <输出.jsonl>
规则见 ../方案.md「瘦身规则」。正式应用用 Swift 重写，行为以本脚本为准。
"""
import json
import sys

PLACEHOLDER = "[图片已移除]"
# 请求记录：请求参数、哈希和对话的重复副本，浏览和恢复都用不到
DROP_TYPES = {"api-request", "api-request-blob", "api-request-shape"}


def slim(node):
    """递归处理，返回 (新节点, 移除的字节数)。"""
    removed = 0
    if isinstance(node, dict):
        src = node.get("source")
        # 规则 1：内容块里的 base64 图片或文档，整块换成文字块
        if (
            node.get("type") in ("image", "document")
            and isinstance(src, dict)
            and src.get("type") == "base64"
        ):
            removed += len(src.get("data", ""))
            label = PLACEHOLDER if node["type"] == "image" else "[文件已移除]"
            return {"type": "text", "text": label}, removed
        out = {}
        for k, v in node.items():
            # 规则 2：工具输出副本里的 base64 字段清空，保留文件路径、尺寸等元数据
            if k == "base64" and isinstance(v, str) and len(v) > 1000:
                removed += len(v)
                out[k] = ""
                out["slimmed"] = True
                continue
            nv, r = slim(v)
            out[k] = nv
            removed += r
        return out, removed
    if isinstance(node, list):
        out = []
        for v in node:
            nv, r = slim(v)
            out.append(nv)
            removed += r
        return out, removed
    return node, 0


def slim_file(src_path, dst_path):
    total_in = total_out = removed = 0
    with open(src_path, encoding="utf-8") as fin, open(dst_path, "w", encoding="utf-8") as fout:
        for line in fin:
            total_in += len(line.encode())
            if '"api-request' in line:
                try:
                    if json.loads(line).get("type") in DROP_TYPES:
                        continue
                except json.JSONDecodeError:
                    pass
            if '"base64"' not in line:
                # 没有 base64 的行原样写出，不重新序列化，保证字节不变
                fout.write(line)
                total_out += len(line.encode())
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                # 写到一半的最后一行等坏行原样保留
                fout.write(line)
                total_out += len(line.encode())
                continue
            new, r = slim(obj)
            removed += r
            s = json.dumps(new, ensure_ascii=False, separators=(",", ":")) + "\n"
            fout.write(s)
            total_out += len(s.encode())
    return total_in, total_out, removed


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    i, o, r = slim_file(sys.argv[1], sys.argv[2])
    print(f"原文件 {i/1e6:.1f}MB → 瘦身后 {o/1e6:.1f}MB，移除 base64 {r/1e6:.1f}MB")
