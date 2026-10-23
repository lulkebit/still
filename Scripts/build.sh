#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDITOR_DIR="$ROOT_DIR/Editor"
EDITOR_OUTPUT="$ROOT_DIR/Sources/Still/Resources/Editor/editor.js"
APP_PATH="$ROOT_DIR/build/still.app"

editor_needs_build=false
if [[ ! -s "$EDITOR_OUTPUT" ]]; then
  editor_needs_build=true
else
  while IFS= read -r source_file; do
    if [[ "$source_file" -nt "$EDITOR_OUTPUT" ]]; then
      editor_needs_build=true
      break
    fi
  done < <(find "$EDITOR_DIR/src" -type f -print; printf '%s\n' "$EDITOR_DIR/package.json" "$EDITOR_DIR/package-lock.json" "$EDITOR_DIR/build.mjs")
fi

if [[ "$editor_needs_build" == true ]]; then
  if [[ ! -d "$EDITOR_DIR/node_modules" ]]; then
    (cd "$EDITOR_DIR" && npm ci)
  fi
  (cd "$EDITOR_DIR" && npm run build)
fi

cd "$ROOT_DIR"
swift build -c release
BIN_DIR="$(swift build --show-bin-path -c release)"
RESOURCE_BUNDLE="$BIN_DIR/Still_Still.bundle"
if [[ ! -d "$RESOURCE_BUNDLE/Contents/Resources/Editor" ]]; then
  echo "Missing bundled Editor resources: $RESOURCE_BUNDLE/Contents/Resources/Editor" >&2
  exit 1
fi

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/still" "$APP_PATH/Contents/MacOS/still"
cp -R "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/Still_Still.bundle"

ICONSET_DIR="$ROOT_DIR/build/still.iconset"
swift "$ROOT_DIR/Scripts/make_icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$APP_PATH/Contents/Resources/still.icns"
rm -rf "$ICONSET_DIR"

cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>CFBundleDisplayName</key><string>still.</string>
  <key>CFBundleExecutable</key><string>still</string>
  <key>CFBundleIconFile</key><string>still</string>
  <key>CFBundleIdentifier</key><string>com.still.notes</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>still.</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_PATH"
echo "$APP_PATH"
