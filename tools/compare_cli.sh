#!/bin/bash
# Python 版 ⇄ Swift 版 输出对照测试。
#
# 迁移期的一致性保证：同一个命令分别跑两套实现，逐行 diff。
# 这是「绞杀者模式」里唯一的正确性关卡 —— 靠肉眼看输出会漏掉一个空格的差别，
# 而空格恰恰最容易出问题：f-string 的 `{:<10}` 是按**字符数**补位、
# print 的换行次数、中文名在补位时算几个位置。
#
# 用法：
#   tools/compare_cli.sh          # 跑全部已登记项
#   tools/compare_cli.sh list     # 只跑指定项（预留）

set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
PY=/usr/bin/python3
SW="$REPO/build/dg-swift"

if [ ! -x "$SW" ]; then
    echo "还没编译，先跑：swift/build.sh" >&2
    exit 1
fi

pass=0
fail=0
A=/tmp/cmpcli-a.txt
B=/tmp/cmpcli-b.txt

report() {   # $1=名称  $2=python 退出码  $3=swift 退出码
    local name="$1" left="$2" right="$3"
    if diff -q "$A" "$B" >/dev/null 2>&1 && [ "$left" = "$right" ]; then
        printf "  ✅ %-24s %3d 行  退出码 %s\n" "$name" "$(wc -l < "$A")" "$left"
        pass=$((pass + 1))
    else
        printf "  ❌ %-24s\n" "$name"
        echo "     python 退出码 $left ／ swift 退出码 $right"
        diff "$A" "$B" 2>&1 | head -14 | sed 's/^/     /'
        fail=$((fail + 1))
    fi
}

# 同一个子命令，两套实现各跑一遍
case_cli() {
    local name="$1"; shift
    "$PY" "$REPO/scripts/dockgroup.py" "$@" > "$A" 2>&1
    local ra=$?
    "$SW" "$@" > "$B" 2>&1
    local rb=$?
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

echo "Python ⇄ Swift 输出对照"
echo
case_cli "list" list
case_config
echo
if [ "$fail" -eq 0 ]; then
    echo "  ✨ 全部通过（$pass 项）"
else
    echo "  ⚠️  $fail 项不一致，$pass 项通过"
    exit 1
fi
