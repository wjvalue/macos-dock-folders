#!/bin/bash
# dockgroup 一键安装。
#
# 双击就能跑（macOS 会用「终端」打开 .command 文件）。
# 做四件事：清隔离属性 → 编译 Swift 引擎 → 装 dg 短命令 → 体检。
#
# 为什么第一步是清隔离：从网络下载的 zip 解压出来，每个文件都带
# com.apple.quarantine 标记。不清掉的话，后面生成的 .app 也会带这个标记，
# 双击时被 Gatekeeper 拦下报「无法验证开发者」—— 那和签名没关系，
# 纯粹是标记在起作用。git clone 下来的代码没有这个标记。

cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"

echo "dockgroup 安装"
echo "仓库位置：$ROOT"
echo

echo "① 清除隔离属性"
if xattr -r -l "$ROOT" 2>/dev/null | grep -q com.apple.quarantine; then
    xattr -cr "$ROOT"
    echo "   已清除（这份代码是从网络下载来的）"
else
    echo "   本来就没有（git clone 或本地创建的文件都不会带）"
fi
echo

echo "② 编译 Swift 引擎"
if ! command -v swiftc >/dev/null 2>&1; then
    echo "   ❌ 找不到 swiftc。请先安装 Xcode Command Line Tools：xcode-select --install"
    exit 1
fi
ENGINE_DIR="$HOME/.local/libexec"
ENGINE="$ENGINE_DIR/dockgroup-engine"
mkdir -p "$ENGINE_DIR"
if swiftc -swift-version 5 -O "$ROOT/scripts/engine/main.swift" \
    -o "$ENGINE" -framework Cocoa; then
    chmod +x "$ENGINE"
    echo "   ✅ 已编译原生引擎"
else
    echo "   ❌ Swift 引擎编译失败"
    exit 1
fi
echo

echo "③ 安装 dg 短命令"
DG="$HOME/.local/bin/dg"
mkdir -p "$HOME/.local/bin"
cat > "$DG" <<EOF
#!/bin/bash
# dg — macOS Dock 分组管理（macos-dock-folders 的快捷入口）
export DOCKGROUP_SOURCE_ROOT="$ROOT/scripts"
exec "$ENGINE" "\$@"
EOF
chmod +x "$DG"
echo "   已安装：$DG"
if printf '%s' ":$PATH:" | grep -q ":$HOME/.local/bin:"; then
    echo "   ~/.local/bin 已在 PATH 里"
else
    echo "   ⚠️  ~/.local/bin 不在 PATH 里。把下面这行加到 ~/.zshrc 然后重开终端："
    echo '       export PATH="$HOME/.local/bin:$PATH"'
fi
echo

echo "④ 依赖体检"
"$DG" doctor
echo

echo "装好了。接着可以："
echo "  dg init     扫描当前 Dock，生成起始配置"
echo "  dg gui      打开图形界面"
echo
read -r -n 1 -s -p "按任意键关闭这个窗口…"
echo
