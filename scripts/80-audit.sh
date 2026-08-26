#!/usr/bin/env bash
# 80-audit.sh — post-build audit: OTA/payload signature, target-files VINTF,
# AVB parse + cryptographic verification, and SHA-256 capture.
#
# Run:  ROOT=/path OUT_REL=out-droidspaces-full bash scripts/80-audit.sh
#
# This is the CORRECTED audit. The original run used `python3 avbtool` (a host
# binary) and swallowed failures with `|| true`; both are forbidden here.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_root

log "=== 80-audit ==="

cd "$ROOT"
OUT="$OUT_DIR"
HOST="$OUT/host/linux-x86/bin"
AUDIT="$ROOT/droidspaces-audit"
mkdir -p "$AUDIT"

# Locate artifacts (prefer the env file emitted by 70-package.sh).
if [ -f "$OUT/droidspaces-package.env" ]; then
  # shellcheck disable=SC1090
  . "$OUT/droidspaces-package.env"
fi
TARGET_FILES="${TARGET_FILES:-$OUT/target/product/lunaa/obj/PACKAGING/target_files_intermediates/lineage_lunaa-target_files.zip}"
mapfile -t OTAS < <(compgen -G "$OUT/target/product/lunaa/lineage-23.2-*-UNOFFICIAL-lunaa.zip")
[ "${#OTAS[@]}" -eq 1 ] || die "expected exactly one OTA, found ${#OTAS[@]}"
OTA="${OTAS[0]}"
IMAGE_ZIP="${IMAGE_ZIP:-$OUT/target/product/lunaa/$(basename "${OTA%.zip}")-images.zip}"

for f in "$TARGET_FILES" "$OTA" "$IMAGE_ZIP"; do
  [ -f "$f" ] || die "artifact missing: $f"
done

# --- status ledger ----------------------------------------------------------
ledger() { printf '%s=%s\n' "$1" "$2"; }
: > "$AUDIT/audit-status.txt"

# 9.2 OTA + payload signature
log "checking OTA + payload signatures"
unzip -p "$OTA" META-INF/com/android/otacert > "$AUDIT/otacert.x509.pem" || die "otacert extract failed"
"$HOST/check_ota_package_signature" "$AUDIT/otacert.x509.pem" "$OTA" \
  > "$AUDIT/ota-signature-check.txt" 2>&1 || die "OTA signature check failed"
grep -q "Whole package signature VERIFIED" "$AUDIT/ota-signature-check.txt" \
  || die "missing 'Whole package signature VERIFIED'"
grep -q "Payload signatures VERIFIED" "$AUDIT/ota-signature-check.txt" \
  || die "missing 'Payload signatures VERIFIED'"
ledger ota_signature_check 0 >> "$AUDIT/audit-status.txt"
log "OTA signature VERIFIED"

# 9.3 target-files VINTF
log "checking target-files VINTF"
"$HOST/check_target_files_vintf" "$TARGET_FILES" \
  > "$AUDIT/target-files-vintf.txt" 2>&1 || die "target-files VINTF check failed"
ledger vintf_check 0 >> "$AUDIT/audit-status.txt"
log "target-files VINTF OK"

# 9.4 FCM 7 policy used by this Droidspaces variant. This requires the complete
# system image, so it is deliberately checked only after target-files VINTF.
python3 - "$OUT" <<'PY'
import sys
import xml.etree.ElementTree as ET
path = sys.argv[1] + '/target/product/lunaa/system/etc/vintf/compatibility_matrix.7.xml'
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
[ $? -eq 0 ] || die "FCM 7 SYSVIPC post-build assertion failed"
ledger fcm_sysvipc_check 0 >> "$AUDIT/audit-status.txt"

# 9.5 AVB: parse from the FINAL images ZIP, then verify with the expected key.
log "AVB parse + verify (final images ZIP only)"
AVB="$HOST/avbtool"
[ -x "$AVB" ] || die "avbtool not executable: $AVB"

# Test-key build key. For a private-key build, set AVB_KEY and AVB_CHAIN_SPECS
# to the corresponding key material and per-partition chain descriptors.
AVB_KEY="${AVB_KEY:-$ROOT/external/avb/test/data/testkey_rsa4096.pem}"

# WARNING: partition names, chain indexes, rollback locations and key paths MUST
# be confirmed against the current `avbtool info_image` output and
# `META/misc_info.txt` before trusting these values for a new build.
[ -f "$AVB_KEY" ] || die "AVB key not found: $AVB_KEY"

IMAGES="$(mktemp -d)"
unzip -q "$IMAGE_ZIP" -d "$IMAGES" || die "failed to extract images ZIP"
AVB_PUBKEY="$IMAGES/expected-key.avbpubkey"
"$AVB" extract_public_key --key "$AVB_KEY" --output "$AVB_PUBKEY" \
  || die "failed to extract expected AVB public key"
# Each item is PARTITION:ROLLBACK_SLOT. The required binary public-key blob is
# appended below. Override only after checking the current misc_info.txt.
AVB_CHAIN_SPECS="${AVB_CHAIN_SPECS:-boot:4 dtbo:3 vendor_boot:1 vbmeta_system:2 vbmeta_vendor:5}"

for image in boot.img dtbo.img vendor_boot.img vbmeta.img vbmeta_system.img vbmeta_vendor.img; do
  "$AVB" info_image --image "$IMAGES/$image" > "$AUDIT/avb-$image.txt" 2>&1 \
    || die "avbtool info_image failed: $image"
  ledger "avb_parse_${image%.img}" 0 >> "$AUDIT/audit-status.txt"
done

for image in boot.img dtbo.img vendor_boot.img; do
  "$AVB" verify_image --image "$IMAGES/$image" --key "$AVB_KEY" \
    > "$AUDIT/verify-$image.txt" 2>&1 || die "avbtool verify_image failed: $image"
  ledger "avb_verify_${image%.img}" 0 >> "$AUDIT/audit-status.txt"
done

# Follow the vbmeta chain to validate chained partitions. avbtool requires one
# --expected_chain_partition flag per descriptor; raw positional descriptors are
# not accepted. Word splitting is intentional here because each descriptor must
# not contain whitespace. expected_chain_partition requires an AVB public-key
# blob, not the PEM accepted by verify_image --key.
read -r -a CHAIN_SPECS <<< "$AVB_CHAIN_SPECS"
CHAIN_ARGS=()
for spec in "${CHAIN_SPECS[@]}"; do
  CHAIN_ARGS+=(--expected_chain_partition "$spec:$AVB_PUBKEY")
done
"$AVB" verify_image \
  --image "$IMAGES/vbmeta.img" \
  --key "$AVB_KEY" \
  --follow_chain_partitions \
  "${CHAIN_ARGS[@]}" \
  > "$AUDIT/verify-vbmeta-chain.txt" 2>&1 || die "avbtool vbmeta chain verification failed"
ledger avb_verify_chain 0 >> "$AUDIT/audit-status.txt"
rm -rf "$IMAGES"
log "AVB parse + verify OK (test-key identity)"

# 9.6 SHA-256. Record paths relative to ROOT so artifacts in different output
# subdirectories remain verifiable without embedding a local absolute path.
log "capturing SHA-256"
for f in "$OTA" "$TARGET_FILES" "$IMAGE_ZIP"; do
  case "$f" in
    "$ROOT"/*) ;;
    *) die "artifact is outside source root: $f" ;;
  esac
done
(
  cd "$ROOT"
  sha256sum "${OTA#"$ROOT"/}" "${TARGET_FILES#"$ROOT"/}" "${IMAGE_ZIP#"$ROOT"/}"
) > "$AUDIT/SHA256SUMS" || die "sha256sum failed"
( cd "$ROOT" && sha256sum -c "$AUDIT/SHA256SUMS" ) || die "SHA-256 verification failed"
ledger archive_sha256_verify 0 >> "$AUDIT/audit-status.txt"

ledger postbuild_exit 0 >> "$AUDIT/audit-status.txt"

log "audit complete: $AUDIT/audit-status.txt"
cat "$AUDIT/audit-status.txt"
exit 0
