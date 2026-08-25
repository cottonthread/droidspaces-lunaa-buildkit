#!/usr/bin/env bash
# 10-install-deps.sh — install the documented dependency set.
#
# This script only *prints* the command; it does not run sudo silently.
# Run with INSTALL=1 to actually execute (you will be prompted for sudo).

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "=== 10-install-deps ==="

# Requires Debian/Ubuntu package names. On other distros, adapt manually and
# refer to the current LineageOS build documentation.
PACKAGES="
bc bison build-essential ccache curl flex
g++-multilib gcc-multilib git git-lfs gnupg gperf imagemagick
lib32ncurses-dev lib32readline-dev lib32z1-dev
liblz4-tool libncurses-dev libsdl1.2-dev libssl-dev
libwxgtk3.0-gtk3-dev libxml2 libxml2-utils lzop pngcrush
rsync schedtool squashfs-tools xsltproc zip zlib1g-dev
python-is-python3 erofs-utils lz4 xxd
protobuf-compiler python3-protobuf libdw-dev libelf-dev libgnutls28-dev
"

log "target packages:"
echo "$PACKAGES" | tr '\n' ' '; echo

if [ "${INSTALL:-0}" = "1" ]; then
  # shellcheck disable=SC2086
  sudo apt update
  # shellcheck disable=SC2086
  sudo apt install -y $PACKAGES
  log "dependencies installed"
else
  log "dry-run: re-run with INSTALL=1 to install (e.g. INSTALL=1 bash scripts/10-install-deps.sh)"
fi

# 'repo' is not an apt package on all distros; note the recommended bootstrap.
log "note: install 'repo' per https://gerrit.googlesource.com/git-repo/ if absent"
exit 0
