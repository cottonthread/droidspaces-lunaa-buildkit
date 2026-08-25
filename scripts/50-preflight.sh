#!/usr/bin/env bash
# 50-preflight.sh — build the kernel and run preflight assertions
# (kernel config, OUT graph, VINTF, APEX gate) before the full build.
#
# Run:  ROOT=/path/to/tree OUT_REL=out-droidspaces-full bash scripts/50-preflight.sh

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "=== 50-preflight ==="

cd "$ROOT"

# Environment (mirrors the successful 2026-08-25 run).
export OUT_DIR="$OUT_REL"
export USE_CCACHE=1
export CCACHE_EXEC="${CCACHE_EXEC:-$(command -v ccache)}"
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
export PATH="$ROOT/prebuilts/jdk/jdk21/linux-x86/bin:$HOME/bin:$PATH"

log "sourcing build/envsetup.sh (do NOT enable 'set -u' before this)"
source build/envsetup.sh
breakfast lunaa

# 1) Build the boot image. VINTF is intentionally evaluated during the complete
# packaging build: Android make declares check_vintf_compatible as a generated
# log-file dependency, not a standalone Ninja target.
log "building bootimage (VINTF runs during the full bacon build)"
m "-j${BUILD_JOBS}" bootimage || die "bootimage build failed"

KCONFIG="$OUT_DIR/target/product/lunaa/obj/KERNEL_OBJ/.config"

# 2) Kernel config assertions.
log "checking required kernel configs"
for config in \
  CONFIG_AS_IS_LLVM=y \
  CONFIG_NET_SCH_TBF=y \
  CONFIG_KFENCE=y \
  CONFIG_KFENCE_SAMPLE_INTERVAL=0 \
  CONFIG_SYSVIPC=y \
  CONFIG_POSIX_MQUEUE=y \
  CONFIG_IPC_NS=y \
  CONFIG_PID_NS=y \
  CONFIG_QCOM_SMEM=y \
  CONFIG_OPLUS_FEATURE_PROJECTINFO=y
do
  grep -qx "$config" "$KCONFIG" || die "missing kernel config: $config"
done
log "kernel configs OK"

# 3) Kernel OUT graph assertion (no nested relative O=).
NINJA="$OUT_DIR/build-lineage_lunaa.ninja"
python3 - "$ROOT" "$NINJA" "$OUT_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1]).resolve()
ninja = Path(sys.argv[2])
out = sys.argv[3]
text = ninja.read_text(errors='replace')
absolute = f'O={root}/{out}/target/product/lunaa/obj/KERNEL_OBJ'
relative = 'O=' + out + '/target/product/lunaa/obj/KERNEL_OBJ'
abs_count = text.count(absolute)
rel_count = text.count(relative)
if abs_count < 20 or rel_count != 0:
    raise SystemExit({'absolute': abs_count, 'relative': rel_count})
print(f'OUT graph OK: absolute={abs_count}, relative={rel_count}')
PY
[ $? -eq 0 ] || die "kernel OUT graph assertion failed"

# 4) VINTF assertion (log ends with COMPATIBLE).
VINTF_LOG="$OUT_DIR/target/product/lunaa/obj/PACKAGING/check_vintf_all_intermediates/check_vintf_compatible.log"
[ -f "$VINTF_LOG" ] || die "VINTF log not found: $VINTF_LOG"
tail -n 1 "$VINTF_LOG" | grep -qx COMPATIBLE || die "VINTF not COMPATIBLE"
log "VINTF COMPATIBLE"

# 5) FCM 7 requires SYSVIPC=y for every 5.4 kernel block.
python3 - "$OUT_DIR" <<'PY'
import sys
import xml.etree.ElementTree as ET
path = (sys.argv[1] + '/target/product/lunaa/system/etc/vintf/compatibility_matrix.7.xml')
root = ET.parse(path).getroot()
blocks = []
for kernel in root.findall('kernel'):
    if kernel.attrib.get('version', '').startswith('5.4'):
        vals = [c.findtext('value') for c in kernel.findall('config')
                if c.findtext('key') == 'CONFIG_SYSVIPC']
        blocks.append(vals)
if not blocks or any(vals != ['y'] for vals in blocks):
    raise SystemExit({'CONFIG_SYSVIPC per 5.4 block': blocks})
print(f'FCM 7 SYSVIPC=y in {len(blocks)} 5.4 block(s)')
PY
[ $? -eq 0 ] || die "FCM 7 SYSVIPC assertion failed"

# 6) APEX allowed-deps gate (conditional — file appears during full build).
NEW_DEPS="$OUT_DIR/soong/apex/depsinfo/new-allowed-deps.txt"
BASE_DEPS="$ROOT/packages/modules/common/build/allowed_deps.txt"
if [ -f "$NEW_DEPS" ]; then
  log "APEX new-allowed-deps.txt present — running set comparison"
  python3 - "$BASE_DEPS" "$NEW_DEPS" <<'PY'
from pathlib import Path
import sys
base = Path(sys.argv[1]); new = Path(sys.argv[2])
def lines(p):
    return [x for x in p.read_text(errors='replace').splitlines()
            if x and not x.startswith('#')]
b, n = lines(base), lines(new)
if len(b) != 1708 or len(n) != 1708:
    raise SystemExit({'base': len(b), 'new': len(n)})
if len(set(b)) != len(b) or len(set(n)) != len(n):
    raise SystemExit('duplicates detected')
if set(b) != set(n):
    raise SystemExit('APEX allowed-deps set changed')
new.write_text('\n'.join(b) + '\n')
print('APEX allowed-deps set identical (1708) — normalized ordering')
PY
  [ $? -eq 0 ] || die "APEX allowed-deps gate failed"
  rm -f "$NEW_DEPS.check"
else
  log "APEX new-allowed-deps.txt not present yet — expected; re-run this gate if bacon stops there"
fi

log "preflight passed — run 60-build.sh next; then use 80-audit.sh to require the generated VINTF log"
exit 0
