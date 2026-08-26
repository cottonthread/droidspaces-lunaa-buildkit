#!/usr/bin/env bash
# 00-host-check.sh — verify the build host before doing any work.
#
# Run:  bash scripts/00-host-check.sh   (optionally: ROOT=/path OUT_REL=name)
#
# Exit 0 = host looks acceptable; anything else = a required precondition failed.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "=== 00-host-check ==="

# 1) Platform
[ "$(uname -s)" = "Linux" ] || die "expected Linux host, got $(uname -s)"
case "$(uname -m)" in x86_64|amd64) : ;; *) die "expected x86_64, got $(uname -m)";; esac
log "platform: $(uname -s) $(uname -m)"

# 2) Required commands
for c in git python3 curl unzip tar bzip2 xz make perl gcc g++; do
  require_cmd "$c"
done
log "core commands present"

# 3) repo (optional here; required at sync stage)
if command -v repo >/dev/null 2>&1; then
  log "repo: $(command -v repo)"
else
  log "WARN: 'repo' not on PATH — install it before 20-sync-sources.sh"
fi

# 4) Filesystem type at $ROOT, or its nearest existing parent on a fresh host.
CHECK_PATH="$ROOT"
while [ ! -e "$CHECK_PATH" ] && [ "$CHECK_PATH" != "/" ]; do
  CHECK_PATH="$(dirname "$CHECK_PATH")"
done
FS="$(stat -f -c %T "$CHECK_PATH" 2>/dev/null || true)"
log "filesystem for $ROOT (checked at $CHECK_PATH): ${FS:-unknown}"
case "$FS" in
  ntfs|drvfs|9p|vboxsf|fuseblk|smb*|cifs) die "unsupported filesystem $FS — use ext4 (or native Linux fs)";;
esac

# 5) Disk free (default: require >= 400 GiB on the same filesystem as $ROOT)
NEED_DISK="${NEED_DISK:-400}"
need_bytes=$(( NEED_DISK * 1024 * 1024 * 1024 ))
avail_bytes="$(df -PB1 "$CHECK_PATH" | awk 'NR==2 {print $4}')"
log "free disk for $ROOT: $(( avail_bytes / 1024 / 1024 / 1024 )) GiB (need ${NEED_DISK} GiB)"
[ "${avail_bytes:-0}" -ge "$need_bytes" ] || die "insufficient free disk"

# 6) RAM + swap (documented WSL: ~28 GiB RAM / 48 GiB swap)
ram_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
log "RAM: $(( ram_kb / 1024 / 1024 )) GiB, swap: $(( swap_kb / 1024 / 1024 )) GiB"
if [ "$(( ram_kb + swap_kb ))" -lt $(( 48 * 1024 * 1024 )) ]; then
  die "recommend at least ~48 GiB of RAM+swap combined"
fi

# 7) Toolchain sanity (optional ccache)
if command -v ccache >/dev/null 2>&1; then
  log "ccache: $(ccache --version | head -n1)"
else
  log "WARN: ccache not found — build will work but be slower"
fi

log "host check passed"
exit 0
