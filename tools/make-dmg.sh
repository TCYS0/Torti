#!/bin/bash
# 把已构建好的 Torti.app 封成可分发的 DMG（拖拽安装式）
#
#   tools/make-dmg.sh            # 版本号取自 Resources/Info.plist
#   tools/make-dmg.sh 1.2.0      # 显式指定版本号（CI 里用 git tag）
#
# 产物：dist/Torti-<版本>.dmg（含 .app + Applications 软链接）与同名 .sha256
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Torti"
PLIST="$PROJECT_DIR/Resources/Info.plist"
APP_DIR="$PROJECT_DIR/$APP_NAME.app"
DIST_DIR="$PROJECT_DIR/dist"

read_plist() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || echo ""
}

VERSION="${1:-$(read_plist CFBundleShortVersionString)}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="$(read_plist CFBundleVersion)"

if [[ ! -d "$APP_DIR" ]]; then
  echo "✗ 没找到 $APP_NAME.app，请先跑 ./build.sh"
  exit 1
fi

DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
mkdir -p "$DIST_DIR"
rm -f "$DMG" "$DMG.sha256"

# --- 暂存目录：.app + 指向 /Applications 的软链接（用户拖过去就是安装） ---
STAGE="$(mktemp -d "/tmp/torti-dmg.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

# 用 ditto 而不是 cp -R：保留扩展属性与资源分叉，签名不会被打断
ditto "$APP_DIR" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

echo "▶ 生成 DMG（版本 ${VERSION} / build ${BUILD_NUMBER}）..."
# UDZO = 压缩只读镜像，体积最小；HFS+ 兼容性最好（老系统也能挂）
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov -quiet \
  "$DMG"

# --- 可选：Developer ID 签名 + 公证 ---
# 没有付费开发者账号时跳过，用户首次打开需右键「打开」（见 README）。
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -n "$IDENTITY" && "$IDENTITY" == Developer\ ID\ Application* ]]; then
  echo "▶ 用 Developer ID 重签 ..."
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$STAGE/$APP_NAME.app"
  if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
    echo "▶ 提交 Apple 公证（约 1-3 分钟）..."
    xcrun notarytool submit "$DMG" \
      --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" \
      --wait
    xcrun stapler staple "$DMG"
    echo "✓ 公证已完成并盖章"
  else
    echo "（未提供 APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD，跳过公证）"
  fi
else
  echo "（ad-hoc 签名：他人首次打开需右键 →「打开」，或执行 README 里的 xattr 命令）"
fi

# 校验文件：发布页附上，下载后可自行核对
( cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "✓ 完成: ${DMG}（${SIZE}）"
echo "  校验: $(cat "$DMG.sha256")"
