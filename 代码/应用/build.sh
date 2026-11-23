#!/bin/zsh
# 编译 回响.app（Apple 芯片，macOS 14+），输出 dist/回响.app。临时签名，自用。
# 用法：zsh 代码/应用/build.sh；装到 ~/Applications 并重新打开：zsh 代码/应用/build.sh install
set -e
VERSION=0.12.0; BUILD=21                           # 版本号只改这里
D="${0:A:h}"; T=$(mktemp -d); APP="$T/回响.app"
trap 'rm -rf "$T"' EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Web"
source "$D/tools/swift-env.sh" "$T"
swiftc -O "${SWIFT_FLAGS[@]}" -parse-as-library -target arm64-apple-macos14.0 "$D"/App/*.swift -o "$APP/Contents/MacOS/Echo"
cp "$D"/Web/*.(html|css|js|json|svg) "$APP/Contents/Resources/Web/"
# ech 的 skill 跟着应用发，版本号和应用一致（ech install-skill 装到 ~/.claude/skills/ech）
mkdir -p "$APP/Contents/Resources/skills"
cp -R "$D/skill/ech" "$APP/Contents/Resources/skills/"
sed -i '' "s/{{VERSION}}/$VERSION/" "$APP/Contents/Resources/skills/ech/SKILL.md"
# 图标：AppIcon.iconset 由 icon/make_icon.py 生成并提交，改图标时跑它
iconutil -c icns "$D/icon/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.cyanext.echo</string>
  <key>CFBundleName</key><string>回响</string>
  <key>CFBundleDisplayName</key><string>回响</string>
  <key>CFBundleExecutable</key><string>Echo</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSDesktopFolderUsageDescription</key><string>把会话备份到桌面上的回响文件夹</string>
  <key>NSDocumentsFolderUsageDescription</key><string>把会话备份到文稿里的文件夹</string>
</dict></plist>
P
plutil -lint -s "$APP/Contents/Info.plist"
# 签名：固定自签名证书「Echo Local Signing」，指定要求是「标识符 + 证书指纹」，每版不变，macOS 给的授权（访问桌面等）重装后还在。
# 证书在专用钥匙串，密码在登录钥匙串（服务 echo-sign-keychain）；没有证书时退回临时签名（每次重装都会重新问授权）。
# 证书备份在密码管理器，换电脑恢复的步骤写在那条的备注里
SIGN=(-s -)
SIGN_KC="$HOME/Library/Keychains/echo-sign.keychain-db"
if [[ -f "$SIGN_KC" ]] && KPW=$(security find-generic-password -s echo-sign-keychain -w 2>/dev/null); then
  security unlock-keychain -p "$KPW" "$SIGN_KC"; unset KPW
  SIGN=(-s "Echo Local Signing" --keychain "$SIGN_KC")
else
  echo "警告：没有签名证书，改用临时签名，每次重装都会重新问授权（恢复见密码管理器）" >&2
fi
codesign --force "${SIGN[@]}" "$APP"
codesign --verify --strict "$APP"
rm -rf "$D/dist"; mkdir -p "$D/dist"; ditto "$APP" "$D/dist/回响.app"
echo "已生成 $D/dist/回响.app（$VERSION，build $BUILD）"
if [[ "$1" == install ]]; then
  osascript -e 'quit app id "com.cyanext.echo"' 2>/dev/null || true
  sleep 1; rm -rf ~/Applications/回响.app; mkdir -p ~/Applications; ditto "$D/dist/回响.app" ~/Applications/回响.app
  env -u TZ open ~/Applications/回响.app   # 终端带美国时区，不去掉的话界面时间不对
  echo "已装到 ~/Applications/回响.app 并打开"
fi
