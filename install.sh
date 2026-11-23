#!/bin/zsh
# 安装回响：下载 GitHub 上最新的发版，装到 ~/Applications 并打开。
# 用法：curl -fsSL https://raw.githubusercontent.com/cyanext/echo/main/install.sh | zsh
# 用 curl 下载的安装包不带隔离标记，自签名的应用打开时不会被 macOS 拦下。
set -e
REPO=cyanext/echo
[[ "$(uname -m)" == arm64 ]] || { echo "回响只支持 Apple 芯片的 Mac" >&2; exit 1; }
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ]] || { echo "回响需要 macOS 14 或更新的版本" >&2; exit 1; }
url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/')
[[ -n "$url" ]] || { echo "没找到安装包，请到 https://github.com/$REPO/releases 下载" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "下载 ${url##*/}"
curl -fL --progress-bar "$url" -o "$tmp/Echo.zip"
ditto -x -k "$tmp/Echo.zip" "$tmp/app"
[[ -d "$tmp/app/回响.app" ]] || { echo "安装包里没有回响.app" >&2; exit 1; }
osascript -e 'quit app id "com.cyanext.echo"' >/dev/null 2>&1 || true
sleep 1
mkdir -p ~/Applications
rm -rf ~/Applications/回响.app
ditto "$tmp/app/回响.app" ~/Applications/回响.app
xattr -cr ~/Applications/回响.app
open ~/Applications/回响.app
echo "已安装到 ~/Applications/回响.app 并打开"
