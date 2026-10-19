#!/bin/zsh
set -euo pipefail
umask 022

PROJECT_ROOT="${0:A:h:h}"
APP_PATH="$PROJECT_ROOT/build/Codex Monitor.app"
APP_PLIST="$APP_PATH/Contents/Info.plist"
APP_BINARY="$APP_PATH/Contents/MacOS/CodexMonitor"
DIST_PATH="$PROJECT_ROOT/dist"

fail() {
  print -u2 -- "Release packaging failed: $*"
  exit 1
}

[[ -f "$APP_PLIST" && -x "$APP_BINARY" ]] || fail "Run ./build.sh first."
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST")
SOURCE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_ROOT/Info.plist")
[[ "$APP_VERSION" == "$SOURCE_VERSION" ]] || fail "The app version differs from Info.plist; rebuild the app."
[[ "$APP_VERSION" =~ '^[0-9]+(\.[0-9]+){1,3}(-[A-Za-z0-9][A-Za-z0-9.-]*)?$' ]] || fail "Invalid release version: $APP_VERSION"

# A native-only build must never be published with a universal filename.
/usr/bin/lipo "$APP_BINARY" -verify_arch arm64 x86_64 || fail "A universal arm64 + x86_64 app is required."
/usr/bin/codesign --verify --deep --strict "$APP_PATH" || fail "The app signature is invalid."
"$APP_BINARY" --self-test || fail "The app self-tests did not pass."

mkdir -p "$PROJECT_ROOT/build" "$DIST_PATH"
STAGING_PATH=$(/usr/bin/mktemp -d "$PROJECT_ROOT/build/release.XXXXXX")
cleanup() {
  # Only remove the private directory returned by mktemp above.
  [[ -n "${STAGING_PATH:-}" && -d "$STAGING_PATH" ]] && /bin/rm -rf -- "$STAGING_PATH"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

IMAGE_ROOT="$STAGING_PATH/image"
DMG_NAME="Codex-Monitor-${APP_VERSION}-universal.dmg"
mkdir "$IMAGE_ROOT"
/usr/bin/ditto "$APP_PATH" "$IMAGE_ROOT/Codex Monitor.app"
/bin/ln -s /Applications "$IMAGE_ROOT/Applications"
/bin/cat > "$IMAGE_ROOT/安装说明.txt" <<'INSTALL'
Codex Monitor 安装说明

1. 将 Codex Monitor.app 拖到旁边的 Applications（应用程序）文件夹。
2. 从“应用程序”打开 Codex Monitor。
3. 将浮窗拖到 Codex 宠物旁。菜单栏中的波形图标可显示、隐藏或退出面板。

要求：macOS 13 或更新版本；支持 Apple Silicon 和 Intel Mac。
周额度需要本机安装 Codex 并登录可查询额度的账户。
系统资源每秒更新，周额度每分钟更新；重置时间按北京时间显示。

这是独立的第三方工具，与 OpenAI 没有官方关联。
当前版本使用本地 ad-hoc 签名，尚未使用 Apple Developer ID 签名或公证。
首次打开时，macOS 可能要求你在“隐私与安全性”中明确确认。
请核对下载来源和发布页提供的 SHA256 校验值，再决定是否打开。
INSTALL
/usr/bin/codesign --verify --deep --strict "$IMAGE_ROOT/Codex Monitor.app"

# Keep the output outside IMAGE_ROOT so it cannot include itself.
/usr/bin/hdiutil create -volname 'Codex Monitor' -srcfolder "$IMAGE_ROOT" \
  -format UDZO -imagekey zlib-level=9 "$STAGING_PATH/$DMG_NAME"
/usr/bin/hdiutil verify "$STAGING_PATH/$DMG_NAME"
(cd "$STAGING_PATH" && /usr/bin/shasum -a 256 "$DMG_NAME" > SHA256SUMS.txt)

# Publish only the two generated artifacts after all validation has succeeded.
/bin/mv -f "$STAGING_PATH/$DMG_NAME" "$DIST_PATH/$DMG_NAME"
/bin/mv -f "$STAGING_PATH/SHA256SUMS.txt" "$DIST_PATH/SHA256SUMS.txt"
print -- "Packaged: $DIST_PATH/$DMG_NAME"
print -- "Checksum: $DIST_PATH/SHA256SUMS.txt"
