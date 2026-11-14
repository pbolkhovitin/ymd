#!/usr/bin/env bash
set -euo pipefail

# Проверки Foundation-компонентов на Mac без установленного XCTest.
macos_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checks_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ymd-swift-checks.XXXXXX")"
trap 'rm -rf "$checks_tmp"' EXIT
swiftc -parse-as-library \
    -module-cache-path "$macos_dir/.build/standalone-modules" \
    "$macos_dir/Sources/ymd-menubar/APIClient.swift" \
    "$macos_dir/Sources/ymd-menubar/AppModel.swift" \
    "$macos_dir/Sources/ymd-menubar/DaemonSupervisor.swift" \
    "$macos_dir/Tests/StandaloneChecks/main.swift" \
    -o "$checks_tmp/checks"
"$checks_tmp/checks"
