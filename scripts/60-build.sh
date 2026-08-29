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

LOG="${BUILD_LOG:-$ROOT/droidspaces-full-build.log}"
EXIT_FILE="${BUILD_EXIT_FILE:-$ROOT/droidspaces-full-build.exit}"

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
# Android's sanitized Ninja environment does not reliably pass arbitrary KBUILD
# variables to the external Kernel make. The Lineage Kernel rule explicitly
# forwards TARGET_KERNEL_ADDITIONAL_FLAGS, so bind the public identity there too.
export TARGET_KERNEL_ADDITIONAL_FLAGS="${TARGET_KERNEL_ADDITIONAL_FLAGS:+$TARGET_KERNEL_ADDITIONAL_FLAGS }KBUILD_BUILD_USER=$KBUILD_BUILD_USER KBUILD_BUILD_HOST=$KBUILD_BUILD_HOST"

source build/envsetup.sh
breakfast lunaa

# repo v2.66+ maintains JSON caches beside each Git config. The LineageOS
# build-manifest rule invokes `repo manifest` inside the Ninja sandbox, where
# HOME and the source tree are read-only. Generate a resolved manifest here,
# before entering Ninja, so all repo config caches are populated while writes
# are allowed. Keep the useful provenance output under OUT.
RESOLVED_MANIFEST_DIR="$OUT_DIR/reproducibility"
RESOLVED_MANIFEST="$RESOLVED_MANIFEST_DIR/resolved-manifest-before-build.xml"
mkdir -p "$RESOLVED_MANIFEST_DIR"
log "prewarming repo config caches and exporting resolved manifest"
python3 .repo/repo/repo manifest -r -o "$RESOLVED_MANIFEST" \
  || die "resolved manifest export / repo cache prewarm failed"
[ -s "$RESOLVED_MANIFEST" ] || die "resolved manifest is empty: $RESOLVED_MANIFEST"

m "-j${BUILD_JOBS}" bacon

# Exit code is captured by the EXIT trap above.
