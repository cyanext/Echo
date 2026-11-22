#!/bin/zsh
# 回归测试：瘦身、消息显示（和原型现场生成的结果比对）、备份挑文件的规则、改名、合集、删除、时间轴取点。改了 EchoSlim、EchoExport、EchoBackup、EchoEdit、Web/app.js 必跑。
# 用法：zsh 代码/应用/tests/run.sh [另外要比对的会话.jsonl…]。样例/ 下有真实会话（不进 git）时一并比对。
set -e
D="${0:A:h:h}"; P="${D:h}/原型"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export TMPDIR="$T/"   # 测试程序的缓存目录（EchoLibrary.supportDir）落在这里，跑完一起删
source "$D/tools/swift-env.sh" "$T"
swiftc "${SWIFT_FLAGS[@]}" -D TEST -parse-as-library -target arm64-apple-macos14.0 "$D"/App/*.swift "$D/tests/test.swift" -o "$T/test"
"$T/test" --rules "$D/tests/fixtures/各类记录.jsonl"
# 时间轴取点的规则在网页脚本里，用 node 跑；没有 node 时跳过并提示
if command -v node >/dev/null; then node "$D/tests/timeline_test.js" "$D/Web/app.js"; else echo "跳过时间轴测试：没有 node" >&2; fi
for f in "$@" "$D"/tests/fixtures/*.jsonl(N) "${D:h:h}"/样例/*.jsonl(N) "${D:h:h:h:h}"/样例/*.jsonl(N); do
  python3 -I "$P/slim.py" "$f" "$T/slim.jsonl" >/dev/null
  python3 -I "$P/export.py" "$f" "$T/data.js" 测试机 >/dev/null
  "$T/test" "$f" "$T/slim.jsonl" "$T/data.js"
done
echo "全部通过"
