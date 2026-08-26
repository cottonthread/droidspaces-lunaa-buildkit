#!/usr/bin/env bash
# 60-build.sh — run the full LineageOS build (bacon) and record its exit code.
#
# Run in the foreground, or wrap in tmux for long builds:
#   tmux new-session -d -s droidspaces-build 'ROOT=/path bash scripts/60-build.sh'
#
# Success is judged ONLY by the exit file, never by tmux session state.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_root

log "=== 60-build ==="

cd "$ROOT"

LOG="$ROOT/droidspaces-full-build.log"
EXIT_FILE="$ROOT/droidspaces-full-build.exit"

rm -f "$EXIT_FILE"
exec > >(tee -a "$LOG") 2>&1
trap 'rc=$?; printf "%s\n" "$rc" > "$EXIT_FILE"; exit "$rc"' EXIT

export OUT_DIR="$OUT_REL"
export USE_CCACHE=1
export CCACHE_EXEC="${CCACHE_EXEC:-$(command -v ccache)}"
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
export PATH="$ROOT/prebuilts/jdk/jdk21/linux-x86/bin:$HOME/bin:$PATH"
# Use non-identifying defaults in generated Android and Kernel metadata.
# Callers may override these with equally non-identifying values when needed.
export BUILD_USERNAME="${BUILD_USERNAME:-android}"
export BUILD_HOSTNAME="${BUILD_HOSTNAME:-repro-build}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-android}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-repro-build}"

source build/envsetup.sh
breakfast lunaa
m "-j${BUILD_JOBS}" bacon

# Exit code is captured by the EXIT trap above.
