#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDITOR_DIR="$ROOT_DIR/Editor"
OUTPUT_DIR="$ROOT_DIR/Sources/Still/Resources/Editor"
FINGERPRINT="$EDITOR_DIR/bundle.sha256"

rebuild_instructions() {
  cat >&2 <<EOF
Editor bundle is missing, stale, or corrupt. Rebuild it explicitly with:
  cd "$EDITOR_DIR" && npm ci && npm run build
EOF
}

fail_bundle() {
  echo "Error: $1" >&2
  rebuild_instructions
  exit 1
}

if ! command -v shasum >/dev/null 2>&1; then
  echo "Error: shasum is required to validate the checked-in Editor bundle." >&2
  exit 1
fi

if [[ ! -d "$EDITOR_DIR/src" ]]; then
  fail_bundle "Editor source directory is missing: $EDITOR_DIR/src"
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
  fail_bundle "generated Editor resources are missing: $OUTPUT_DIR"
fi

required_outputs=(
  "$OUTPUT_DIR/editor.js"
  "$OUTPUT_DIR/editor.css"
  "$OUTPUT_DIR/index.html"
  "$OUTPUT_DIR/THIRD_PARTY_NOTICES.txt"
)
for output in "${required_outputs[@]}"; do
  if [[ ! -s "$output" ]]; then
    fail_bundle "generated Editor output is missing or empty: ${output#"$ROOT_DIR"/}"
  fi
done

temporary_file="$(mktemp "${TMPDIR:-/tmp}/still-editor-bundle.XXXXXX")"
file_list="$(mktemp "${TMPDIR:-/tmp}/still-editor-files.XXXXXX")"
trap 'rm -f "$temporary_file" "$file_list"' EXIT

{
  printf '%s\n' \
    "$EDITOR_DIR/package.json" \
    "$EDITOR_DIR/package-lock.json" \
    "$EDITOR_DIR/build.mjs"
  find "$EDITOR_DIR/src" -type f -print
  printf '%s\n' "${required_outputs[@]}"
} | LC_ALL=C sort > "$file_list"

if [[ ! -s "$file_list" ]]; then
  fail_bundle "no Editor inputs or outputs were found"
fi

while IFS= read -r absolute_path; do
  if [[ ! -f "$absolute_path" ]]; then
    fail_bundle "Editor bundle input is missing: ${absolute_path#"$ROOT_DIR"/}"
  fi
  checksum_output="$(shasum -a 256 "$absolute_path")"
  checksum="${checksum_output%% *}"
  relative_path="${absolute_path#"$ROOT_DIR"/}"
  printf '%s  %s\n' "$checksum" "$relative_path" >> "$temporary_file"
done < "$file_list"

if [[ ! -f "$FINGERPRINT" ]]; then
  fail_bundle "Editor bundle fingerprint is missing: ${FINGERPRINT#"$ROOT_DIR"/}"
fi

if ! cmp -s "$temporary_file" "$FINGERPRINT"; then
  fail_bundle "Editor bundle fingerprint does not match its sources and generated outputs"
fi
