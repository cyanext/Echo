# build.sh、tests/run.sh 共用的编译设置，用法：source "$D/tools/swift-env.sh" <临时目录>，之后用 $SWIFT_FLAGS。照伙伴云NAS应用 mac/tools/swift-env.sh。
# 1. 桌面同步工具会补出「X 2.swift」这种副本，一编译就报重复定义：先查出来停下，和原文件比对一致再删
# 2. zstd：Codex 的旧会话是 .jsonl.zst，静态链接 Homebrew 的 libzstd.a（模块定义在 tools/zstd/），没装时提示
# 3. 本机命令行工具有重复定义 SwiftBridging 模块的问题，用 vfsoverlay 屏蔽 bridging.modulemap
swift_dups=("$D"/App/*\ 2.*(N) "$D"/Web/*\ 2.*(N) "$D"/tests/*\ 2.*(N) "$D"/tools/*\ 2.*(N))
if (( ${#swift_dups} )); then
  echo "同步工具补出了这些副本，先和原文件比对，一致就删：" >&2; printf '  %s\n' "${swift_dups[@]}" >&2; exit 1
fi
mkdir -p "$1/mcache"
: > "$1/empty.modulemap"
cat > "$1/overlay.yaml" <<Y
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "directory", "name": "/Library/Developer/CommandLineTools/usr/include/swift",
  "contents": [ { "type": "file", "name": "bridging.modulemap", "external-contents": "$1/empty.modulemap" } ] } ] }
Y
ZSTD_A=/opt/homebrew/opt/zstd/lib/libzstd.a
if [[ ! -f $ZSTD_A ]]; then echo "缺 zstd：先 brew install zstd" >&2; exit 1; fi
SWIFT_FLAGS=(-I "$D/tools/zstd" "$ZSTD_A" -swift-version 5 -module-cache-path "$1/mcache" -vfsoverlay "$1/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$1/overlay.yaml")
