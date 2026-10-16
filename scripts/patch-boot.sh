#!/bin/bash
# Patch the stock boot image with Magisk on a Linux PC (no phone needed).
# The arm64 Magisk tools run through qemu-user via binfmt_misc.
#
# Usage: scripts/patch-boot.sh <boot_stock.img> <Magisk-vXX.apk> [workdir]
# Result: <workdir>/new-boot.img (same size as the boot partition, 40 MiB on Blake)
#
# Host packages: sudo apt install qemu-user-static binfmt-support unzip
# Tested with Magisk v30.7.
set -euo pipefail

BOOT=$(realpath "${1:?usage: $0 <boot_stock.img> <Magisk.apk> [workdir]}")
APK=$(realpath "${2:?usage: $0 <boot_stock.img> <Magisk.apk> [workdir]}")
WORK=$(realpath -m "${3:-magisk-patch}")
mkdir -p "$WORK"; cd "$WORK"

unzip -o -q "$APK" 'lib/arm64-v8a/*' 'assets/*'
cp -f lib/arm64-v8a/libmagisk.so      magisk
cp -f lib/arm64-v8a/libmagiskinit.so  magiskinit
cp -f lib/arm64-v8a/libmagiskboot.so  magiskboot
cp -f lib/arm64-v8a/libinit-ld.so     init-ld
cp -f lib/arm64-v8a/libbusybox.so     busybox
cp -f assets/boot_patch.sh assets/util_functions.sh assets/stub.apk .
chmod +x magisk magiskinit magiskboot init-ld busybox boot_patch.sh

./magiskboot >/dev/null 2>&1 || [ $? -ne 126 ] || { echo "arm64 binaries do not run: install qemu-user-static + binfmt-support"; exit 1; }

rm -f new-boot.img; cp -f "$BOOT" input-boot.img   # not "stock_boot.img": boot_patch.sh uses that name itself
# Keep dm-verity and forced encryption as on stock (userdata is FBE-encrypted).
# boot_patch.sh needs bash, plain sh fails.
KEEPVERITY=true KEEPFORCEENCRYPT=true bash ./boot_patch.sh input-boot.img

[ -f new-boot.img ] || { echo "patch failed"; exit 1; }
[ "$(stat -c%s new-boot.img)" = "$(stat -c%s "$BOOT")" ] || echo "note: new-boot.img size differs from the input"
ls -l "$WORK/new-boot.img"
