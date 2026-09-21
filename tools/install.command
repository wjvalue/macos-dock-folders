#!/bin/bash
# dockgroup 一键安装。
#
# 双击就能跑（macOS 会用「终端」打开 .command 文件）。
#
# 两种安装来源：
#   A. 预编译发布包（含 prebuilt/ 目录）—— 装 universal 二进制，启动器/管理
#      窗口的二进制直接预置进缓存，**不需要 CLT、Python、Pillow**。
#   B. git clone 的源码 —— 走原路径：补 Pillow → 装 Python shim → 体检，
#      首次 apply 时现场 swiftc 编译（约 8 秒，之后走缓存）。
#
# 为什么有预编译包也要先清隔离：从网络下载的 zip 解压出来，每个文件都带
# com.apple.quarantine 标记。不清掉的话，生成的 .app 双击时会被 Gatekeeper
# 拦下报「无法验证开发者」—— 那和签名没关系，纯粹是标记在起作用。

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

DG="$HOME/.local/bin/dg"
MARKER="$HOME/.local/bin/.dg-repo-root"
CACHE="$HOME/Dock Groups/.cache"
PREBUILT="$ROOT/prebuilt/dg"

if [ -x "$PREBUILT" ]; then
    # ─────────────────────────────── A. 预编译包
    echo "② 安装 dg（预编译 universal 二进制）"
    mkdir -p "$HOME/.local/bin"
    if [ -f "$DG" ] && head -1 "$DG" 2>/dev/null | grep -q '^#!'; then
        # 旧的 Python shim：留个备份再换。它的历史使命（包一层 python3）
        # 已经被二进制接管。
        cp "$DG" "$DG.python-shim.bak"
        echo "   旧的 Python shim 已备份为 dg.python-shim.bak"
    fi
    cp "$PREBUILT" "$DG"
    chmod +x "$DG"
    echo "   已安装 → $DG"
    echo "$ROOT" > "$MARKER"
    echo "   仓库位置已记录到 $MARKER（引擎按它找源码与脚本）"

    echo
    echo "③ 预置启动器 / 管理窗口二进制"
    # 放进缓存 + 写源码摘要戳 → apply 时命中缓存，现场不用 swiftc。
    # 戳必须和 ships 的源码一致 —— 发布包就是从同一棵源码树构建的。
    mkdir -p "$CACHE"
    cp "$ROOT/prebuilt/DockGroupLauncher.bin" "$CACHE/.launcher.bin"
    cp "$ROOT/prebuilt/DockGroupManager.bin" "$CACHE/.manager.bin"
    shasum -a 256 "$ROOT/scripts/launcher/main.swift" | awk '{print $1}' \
        > "$CACHE/.launcher.src-stamp"
    shasum -a 256 "$ROOT/scripts/manager/main.swift" | awk '{print $1}' \
        > "$CACHE/.manager.src-stamp"
    echo "   已放入 $CACHE（apply 免编译）"
    DG_RUN="bin"
else
    # ─────────────────────────────── B. 源码安装
    echo "② 补齐 Pillow"
    # Pillow 不在 macOS 自带依赖里（见 README「安装」那张表）。缺了它后面所有命令
    # 都跑不动 —— 以前没这一步，新用户照文档 clone 下来第一次跑就报错，还以为
    # 是自己哪里弄错了。检查用 -s 吗？不用：这里要的就是「用户现在能不能跑」。
    if /usr/bin/python3 -c "import PIL" 2>/dev/null; then
        echo "   已装：Pillow $(/usr/bin/python3 -c 'import PIL; print(PIL.__version__)' 2>/dev/null)"
    else
        echo "   缺 Pillow，装到 /usr/bin/python3 的 user site …"
        if /usr/bin/python3 -m pip install --user Pillow; then
            echo "   ✅ 装好了"
        else
            echo "   ⚠️  自动安装没成功，请手动执行（国内网络可能要挂代理）："
            echo "       /usr/bin/python3 -m pip install --user Pillow"
        fi
    fi
    echo

    echo "③ 安装 dg 短命令"
    if [ -f "$DG" ] && grep -q "dockgroup.py" "$DG" 2>/dev/null; then
        # 已经有了就绝不覆盖：用户手上那份可能改过路径、加过别名。
        echo "   已存在：$DG"
        if grep -qF "$ROOT/scripts/dockgroup.py" "$DG"; then
            echo "   指向本仓库，跳过"
        else
            echo "   ⚠️  它指向的是别的路径，没有动它。"
            echo "      想切到本仓库的话，手动改 $DG 里的 DG_PY。"
        fi
    else
        mkdir -p "$HOME/.local/bin"
        cat > "$DG" <<EOF
#!/bin/bash
# dg — macOS Dock 分组管理（macos-dock-folders 的快捷入口）
#
# 装在这里是为了免去每次敲长路径 + /usr/bin/python3。
# 工具本体在下面这个路径；如果哪天把它移走了，改这一行即可。
DG_PY="$ROOT/scripts/dockgroup.py"

if [ ! -f "\$DG_PY" ]; then
    echo "❌ 找不到 dockgroup.py：\$DG_PY" >&2
    echo "   工具可能被移动过。改一下 \$0 里的 DG_PY 路径就好。" >&2
    exit 1
fi

exec /usr/bin/python3 "\$DG_PY" "\$@"
EOF
        chmod +x "$DG"
        echo "   已装到 $DG"
    fi
    DG_RUN="py"
fi
echo

if printf '%s' ":$PATH:" | grep -q ":$HOME/.local/bin:"; then
    echo "   ~/.local/bin 已在 PATH 里"
else
    echo "   ⚠️  ~/.local/bin 不在 PATH 里。把下面这行加到 ~/.zshrc 然后重开终端："
    echo '       export PATH="$HOME/.local/bin:$PATH"'
fi
echo

echo "④ 依赖体检"
if [ "${DG_RUN:-}" = "bin" ]; then
    "$DG" doctor
else
    /usr/bin/python3 "$ROOT/scripts/dockgroup.py" doctor
fi
echo

echo "装好了。接着可以："
echo "  dg init     扫描当前 Dock，生成起始配置"
echo "  dg gui      打开图形界面"
echo
read -r -n 1 -s -p "按任意键关闭这个窗口…"
echo
