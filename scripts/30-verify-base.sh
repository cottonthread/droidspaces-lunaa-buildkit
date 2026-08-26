#!/usr/bin/env bash
# 30-verify-base.sh — verify every synced project matches the frozen manifest,
# and that the tree is clean before any patches are applied.
#
# Run:  ROOT=/path/to/tree bash scripts/30-verify-base.sh

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_root

log "=== 30-verify-base ==="
require_cmd repo

cd "$ROOT"

# 1) Export current resolved manifest and compare path->revision.
repo manifest -r -o "$ROOT/current-manifest.xml" \
  || die "failed to export resolved manifest"

FROZEN="$KIT_DIR/manifests/frozen-20260825.xml"
python3 - "$FROZEN" "$ROOT/current-manifest.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

def projects(path):
    result = {}
    for node in ET.parse(path).getroot().findall('project'):
        p = node.get('path', node.get('name'))
        if p in result:
            raise SystemExit(f'duplicate project path: {p}')
        result[p] = node.get('revision')
    return result

expected = projects(sys.argv[1])
actual = projects(sys.argv[2])
if expected != actual:
    missing = sorted(expected.keys() - actual.keys())
    extra = sorted(actual.keys() - expected.keys())
    changed = sorted(p for p in expected.keys() & actual.keys()
                     if expected[p] != actual[p])
    raise SystemExit({'missing': missing, 'extra': extra, 'changed_revision': changed})
print(f'OK: {len(actual)} projects match the frozen manifest')
PY
[ $? -eq 0 ] || die "manifest comparison failed"

# 2) Explicitly verify the 7 patch-target projects are at their base revisions.
while IFS=$'\t' read -r project_path revision; do
  actual="$(git -C "$ROOT/$project_path" rev-parse HEAD 2>/dev/null || true)"
  [ "$actual" = "$revision" ] \
    || die "HEAD mismatch for $project_path: expected $revision, got ${actual:-missing}"
  log "OK $project_path @ $revision"
done < <(printf '%s\n' "$EXPECTED_REVISIONS" | sed '/^[[:space:]]*$/d')

# 3) Require a clean tree everywhere before patching.
log "checking tree cleanliness (this can take a few minutes)..."
dirty=0
repo forall -e -c '
  if [ -n "$(git status --porcelain)" ]; then
    echo "DIRTY: $REPO_PATH" >&2
    git status --short >&2
    exit 1
  fi
' || dirty=1
if [ "$dirty" -ne 0 ]; then
  die "tree is not clean — resolve or stash changes before continuing"
fi

log "base verification passed — run 40-apply-patches.sh next"
exit 0
