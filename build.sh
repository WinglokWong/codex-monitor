#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
monitor_app="$PWD/build/Codex Monitor.app"
mkdir -p build/module-cache build/binaries "$monitor_app/Contents/MacOS" "$monitor_app/Contents/Resources"
if [[ ! -f Assets/AppIcon.icns ]]; then
  print -u2 'Missing Assets/AppIcon.icns. Generate it with scripts/generate-icon.swift.'
  exit 1
fi
for monitor_arch in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -O -whole-module-optimization \
    -target "${monitor_arch}-apple-macosx13.0" -module-cache-path "$PWD/build/module-cache" \
    Sources/*.swift -o "build/binaries/CodexMonitor-${monitor_arch}" \
    -framework AppKit -framework SwiftUI -framework SystemConfiguration
done
xcrun lipo -create build/binaries/CodexMonitor-arm64 build/binaries/CodexMonitor-x86_64 \
  -output "$monitor_app/Contents/MacOS/CodexMonitor"
cp Info.plist "$monitor_app/Contents/Info.plist"
cp Assets/AppIcon.icns "$monitor_app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$monitor_app" >/dev/null
codesign --verify --deep --strict "$monitor_app"
print 'Built Release: build/Codex Monitor.app (Universal: Apple Silicon + Intel)'
