#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/focus-evidence-check.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
swiftc -parse-as-library -module-cache-path "$task_temp/module-cache" \
    "$task_root/Sources/ScreenEvidenceStore.swift" \
    "$task_root/scripts/tests/evidence-store-check.swift" \
    -o "$task_temp/evidence-check"
"$task_temp/evidence-check"
