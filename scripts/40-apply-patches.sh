#!/usr/bin/env bash
# 40-apply-patches.sh — apply the per-project patches and restore the kernel
# overlay files, then verify the resulting tree matches expectations.
#
# Run:  ROOT=/path/to/tree bash scripts/40-apply-patches.sh

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_root

log "=== 40-apply-patches ==="

cd "$ROOT"
INDEX="$KIT_DIR/patches/PATCHES.tsv"
[ -f "$INDEX" ] || die "patch index not found: $INDEX"

# 1) First pass: check every patch applies cleanly before touching anything.
log "dry-run: git apply --check for all patches"
while IFS=$'\t' read -r patch project revision; do
  [ -f "$KIT_DIR/patches/$patch" ] || die "patch file missing: $patch"
  git -C "$ROOT/$project" apply --check "$KIT_DIR/patches/$patch" \
    || die "patch does not apply cleanly: $project ($patch)"
  log "check OK: $project ($patch)"
done < <(grep -v '^#' "$INDEX" | sed '/^[[:space:]]*$/d')

# 2) Second pass: apply for real.
log "applying patches"
while IFS=$'\t' read -r patch project revision; do
  git -C "$ROOT/$project" apply "$KIT_DIR/patches/$patch" \
    || die "apply failed: $project ($patch)"
  log "applied: $project ($patch)"
done < <(grep -v '^#' "$INDEX" | sed '/^[[:space:]]*$/d')

# 3) Restore the kernel overlay files (allow-list only).
KERNEL="$ROOT/kernel/oneplus/sm8350"
OVERLAY="$KIT_DIR/overlays/kernel/oneplus/sm8350"
[ -d "$OVERLAY" ] || die "overlay dir missing: $OVERLAY"

log "restoring kernel overlay allow-list"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$OVERLAY/$f" ] || die "overlay source missing: $f"
  mkdir -p "$KERNEL/$(dirname "$f")"
  cp -a "$OVERLAY/$f" "$KERNEL/$f"
done <<< "$KERNEL_OVERLAY_ALLOWLIST"
chmod +x "$KERNEL/scripts/as-version.sh"

# 4) Verify the untracked allow-list is exactly as expected.
log "verifying kernel untracked allow-list"
expected="$(printf '%s\n' $KERNEL_OVERLAY_ALLOWLIST | LC_ALL=C sort)"
actual="$(git -C "$KERNEL" ls-files --others --exclude-standard | LC_ALL=C sort)"
if [ "$actual" != "$expected" ]; then
  echo "--- expected untracked ---" >&2; echo "$expected" >&2
  echo "--- actual untracked ---" >&2; echo "$actual" >&2
  die "kernel untracked files do not match allow-list"
fi

# 5) Whitespace sanity on all modified projects.
log "git diff --check on all modified projects"
while IFS=$'\t' read -r project revision; do
  git -C "$ROOT/$project" diff --check || die "diff --check failed: $project"
done < <(printf '%s\n' "$EXPECTED_REVISIONS" | sed '/^[[:space:]]*$/d')

log "patches and overlays applied — run 50-preflight.sh next"
exit 0
