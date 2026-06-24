#!/usr/bin/env bash
# Dev runner: build and launch ClaudeBar in the foreground.
# The menu-bar item appears immediately; Ctrl-C to stop.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
echo "==> Running. Look for ClaudeBar in the menu bar (top-right). Ctrl-C to quit."
exec .build/release/ClaudeBar
