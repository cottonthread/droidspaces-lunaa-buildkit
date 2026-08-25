#!/usr/bin/env bash
# Common helpers for the Droidspaces lunaa reproducibility buildkit.
# Source this from each stage script; do not execute it directly.
#
# Convention: scripts are run from the repository root OR with $ROOT set to the
# AOSP/LineageOS source tree root. The kit root is always the parent of scripts/.

# NOTE: `set -u` is intentionally NOT used — LineageOS `build/envsetup.sh`
# is incompatible with nounset, and the stage scripts must source it.
set -eo pipefail

# --- kit root ---------------------------------------------------------------
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
KIT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- source tree root -------------------------------------------------------
# Default: $HOME/realme (the documented WSL layout). Override with ROOT=...
ROOT="${ROOT:-$HOME/realme}"
if [ ! -d "$ROOT" ]; then
  echo "ERROR: source root not found: $ROOT (set ROOT=/path/to/tree)" >&2
  exit 1
fi

# --- output -----------------------------------------------------------------
OUT_REL="${OUT_REL:-out-droidspaces-full}"
OUT_DIR="$ROOT/$OUT_REL"
BUILD_JOBS="${BUILD_JOBS:-4}"

# --- logging ----------------------------------------------------------------
ts() { date '+%Y-%m-%d %H:%M:%S %Z'; }
log() { printf '[%s] %s\n' "$(ts)" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$(ts)" "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# --- known-good base revisions for patch targets ----------------------------
# project_path<TAB>revision
EXPECTED_REVISIONS="
build/soong	4035bec90f84b583a1502b9a546c6117a28fdbe2
hardware/oplus	9ed73330d06ad8ef3aa4595f6ee49837928dfda6
kernel/configs	091688a5c5186cd124a0d19b06441bb8b04c3073
kernel/oneplus/sm8350	f96127f51a9a5cda38dd1b938d68d0c0593f3844
vendor/oneplus/sm8350-common	6297e5b930f2a200199814e87866d515f0775d7b
vendor/realme/lunaa	091d584924b7174b54dc2ed8f0f3e6fd3a307a06
vendor/lineage	40bf2561c068fb27d8171d30fd6553850859cf15
"

# Kernel overlay allowlist: files that must be restored from overlays/.
KERNEL_OVERLAY_ALLOWLIST="
Documentation/dev-tools/kfence.rst
arch/arm64/include/asm/kfence.h
arch/x86/include/asm/kfence.h
include/linux/kfence.h
include/trace/events/error_report.h
kernel/trace/error_report-traces.c
lib/Kconfig.kfence
mm/kfence/Makefile
mm/kfence/core.c
mm/kfence/kfence.h
mm/kfence/kfence_test.c
mm/kfence/report.c
scripts/as-version.sh
"
