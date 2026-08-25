#!/usr/bin/env bash
# 20-sync-sources.sh — initialize and sync the pinned LineageOS 23.2 tree.
#
# Creates (or reuses) the repo tree at $ROOT, then installs the frozen manifest
# and syncs every project to the exact pinned revision.
#
# Run:  ROOT=/path/to/tree bash scripts/20-sync-sources.sh
#
# NOTE: the frozen manifest uses a relative fetch for the LineageOS 'github'
# remote, so we MUST `repo init` against the official LineageOS manifest repo
# first, then replace .repo/manifest.xml with the frozen one. Do not init
# directly against this kit repository.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "=== 20-sync-sources ==="
require_cmd repo

FROZEN="$KIT_DIR/manifests/frozen-20260825.xml"
[ -f "$FROZEN" ] || die "frozen manifest not found: $FROZEN"

mkdir -p "$ROOT"
cd "$ROOT"

# 1) Initialize against official LineageOS manifest (provides relative fetch base).
if [ ! -d "$ROOT/.repo" ]; then
  log "repo init -u https://github.com/LineageOS/android.git -b lineage-23.2"
  repo init \
    -u https://github.com/LineageOS/android.git \
    -b lineage-23.2 \
    --git-lfs \
    --no-clone-bundle || die "repo init failed"
else
  log ".repo already present; reusing existing manifest repo"
fi

# 2) Refuse to run if local manifests already exist (would change the tree).
if [ -e "$ROOT/.repo/local_manifests" ]; then
  die "found $ROOT/.repo/local_manifests — move it aside and review before continuing"
fi

# 3) Back up the current manifest and install the frozen one.
cp -L "$ROOT/.repo/manifest.xml" "$ROOT/.repo/manifest.before-droidspaces.xml" \
  || die "failed to back up current manifest"
rm -f "$ROOT/.repo/manifest.xml"
cp -L "$FROZEN" "$ROOT/.repo/manifest.xml" || die "failed to install frozen manifest"

# 4) Sync.
log "repo sync (jobs=$BUILD_JOBS)"
repo sync -c "-j${BUILD_JOBS}" --force-sync --no-clone-bundle --no-tags \
  || die "repo sync failed"

log "sync complete — run 30-verify-base.sh next"
exit 0
