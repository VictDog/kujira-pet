#!/bin/bash
# 一张图换一个角色：生成整套动画包并装到「更换角色」列表里。
#
#   ./Tools/new-character.sh <图片路径> <包名> [显示名]
#
# 例：
#   ./Tools/new-character.sh ~/Downloads/cat.png cat "小猫"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 默认装到外置角色目录；设 KUJIRA_DEST 可以改目标（自检 / CI 用）。
DEST="${KUJIRA_DEST:-$HOME/Library/Application Support/DSH桌宠/characters}"

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

# 生成服务常给白底图 + 角落水印。没有 alpha 通道就先泛洪抠掉纯色背景：
# 浅色水印与白底连通，会被一起清掉，不用再手动裁边。
# 绿幕 / 蓝幕请先用 Tools/keyout.swift --mode green|blue 转成透明图再传进来。
IMG_USE="$IMG"
if ! sips -g hasAlpha "$IMG" 2>/dev/null | grep -q "hasAlpha: yes"; then
    mkdir -p "$ROOT/.build"
    KEYOUT="$ROOT/.build/keyout"
    if [ ! -x "$KEYOUT" ]; then
        echo "==> 先编译抠图工具"
        swiftc -O -swift-version 5 "$ROOT/Tools/keyout.swift" -o "$KEYOUT"
    fi
    CLEAN="$(mktemp -d)/clean.png"
    echo "==> 图片没有透明通道，先抠掉白底与水印"
    "$KEYOUT" "$IMG" "$CLEAN" --mode white --tol 30 --floor 228
    IMG_USE="$CLEAN"
fi

echo "==> 生成角色包 $ID"
"$ROOT/Tools/makechar" "$IMG_USE" "$ID" "$DEST"

printf '%s\n' "$TITLE" > "$DEST/$ID/title.txt"

echo ""
echo "完成。右键桌宠 → 更换角色 → 「${TITLE}」即可切换。"
echo "包目录: $DEST/$ID"
