#!/bin/zsh
# 安装回响：下载 GitHub 上最新的发版，装到「应用程序」（/Applications）并打开。
# macOS 27 的菜单栏整理工具只认装在 /Applications 里的应用，装在别处时菜单栏图标可能被一直藏住；
# 没有权限写 /Applications 时退回 ~/Applications。
# 用法：curl -fsSL https://raw.githubusercontent.com/cyanext/Echo/main/install.sh | zsh
# 用 curl 下载的安装包不带隔离标记，自签名的应用打开时不会被 macOS 拦下。
set -e
REPO=cyanext/Echo
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
dir=/Applications
[[ -w $dir ]] || { dir=~/Applications; mkdir -p $dir; }
rm -rf "$dir/回响.app"
ditto "$tmp/app/回响.app" "$dir/回响.app"
xattr -cr "$dir/回响.app"
# 以前装在 ~/Applications 的旧版删掉，免得留两份
[[ $dir == /Applications ]] && rm -rf ~/Applications/回响.app
open "$dir/回响.app"
echo "已安装到 $dir/回响.app 并打开"
