#!/bin/bash
# 构建预编译发布包。
#
# 产出（build/release/）：
#   dg                     universal 二进制（arm64 + x86_64）
#   DockGroupLauncher.bin  universal 启动器二进制
#   DockGroupManager.bin   universal 管理窗口二进制
#   dockgroup-v<版本>-prebuilt.zip   发布资产 = git archive 源码树 + prebuilt/
#
# 用法：tools/build-release.sh [版本号]  （缺省从 scripts/dockgroup.py 读）
#
# 为什么 launcher/manager 也要预编译：dg apply/rebuild 会现场 swiftc 编译它们，
# 预编译版由 install.command 直接放进 ~/Dock Groups/.cache/（源码摘要戳一起
# 放），launcherBinary/managerBinary 命中缓存 → 用户机器上**不需要 CLT**。

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

SDK="$(xcrun --sdk macosx --show-sdk-path)"
OUT="$REPO/build/release"
rm -rf "$OUT"
mkdir -p "$OUT/prebuilt"

build_one() {  # $1=输出  $2=target  $3...=源文件（其余参数透传给 swiftc）
    local out="$1" target="$2"; shift 2
    swiftc -sdk "$SDK" -target "$target" -O -o "$out" "$@"
}

echo "① 编译 dg（arm64 + x86_64 → universal）"
# BuildInfo.swift 由 swift/build.sh 的逻辑生成；发布包里烧入的仓库路径只是
# 兜底，运行时以 ~/.local/bin/.dg-repo-root 标记文件为准（见 Paths.swift）。
cat > swift/Core/BuildInfo.swift <<EOF
// 由 tools/build-release.sh 生成，别手工改，也别提交。
let BUILD_REPO_ROOT = "$REPO"
EOF
for arch in arm64 x86_64; do
    build_one "$OUT/dg-$arch" "$arch-apple-macos12.0" \
        swift/main.swift swift/Core/*.swift swift/Commands/*.swift \
        -framework Cocoa
done
lipo -create -output "$OUT/prebuilt/dg" "$OUT/dg-arm64" "$OUT/dg-x86_64"

echo "② 编译启动器（universal）"
for arch in arm64 x86_64; do
    build_one "$OUT/launcher-$arch" "$arch-apple-macos12.0" \
        -swift-version 5 scripts/launcher/main.swift -framework Cocoa
done
lipo -create -output "$OUT/prebuilt/DockGroupLauncher.bin" \
    "$OUT/launcher-arm64" "$OUT/launcher-x86_64"

echo "③ 编译管理窗口（universal）"
for arch in arm64 x86_64; do
    build_one "$OUT/manager-$arch" "$arch-apple-macos12.0" \
        -swift-version 5 -parse-as-library scripts/manager/main.swift \
        -framework SwiftUI -framework Cocoa
done
lipo -create -output "$OUT/prebuilt/DockGroupManager.bin" \
    "$OUT/manager-arm64" "$OUT/manager-x86_64"

echo "④ 自检"
"$OUT/prebuilt/dg" --version
file "$OUT/prebuilt/dg" | head -1

echo "⑤ 组装发布 zip（git archive 源码树 + prebuilt/）"
STAGE="$OUT/dockgroup-$VERSION"
rm -rf "$STAGE"; mkdir -p "$STAGE"
git archive HEAD | tar -x -C "$STAGE"
cp -R "$OUT/prebuilt" "$STAGE/prebuilt"
(
    cd "$OUT"
    # 用 python 打 zip：macOS 自带 ditto 也行，但要固定顶层目录名
    /usr/bin/python3 -c "
import shutil
shutil.make_archive('dockgroup-$VERSION-prebuilt', 'zip', '.', 'dockgroup-$VERSION')
"
)
echo
echo "✅ 完成："
ls -lh "$OUT/prebuilt/" "$OUT/dockgroup-$VERSION-prebuilt.zip"
echo "   上传：gh release upload <tag> $OUT/dockgroup-$VERSION-prebuilt.zip --clobber"
