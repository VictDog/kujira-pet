#!/bin/bash
# 打一个可以直接拖进 GitHub Releases 的 zip
#
#   ./Tools/release.sh 1.1.0
#
# 流程：编译 → 打包 → 打印体积、架构、SHA-256 和 gh 上传命令。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"

if [ -z "$VERSION" ]; then
    echo "用法: $0 <版本号，例如 1.1.0>"
    exit 1
fi

APP="$ROOT/Kujira 桌宠.app"
ZIP="$ROOT/dist/Kujira-$VERSION-macOS-universal.zip"

cd "$ROOT"
./build.sh

EXEC=$(/usr/libexec/PlistBuddy -c "Print CFBundleExecutable" "$APP/Contents/Info.plist")
mkdir -p "$ROOT/dist"
rm -f "$ZIP"

# 必须用 ditto：用 zip 命令会把 .app 里的符号链接和权限拍平，解压后签名就废了
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo
echo "产物    $ZIP"
ls -lh "$ZIP" | awk '{print "体积    "$5}'
echo "架构    $(lipo -archs "$APP/Contents/MacOS/$EXEC")"
printf "SHA-256 "; shasum -a 256 "$ZIP" | awk '{print $1}'
echo
echo "上传（装了 gh 且已登录）："
echo "  gh release create v$VERSION \"$ZIP\" \\"
echo "    --title \"Kujira $VERSION\" \\"
echo "    --notes-file docs/release-notes-v$VERSION.md"
echo
echo "没装 gh 就走网页：仓库 → Releases → Draft a new release → 选 tag v$VERSION → 把这行路径的文件拖进去"
