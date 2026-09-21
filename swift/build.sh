#!/bin/bash
# 编译 Swift 版 dg。
#
# 为什么还是「swiftc 直接编译」而不是 Xcode 工程、也不引第三方依赖：
# 这个项目一直刻意保持这条路子（见 scripts/dockgroup.py 的 build_launcher_app），
# 好处是整个工具只需要 CLT。换成 SPM/Xcode 工程会引入 Package.swift、
# 构建缓存目录这些东西，对这么小的工具是负担。
#
# 用法：
#   swift/build.sh              # 编译到 <repo>/build/dg-swift
#   swift/build.sh /tmp/dg      # 指定输出路径

set -euo pipefail
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
OUT="${1:-$REPO/build/dg-swift}"

# 把仓库位置烧进二进制 —— Swift 没有 Python 的 __file__，运行时无从知道自己
# 是从哪个仓库编出来的。生成的文件不进版本库（见 .gitignore）。
cat > Core/BuildInfo.swift <<EOF
// 由 swift/build.sh 生成，别手工改，也别提交。
let BUILD_REPO_ROOT = "$REPO"
EOF

mkdir -p "$(dirname "$OUT")"
swiftc -O -o "$OUT" \
    main.swift \
    Core/*.swift \
    Commands/*.swift \
    -framework Cocoa

echo "✅ 编译完成：$OUT"
