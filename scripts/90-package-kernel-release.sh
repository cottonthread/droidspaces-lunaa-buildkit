#!/usr/bin/env bash
# 90-package-kernel-release.sh — create and independently verify the public,
# Kernel-only Droidspaces release archive after the artifact-bound audit passes.
#
# Run:
#   ROOT=/path OUT_REL=out-droidspaces-full \
#   AUDIT_DIR=/path/to/successful-audit \
#   BUILD_EXIT_FILE=/path/to/build.exit \
#   POSTBUILD_EXIT_FILE=/path/to/postbuild.exit \
#   EXPECTED_KERNEL_COMMIT=<40-hex commit> \
#   KERNEL_SOURCE_URL=https://github.com/<owner>/<repo>/commit/<commit> \
#   bash scripts/90-package-kernel-release.sh

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_root

log "=== 90-package-kernel-release ==="

for cmd in cmp flock git grep gzip lz4 od python3 sha256sum unzip zip; do
  require_cmd "$cmd"
done

OUT="$OUT_DIR"
PRODUCT_OUT="$OUT/target/product/lunaa"
KERNEL_OBJ="$PRODUCT_OUT/obj/KERNEL_OBJ"
KERNEL_TREE="$ROOT/kernel/oneplus/sm8350"
AUDIT="${AUDIT_DIR:-$ROOT/droidspaces-audit}"
RELEASE_DIR="${RELEASE_DIR:-$ROOT/release/kernel}"
BUILD_EXIT_FILE="${BUILD_EXIT_FILE:-$ROOT/droidspaces-full-build.exit}"
POSTBUILD_EXIT_FILE="${POSTBUILD_EXIT_FILE:-$ROOT/droidspaces-postbuild.exit}"
readonly PINNED_AVB_PUBLIC_KEY_SHA256="7728e30f50bfa5cea165f473175a08803f6a8346642b5aa10913e9d9e6defef6"
readonly PINNED_AVB_KEY="$ROOT/external/avb/test/data/testkey_rsa4096.pem"
[ -z "${EXPECTED_AVB_PUBLIC_KEY_SHA256+x}" ] \
  || die "EXPECTED_AVB_PUBLIC_KEY_SHA256 override is forbidden in release packaging mode"
[ -z "${AVB_KEY+x}" ] || die "AVB_KEY override is forbidden in release packaging mode"

BOOT="$PRODUCT_OUT/boot.img"
IMAGE="$KERNEL_OBJ/arch/arm64/boot/Image"
CONFIG="$KERNEL_OBJ/.config"
KERNEL_RELEASE_FILE="$KERNEL_OBJ/include/config/kernel.release"
COMPILE_HEADER="$KERNEL_OBJ/include/generated/compile.h"
RESOLVED_MANIFEST="$OUT/reproducibility/resolved-manifest-before-build.xml"
AUDIT_LEDGER="$AUDIT/audit-status.txt"
AUDIT_ATTESTATION="$AUDIT/attestation.txt"
AUDIT_BOOT_BINDING="$AUDIT/BOOT-BINDING.txt"
AUDIT_AVB_DIGEST="$AUDIT/AVB-PUBLIC-KEY-SHA256.txt"
AVB="$OUT/host/linux-x86/bin/avbtool"
UNPACK_BOOTIMG="$OUT/host/linux-x86/bin/unpack_bootimg"
AVB_KEY="$PINNED_AVB_KEY"

for f in "$BUILD_EXIT_FILE" "$POSTBUILD_EXIT_FILE"; do
  [ -f "$f" ] || die "required exit file missing: $f"
  [ "$(tr -d '\r\n[:space:]' < "$f")" = 0 ] || die "exit file is not zero: $f"
done
for f in "$BOOT" "$IMAGE" "$CONFIG" "$KERNEL_RELEASE_FILE" \
         "$COMPILE_HEADER" "$RESOLVED_MANIFEST" "$AUDIT_LEDGER" \
         "$AUDIT_ATTESTATION" "$AUDIT_BOOT_BINDING" "$AUDIT_AVB_DIGEST"; do
  [ -s "$f" ] || die "required release input missing or empty: $f"
done
[ -x "$AVB" ] || die "avbtool not executable: $AVB"
[ -x "$UNPACK_BOOTIMG" ] || die "unpack_bootimg not executable: $UNPACK_BOOTIMG"
[ -f "$AVB_KEY" ] || die "AVB key not found: $AVB_KEY"

# Require the exact audit schema: every expected key once, no unknown keys.
python3 - "$AUDIT_LEDGER" <<'PY_LEDGER' || die "audit ledger schema validation failed"
from pathlib import Path
import sys
expected = [
    'build_exit', 'ota_zip_test', 'target_files_zip_test',
    'image_zip_generation', 'image_zip_test', 'ota_signature_check',
    'vintf_check', 'fcm_sysvipc_check', 'avb_parse_boot',
    'avb_parse_dtbo', 'avb_parse_vendor_boot', 'avb_parse_vbmeta',
    'avb_parse_vbmeta_system', 'avb_parse_vbmeta_vendor',
    'avb_verify_boot', 'avb_verify_dtbo', 'avb_verify_vendor_boot',
    'avb_verify_chain', 'archive_sha256_verify', 'postbuild_exit',
]
lines = Path(sys.argv[1]).read_text().splitlines()
parsed = []
for line in lines:
    parts = line.split('=', 1)
    if len(parts) != 2 or parts[1] != '0':
        raise SystemExit(f'malformed or non-zero ledger entry: {line!r}')
    parsed.append(parts[0])
if parsed != expected:
    raise SystemExit({'expected': expected, 'actual': parsed})
print('audit ledger schema OK: 20 exact zero-valued entries')
PY_LEDGER

KERNEL_RELEASE="$(tr -d '\r\n' < "$KERNEL_RELEASE_FILE")"
[ -n "$KERNEL_RELEASE" ] || die "empty Kernel release"
case "$KERNEL_RELEASE" in
  *-dirty*) die "refusing to publish a dirty Kernel: $KERNEL_RELEASE" ;;
esac
grep -Eq '^#define LINUX_COMPILE_BY "android"$' "$COMPILE_HEADER" \
  || die "Kernel compile user is not android"
grep -Eq '^#define LINUX_COMPILE_HOST "repro-build"$' "$COMPILE_HEADER" \
  || die "Kernel compile host is not repro-build"

# Mirror the complete preflight config gate and explicitly require namespaces.
for required in \
  CONFIG_AS_IS_LLVM=y \
  CONFIG_NET_SCH_TBF=y \
  CONFIG_KFENCE=y \
  CONFIG_KFENCE_SAMPLE_INTERVAL=0 \
  CONFIG_SYSVIPC=y \
  CONFIG_POSIX_MQUEUE=y \
  CONFIG_NAMESPACES=y \
  CONFIG_IPC_NS=y \
  CONFIG_PID_NS=y \
  CONFIG_QCOM_SMEM=y \
  CONFIG_OPLUS_FEATURE_PROJECTINFO=y
do
  grep -qx "$required" "$CONFIG" || die "required Kernel config missing: $required"
done

git -C "$KERNEL_TREE" diff --quiet --ignore-submodules -- \
  || die "Kernel worktree has unstaged changes"
git -C "$KERNEL_TREE" diff --cached --quiet --ignore-submodules -- \
  || die "Kernel worktree has staged changes"
[ -z "$(git -C "$KERNEL_TREE" status --porcelain --untracked-files=all)" ] \
  || die "Kernel worktree has tracked or untracked changes"
KERNEL_COMMIT="$(git -C "$KERNEL_TREE" rev-parse HEAD)"
[[ "${EXPECTED_KERNEL_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] \
  || die "EXPECTED_KERNEL_COMMIT must be a 40-character lowercase commit"
[ "$KERNEL_COMMIT" = "$EXPECTED_KERNEL_COMMIT" ] \
  || die "Kernel HEAD $KERNEL_COMMIT does not match EXPECTED_KERNEL_COMMIT"
[ -n "${KERNEL_SOURCE_URL:-}" ] || die "KERNEL_SOURCE_URL is required"
case "$KERNEL_SOURCE_URL" in
  */commit/"$KERNEL_COMMIT") ;;
  *) die "KERNEL_SOURCE_URL must end in /commit/$KERNEL_COMMIT" ;;
esac
cmp "$IMAGE" "$PRODUCT_OUT/kernel" \
  || die "KERNEL_OBJ Image does not match product kernel"

# Resolve the exact audited archive paths without executing package metadata.
PACKAGE_ENV="$OUT/droidspaces-package.env"
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
    resolved = Path(raw).resolve(strict=True)
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
if parsed['IMAGE_ZIP'] != product / (ota.stem + '-images.zip'):
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
for f in "$OTA" "$TARGET_FILES" "$IMAGE_ZIP"; do
  [ -s "$f" ] || die "audited archive missing or empty: $f"
done

RELEASE_DATE="${RELEASE_DATE:-$(date '+%Y%m%d')}"
[[ "$RELEASE_DATE" =~ ^[0-9]{8}$ ]] || die "RELEASE_DATE must match YYYYMMDD"
SAFE_RELEASE="$(printf '%s' "$KERNEL_RELEASE" | tr -c 'A-Za-z0-9._-' '-')"
ARCHIVE_BASENAME="droidspaces-lunaa-kernel-${SAFE_RELEASE}-${RELEASE_DATE}"
FINAL_RELEASE_DIR="$RELEASE_DIR/$ARCHIVE_BASENAME"
ARCHIVE="$FINAL_RELEASE_DIR/$ARCHIVE_BASENAME.zip"
ARCHIVE_SHA="$FINAL_RELEASE_DIR/$ARCHIVE_BASENAME.zip.sha256"

if [ -e "$RELEASE_DIR" ] || [ -L "$RELEASE_DIR" ]; then
  [ -d "$RELEASE_DIR" ] && [ ! -L "$RELEASE_DIR" ] \
    || die "release destination is not a real directory: $RELEASE_DIR"
else
  mkdir -p "$RELEASE_DIR"
fi
exec 9> "$RELEASE_DIR/.package-kernel-release.lock"
flock -n 9 || die "another Kernel release packaging process holds the lock"
[ ! -e "$FINAL_RELEASE_DIR" ] && [ ! -L "$FINAL_RELEASE_DIR" ] \
  || die "release destination already exists: $FINAL_RELEASE_DIR"

WORK="$(mktemp -d "$RELEASE_DIR/.${ARCHIVE_BASENAME}.stage.XXXXXXXX")"
VERIFY="$(mktemp -d "$RELEASE_DIR/.${ARCHIVE_BASENAME}.verify.XXXXXXXX")"
AUDITED_IMAGES="$(mktemp -d "$RELEASE_DIR/.${ARCHIVE_BASENAME}.audit.XXXXXXXX")"
PUBLISH_STAGE="$(mktemp -d "$RELEASE_DIR/.${ARCHIVE_BASENAME}.publish.XXXXXXXX")"
cleanup() {
  rm -rf "$WORK" "$VERIFY" "$AUDITED_IMAGES" "$PUBLISH_STAGE"
}
trap cleanup EXIT
PKG="$WORK/$ARCHIVE_BASENAME"
mkdir -p "$PKG"

unzip -p "$IMAGE_ZIP" boot.img > "$AUDITED_IMAGES/boot.img" \
  || die "failed to extract audited boot.img from images ZIP"
unzip -p "$TARGET_FILES" IMAGES/boot.img > "$AUDITED_IMAGES/target-files-boot.img" \
  || die "failed to extract audited boot.img from target-files"
for f in "$AUDITED_IMAGES/boot.img" "$AUDITED_IMAGES/target-files-boot.img"; do
  [ -s "$f" ] || die "audited distributable boot.img is empty: $f"
done
cmp "$AUDITED_IMAGES/boot.img" "$AUDITED_IMAGES/target-files-boot.img" \
  || die "images ZIP boot.img does not match target-files boot.img"
mkdir -p "$AUDITED_IMAGES/distribution-unpacked" "$AUDITED_IMAGES/product-unpacked"
"$UNPACK_BOOTIMG" --boot_img "$AUDITED_IMAGES/boot.img" \
  --out "$AUDITED_IMAGES/distribution-unpacked" \
  > "$AUDITED_IMAGES/distribution-boot-unpack.txt" \
  || die "audited distribution boot.img unpack failed"
"$UNPACK_BOOTIMG" --boot_img "$BOOT" --out "$AUDITED_IMAGES/product-unpacked" \
  > "$AUDITED_IMAGES/product-boot-unpack.txt" \
  || die "product boot.img unpack failed"
cmp "$AUDITED_IMAGES/distribution-unpacked/kernel" "$IMAGE" \
  || die "audited distribution boot.img Kernel does not match release Image"
cmp "$AUDITED_IMAGES/product-unpacked/kernel" "$IMAGE" \
  || die "product boot.img Kernel does not match release Image"

# Recompute and strictly validate every public audit evidence file before copying it.
EXPECTED_BOOT_SHA256="$(sha256sum "$AUDITED_IMAGES/boot.img" | cut -d' ' -f1)"
EXPECTED_PRODUCT_BOOT_SHA256="$(sha256sum "$BOOT" | cut -d' ' -f1)"
EXPECTED_IMAGE_SHA256="$(sha256sum "$IMAGE" | cut -d' ' -f1)"
python3 - "$AUDIT_BOOT_BINDING" "$EXPECTED_BOOT_SHA256" \
  "$EXPECTED_PRODUCT_BOOT_SHA256" "$EXPECTED_IMAGE_SHA256" <<'PY_BINDING' \
  || die "boot binding evidence does not match current release inputs"
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
print('boot binding evidence matches current release inputs')
PY_BINDING
EXPECTED_AVB_DIGEST_LINE="$PINNED_AVB_PUBLIC_KEY_SHA256  expected-key.avbpubkey"
[ "$(tr -d '\r\n' < "$AUDIT_AVB_DIGEST")" = "$EXPECTED_AVB_DIGEST_LINE" ] \
  || die "AVB public-key digest evidence has unexpected content"

AVB_PUBKEY="$AUDITED_IMAGES/expected-key.avbpubkey"
"$AVB" extract_public_key --key "$AVB_KEY" --output "$AVB_PUBKEY" \
  || die "failed to extract expected AVB public key"
[ "$(sha256sum "$AVB_PUBKEY" | cut -d' ' -f1)" = "$PINNED_AVB_PUBLIC_KEY_SHA256" ] \
  || die "AVB key does not match the pinned test-key digest"

# Validate schema v2 and bind exits, audit evidence and all current release inputs.
python3 - "$AUDIT_ATTESTATION" \
  "$KERNEL_COMMIT" \
  "$(sha256sum "$OTA" | cut -d' ' -f1)" \
  "$(sha256sum "$TARGET_FILES" | cut -d' ' -f1)" \
  "$(sha256sum "$IMAGE_ZIP" | cut -d' ' -f1)" \
  "$EXPECTED_BOOT_SHA256" \
  "$(sha256sum "$AUDITED_IMAGES/target-files-boot.img" | cut -d' ' -f1)" \
  "$EXPECTED_PRODUCT_BOOT_SHA256" \
  "$EXPECTED_IMAGE_SHA256" \
  "$(sha256sum "$CONFIG" | cut -d' ' -f1)" \
  "$(sha256sum "$RESOLVED_MANIFEST" | cut -d' ' -f1)" \
  "$PINNED_AVB_PUBLIC_KEY_SHA256" \
  "$(sha256sum "$AUDIT_BOOT_BINDING" | cut -d' ' -f1)" \
  "$(sha256sum "$AUDIT_AVB_DIGEST" | cut -d' ' -f1)" \
  "$(sha256sum "$BUILD_EXIT_FILE" | cut -d' ' -f1)" \
  "$(sha256sum "$POSTBUILD_EXIT_FILE" | cut -d' ' -f1)" \
  "$(sha256sum "$AUDIT_LEDGER" | cut -d' ' -f1)" <<'PY_ATTEST' \
  || die "audit attestation does not match current release inputs"
from pathlib import Path
import sys
keys = [
    'schema_version', 'kernel_commit', 'ota_sha256', 'target_files_sha256',
    'images_zip_sha256', 'images_zip_boot_sha256', 'target_files_boot_sha256',
    'product_boot_intermediate_sha256', 'kernel_image_sha256', 'kernel_config_sha256',
    'resolved_manifest_sha256', 'avb_public_key_sha256', 'boot_binding_sha256',
    'avb_public_key_digest_file_sha256', 'build_exit_file_sha256',
    'postbuild_exit_file_sha256', 'audit_ledger_sha256',
]
values = ['2', *sys.argv[2:]]
lines = Path(sys.argv[1]).read_text().splitlines()
actual = []
for line in lines:
    parts = line.split('=', 1)
    if len(parts) != 2:
        raise SystemExit(f'malformed attestation entry: {line!r}')
    actual.append(tuple(parts))
expected = list(zip(keys, values))
if actual != expected:
    raise SystemExit({'expected': expected, 'actual': actual})
print('audit attestation v2 matches all current release inputs')
PY_ATTEST

# Parse and inspect the ramdisk archive without writing its members to disk.
RAMDISK_INPUT="$AUDITED_IMAGES/distribution-unpacked/ramdisk"
RAMDISK_CPIO="$AUDITED_IMAGES/ramdisk.cpio"
case "$(od -An -tx1 -N4 "$RAMDISK_INPUT" | tr -d ' \n')" in
  30373037)
    RAMDISK_FORMAT=newc
    cp "$RAMDISK_INPUT" "$RAMDISK_CPIO"
    ;;
  04224d18|02214c18)
    RAMDISK_FORMAT=newc_lz4
    "$OUT/host/linux-x86/bin/lz4" -d -c "$RAMDISK_INPUT" > "$RAMDISK_CPIO" \
      || die "boot ramdisk LZ4 decompression failed"
    ;;
  1f8b0800|1f8b0808)
    RAMDISK_FORMAT=newc_gzip
    gzip -d -c "$RAMDISK_INPUT" > "$RAMDISK_CPIO" \
      || die "boot ramdisk gzip decompression failed"
    ;;
  *) die "unsupported boot ramdisk compression or format" ;;
esac
python3 - "$RAMDISK_CPIO" "$RAMDISK_FORMAT" \
  > "$PKG/BOOT-RAMDISK-CONTENTS.txt" <<'PY_RAMDISK' \
  || die "boot ramdisk content audit failed"
from pathlib import Path, PurePosixPath
import stat
import sys
blob = Path(sys.argv[1]).read_bytes()
pos = 0
entries = []
archive_count = 0
forbidden_names = (
    'magisk', 'overlay.d', 'adb_keys', 'authorized_keys', '.ssh',
    'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519', '.p12', '.pfx', '.jks',
    'keymint', 'credential', 'credentials',
)
forbidden_data = (
    b'-----begin private key-----', b'-----begin rsa private key-----',
    b'-----begin ec private key-----', b'-----begin dsa private key-----',
    b'-----begin openssh private key-----', b'-----begin encrypted private key-----',
    b'-----begin pgp private key block-----', b'openssh-key-v1\x00',
    b'/data/adb/magisk', b'/.magisk', b'authorized_keys', b'adb_keys',
    b'aws_secret_access_key', b'client_secret', b'private_key_id',
)
def align4(value):
    return (value + 3) & ~3
def skip_zero_padding(offset):
    while offset < len(blob) and blob[offset] == 0:
        offset += 1
    return offset
while True:
    pos = skip_zero_padding(pos)
    if pos == len(blob):
        break
    archive_count += 1
    archive_has_trailer = False
    while pos + 110 <= len(blob):
        magic = blob[pos:pos + 6]
        if magic not in (b'070701', b'070702'):
            raise SystemExit(f'invalid cpio magic at offset {pos}: {magic!r}')
        try:
            fields = [int(blob[pos + 6 + i * 8:pos + 14 + i * 8], 16) for i in range(13)]
        except ValueError as exc:
            raise SystemExit(f'invalid hexadecimal cpio header at offset {pos}: {exc}')
        mode, size, name_size = fields[1], fields[6], fields[11]
        if name_size < 1:
            raise SystemExit(f'invalid cpio filename size at offset {pos}')
        name_start = pos + 110
        raw_name = blob[name_start:name_start + name_size]
        if len(raw_name) != name_size or not raw_name.endswith(b'\0'):
            raise SystemExit('invalid cpio filename')
        name = raw_name[:-1].decode('utf-8', 'surrogateescape')
        data_start = align4(name_start + name_size)
        if any(blob[name_start + name_size:data_start]):
            raise SystemExit(f'non-zero filename padding for {name!r}')
        data = blob[data_start:data_start + size]
        if len(data) != size:
            raise SystemExit(f'truncated cpio data for {name!r}')
        next_pos = align4(data_start + size)
        pos = next_pos
        if name == 'TRAILER!!!':
            if size != 0:
                raise SystemExit('cpio trailer unexpectedly contains data')
            archive_has_trailer = True
            break
        pure = PurePosixPath(name)
        if not name or name.startswith('/') or '..' in pure.parts or '\x00' in name:
            raise SystemExit(f'unsafe ramdisk path: {name!r}')
        lower_name = name.lower()
        if any(marker in lower_name for marker in forbidden_names):
            raise SystemExit(f'forbidden ramdisk path marker: {name!r}')
        lower_data = data.lower()
        if any(marker in lower_data for marker in forbidden_data):
            raise SystemExit(f'forbidden ramdisk content marker in: {name!r}')
        entries.append((archive_count, mode, size, name))
    if not archive_has_trailer:
        raise SystemExit(f'cpio trailer not found in archive {archive_count}')
    next_nonzero = skip_zero_padding(pos)
    if next_nonzero == len(blob):
        pos = next_nonzero
        break
    if blob[next_nonzero:next_nonzero + 6] not in (b'070701', b'070702'):
        raise SystemExit(f'unparsed non-zero bytes after cpio trailer at offset {next_nonzero}')
    pos = next_nonzero
if archive_count < 1:
    raise SystemExit('no cpio archive found')
print(f'boot_ramdisk_format={sys.argv[2]}')
print(f'boot_ramdisk_archive_count={archive_count}')
print(f'boot_ramdisk_entry_count={len(entries)}')
print('boot_ramdisk_sensitive_marker_scan=clear')
print('boot_ramdisk_trailing_data_check=clear')
print('')
print('archive mode size path')
for archive, mode, size, name in entries:
    print(f'{archive} {stat.S_IMODE(mode):04o} {size} {name}')
PY_RAMDISK

cp "$AUDITED_IMAGES/boot.img" "$PKG/boot.img"
cp "$IMAGE" "$PKG/Image"
cp "$CONFIG" "$PKG/kernel.config"
cp "$RESOLVED_MANIFEST" "$PKG/resolved-manifest.xml"
cp "$AUDIT_LEDGER" "$PKG/FIRMWARE-AUDIT-STATUS.txt"
cp "$AUDIT_ATTESTATION" "$PKG/AUDIT-ATTESTATION.txt"
cp "$AUDIT_BOOT_BINDING" "$PKG/BOOT-BINDING.txt"
cp "$AUDIT_AVB_DIGEST" "$PKG/AVB-PUBLIC-KEY-SHA256.txt"

"$AVB" info_image --image "$PKG/boot.img" > "$PKG/BOOT-AVB-INFO.txt" \
  || die "boot.img AVB metadata parse failed"
"$AVB" verify_image --image "$PKG/boot.img" --key "$AVB_KEY" \
  > "$PKG/BOOT-AVB-VERIFY.txt" 2>&1 || die "boot.img AVB verification failed"

BUILD_FINGERPRINT=""
for prop in "$PRODUCT_OUT/system/build.prop" \
            "$PRODUCT_OUT/system/system/build.prop" \
            "$PRODUCT_OUT/vendor/build.prop"; do
  [ -f "$prop" ] || continue
  line="$(grep -m1 '^ro.build.fingerprint=' "$prop" || true)"
  if [ -n "$line" ]; then
    BUILD_FINGERPRINT="${line#*=}"
    break
  fi
done
MANIFEST_SHA256="$(sha256sum "$RESOLVED_MANIFEST" | cut -d' ' -f1)"
AUDIT_SHA256="$(sha256sum "$AUDIT_LEDGER" | cut -d' ' -f1)"

cat > "$PKG/PROVENANCE.txt" <<EOF
Device: Realme GT Master Edition (lunaa / RMX3360)
Android / ROM: LineageOS 23.2 / Android 16
Kernel release: $KERNEL_RELEASE
Kernel commit: $KERNEL_COMMIT
Kernel source: $KERNEL_SOURCE_URL
Kernel build identity: android@repro-build
Android build fingerprint: ${BUILD_FINGERPRINT:-not recorded}
Resolved manifest SHA-256: $MANIFEST_SHA256
Firmware audit ledger SHA-256: $AUDIT_SHA256
AVB public key SHA-256: $PINNED_AVB_PUBLIC_KEY_SHA256
Package date: $RELEASE_DATE
Build type: userdebug / AOSP test keys
Reproducibility scope: frozen source inputs and documented build path; no bit-for-bit claim
EOF

cat > "$PKG/README.md" <<'EOF'
# Droidspaces Kernel for Realme GT Master Edition

This Kernel-only package targets the Realme GT Master Edition
(`lunaa` / `RMX3360`) on the matching LineageOS 23.2 / Android 16 build.
Read `PROVENANCE.txt` and verify `SHA256SUMS` before using any file.

## Contents

- `boot.img`: complete, unmodified and **not Magisk-patched** boot image.
- `Image`: raw arm64 Kernel image for inspection or advanced integration; it is
  not a general-purpose fastboot replacement for `boot.img`.
- `kernel.config`: final build configuration.
- `resolved-manifest.xml`: frozen, resolved source inputs used by the build.
- `PROVENANCE.txt`: exact immutable source commit and build identity.
- `BOOT-AVB-INFO.txt` / `BOOT-AVB-VERIFY.txt`: boot AVB evidence.
- `AVB-PUBLIC-KEY-SHA256.txt`: pinned AOSP test-key public-key digest.
- `FIRMWARE-AUDIT-STATUS.txt` / `AUDIT-ATTESTATION.txt`: mandatory offline
  firmware audit result and hashes binding the audited artifacts.
- `BOOT-BINDING.txt`: evidence that the audited images ZIP boot image matches
  this boot image and that its embedded Kernel matches `Image`.
- `BOOT-RAMDISK-CONTENTS.txt`: ramdisk inventory and sensitive-marker scan.

## Safety and installation scope

This package is not an AnyKernel package and has not been validated on arbitrary
ROM builds. Back up the currently installed boot image and confirm the exact ROM,
device, bootloader-unlock state and active-slot procedure before flashing.

Flashing the supplied unpatched `boot.img` replaces the current boot image and
therefore also replaces an existing Magisk-patched boot image. If Magisk root is
required, patch this exact supplied `boot.img` yourself with your trusted Magisk
installation, then validate the resulting image before flashing. No pre-patched
image is distributed.

Do not relock the bootloader based on this package. The build uses AOSP test keys,
and safe relocking was not validated. Droidspaces userspace, its application and
its Magisk module are separate components and are not embedded in this package.

Validated status remains **Partial**: earlier device testing covered Magisk root,
the Droidspaces daemon, MainActivity and two `droidspaces check` runs. Full
container lifecycle, GPU acceleration and long-term stability remain untested.
EOF

(
  cd "$PKG"
  sha256sum boot.img Image kernel.config resolved-manifest.xml PROVENANCE.txt \
    README.md BOOT-AVB-INFO.txt BOOT-AVB-VERIFY.txt \
    AVB-PUBLIC-KEY-SHA256.txt FIRMWARE-AUDIT-STATUS.txt \
    AUDIT-ATTESTATION.txt BOOT-BINDING.txt BOOT-RAMDISK-CONTENTS.txt \
    > SHA256SUMS
  sha256sum -c SHA256SUMS
)

ARCHIVE_TMP="$WORK/$ARCHIVE_BASENAME.zip"
ARCHIVE_SHA_TMP="$WORK/$ARCHIVE_BASENAME.zip.sha256"
(
  cd "$WORK"
  zip -X -9 -r "$ARCHIVE_TMP" "$ARCHIVE_BASENAME" >/dev/null
)
unzip -t "$ARCHIVE_TMP" >/dev/null || die "Kernel-only ZIP integrity test failed"
unzip -q "$ARCHIVE_TMP" -d "$VERIFY" || die "Kernel-only ZIP extraction failed"
(
  cd "$VERIFY/$ARCHIVE_BASENAME"
  sha256sum -c SHA256SUMS
) || die "internal Kernel-only checksums failed"
cmp "$AUDITED_IMAGES/boot.img" "$VERIFY/$ARCHIVE_BASENAME/boot.img" \
  || die "packaged boot.img does not match audited distribution boot"
cmp "$IMAGE" "$VERIFY/$ARCHIVE_BASENAME/Image" \
  || die "packaged Image does not match release OUT"
cmp "$CONFIG" "$VERIFY/$ARCHIVE_BASENAME/kernel.config" \
  || die "packaged Kernel config does not match release OUT"
cmp "$RESOLVED_MANIFEST" "$VERIFY/$ARCHIVE_BASENAME/resolved-manifest.xml" \
  || die "packaged resolved manifest does not match release OUT"
"$AVB" verify_image --image "$VERIFY/$ARCHIVE_BASENAME/boot.img" --key "$AVB_KEY" \
  > /dev/null 2>&1 || die "extracted package boot.img AVB verification failed"
SECOND_UNPACK="$VERIFY/unpacked-boot"
"$UNPACK_BOOTIMG" --boot_img "$VERIFY/$ARCHIVE_BASENAME/boot.img" --out "$SECOND_UNPACK" \
  > /dev/null || die "extracted package boot.img unpack failed"
cmp "$SECOND_UNPACK/kernel" "$VERIFY/$ARCHIVE_BASENAME/Image" \
  || die "extracted package boot Kernel does not match packaged Image"

(
  cd "$WORK"
  sha256sum "$(basename "$ARCHIVE_TMP")" > "$(basename "$ARCHIVE_SHA_TMP")"
  sha256sum -c "$(basename "$ARCHIVE_SHA_TMP")"
)
# Publish the verified ZIP and checksum as one complete directory transaction.
# renameat2(RENAME_NOREPLACE) is atomic and cannot leave a one-sided asset pair.
cp "$ARCHIVE_TMP" "$PUBLISH_STAGE/$(basename "$ARCHIVE")" \
  || die "archive staging copy failed"
cp "$ARCHIVE_SHA_TMP" "$PUBLISH_STAGE/$(basename "$ARCHIVE_SHA")" \
  || die "checksum staging copy failed"
(
  cd "$PUBLISH_STAGE"
  sha256sum -c "$(basename "$ARCHIVE_SHA")"
) || die "staged publication checksum verification failed"
python3 - "$PUBLISH_STAGE" "$FINAL_RELEASE_DIR" <<'PY_PUBLISH' \
  || die "atomic no-clobber release publication failed: $FINAL_RELEASE_DIR"
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
PUBLISH_STAGE=""
(
  cd "$FINAL_RELEASE_DIR"
  sha256sum -c "$(basename "$ARCHIVE_SHA")"
) || die "published archive checksum verification failed"

log "Kernel-only release package complete"
log "archive: $ARCHIVE"
log "checksum: $ARCHIVE_SHA"
log "Kernel release: $KERNEL_RELEASE"
log "Kernel source: $KERNEL_SOURCE_URL"
exit 0
