#!/bin/bash
# 构建「下载即用」的 DockGroup.app 发布包。
#
# 产出（build/release/，在 build-release.sh 的产物之上追加）：
#   DockGroup.app                    自安装 App（universal）
#   DockGroup-v<版本>-macos.zip      发布资产 = ditto 打包的 DockGroup.app
#
# .app 结构：
#   Contents/MacOS/DockGroup          bootstrap 入口（swift/Bootstrap/main.swift）：
#                                     双击 → 装载荷 → `dg gui` 开管理窗口
#   Contents/Resources/repo/          载荷，与 prebuilt.zip 同构：
#                                     scripts/（git archive HEAD）+ prebuilt/
#   Contents/Resources/AppIcon.icns   用 dg gui 顺路画的 manager 图标（可选）
#
# 用法：tools/build-app.sh [版本号]  （缺省从 scripts/dockgroup.py 读）
#
# 依赖：tools/build-release.sh（先跑它拿预编译产物；发布时两个资产都要）。
#
# 为什么载荷从 git archive 拿而不是工作树：build-release.sh 的 zip 用的是
# HEAD，.app 载荷必须和 zip 里的源码逐字节一致 —— 否则用户机上的源码摘要戳
# 和缓存种子对不上，缓存判定就乱了。发版流程约定「先 commit 再构建」。

set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION=$(/usr/bin/python3 - <<'PY'
import re, sys
sys.path.insert(0, 'scripts')
from dockgroup import __version__
print(__version__)
PY
)
fi
echo "版本：$VERSION"

# ① 先拿预编译产物 + HEAD 源码树（zip 与 .app 载荷同源）
echo "① 复用 build-release.sh 的产物"
if [ ! -x "build/release/prebuilt/dg" ] || [ ! -d "build/release/dockgroup-$VERSION" ]; then
    tools/build-release.sh "$VERSION"
fi
STAGE="build/release/dockgroup-$VERSION"
[ -d "$STAGE" ] || { echo "❌ 找不到 $STAGE，请先 commit 再跑（git archive 用 HEAD）" >&2; exit 1; }

SDK="$(xcrun --sdk macosx --show-sdk-path)"
OUT="$REPO/build/release"
APP="$OUT/DockGroup.app"

echo "② 编译 bootstrap 入口（universal）"
mkdir -p "$OUT"
for arch in arm64 x86_64; do
    swiftc -sdk "$SDK" -target "$arch-apple-macos12.0" -O \
        -o "$OUT/bootstrap-$arch" swift/Bootstrap/main.swift \
        -framework Foundation
done
lipo -create -output "$OUT/bootstrap-universal" \
    "$OUT/bootstrap-arm64" "$OUT/bootstrap-x86_64"

echo "③ 生成 App 图标（借 dg gui 画 manager 图标）"
ICNS_ARGS=()
FAKE_HOME="$(mktemp -d)"
if DOCKGROUP_HOME="$FAKE_HOME/Dock Groups" "$OUT/prebuilt/dg" gui --no-open >/dev/null 2>&1 \
   && [ -f "$FAKE_HOME/Dock Groups/.cache/manager-icon.png" ]; then
    ICONSET="$FAKE_HOME/AppIcon.iconset"
    mkdir -p "$ICONSET"
    SRC="$FAKE_HOME/Dock Groups/.cache/manager-icon.png"
    for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" \
                "64 icon_32x32@2x" "128 icon_128x128" "256 icon_128x128@2x" \
                "256 icon_256x256" "512 icon_256x256@2x" "512 icon_512x512" \
                "1024 icon_512x512@2x"; do
        set -- $spec
        sips -z "$1" "$1" "$SRC" --out "$ICONSET/$2.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$FAKE_HOME/AppIcon.icns"
    ICNS_ARGS=(--icon "$FAKE_HOME/AppIcon.icns")
    echo "   已生成 AppIcon.icns"
else
    echo "   ⚠️  没画出 manager 图标，App 用通用图标（不影响功能）"
fi

echo "④ 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/repo"
cp "$OUT/bootstrap-universal" "$APP/Contents/MacOS/DockGroup"
chmod 755 "$APP/Contents/MacOS/DockGroup"
cp -R "$STAGE/scripts" "$APP/Contents/Resources/repo/scripts"
cp -R "$STAGE/prebuilt" "$APP/Contents/Resources/repo/prebuilt"
if [ -n "${ICNS_ARGS:+x}" ]; then
    cp "$FAKE_HOME/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Info.plist：LSUIElement —— bootstrap 只负责装完拉起管理窗口，不抢 Dock 位置；
# NSPrincipalClass 照 ManagerApp 的规矩不能少。
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>DockGroup</string>
    <key>CFBundleExecutable</key>
    <string>DockGroup</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>local.dockgroup.bootstrap</string>
    <key>CFBundleName</key>
    <string>DockGroup</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

echo "⑤ 打 zip"
( cd "$OUT" && ditto -c -k --keepParent "DockGroup.app" "DockGroup-$VERSION-macos.zip" )

rm -rf "$FAKE_HOME"
echo
echo "✅ 完成："
ls -lh "$APP" "$OUT/DockGroup-$VERSION-macos.zip"
echo "   沙箱自测：rm -rf /tmp/dgtest && mkdir -p /tmp/dgtest && \\"
echo "     HOME=/tmp/dgtest DOCKGROUP_BOOTSTRAP_NO_OPEN=1 '$APP/Contents/MacOS/DockGroup'"
echo "   上传：gh release upload <tag> '$OUT/DockGroup-$VERSION-macos.zip' --clobber"
