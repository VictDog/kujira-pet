#!/bin/bash
# 一张图换一个角色：生成整套动画包并装到「更换角色」列表里。
#
#   ./Tools/new-character.sh <图片路径> <包名> [显示名]
#
# 例：
#   ./Tools/new-character.sh ~/Downloads/cat.png cat "小猫"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HOME/Library/Application Support/DSH桌宠/characters"

if [ $# -lt 2 ]; then
    echo "用法: $0 <图片路径> <包名> [显示名]"
    echo "  包名用英文/数字，显示名随便写中文"
    exit 1
fi

IMG="$1"
ID="$2"
TITLE="${3:-$2}"

if [ ! -f "$IMG" ]; then
    echo "找不到图片: $IMG"
    exit 1
fi

if [ ! -x "$ROOT/Tools/makechar" ]; then
    echo "==> 先编译生成工具"
    swiftc -O -swift-version 5 "$ROOT/Tools/makechar.swift" -o "$ROOT/Tools/makechar"
fi

echo "==> 生成角色包 $ID"
"$ROOT/Tools/makechar" "$IMG" "$ID" "$DEST"

printf '%s\n' "$TITLE" > "$DEST/$ID/title.txt"

echo ""
echo "完成。右键桌宠 → 更换角色 → 「$TITLE」即可切换。"
echo "包目录: $DEST/$ID"
