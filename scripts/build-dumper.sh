#!/bin/bash
# Build recovery-dumper.img for the Shelly Wall Display XL (Blake, RK3566).
#
# The image contains a kernel built from Rockchip's public 4.19 tree with the
# device's own kernel config, plus a tiny busybox initramfs (dumper/rootfs/init)
# that exports the whole eMMC as a USB mass storage device.
#
# Usage: scripts/build-dumper.sh <device-kernel-config> [workdir]
#   <device-kernel-config>  plain text config, from the display:
#                           adb shell zcat /proc/config.gz > device.config
#   [workdir]               default: ./build
#
# Host packages (Debian/Ubuntu/Mint):
#   sudo apt install git gcc-aarch64-linux-gnu bc bison flex libssl-dev \
#                    python-is-python3 cpio curl
set -euo pipefail

CONFIG=$(realpath "${1:?usage: $0 <device-kernel-config> [workdir]}")
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(realpath -m "${2:-build}")
mkdir -p "$WORK"; cd "$WORK"

# Exact commit of rockchip-linux/kernel (branch develop-4.19) used on 2026-10-15
KERNEL_COMMIT=f39b590ea11da2d897644e42119ba5099b2eefc8
# Static arm64 busybox from Ubuntu (busybox-static 1:1.38.0-3ubuntu5)
BUSYBOX_DEB=http://ports.ubuntu.com/pool/universe/b/busybox/busybox-static_1.38.0-3ubuntu5_arm64.deb
BUSYBOX_SHA256=f0e633e4b38b46b8bb4928489155c5edf3ca04beda2d555bbdd193e54e7c9315

export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-

# 1. Kernel source
if [ ! -d kernel/.git ]; then
  git init -q kernel
  git -C kernel fetch -q --depth 1 https://github.com/rockchip-linux/kernel "$KERNEL_COMMIT"
  git -C kernel checkout -q FETCH_HEAD
fi
cd kernel

# 2. Build fixes for a current GCC (13) on this old 4.19 tree
#    - Rockchip's gcc-wrapper.py turns every warning into an error: disable it
#    - drop -Werror from driver Makefiles
grep -q 'wrapper disabled' scripts/gcc-wrapper.py || python3 - <<'EOF'
p = 'scripts/gcc-wrapper.py'
s = open(p).read()
needle = 'def interpret_warning(line):\n    """Decode the message from gcc.  The messages we care about have a filename, and a warning"""\n'
assert needle in s, 'gcc-wrapper.py layout changed'
s = s.replace(needle, needle + '    return  # wrapper disabled (GCC 13 vs kernel 4.19)\n')
open(p, 'w').write(s)
EOF
grep -rl -- '-Werror' drivers/ | while read -r f; do sed -i 's/-Werror[=a-z-]*//g' "$f"; done

# 3. Device config + build (Image and resource.img with the rk3566-evb2-lp4x-v10 DTB)
cp "$CONFIG" .config
make olddefconfig >/dev/null
for opt in USB_CONFIGFS_MASS_STORAGE BLK_DEV_INITRD DEVTMPFS; do
  grep -q "^CONFIG_$opt=y" .config || { echo "CONFIG_$opt missing in device config"; exit 1; }
done
make -j"$(nproc)" KCFLAGS="-Wno-error" Image rk3566-evb2-lp4x-v10.img
cd "$WORK"

# 4. Initramfs: dumper init + static busybox
rm -rf rootfs; cp -a "$REPO/dumper/rootfs" rootfs
mkdir -p rootfs/bin rootfs/dev rootfs/proc rootfs/sys/kernel/config
if [ ! -f busybox ]; then
  curl -sfL -o busybox.deb "$BUSYBOX_DEB"
  rm -rf bbx; mkdir bbx; dpkg-deb -x busybox.deb bbx
  cp bbx/usr/bin/busybox-static busybox; rm -rf bbx busybox.deb
fi
echo "$BUSYBOX_SHA256  busybox" | sha256sum -c -
install -m 755 busybox rootfs/bin/busybox
ln -sf busybox rootfs/bin/sh
chmod 755 rootfs/init
(cd rootfs && find . | cpio -o -H newc 2>/dev/null | gzip -9) > dumper.cpio.gz

# 5. Boot image, header v0, same load addresses as the stock boot image
#    (kernel 0x10008000, ramdisk 0x11000000, second 0x10f00000, tags 0x10000100)
python3 kernel/scripts/mkbootimg \
  --kernel kernel/arch/arm64/boot/Image \
  --ramdisk dumper.cpio.gz \
  --second kernel/resource.img \
  --pagesize 2048 \
  --cmdline "console=ttyFIQ0 androidboot.hardware=rk30board init=/init rootwait panic=10" \
  -o recovery-dumper.img

python3 - <<'EOF'
import struct
d = open('recovery-dumper.img', 'rb').read(2048)
assert d[:8] == b'ANDROID!'
k, ka, r, ra, s, sa, ta, pg = struct.unpack_from('<8I', d, 8)
assert (ka, ra, sa, ta, pg) == (0x10008000, 0x11000000, 0x10f00000, 0x10000100, 2048), 'unexpected addresses'
print('recovery-dumper.img ok: kernel %d, ramdisk %d, second %d bytes' % (k, r, s))
EOF
ls -l "$WORK/recovery-dumper.img"
