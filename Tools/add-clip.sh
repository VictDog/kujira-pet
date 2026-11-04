#!/bin/bash
# 给角色包加一段「真实视频」动作，并自动更新 catalog.json。
#
#   ./Tools/add-clip.sh <视频/GIF> <包名> <动作名> [额外参数…]
#
# 例：
#   ./Tools/add-clip.sh ~/Downloads/wave.mp4 shiba "点击回应-挥手"
#   ./Tools/add-clip.sh ~/Downloads/walk.mov shiba "走路" --fill loop
#
# 素材要求（越接近越省事）：
#   · 角色全身在画面里，不要被切掉
#   · 背景是纯色（绿幕最佳）；不是纯色就加 --matte 用系统主体抠图
#   · 不要有地面阴影
#
# 生成服务（豆包/即梦/Sora 等）一般会在角上压水印，默认已经抹掉左上角那块；
# 水印在别的位置就传 --clear x0,y0,x1,y1（0-1 归一化）自己指定。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HOME/Library/Application Support/DSH桌宠/characters"

if [ $# -lt 3 ]; then
    echo "用法: $0 <视频/GIF> <包名> <动作名> [额外参数…]"
    echo "  动作名决定分类：待机* / 点击* / 睡* / 走* / 转身* / 拖* / 其它"
    exit 1
fi

SRC="$1"; ID="$2"; NAME="$3"; shift 3

if [ ! -e "$SRC" ]; then
    echo "找不到素材: $SRC"
    exit 1
fi

if [ ! -x "$ROOT/Tools/makeclip" ]; then
    echo "==> 先编译转换工具"
    swiftc -O -swift-version 5 "$ROOT/Tools/makeclip.swift" -o "$ROOT/Tools/makeclip"
fi

PACK="$DEST/$ID"
mkdir -p "$PACK/animations"

# 没有指定 --key / --matte 时默认自动判色
has_key=0
for a in "$@"; do
    case "$a" in --key|--key=*|--matte) has_key=1 ;; esac
done
if [ "$has_key" = "0" ]; then
    set -- --key auto "$@"
fi

# 没指定水印区域时，默认抹掉左上角
has_clear=0
for a in "$@"; do
    case "$a" in --clear|--clear=*) has_clear=1 ;; esac
done
if [ "$has_clear" = "0" ]; then
    set -- --clear 0,0,0.18,0.07 "$@"
fi

echo "==> $NAME"
"$ROOT/Tools/makeclip" "$SRC" "$PACK" "$NAME" "$@"

python3 "$ROOT/Tools/rebuild-catalog.py" "$PACK"

echo ""
echo "完成。右键桌宠 → 更换角色 → 选「$(cat "$PACK/title.txt" 2>/dev/null || echo "$ID")」，"
echo "如果已经在用这个角色，退出再打开就能看到新动作。"
