#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/still-editor-validation.XXXXXX")"
FIXTURE="$TEST_DIR/project with spaces"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$FIXTURE/Scripts" "$FIXTURE/Editor" "$FIXTURE/Sources/Still/Resources" \
  "$FIXTURE/Vendor/swift-sdk" "$FIXTURE/Vendor/SwiftSoup" "$FIXTURE/Vendor/textual"
cp "$ROOT_DIR/Scripts/build.sh" "$ROOT_DIR/Scripts/validate_editor_bundle.sh" "$FIXTURE/Scripts/"
cp "$ROOT_DIR/Editor/package.json" "$ROOT_DIR/Editor/package-lock.json" "$ROOT_DIR/Editor/build.mjs" "$ROOT_DIR/Editor/bundle.sha256" "$FIXTURE/Editor/"
cp -R "$ROOT_DIR/Editor/src" "$FIXTURE/Editor/src"
cp -R "$ROOT_DIR/Sources/Still/Resources/Editor" "$FIXTURE/Sources/Still/Resources/Editor"
chmod +x "$FIXTURE/Scripts/build.sh" "$FIXTURE/Scripts/validate_editor_bundle.sh"

validator="$FIXTURE/Scripts/validate_editor_bundle.sh"
expect_invalid() {
  local label="$1"
  local stderr_file="$TEST_DIR/$label.stderr"
  if "$validator" > /dev/null 2> "$stderr_file"; then
    echo "FAIL: validator accepted $label" >&2
    exit 1
  fi
  if ! grep -q 'npm ci && npm run build' "$stderr_file"; then
    echo "FAIL: $label did not include explicit rebuild instructions" >&2
    cat "$stderr_file" >&2
    exit 1
  fi
}

"$validator"
touch "$FIXTURE/Editor/src/editor.js"
"$validator"
echo "PASS: timestamp-only changes reuse the checked-in bundle"

printf '\n// tamper\n' >> "$FIXTURE/Editor/src/editor.js"
expect_invalid "tampered-source"
cp "$ROOT_DIR/Editor/src/editor.js" "$FIXTURE/Editor/src/editor.js"
echo "PASS: changed source content is rejected"

printf '\n' >> "$FIXTURE/Editor/package-lock.json"
expect_invalid "changed-build-input"
cp "$ROOT_DIR/Editor/package-lock.json" "$FIXTURE/Editor/package-lock.json"
echo "PASS: changed package/build inputs are rejected"

printf '\n/* tamper */\n' >> "$FIXTURE/Sources/Still/Resources/Editor/editor.js"
expect_invalid "tampered-output"
cp "$ROOT_DIR/Sources/Still/Resources/Editor/editor.js" "$FIXTURE/Sources/Still/Resources/Editor/editor.js"
echo "PASS: changed generated output is rejected"

printf 'tampered fingerprint\n' >> "$FIXTURE/Editor/bundle.sha256"
expect_invalid "tampered-fingerprint"
cp "$ROOT_DIR/Editor/bundle.sha256" "$FIXTURE/Editor/bundle.sha256"
echo "PASS: corrupt bundle fingerprints are rejected"

mv "$FIXTURE/Sources/Still/Resources/Editor/editor.css" "$TEST_DIR/editor.css"
expect_invalid "missing-output"
mv "$TEST_DIR/editor.css" "$FIXTURE/Sources/Still/Resources/Editor/editor.css"
echo "PASS: missing generated output is rejected"

printf 'export const added = true;\n' > "$FIXTURE/Editor/src/regression-added.js"
expect_invalid "added-source"
rm "$FIXTURE/Editor/src/regression-added.js"
echo "PASS: added source files are detected"

mv "$FIXTURE/Editor/src/editor.css" "$TEST_DIR/editor.css"
expect_invalid "deleted-source"
mv "$TEST_DIR/editor.css" "$FIXTURE/Editor/src/editor.css"
echo "PASS: deleted source files are detected"

mkdir "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/node" <<'STUB'
#!/bin/sh
echo "node $*" >> "$STILL_EDITOR_TEST_TRACE"
exit 91
STUB
cat > "$TEST_DIR/bin/npm" <<'STUB'
#!/bin/sh
echo "npm $*" >> "$STILL_EDITOR_TEST_TRACE"
exit 92
STUB
cat > "$TEST_DIR/bin/swift" <<'STUB'
#!/bin/sh
echo "swift $*" >> "$STILL_EDITOR_TEST_TRACE"
exit 42
STUB
chmod +x "$TEST_DIR/bin/node" "$TEST_DIR/bin/npm" "$TEST_DIR/bin/swift"

set +e
PATH="$TEST_DIR/bin:$PATH" STILL_EDITOR_TEST_TRACE="$TEST_DIR/commands.log" "$FIXTURE/Scripts/build.sh" > "$TEST_DIR/build.stdout" 2> "$TEST_DIR/build.stderr"
build_status=$?
set -e

if [[ "$build_status" -ne 42 ]] || ! grep -qx 'swift build -c release' "$TEST_DIR/commands.log"; then
  echo "FAIL: normal build did not pass bundle validation and reach the Swift build" >&2
  cat "$TEST_DIR/build.stdout" "$TEST_DIR/build.stderr" "$TEST_DIR/commands.log" >&2
  exit 1
fi
if grep -Eq '^(node|npm) ' "$TEST_DIR/commands.log"; then
  echo "FAIL: normal build invoked Node or npm while reusing the bundle" >&2
  cat "$TEST_DIR/commands.log" >&2
  exit 1
fi
echo "PASS: normal build reuses the bundle without invoking Node or npm"

rm -rf "$FIXTURE/Vendor/textual"
: > "$TEST_DIR/commands.log"
set +e
PATH="$TEST_DIR/bin:$PATH" STILL_EDITOR_TEST_TRACE="$TEST_DIR/commands.log" "$FIXTURE/Scripts/build.sh" > "$TEST_DIR/missing-vendor.stdout" 2> "$TEST_DIR/missing-vendor.stderr"
build_status=$?
set -e
if [[ "$build_status" -eq 0 ]] || ! grep -q 'Missing locally vendored Swift dependency: Vendor/textual' "$TEST_DIR/missing-vendor.stderr"; then
  echo "FAIL: normal build did not report a missing local Swift dependency" >&2
  cat "$TEST_DIR/missing-vendor.stdout" "$TEST_DIR/missing-vendor.stderr" >&2
  exit 1
fi
if [[ -s "$TEST_DIR/commands.log" ]]; then
  echo "FAIL: normal build invoked Swift despite a missing local dependency" >&2
  cat "$TEST_DIR/commands.log" >&2
  exit 1
fi
echo "PASS: missing local Swift dependencies fail before invoking SwiftPM"
