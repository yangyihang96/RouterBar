#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
swift test --scratch-path "$HOME/Library/Caches/com.yihang.RouterBar/Build"
