#!/bin/zsh
# Builds LazyBoard and wraps it as build/LazyBoard.app (ad-hoc signed).
set -e
cd "$(dirname "$0")"
swift build -c release 2>&1 | tail -1
APP="build/LazyBoard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LazyBoard "$APP/Contents/MacOS/LazyBoard"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature with an identifier-based designated requirement, so the Accessibility
# grant survives rebuilds (the default cdhash requirement changes on every build).
codesign --force --sign - --identifier com.jeancharairat.lazyboard \
  --requirements '=designated => identifier "com.jeancharairat.lazyboard"' "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign -d -r- "$APP" 2>&1 | grep designated
echo "Built $APP"
