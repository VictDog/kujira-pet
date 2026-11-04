#!/bin/bash
# 把 Sources + Resources 打成一个可直接双击运行的 .app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/Kujira 桌宠.app"
BIN="DSH-Pet"

echo "==> 编译 Swift"
rm -rf "$ROOT/.build"
mkdir -p "$ROOT/.build"

# 有 Apple Silicon 也有 Intel：分别编译再 lipo 成通用二进制。
# 某一架构编不出来（比如 SDK 缺片）就退化成单架构，不中断构建。
build_slice() {
    swiftc -O -swift-version 5 -target "$1-apple-macos13.0" \
        "$ROOT"/Sources/*.swift -o "$ROOT/.build/$BIN-$2"
}

if build_slice arm64 arm64; then
    SLICES=("$ROOT/.build/$BIN-arm64")
    if build_slice x86_64 x86_64; then
        SLICES+=("$ROOT/.build/$BIN-x86_64")
    else
        echo "    Intel 切片编译失败，只产出 arm64"
    fi
    if [ ${#SLICES[@]} -gt 1 ]; then
        lipo -create "${SLICES[@]}" -output "$ROOT/.build/$BIN"
    else
        cp "${SLICES[0]}" "$ROOT/.build/$BIN"
    fi
else
    echo "    arm64 编译失败，重试本机默认架构"
    swiftc -O -swift-version 5 "$ROOT"/Sources/*.swift -o "$ROOT/.build/$BIN"
fi
lipo -archs "$ROOT/.build/$BIN" | awk '{print "    架构 "$0}'

echo "==> 编译角色生成工具"
swiftc -O -swift-version 5 "$ROOT/Tools/makechar.swift" -o "$ROOT/Tools/makechar" 2>/dev/null \
    && echo "    Tools/makechar 就绪" \
    || echo "    makechar 编译失败（不影响 App 运行）"

echo "==> 组装 App Bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/$BIN" "$APP/Contents/MacOS/$BIN"
cp "$ROOT/Resources/click-duck.wav" "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/characters" "$APP/Contents/Resources/characters"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

echo "==> 本地签名"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
    && echo "    已 ad-hoc 签名" \
    || echo "    签名失败（不影响本机运行）"

echo "==> 完成：$APP"
du -sh "$APP" | awk '{print "    体积 "$1}'
