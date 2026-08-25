#!/usr/bin/env bash
# 70-package.sh — build the official target-files ZIP and the fastboot images ZIP.
#
# Run:  ROOT=/path OUT_REL=out-droidspaces-full bash scripts/70-package.sh

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "=== 70-package ==="

cd "$ROOT"
OUT="$OUT_DIR"
GRAPH="$OUT/combined-lineage_lunaa.ninja"
TARGET="$OUT/target/product/lunaa/obj/PACKAGING/target_files_intermediates/lineage_lunaa-target_files.zip"

# 1) Build the official target-files ZIP via the explicit ninja target.
log "building target-files ZIP"
[ -f "$GRAPH" ] || die "ninja graph not found: $GRAPH"
"$ROOT/prebuilts/build-tools/linux-x86/bin/ninja" \
  -f "$GRAPH" "-j${BUILD_JOBS}" "$TARGET" || die "target-files build failed"

# 2) Locate the single OTA package.
mapfile -t OTAS < <(compgen -G "$OUT/target/product/lunaa/lineage-23.2-*-UNOFFICIAL-lunaa.zip")
[ "${#OTAS[@]}" -eq 1 ] || die "expected exactly one OTA, found ${#OTAS[@]}"
OTA="${OTAS[0]}"

# 3) Generate the images ZIP.
IMAGE_ZIP="$OUT/target/product/lunaa/$(basename "${OTA%.zip}")-images.zip"
log "generating images ZIP: $IMAGE_ZIP"
"$OUT/host/linux-x86/bin/img_from_target_files" "$TARGET" "$IMAGE_ZIP" \
  || die "img_from_target_files failed"

# 4) Integrity test both ZIPs.
unzip -t "$TARGET" >/dev/null || die "target-files ZIP failed integrity test"
unzip -t "$IMAGE_ZIP" >/dev/null || die "images ZIP failed integrity test"

log "packaging complete"
log "OTA:        $OTA"
log "target-files: $TARGET"
log "images ZIP: $IMAGE_ZIP"

# Emit a small machine-readable manifest for the next stage.
cat > "$OUT/droidspaces-package.env" <<EOF
OTA=$OTA
TARGET_FILES=$TARGET
IMAGE_ZIP=$IMAGE_ZIP
EOF

log "run 80-audit.sh next"
exit 0
