#!/bin/bash
# 编译 → 打包 .app → 封成可分发的 DMG
#
#   ./build.sh               # 出 Torti.app + dist/Torti-<版本>.dmg（可直接发人/挂 Release）
#   ./build.sh --app-only    # 只出 app，不封 dmg（本地调试用，快一点）
set -euo pipefail

cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"
APP_NAME="Torti"
APP_DIR="$PROJECT_DIR/$APP_NAME.app"

MAKE_DMG=1
[[ "${1:-}" == "--app-only" ]] && MAKE_DMG=0

echo "▶ 编译 release（arm64 + x86_64 通用二进制）..."
# 双 --arch 让 SwiftPM 编译后 lipo 成 universal，Intel Mac 也能跑；
# 产物落在 .build/apple/Products/Release/，不再是 .build/release/
swift build -c release --disable-sandbox --arch arm64 --arch x86_64 2>&1 | tail -20

BIN="$PROJECT_DIR/.build/apple/Products/Release/Torti"
[[ -f "$BIN" ]] || BIN="$PROJECT_DIR/.build/release/Torti"
if [[ ! -f "$BIN" ]]; then
  echo "✗ 未找到编译产物: $BIN"
  exit 1
fi

echo "▶ 组装 $APP_DIR ..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/Torti"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# 图标缺失时也重新生成一次（tools/gen-icon.swift 是矢量绘制，不需要额外依赖）
if [[ ! -f "$PROJECT_DIR/Resources/AppIcon.icns" ]]; then
  echo "▶ 生成图标 ..."
  swiftc -O -parse-as-library "$PROJECT_DIR/tools/gen-icon.swift" -o /tmp/gen-icon \
    && /tmp/gen-icon /tmp/TortiIcon.iconset \
    && iconutil -c icns /tmp/TortiIcon.iconset -o "$PROJECT_DIR/Resources/AppIcon.icns"
fi
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
chmod +x "$APP_DIR/Contents/MacOS/Torti"

codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || echo "（跳过签名）"

echo "✓ 完成: $APP_DIR"

if [[ $MAKE_DMG -eq 1 ]]; then
  chmod +x "$PROJECT_DIR/tools/make-dmg.sh"
  "$PROJECT_DIR/tools/make-dmg.sh"
fi

echo "  运行: open \"$APP_DIR\""
