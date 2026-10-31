#!/bin/zsh
# Builds ThaiTab and wraps it as build/ThaiTab.app (ad-hoc signed).
set -e
cd "$(dirname "$0")"
swift build -c release 2>&1 | tail -1
APP="build/ThaiTab.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ThaiTab "$APP/Contents/MacOS/ThaiTab"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature with an identifier-based designated requirement, so the Accessibility
# grant survives rebuilds (the default cdhash requirement changes on every build).
codesign --force --sign - --identifier com.jeen.thaitab \
  --requirements '=designated => identifier "com.jeen.thaitab"' "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign -d -r- "$APP" 2>&1 | grep designated
echo "Built $APP"
