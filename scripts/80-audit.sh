#!/usr/bin/env bash
# 80-audit.sh — post-build audit: archive integrity, OTA/payload signatures,
# target-files VINTF, AVB verification, and an artifact-bound attestation.
#
# Run: ROOT=/path OUT_REL=out-droidspaces-full \
#   POSTBUILD_EXIT_FILE=/path/to/postbuild.exit bash scripts/80-audit.sh

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_root

log "=== 80-audit ==="

for cmd in cmp flock git python3 sha256sum unzip; do
  require_cmd "$cmd"
done

cd "$ROOT"
OUT="$OUT_DIR"
HOST="$OUT/host/linux-x86/bin"
AUDIT_FINAL="${AUDIT_DIR:-$ROOT/droidspaces-audit}"
BUILD_EXIT_FILE="${BUILD_EXIT_FILE:-$ROOT/droidspaces-full-build.exit}"
POSTBUILD_EXIT_FILE="${POSTBUILD_EXIT_FILE:-$ROOT/droidspaces-postbuild.exit}"
PACKAGE_ENV="$OUT/droidspaces-package.env"
readonly PINNED_AVB_PUBLIC_KEY_SHA256="7728e30f50bfa5cea165f473175a08803f6a8346642b5aa10913e9d9e6defef6"
readonly PINNED_AVB_KEY="$ROOT/external/avb/test/data/testkey_rsa4096.pem"
PRODUCT_OUT="$OUT/target/product/lunaa"
KERNEL_TREE="$ROOT/kernel/oneplus/sm8350"
KERNEL_OBJ="$PRODUCT_OUT/obj/KERNEL_OBJ"
PRODUCT_BOOT="$PRODUCT_OUT/boot.img"
KERNEL_IMAGE="$KERNEL_OBJ/arch/arm64/boot/Image"
KERNEL_CONFIG="$KERNEL_OBJ/.config"
RESOLVED_MANIFEST="$OUT/reproducibility/resolved-manifest-before-build.xml"

# Release audits have one immutable AVB identity. Tests must modify fixtures rather
# than override the expected key or digest through the environment.
[ -z "${EXPECTED_AVB_PUBLIC_KEY_SHA256+x}" ] \
  || die "EXPECTED_AVB_PUBLIC_KEY_SHA256 override is forbidden in release audit mode"
[ -z "${AVB_KEY+x}" ] || die "AVB_KEY override is forbidden in release audit mode"

# Parse the three-key data manifest emitted by 70-package.sh without executing it.
[ -s "$PACKAGE_ENV" ] || die "package environment missing or empty: $PACKAGE_ENV"
PACKAGE_OUTPUT="$(python3 - "$PACKAGE_ENV" "$OUT" <<'PY_PACKAGE'
from pathlib import Path
import os
import re
import sys
manifest = Path(sys.argv[1])
out = Path(sys.argv[2]).resolve(strict=True)
keys = ('OTA', 'TARGET_FILES', 'IMAGE_ZIP')
parsed = {}
for number, line in enumerate(manifest.read_text().splitlines(), 1):
    match = re.fullmatch(r'(OTA|TARGET_FILES|IMAGE_ZIP)=(/[A-Za-z0-9._/+:-]+)', line)
    if not match:
        raise SystemExit(f'unsafe or unknown package manifest entry at line {number}: {line!r}')
    key, raw = match.groups()
    if key in parsed:
        raise SystemExit(f'duplicate package manifest key: {key}')
    path = Path(raw)
    resolved = path.resolve(strict=True)
    if os.path.commonpath((str(out), str(resolved))) != str(out):
        raise SystemExit(f'{key} is outside OUT: {resolved}')
    parsed[key] = resolved
if list(parsed) != list(keys):
    raise SystemExit({'expected_keys': keys, 'actual_keys': tuple(parsed)})
product = out / 'target/product/lunaa'
ota = parsed['OTA']
expected_target = product / 'obj/PACKAGING/target_files_intermediates/lineage_lunaa-target_files.zip'
if parsed['TARGET_FILES'] != expected_target:
    raise SystemExit(f'unexpected TARGET_FILES path: {parsed["TARGET_FILES"]}')
if ota.parent != product or not re.fullmatch(r'lineage-23\.2-[0-9]{8}-UNOFFICIAL-lunaa\.zip', ota.name):
    raise SystemExit(f'unexpected OTA path or name: {ota}')
expected_images = product / (ota.stem + '-images.zip')
if parsed['IMAGE_ZIP'] != expected_images:
    raise SystemExit(f'unexpected IMAGE_ZIP path: {parsed["IMAGE_ZIP"]}')
for key in keys:
    print(parsed[key])
PY_PACKAGE
)" || die "package environment validation failed"
mapfile -t PACKAGE_PATHS <<< "$PACKAGE_OUTPUT"
[ "${#PACKAGE_PATHS[@]}" -eq 3 ] || die "package manifest parser returned an invalid result"
OTA="${PACKAGE_PATHS[0]}"
TARGET_FILES="${PACKAGE_PATHS[1]}"
IMAGE_ZIP="${PACKAGE_PATHS[2]}"

for f in "$TARGET_FILES" "$OTA" "$IMAGE_ZIP" "$PRODUCT_BOOT" \
         "$KERNEL_IMAGE" "$KERNEL_CONFIG" "$RESOLVED_MANIFEST"; do
  [ -s "$f" ] || die "required audit input missing or empty: $f"
done
[ -f "$BUILD_EXIT_FILE" ] || die "build exit file missing: $BUILD_EXIT_FILE"
[ "$(tr -d '\r\n[:space:]' < "$BUILD_EXIT_FILE")" = 0 ] \
  || die "full build exit is not zero"
[ -f "$POSTBUILD_EXIT_FILE" ] || die "post-build exit file missing: $POSTBUILD_EXIT_FILE"
[ "$(tr -d '\r\n[:space:]' < "$POSTBUILD_EXIT_FILE")" = 0 ] \
  || die "post-build exit is not zero"
POSTBUILD_EXIT_SHA256="$(sha256sum "$POSTBUILD_EXIT_FILE" | cut -d' ' -f1)"
KERNEL_COMMIT="$(git -C "$KERNEL_TREE" rev-parse HEAD)"
[[ "$KERNEL_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "invalid Kernel HEAD"
[ -z "$(git -C "$KERNEL_TREE" status --porcelain --untracked-files=all)" ] \
  || die "Kernel worktree is not clean"

AUDIT_PARENT="$(dirname "$AUDIT_FINAL")"
AUDIT_NAME="$(basename "$AUDIT_FINAL")"
mkdir -p "$AUDIT_PARENT"
[ -d "$AUDIT_PARENT" ] && [ ! -L "$AUDIT_PARENT" ] \
  || die "audit parent is not a real directory: $AUDIT_PARENT"
exec 9> "$AUDIT_PARENT/.${AUDIT_NAME}.publish.lock"
flock -n 9 || die "another audit publication process holds the lock"
[ ! -e "$AUDIT_FINAL" ] && [ ! -L "$AUDIT_FINAL" ] \
  || die "audit destination already exists: $AUDIT_FINAL"
AUDIT="$(mktemp -d "$AUDIT_PARENT/.${AUDIT_NAME}.stage.XXXXXXXX")"
IMAGES=""
BOOT_UNPACK=""
cleanup() {
  [ -z "$IMAGES" ] || rm -rf "$IMAGES"
  [ -z "$BOOT_UNPACK" ] || rm -rf "$BOOT_UNPACK"
  [ -z "$AUDIT" ] || rm -rf "$AUDIT"
}
trap cleanup EXIT

ledger() { printf '%s=%s\n' "$1" "$2"; }
: > "$AUDIT/audit-status.txt"
ledger build_exit 0 >> "$AUDIT/audit-status.txt"

log "checking OTA, target-files and images ZIP integrity"
unzip -t "$OTA" > "$AUDIT/ota-zip-test.txt" 2>&1 \
  || die "OTA ZIP failed integrity test"
ledger ota_zip_test 0 >> "$AUDIT/audit-status.txt"
unzip -t "$TARGET_FILES" > "$AUDIT/target-files-zip-test.txt" 2>&1 \
  || die "target-files ZIP failed integrity test"
ledger target_files_zip_test 0 >> "$AUDIT/audit-status.txt"
ledger image_zip_generation 0 >> "$AUDIT/audit-status.txt"
unzip -t "$IMAGE_ZIP" > "$AUDIT/images-zip-test.txt" 2>&1 \
  || die "images ZIP failed integrity test"
ledger image_zip_test 0 >> "$AUDIT/audit-status.txt"

log "checking OTA + payload signatures"
unzip -p "$OTA" META-INF/com/android/otacert > "$AUDIT/otacert.x509.pem" \
  || die "otacert extract failed"
"$HOST/check_ota_package_signature" "$AUDIT/otacert.x509.pem" "$OTA" \
  > "$AUDIT/ota-signature-check.txt" 2>&1 || die "OTA signature check failed"
grep -q "Whole package signature VERIFIED" "$AUDIT/ota-signature-check.txt" \
  || die "missing 'Whole package signature VERIFIED'"
grep -q "Payload signatures VERIFIED" "$AUDIT/ota-signature-check.txt" \
  || die "missing 'Payload signatures VERIFIED'"
ledger ota_signature_check 0 >> "$AUDIT/audit-status.txt"
log "OTA signature VERIFIED"

log "checking target-files VINTF"
"$HOST/check_target_files_vintf" "$TARGET_FILES" \
  > "$AUDIT/target-files-vintf.txt" 2>&1 || die "target-files VINTF check failed"
ledger vintf_check 0 >> "$AUDIT/audit-status.txt"
log "target-files VINTF OK"

python3 - "$OUT" > "$AUDIT/fcm-sysvipc-check.txt" <<'PY_FCM' \
  || die "FCM 7 SYSVIPC post-build assertion failed"
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
declaring_blocks = [vals for vals in blocks if vals]
if not blocks or not declaring_blocks or any(vals != ['y'] for vals in declaring_blocks):
    raise SystemExit({'CONFIG_SYSVIPC declarations in 5.4 blocks': blocks})
print(f'FCM 7 SYSVIPC=y in {len(declaring_blocks)} declaring block(s) '
      f'across {len(blocks)} 5.4 block(s)')
PY_FCM
cat "$AUDIT/fcm-sysvipc-check.txt"
ledger fcm_sysvipc_check 0 >> "$AUDIT/audit-status.txt"

log "AVB parse + verify (final images ZIP only)"
AVB="$HOST/avbtool"
UNPACK_BOOTIMG="$HOST/unpack_bootimg"
AVB_KEY="$PINNED_AVB_KEY"
[ -x "$AVB" ] || die "avbtool not executable: $AVB"
[ -x "$UNPACK_BOOTIMG" ] || die "unpack_bootimg not executable: $UNPACK_BOOTIMG"
[ -f "$AVB_KEY" ] || die "AVB key not found: $AVB_KEY"

IMAGES="$(mktemp -d)"
unzip -q "$IMAGE_ZIP" -d "$IMAGES" || die "failed to extract images ZIP"
AVB_PUBKEY="$IMAGES/expected-key.avbpubkey"
"$AVB" extract_public_key --key "$AVB_KEY" --output "$AVB_PUBKEY" \
  || die "failed to extract expected AVB public key"
ACTUAL_AVB_PUBLIC_KEY_SHA256="$(sha256sum "$AVB_PUBKEY" | cut -d' ' -f1)"
[ "$ACTUAL_AVB_PUBLIC_KEY_SHA256" = "$PINNED_AVB_PUBLIC_KEY_SHA256" ] \
  || die "AVB public key digest does not match the pinned test-key identity"
printf '%s  expected-key.avbpubkey\n' "$ACTUAL_AVB_PUBLIC_KEY_SHA256" \
  > "$AUDIT/AVB-PUBLIC-KEY-SHA256.txt"

readonly AVB_CHAIN_SPECS="boot:4 dtbo:3 vendor_boot:1 vbmeta_system:2 vbmeta_vendor:5"
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
read -r -a CHAIN_SPECS <<< "$AVB_CHAIN_SPECS"
CHAIN_ARGS=()
for spec in "${CHAIN_SPECS[@]}"; do
  CHAIN_ARGS+=(--expected_chain_partition "$spec:$AVB_PUBKEY")
done
"$AVB" verify_image --image "$IMAGES/vbmeta.img" --key "$AVB_KEY" \
  --follow_chain_partitions "${CHAIN_ARGS[@]}" \
  > "$AUDIT/verify-vbmeta-chain.txt" 2>&1 || die "avbtool vbmeta chain verification failed"
ledger avb_verify_chain 0 >> "$AUDIT/audit-status.txt"

# Bind the distributable boot across both packaging archives. The product boot
# is an intermediate: releasetools rebuilds its ramdisk for target-files, so its
# whole-image bytes may differ. Both boots must embed the exact same Kernel.
unzip -p "$TARGET_FILES" IMAGES/boot.img > "$IMAGES/target-files-boot.img" \
  || die "failed to extract target-files boot.img"
[ -s "$IMAGES/target-files-boot.img" ] || die "target-files boot.img is empty"
cmp "$IMAGES/boot.img" "$IMAGES/target-files-boot.img" \
  || die "images ZIP boot.img does not match target-files boot.img"
BOOT_UNPACK="$(mktemp -d)"
mkdir -p "$BOOT_UNPACK/distribution" "$BOOT_UNPACK/product"
"$UNPACK_BOOTIMG" --boot_img "$IMAGES/boot.img" \
  --out "$BOOT_UNPACK/distribution" > "$AUDIT/distribution-boot-unpack.txt" \
  || die "audited distribution boot.img unpack failed"
"$UNPACK_BOOTIMG" --boot_img "$PRODUCT_BOOT" \
  --out "$BOOT_UNPACK/product" > "$AUDIT/product-boot-unpack.txt" \
  || die "product boot.img unpack failed"
cmp "$BOOT_UNPACK/distribution/kernel" "$KERNEL_IMAGE" \
  || die "distribution boot.img Kernel does not match KERNEL_OBJ Image"
cmp "$BOOT_UNPACK/product/kernel" "$KERNEL_IMAGE" \
  || die "product boot.img Kernel does not match KERNEL_OBJ Image"
{
  printf 'images_zip_boot_matches_target_files_boot=yes\n'
  printf 'distribution_boot_kernel_matches_kernel_image=yes\n'
  printf 'product_boot_kernel_matches_kernel_image=yes\n'
  printf 'images_zip_boot_sha256=%s\n' "$(sha256sum "$IMAGES/boot.img" | cut -d' ' -f1)"
  printf 'target_files_boot_sha256=%s\n' "$(sha256sum "$IMAGES/target-files-boot.img" | cut -d' ' -f1)"
  printf 'product_boot_intermediate_sha256=%s\n' "$(sha256sum "$PRODUCT_BOOT" | cut -d' ' -f1)"
  printf 'kernel_image_sha256=%s\n' "$(sha256sum "$KERNEL_IMAGE" | cut -d' ' -f1)"
} > "$AUDIT/BOOT-BINDING.txt"
python3 - "$AUDIT/BOOT-BINDING.txt" \
  "$(sha256sum "$IMAGES/boot.img" | cut -d' ' -f1)" \
  "$(sha256sum "$PRODUCT_BOOT" | cut -d' ' -f1)" \
  "$(sha256sum "$KERNEL_IMAGE" | cut -d' ' -f1)" <<'PY_BINDING' \
  || die "boot binding evidence schema validation failed"
from pathlib import Path
import sys
expected = [
    ('images_zip_boot_matches_target_files_boot', 'yes'),
    ('distribution_boot_kernel_matches_kernel_image', 'yes'),
    ('product_boot_kernel_matches_kernel_image', 'yes'),
    ('images_zip_boot_sha256', sys.argv[2]),
    ('target_files_boot_sha256', sys.argv[2]),
    ('product_boot_intermediate_sha256', sys.argv[3]),
    ('kernel_image_sha256', sys.argv[4]),
]
actual = []
for line in Path(sys.argv[1]).read_text().splitlines():
    parts = line.split('=', 1)
    if len(parts) != 2:
        raise SystemExit(f'malformed binding entry: {line!r}')
    actual.append(tuple(parts))
if actual != expected:
    raise SystemExit({'expected': expected, 'actual': actual})
print('boot binding evidence schema OK')
PY_BINDING
log "AVB and distributable boot/Image binding OK (pinned test-key identity)"

log "capturing SHA-256"
(
  cd "$ROOT"
  sha256sum "${OTA#"$ROOT"/}" "${TARGET_FILES#"$ROOT"/}" "${IMAGE_ZIP#"$ROOT"/}"
) > "$AUDIT/SHA256SUMS" || die "sha256sum failed"
( cd "$ROOT" && sha256sum -c "$AUDIT/SHA256SUMS" ) \
  > "$AUDIT/sha256-verify.txt" || die "SHA-256 verification failed"
ledger archive_sha256_verify 0 >> "$AUDIT/audit-status.txt"
ledger postbuild_exit 0 >> "$AUDIT/audit-status.txt"

BOOT_BINDING_SHA256="$(sha256sum "$AUDIT/BOOT-BINDING.txt" | cut -d' ' -f1)"
AVB_DIGEST_FILE_SHA256="$(sha256sum "$AUDIT/AVB-PUBLIC-KEY-SHA256.txt" | cut -d' ' -f1)"
ATTESTATION_TMP="$AUDIT/attestation.txt.tmp"
{
  printf 'schema_version=2\n'
  printf 'kernel_commit=%s\n' "$KERNEL_COMMIT"
  printf 'ota_sha256=%s\n' "$(sha256sum "$OTA" | cut -d' ' -f1)"
  printf 'target_files_sha256=%s\n' "$(sha256sum "$TARGET_FILES" | cut -d' ' -f1)"
  printf 'images_zip_sha256=%s\n' "$(sha256sum "$IMAGE_ZIP" | cut -d' ' -f1)"
  printf 'images_zip_boot_sha256=%s\n' "$(sha256sum "$IMAGES/boot.img" | cut -d' ' -f1)"
  printf 'target_files_boot_sha256=%s\n' "$(sha256sum "$IMAGES/target-files-boot.img" | cut -d' ' -f1)"
  printf 'product_boot_intermediate_sha256=%s\n' "$(sha256sum "$PRODUCT_BOOT" | cut -d' ' -f1)"
  printf 'kernel_image_sha256=%s\n' "$(sha256sum "$KERNEL_IMAGE" | cut -d' ' -f1)"
  printf 'kernel_config_sha256=%s\n' "$(sha256sum "$KERNEL_CONFIG" | cut -d' ' -f1)"
  printf 'resolved_manifest_sha256=%s\n' "$(sha256sum "$RESOLVED_MANIFEST" | cut -d' ' -f1)"
  printf 'avb_public_key_sha256=%s\n' "$ACTUAL_AVB_PUBLIC_KEY_SHA256"
  printf 'boot_binding_sha256=%s\n' "$BOOT_BINDING_SHA256"
  printf 'avb_public_key_digest_file_sha256=%s\n' "$AVB_DIGEST_FILE_SHA256"
  printf 'build_exit_file_sha256=%s\n' "$(sha256sum "$BUILD_EXIT_FILE" | cut -d' ' -f1)"
  printf 'postbuild_exit_file_sha256=%s\n' "$POSTBUILD_EXIT_SHA256"
  printf 'audit_ledger_sha256=%s\n' "$(sha256sum "$AUDIT/audit-status.txt" | cut -d' ' -f1)"
} > "$ATTESTATION_TMP"
mv -T "$ATTESTATION_TMP" "$AUDIT/attestation.txt"

# renameat2(RENAME_NOREPLACE) atomically publishes the complete directory and
# refuses a destination created by any process, including one that ignores our lock.
python3 - "$AUDIT" "$AUDIT_FINAL" <<'PY_PUBLISH' \
  || die "atomic no-clobber audit publication failed: $AUDIT_FINAL"
import ctypes
import os
import sys
source, destination = map(os.fsencode, sys.argv[1:3])
libc = ctypes.CDLL(None, use_errno=True)
renameat2 = libc.renameat2
renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameat2.restype = ctypes.c_int
if renameat2(-100, source, -100, destination, 1) != 0:  # AT_FDCWD, RENAME_NOREPLACE
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error), sys.argv[2])
PY_PUBLISH
AUDIT=""
log "audit complete and atomically published without overwrite: $AUDIT_FINAL"
cat "$AUDIT_FINAL/audit-status.txt"
exit 0
