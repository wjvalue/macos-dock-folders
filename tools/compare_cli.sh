#!/bin/bash
# Python 版 ⇄ Swift 版 输出对照测试。
#
# 迁移期的一致性保证：同一个命令分别跑两套实现，逐行 diff。
# 这是「绞杀者模式」里唯一的正确性关卡 —— 靠肉眼看输出会漏掉一个空格的差别，
# 而空格恰恰最容易出问题：f-string 的 `{:<10}` 是按**字符数**补位、
# print 的换行次数、中文名在补位时算几个位置。
#
# 覆盖两类场景：
#   · 正常路径 —— 每个已搬迁的命令跑一遍
#   · 异常分支 —— doctor 的「依赖缺失」「产物路径失效」在正常环境下根本跑不到。
#     只测正常路径的话，这些分支里的输出差异永远发现不了（而它们恰恰是
#     dg doctor 存在的意义，出事时用户看到的就是这些行）。
#
# 用法：
#   tools/compare_cli.sh

set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
PY=/usr/bin/python3
SW="$REPO/build/dg-swift"
TMPHOME=/tmp/cmpcli-home

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
        diff "$A" "$B" 2>&1 | head -14 | sed 's/^/     /'
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
# 格式一旦漂了，groups.json 的 diff 里就全是噪音（2026-09-20 实际踩过）。
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

# 造一个「产物路径失效」的场景：隔离的 DOCKGROUP_HOME + 一个 Info.plist
# 指向不存在路径的 .app。doctor 全靠这种场景才有意义。
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

echo "Python ⇄ Swift 输出对照"
echo "── 正常路径 ──"
run_pair "list" "" list
run_pair "doctor" "" doctor
case_config

echo
echo "── 异常分支 ──"
setup_stale_home
run_pair "doctor：产物路径失效" "DOCKGROUP_HOME=$TMPHOME" doctor
run_pair "doctor：PATH 里什么都没有" "PATH=/nonexistent" doctor
rm -rf "$TMPHOME"

echo
if [ "$fail" -eq 0 ]; then
    echo "  ✨ 全部通过（$pass 项）"
else
    echo "  ⚠️  $fail 项不一致，$pass 项通过"
    exit 1
fi
