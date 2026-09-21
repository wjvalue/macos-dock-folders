#!/bin/bash
# Python 版 ⇄ Swift 版 对照测试。
#
# 迁移期的一致性保证。三类对照：
#
#   ① 文本输出 —— 同一个命令跑两套实现，逐行 diff。这是最严的一档：
#      一个空格的差别都算失败。空格恰恰最容易出问题（f-string 的 `{:<10}`
#      按**字符数**补位、print 的换行次数、中文名算几个位置）。
#   ② 生成的文件 —— init 会写 groups.json，把它并进输出一起 diff。
#   ③ 像素 —— 图像合成和图标提取没法逐字节比（PNG 编码器不同），改比 MAE。
#      阈值 1.0/255：这个量级足以区分「移植对了」和「哪儿写错了」。
#      实测两条路的 MAE 都在 0.3~0.7，而写错一处就是十几。
#
# 异常分支也覆盖：doctor 的「依赖缺失」「产物路径失效」在正常环境下根本跑不到，
# 得靠 DOCKGROUP_HOME 和 PATH 把它们逼出来 —— 而那恰恰是 doctor 存在的意义。
#
# 用法：tools/compare_cli.sh

set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
PY=/usr/bin/python3
SW="$REPO/build/dg-swift"
TMPHOME=/tmp/cmpcli-home
PX=/tmp/cmpcli-px
ICONS="$HOME/Dock Groups/.cache/app-icons"
PIXEL_MAX=1.0

if [ ! -x "$SW" ]; then
    echo "还没编译，先跑：swift/build.sh" >&2
    exit 1
fi

pass=0
fail=0
A=/tmp/cmpcli-a.txt
B=/tmp/cmpcli-b.txt

report() {   # $1=名称  $2=python 退出码  $3=swift 退出码
    if diff -q "$A" "$B" >/dev/null 2>&1 && [ "$2" = "$3" ]; then
        printf "  ✅ %-30s %3d 行  退出码 %s\n" "$1" "$(wc -l < "$A")" "$2"
        pass=$((pass + 1))
    else
        printf "  ❌ %-30s\n" "$1"
        echo "     python 退出码 $2 ／ swift 退出码 $3"
        diff "$A" "$B" 2>&1 | head -16 | sed 's/^/     /'
        fail=$((fail + 1))
    fi
}

# $1=名称  $2=环境变量串（可空）  $3...=参数
run_pair() {
    local name="$1" envs="$2"; shift 2
    local ra rb
    if [ -n "$envs" ]; then
        env $envs "$PY" "$REPO/scripts/dockgroup.py" "$@" > "$A" 2>&1; ra=$?
        env $envs "$SW" "$@" > "$B" 2>&1; rb=$?
    else
        "$PY" "$REPO/scripts/dockgroup.py" "$@" > "$A" 2>&1; ra=$?
        "$SW" "$@" > "$B" 2>&1; rb=$?
    fi
    report "$name" "$ra" "$rb"
}

# groups.json 读进来再序列化 —— 配置模块唯一的正确性关卡。
case_config() {
    "$PY" -c "
import io, json, sys
sys.path.insert(0, '$REPO/scripts')
from dockgroup import load_config
buf = io.StringIO()
json.dump(load_config(), buf, ensure_ascii=False, indent=2)
sys.stdout.write(buf.getvalue())
" > "$A" 2>&1
    local ra=$?
    "$SW" __dump-config > "$B" 2>&1
    local rb=$?
    report "config 往返序列化" "$ra" "$rb"
}

setup_stale_home() {
    rm -rf "$TMPHOME"
    mkdir -p "$TMPHOME/.apps/Fake.app/Contents"
    "$PY" -c "
import plistlib
with open('$TMPHOME/.apps/Fake.app/Contents/Info.plist', 'wb') as f:
    plistlib.dump({
        'CFBundleExecutable': 'DockGroupLauncher',
        'CFBundleName': 'Fake',
        'DockGroupScript': '/已移动的仓库/scripts/dockgroup.py',
        'DockGroupFolder': '$TMPHOME/不存在的分组',
    }, f)
"
}

# 有副作用的命令：隔离落盘 + 每轮清空，把生成出来的 groups.json 并进输出一起比。
# $1=名称  $2=环境变量串  $3=预置配置（"" / "existing" / "grouped"）  $4...=参数
run_pair_stateful() {
    local name="$1" envs="$2" preset="$3"; shift 3
    local ra rb out
    for side in a b; do
        rm -rf "$TMPHOME"; mkdir -p "$TMPHOME"
        case "$preset" in
            existing) echo '{"groups": []}' > "$TMPHOME/groups.json" ;;
            grouped)  cat > "$TMPHOME/groups.json" <<'JSON'
{
  "style": "graphite",
  "groups": [
    {
      "name": "测试组",
      "enabled": true,
      "placement": "left",
      "apps": []
    }
  ],
  "material": "hud",
  "layout": "row"
}
JSON
                      ;;
        esac
        if [ "$side" = a ]; then
            env $envs "$PY" "$REPO/scripts/dockgroup.py" "$@" > "$A" 2>&1; ra=$?
            out="$A"
        else
            env $envs "$SW" "$@" > "$B" 2>&1; rb=$?
            out="$B"
        fi
        if [ -f "$TMPHOME/groups.json" ]; then
            echo "── groups.json ──" >> "$out"
            cat "$TMPHOME/groups.json" >> "$out"
        else
            echo "── 没有生成 groups.json ──" >> "$out"
        fi
    done
    report "$name" "$ra" "$rb"
}

# 像素对照：不算逐字节，只看 MAE 够不够小。
pixel_report() {   # $1=名称  $2=参考 png  $3=待测 png
    local mae
    mae=$("$PY" - "$2" "$3" <<'PY'
import sys
from PIL import Image, ImageChops, ImageStat
a = Image.open(sys.argv[1]).convert("RGBA")
b = Image.open(sys.argv[2]).convert("RGBA")
if a.size != b.size:
    print("尺寸不同"); sys.exit(0)
d = ImageChops.difference(a, b)
print(f"{sum(ImageStat.Stat(d).mean[:3]) / 3:.4f}")
PY
)
    if [ "$mae" = "尺寸不同" ] || [ -z "$mae" ]; then
        printf "  ❌ %-30s %s\n" "$1" "${mae:-读取失败}"
        fail=$((fail + 1))
        return
    fi
    if "$PY" -c "import sys; sys.exit(0 if float('$mae') < $PIXEL_MAX else 1)"; then
        printf "  ✅ %-30s MAE %.4f / 255\n" "$1" "$mae"
        pass=$((pass + 1))
    else
        printf "  ❌ %-30s MAE %s（阈值 ${PIXEL_MAX}）\n" "$1" "$mae"
        fail=$((fail + 1))
    fi
}

# 图像合成：固定输入图标，把 app_icons 那层的变量隔离掉
case_mosaic() {
    local style="$1"
    local i1="$ICONS/App Store-1786589515.png" i2="$ICONS/Calculator-1786589515.png"
    local i3="$ICONS/DSH Desktop-1789270360.png" i4="$ICONS/Mail-1786589515.png"
    for f in "$i1" "$i2" "$i3" "$i4"; do
        [ -f "$f" ] || { printf "  ·  %-30s 跳过（测试图标不存在）\n" "mosaic $style"; return; }
    done
    "$PY" -c "
import sys; sys.path.insert(0, '$REPO/scripts')
from dockgroup import make_mosaic
make_mosaic(['$i1','$i2','$i3','$i4'], '$PX-ref.png', style='$style')
"
    "$SW" __make-mosaic "$style" 1024 "$PX-sw.png" "$i1" "$i2" "$i3" "$i4" >/dev/null
    pixel_report "mosaic：$style" "$PX-ref.png" "$PX-sw.png"
}

# 图标提取：Python 走 JXA，Swift 直接调 NSWorkspace
case_grab() {
    local apps=(/System/Applications/Calculator.app /System/Applications/Notes.app)
    for a in "${apps[@]}"; do [ -d "$a" ] || { echo "  ·  跳过图标提取（测试 App 不存在）"; return; }; done
    # ⚠️ 两边必须用**各自的** DOCKGROUP_HOME：否则第二遍会命中第一遍写下的缓存、
    # 直接复用同一个 PNG，MAE 恒为 0 —— 看着全绿，其实压根没测到提取逻辑。
    rm -rf "$PX"; mkdir -p "$PX/py" "$PX/sw"
    DOCKGROUP_HOME="$PX/home-py" "$PY" -c "
import shutil, sys
sys.path.insert(0, '$REPO/scripts')
from pathlib import Path
from dockgroup import app_icons
apps = [Path(p) for p in ['${apps[0]}', '${apps[1]}']]
got = app_icons(apps)
for a in apps:
    p = got.get(a)
    if p: shutil.copy(p, Path('$PX/py') / (a.stem + '.png'))
" >/dev/null 2>&1
    DOCKGROUP_HOME="$PX/home-sw" "$SW" __grab-icons "$PX/sw" "${apps[0]}" "${apps[1]}" >/dev/null 2>&1
    for f in "$PX/py"/*.png; do
        [ -f "$f" ] || continue
        n=$(basename "$f")
        [ -f "$PX/sw/$n" ] && pixel_report "图标提取：$n" "$f" "$PX/sw/$n" \
                           || { printf "  ❌ %-30s Swift 侧没产出\n" "图标提取：$n"; fail=$((fail + 1)); }
    done
}

# .app 构建：两边各构建一次，比对产物。
#
# ⚠️ 不能跑 `dg rebuild` —— 它会 killall Dock，从沙箱里跑会把当前命令连带打死
# （exit 137、零输出）。所以用内部命令 `__build-group`：只构建，不重启 Dock。
#
# ⚠️ Info.plist 里的 CFBundleVersion 必须**归一化掉再比**。它是按内容摘要算的
# （sha256(plist + 图标 + 签名前的二进制)），而两边的图标 PNG 有亚像素差异、
# swiftc 产物还带 LC_UUID 非确定性 —— 版本号注定不同。结构对了才是重点。
case_launcher_app() {
    local T=/tmp/cmpapp
    rm -rf "$T"; mkdir -p "$T/测试组"
    local i1="$ICONS/App Store-1786589515.png" i2="$ICONS/Calculator-1786589515.png"
    for f in "$i1" "$i2"; do
        [ -f "$f" ] || { echo "  ·  .app 构建：跳过（测试图标不存在）"; return; }
    done

    # 输入：分组别名（用 Python 侧建，它是输入不是被测对象）+ 配置
    DOCKGROUP_HOME="$T" "$PY" -c "
import sys; sys.path.insert(0, '$REPO/scripts')
from dockgroup import jxa
jxa('mkalias', '$T/测试组', '/System/Applications/Calculator.app', '/System/Applications/Notes.app')
" >/dev/null 2>&1
    cat > "$T/groups.json" <<'JSON'
{
  "style": "graphite",
  "groups": [{"name": "测试组", "enabled": false, "placement": "left", "apps": []}],
  "material": "hud",
  "layout": "row"
}
JSON

    local PYAPP=/tmp/cmpapp-py SWAPP=/tmp/cmpapp-sw
    rm -rf "$PYAPP" "$SWAPP"; mkdir -p "$PYAPP" "$SWAPP"

    DOCKGROUP_HOME="$T" "$PY" -c "
import sys; sys.path.insert(0, '$REPO/scripts')
from dockgroup import build_launcher_app, load_config, find_group, group_material, group_layout
cfg = load_config(); g = find_group(cfg, '测试组')
build_launcher_app(g, style=cfg.get('style'), material=group_material(cfg, g),
                   layout=group_layout(cfg, g), seed=False)
" >/dev/null 2>&1
    cp -R "$T/.apps/测试组.app" "$PYAPP/" 2>/dev/null
    cp "$T/.cache/测试组.png" "$PYAPP/mosaic.png" 2>/dev/null

    # 清掉产物重来，让 Swift 从零构建（不要命中 Python 留下的缓存）
    rm -rf "$T/.apps" "$T/.cache"
    DOCKGROUP_HOME="$T" "$SW" __build-group 测试组 >/dev/null 2>&1
    cp -R "$T/.apps/测试组.app" "$SWAPP/" 2>/dev/null
    cp "$T/.cache/测试组.png" "$SWAPP/mosaic.png" 2>/dev/null

    # ① Info.plist：抹掉两个版本键后逐字节比
    local norm="$PY -c \"
import re, sys
t = open(sys.argv[1], encoding='utf-8').read()
t = re.sub(r'<key>CFBundleVersion</key>\\\\s*<string>[^<]*</string>', '<key>CFBundleVersion</key><string>X</string>', t)
t = re.sub(r'<key>CFBundleShortVersionString</key>\\\\s*<string>[^<]*</string>', '<key>CFBundleShortVersionString</key><string>X</string>', t)
sys.stdout.write(t)
\""
    eval "$norm \"$PYAPP/测试组.app/Contents/Info.plist\"" > "$A" 2>&1
    eval "$norm \"$SWAPP/测试组.app/Contents/Info.plist\"" > "$B" 2>&1
    report ".app：Info.plist（版本键归一化）" 0 0

    # ② bundle 结构：有哪些文件
    (cd "$PYAPP/测试组.app" && find . -type f | sort) > "$A" 2>&1
    (cd "$SWAPP/测试组.app" && find . -type f | sort) > "$B" 2>&1
    report ".app：bundle 结构" 0 0

    # ③ 合成图标：比像素
    [ -f "$PYAPP/mosaic.png" ] && [ -f "$SWAPP/mosaic.png" ] \
        && pixel_report ".app：合成图标" "$PYAPP/mosaic.png" "$SWAPP/mosaic.png" \
        || { printf "  ❌ %-30s 有产物缺失\n" ".app：合成图标"; fail=$((fail + 1)); }

    rm -rf "$T" "$PYAPP" "$SWAPP"
}

# Dock 写入：拿一份固定的 Dock 配置样本当输入，两边各写一次，比**写出的字节**。
#
# 这是整个工具里唯一会改用户 Dock 的地方，也是最该被测死的一段。靠
# DOCKGROUP_DOCK_PLIST 把落盘目标换成临时文件 —— 否则两套实现会先后把用户的 Dock
# 真改掉两次，而 killall Dock 还会把当前命令连带打死（exit 137、零输出）。
#
# 样本（tools/dock_fixture.py）刻意覆盖了自动落位 / 剔除已折叠成员 / 清掉同名旧图标 /
# 右侧区过滤 / 兜底追加五条分支 —— 只测 happy path 的话这些一条都跑不到。
case_dock_sync() {
    local extra="$1"
    local label="dock sync"
    local prune="True"
    if [ -n "$extra" ]; then label="dock sync $extra"; prune="False"; fi

    local T=/tmp/cmpdock
    rm -rf "$T"; mkdir -p "$T"
    DOCKGROUP_HOME="$T/home" "$PY" "$REPO/tools/dock_fixture.py" "$T" "$T/home" >/dev/null 2>&1
    if [ ! -f "$T/dock.plist" ]; then
        printf "  ·  %-30s 跳过（样本生成失败）\n" "$label"
        return
    fi
    cp "$T/dock.plist" "$T/py.plist"; cp "$T/dock.plist" "$T/sw.plist"

    # ⚠️ 两边必须用**同一个** DOCKGROUP_HOME：写出的 tile 里含落盘路径，
    # 目录不同就没法逐字节比了。要隔离的是 Dock 配置的输出文件，不是 home。
    PYPRUNE="$prune" DOCKGROUP_HOME="$T/home" DOCKGROUP_DOCK_PLIST="$T/py.plist" \
        "$PY" -c "
import os, sys
sys.path.insert(0, '$REPO/scripts')
from dockgroup import load_config, dock_sync
dock_sync(load_config(), only=None, prune=os.environ['PYPRUNE'] == 'True')
" > "$A" 2>&1
    local ra=$?
    DOCKGROUP_HOME="$T/home" DOCKGROUP_DOCK_PLIST="$T/sw.plist" \
        "$SW" __dock-sync $extra > "$B" 2>&1
    local rb=$?

    if cmp -s "$T/py.plist" "$T/sw.plist"; then
        printf "  ✅ %-30s %6d 字节  退出码 %s\n" "$label" \
               "$(wc -c < "$T/py.plist" | tr -d ' ')" "$ra"
        pass=$((pass + 1))
    else
        printf "  ❌ %-30s\n" "$label"
        echo "     python 退出码 $ra ／ swift 退出码 $rb"
        diff "$T/py.plist" "$T/sw.plist" 2>&1 | head -20 | sed 's/^/     /'
        fail=$((fail + 1))
    fi
    rm -rf "$T"
}

# rebuild：走完整的 refresh_groups（含逐分组构建 + 「跳过失败分组」那条路）。
# 靠 DOCKGROUP_DOCK_PLIST 关掉 killall，否则从沙箱里跑会把当前命令打死。
case_rebuild() {
    local T=/tmp/cmprebuild
    rm -rf "$T"; mkdir -p "$T/测试组"
    DOCKGROUP_HOME="$T" "$PY" -c "
import sys; sys.path.insert(0, '$REPO/scripts')
from dockgroup import jxa
jxa('mkalias', '$T/测试组', '/System/Applications/Calculator.app')
" >/dev/null 2>&1
    cat > "$T/groups.json" <<'JSON'
{
  "style": "graphite",
  "groups": [
    {
      "name": "测试组",
      "enabled": true,
      "placement": "left",
      "apps": []
    }
  ],
  "material": "hud",
  "layout": "row"
}
JSON
    local ra rb
    rm -rf "$T/.cache" "$T/.apps"
    DOCKGROUP_HOME="$T" "$PY" "$REPO/scripts/dockgroup.py" rebuild > "$A" 2>&1; ra=$?
    rm -rf "$T/.cache" "$T/.apps"
    DOCKGROUP_HOME="$T" "$SW" rebuild > "$B" 2>&1; rb=$?
    report "rebuild" "$ra" "$rb"
    rm -rf "$T"
}


echo "Python ⇄ Swift 对照"
echo "── 文本输出：正常路径 ──"
run_pair "list" "" list
run_pair "doctor" "" doctor
run_pair "style（列材质）" "" style
run_pair "layout（列布局与宫格预览）" "" layout
case_config

echo
echo "── 文本输出：异常分支 ──"
setup_stale_home
run_pair "doctor：产物路径失效" "DOCKGROUP_HOME=$TMPHOME" doctor
run_pair "doctor：PATH 里什么都没有" "PATH=/nonexistent" doctor
rm -rf "$TMPHOME"

echo
echo "── 有副作用的命令（隔离落盘 + 比对生成的文件）──"
run_pair_stateful "init" "DOCKGROUP_HOME=$TMPHOME" "" init
run_pair_stateful "init：配置已存在" "DOCKGROUP_HOME=$TMPHOME" "existing" init
run_pair_stateful "init --force：覆盖" "DOCKGROUP_HOME=$TMPHOME" "existing" init --force
STYLE_ENV="DOCKGROUP_HOME=$TMPHOME DOCKGROUP_DOCK_PLIST=$TMPHOME/dock.plist"
# ⚠️ `dg style` 管的是**面板材质**（MATERIALS），不是图标风格（graphite / paper / …）。
# 这两个东西在配置里都叫 "style"，很容易写错 —— 用 "paper" 会走进「没有这个材质」
# 那条分支，看着是绿的，其实测的是错误路径。
run_pair_stateful "style 测试组 popover" "$STYLE_ENV" "grouped" style 测试组 popover
run_pair_stateful "style 测试组 default" "$STYLE_ENV" "grouped" style 测试组 default
run_pair_stateful "style --all menu" "$STYLE_ENV" "grouped" style --all menu
run_pair_stateful "layout --all dock-grid" "$STYLE_ENV" "grouped" layout --all dock-grid
run_pair_stateful "layout 不存在组" "$STYLE_ENV" "grouped" layout 没有这个组 auto
run_pair_stateful "style 不存在的材质" "$STYLE_ENV" "grouped" style 测试组 没有这个材质
rm -rf "$TMPHOME"

echo
echo "── Dock 写入（比写出的配置字节，不碰真 Dock）──"
case_dock_sync ""
case_dock_sync "--keep-originals"

echo
echo "── 像素对照（阈值 MAE < ${PIXEL_MAX}）──"
rm -rf "$PX"; mkdir -p "$PX"
case_mosaic graphite
case_mosaic paper
case_mosaic glass-dark
case_grab
rm -rf "$PX"

echo
echo "── .app 构建（用 __build-group，不触发 killall Dock）──"
case_launcher_app

echo
echo "── rebuild（完整 refresh_groups，killall 已由测试开关关掉）──"
case_rebuild

echo
if [ "$fail" -eq 0 ]; then
    echo "  ✨ 全部通过（$pass 项）"
else
    echo "  ⚠️  $fail 项不一致，$pass 项通过"
    exit 1
fi
