# Shelly Wall Display XL: root without opening the case

Magisk root for the **Shelly Wall Display XL** (SAWD-3A1XE10EU2, codename **Blake**, Rockchip RK3566), done entirely over USB. No soldering, no UART, no foreign boot image. The **original boot image is backed up first** and stays the way back.

> [!CAUTION]
> This worked on **one** device, on 15 October 2026. It writes to the eMMC. Shelly will most likely refuse warranty, and a mistake can brick the display. Use it only on a device you own and can afford to lose. Read the whole page before you start.

**Not included on purpose:** no Shelly firmware, no partition images, no device identifiers. Everything here is either our own script or built from public sources on your PC. You dump your own device.

## Tested combination

| Item | Value |
|---|---|
| Model / codename | SAWD-3A1XE10EU2 / Blake |
| SoC / board | RK3566, `rockchip,rk3566-evb2-lp4x-v10` (Rockchip reference board) |
| Shelly firmware | 2.8.3, ID `20261012-141904/2.8.3-48174502c` |
| Android | 11 (API 30), security patch 2021-10-01, Rockchip SDK `ANDROID11_RKR12` |
| Fingerprint | `Shelly/Blake/Blake:11/RD2A.211001.002/vBlake.22f119c:user/release-keys` |
| Kernel | 4.19.232 #69, 7 November 2025 |
| Bootloader | U-Boot 2017.09, **unlocked from the factory** (`ro.boot.flash.locked=0`, `verifiedbootstate=orange`) |
| Magisk | 30.7 |
| Host | Linux Mint 22 (Ubuntu 24.04 base), GCC 13 cross compiler |

The script checks nothing about your firmware for you. If your fingerprint, kernel or partition layout differs, stop and compare first.

## Why this route

What we found on the XL, all measured on the device:

- **`adb root` is refused** (production build). The shell user cannot read block devices, so nothing can be dumped from running Android.
- **`rkdeveloptool` (Loader and Maskrom mode) only reads the first 32 MiB** of the eMMC. Everything from LBA 65536 on comes back as `0xCC`. The boot partition starts at 25 MiB and is 40 MiB long, so its end (the Android ramdisk that Magisk needs) is out of reach. The X2i root project ran into the same wall.
- **`fastboot boot` is a no-op** on Shelly's U-Boot. It answers `OKAY` and falls back to fastboot about 1.5 s later, the same with a valid image and with a file of zeros.
- **`fastboot flash` works**, because the bootloader is unlocked.

So the route is: build a small Linux image (Rockchip's public kernel with the device's own config, plus a busybox initramfs) and flash it into **recovery**. Booted with `adb reboot recovery`, it exports the **whole eMMC as a USB disk** to the PC. From there you back up every partition, patch your own stock boot image with Magisk on the PC, and write it back through the same USB disk.

Partition layout on our unit:

| # | Name | Start LBA | Size |
|---|---|---|---|
| 1 | security | 8192 | 4 MiB |
| 2 | uboot | 16384 | 4 MiB |
| 3 | trust | 24576 | 4 MiB |
| 4 | misc | 32768 | 4 MiB |
| 5 | dtbo | 40960 | 4 MiB |
| 6 | vbmeta | 49152 | 1 MiB |
| 7 | **boot** | 51200 | 40 MiB |
| 8 | **recovery** | 133120 | 128 MiB |
| 9 | backup | 395264 | 384 MiB (all zeros) |
| 10 | cache | 1181696 | 384 MiB |
| 11 | metadata | 1968128 | 16 MiB |
| 12 | stback | 2000896 | 1500 MiB (empty ext4 named "system") |
| 13 | baseparameter | 5072896 | 1 MiB |
| 14 | super | 5074944 | 3112 MiB (system, vendor, product, odm, system_ext) |
| 15 | userdata | 11448320 | rest, file-based encryption |

## What you give up

**The stock recovery.** It sits beyond 32 MiB too, so it cannot be backed up before the dumper overwrites it. There is no `recovery-from-boot.p` on this firmware to rebuild it.

On the XL that costs little:

- **Shelly firmware updates do not use recovery.** The 2.8.3 update log in `/cache/update_log` shows a shell script running inside Android: it checks MD5 sums, installs `Stargate.apk` and `ShellyPlaceholder.apk` with `pm install`, and rewrites `device_owner_2.xml` and `device_admins.xml`. Boot is not touched. We have not yet run a firmware update on the rooted unit, so treat "root survives updates" as expected, not proven.
- The stock recovery log only shows `--wipe_all`, the factory reset. **A factory reset from the Shelly menu will not wipe anything** while the dumper sits in recovery: the dumper clears the reboot command in `misc` and the display comes back unchanged.

## What you need

- A Linux PC (the scripts are bash, tested on Linux Mint 22).
- A **USB-C data cable** from the display to the PC. With ADB off, the port only takes power. Data appears once ADB is on.
- ADB enabled on the display: Settings → About device, tap **F H F F H F H H** (F = "FW Version", H = "Hardware Revision"), then in Shelly's developer options turn on debugging, ADB, and ADB over Wi-Fi. The [ShellyElevate wiki](https://github.com/RapierXbox/ShellyElevate/wiki/Installation) has the details.
- Packages:
  ```
  sudo apt install adb fastboot git gcc-aarch64-linux-gnu bc bison flex libssl-dev \
       python-is-python3 cpio curl qemu-user-static binfmt-support unzip aapt zip
  ```
- The Magisk APK (v30.7 tested) from the [Magisk releases](https://github.com/topjohnwu/Magisk/releases).
- About 6 GiB of free disk for the partition backups, about 3 GiB for the kernel build.
- Someone who can unplug and replug the display. If it ever hangs, only a power cycle helps.

## Steps

### 1. Build the dumper image

The kernel config comes from your own display. `/proc/config.gz` is readable without root.

```
adb shell zcat /proc/config.gz > device.config
scripts/build-dumper.sh device.config build
```

Result: `build/recovery-dumper.img`, about 32 MiB. The script pins the exact Rockchip kernel commit and the busybox binary (SHA-256 checked) we used. It also applies the build fixes a current GCC needs on this old tree.

### 2. Flash it into recovery

```
adb reboot bootloader
fastboot devices                 # should show the display
fastboot flash recovery build/recovery-dumper.img
fastboot reboot
```

Android and boot stay untouched. If `fastboot reboot` seems to land in fastboot again, an old `fastboot` process is still holding the device: end all `fastboot` processes on the PC and try once more.

### 3. Boot the dumper

```
adb reboot recovery
```

After a few seconds a new USB disk appears on the PC (USB ID `2207:0019`, product "eMMC-Dump", about 29 GiB, 15 partitions). Find it and **double-check you have the right disk**:

```
lsblk -o NAME,SIZE,MODEL,PARTLABEL
```

Below, `/dev/sdX` stands for that disk. Do not mix it up with your PC's own disks.

The dumper has two safety nets:
- It clears the boot command in `misc` right away, so any reboot afterwards goes back to Android.
- It reboots by itself after **45 minutes**. If the USB gadget does not come up at all, it reboots after 3 seconds.

There is no shell in the dumper. It only serves the disk.

### 4. Back up everything

```
mkdir backup && cd backup
for i in $(seq 1 14); do sudo dd if=/dev/sdX$i of=p$i.img bs=4M status=none; done
sudo chown $USER: *.img && sha256sum *.img > sha256.txt
cp p7.img boot_stock.img
```

Partition 15 (userdata) is encrypted and skipped. **Keep this backup somewhere safe.** `p8.img` is already the dumper, not the stock recovery.

Check that `boot_stock.img` is complete: it must start with `ANDROID!` and must not contain `0xCC` filler blocks at the end.

### 5. Patch boot with Magisk on the PC

```
scripts/patch-boot.sh backup/boot_stock.img Magisk-v30.7.apk magisk-patch
```

The script runs Magisk's own `boot_patch.sh` with the arm64 tools under qemu-user. It keeps verity and forced encryption, like the stock image. Result: `magisk-patch/new-boot.img`, 40 MiB.

### 6. Write the patched boot

While the dumper still serves the disk:

```
sudo dd if=/dev/sdX7 bs=4M status=none | cmp - backup/boot_stock.img && echo "partition 7 is boot"
sudo dd if=magisk-patch/new-boot.img of=/dev/sdX7 bs=4M conv=fsync
sudo dd if=/dev/sdX7 bs=4M status=none | cmp - magisk-patch/new-boot.img && echo "verified"
sync
```

Then wait. The dumper reboots by itself when its 45 minutes are up, and the display starts Android with Magisk. We waited for that. A power cycle after `sync` should be safe too, but we did not test it.

### 7. Finish Magisk

```
adb install Magisk-v30.7.apk
```

Open the Magisk app on the display. It asks for "additional setup" and reboots once. Afterwards:

- `su` lives at `/debug_ramdisk/su`, it is not in the `adb shell` PATH.
- The first `su` request has to be allowed on the touchscreen.

Check: `adb shell /debug_ramdisk/su -c id` shows `uid=0(root)`.

### Way back

Boot the dumper again and write your stock boot back:

```
adb reboot recovery
sudo dd if=backup/boot_stock.img of=/dev/sdX7 bs=4M conv=fsync
```

## ShellyElevate as a privileged app, systemless

[ShellyElevate](https://github.com/RapierXbox/ShellyElevate) needs to be a privileged system app for its full feature set. With Magisk, a module can provide that without remounting `/system`:

```
shellyelevate-module/build-module.sh ShellyElevateV2.apk shellyelevate-privapp.zip
adb push shellyelevate-privapp.zip /data/local/tmp/
adb shell /debug_ramdisk/su -c "/debug_ramdisk/magisk --install-module /data/local/tmp/shellyelevate-privapp.zip"
adb reboot
```

The module puts the APK into `/system/priv-app/ShellyElevateV2`, whitelists every `android.permission.*` the APK requests as a privileged permission, and makes `/dev/input/event*` readable for swipe gestures. Remove the module in the Magisk app to undo it.

After the reboot, grant the runtime permissions the same way ShellyElevate's own `tools/install-privapp.sh` does: `appops` WRITE_SETTINGS, SYSTEM_ALERT_WINDOW and GET_USAGE_STATS to allow, the `deviceidle` whitelist, and `pm grant` for ACCESS_FINE_LOCATION, RECORD_AUDIO and WRITE_SECURE_SETTINGS.

Check: `adb shell dumpsys package me.rapierxbox.shellyelevatev2 | grep -E "codePath|privateFlags"` shows `/system/priv-app/ShellyElevateV2` and `PRIVILEGED`.

## Running the display without internet

We block the display's internet access at the router and keep everything local with Home Assistant. Two things then break quietly.

**The clock.** After the reboots during rooting, our display came up with the firmware date (13 January 2026). Internet was blocked at the router except NTP over IPv4, and IPv6 was blocked completely. What we measured:

- The Shelly app writes Android's NTP server setting (`settings get global ntp_server`). When the Shelly SNTP setting changes, it copies that value. At every boot it wrote `time.google.com` back on our unit, although the Shelly setting pointed to our LAN server.
- `time.google.com`, `time.apple.com` and `2.android.pool.ntp.org` did not answer from the display. All three resolve to IPv6 addresses on a dual-stack network, which our block drops. Android only got the time from a fallback server without IPv6 (`ntp1.aliyun.com`) over IPv4.
- Shelly's own service queries the SNTP server set in its config, and our LAN server sees those requests.

What works for us: a LAN NTP server for the Shelly service, plus outgoing NTP over IPv4 allowed for Android's fallback. If you block IPv6 too, check the clock after a reboot.

```
curl -s -H 'Content-Type: application/json' \
  -d '{"id":1,"src":"pc","method":"Sys.SetConfig","params":{"config":{"sntp":{"server":"192.0.2.10"}}}}' \
  http://<display-ip>/rpc
```

Replace `192.0.2.10` with your NTP server.

**Wake word models.** ShellyElevate downloads its microWakeWord models and the VAD model from GitHub. Offline, copy them yourself from [esphome/micro-wake-word-models](https://github.com/esphome/micro-wake-word-models) (`models/v2`, the `.tflite` plus its `.json`) into the app's `files/wakewords/` directory. Owner must be the app's UID and mode `600`. We did that with root. The ShellyElevate wiki also describes an import from `/sdcard/Download`, which we have not tried.

## Other observations

- **SELinux runs permissive.** `getenforce` says `Permissive`, and the kernel log shows `permissive=1` denials from the first policy load on. The boot command line still says `androidboot.selinux=enforcing`. Our boot image is Magisk-patched, and Magisk does not switch SELinux to permissive, so this is most likely Shelly's stock state. Please confirm on an unrooted unit.
- **Device owner.** Every Shelly update rewrites `device_owner_2.xml` and `device_admins.xml`, so the stock app becomes device owner and device admin again after each update.
- **No temperature or humidity sensor.** The XL's datasheet says so, and the firmware reports the SHT3x as missing.

## Files

| Path | What it does |
|---|---|
| `dumper/rootfs/init` | busybox init: clears `misc`, exports the eMMC via the configfs mass storage gadget, two safety reboots |
| `scripts/build-dumper.sh` | builds the kernel (pinned Rockchip commit, device config) and `recovery-dumper.img` |
| `scripts/patch-boot.sh` | runs Magisk's `boot_patch.sh` on the PC through qemu-user |
| `shellyelevate-module/build-module.sh` | builds the Magisk module for ShellyElevate |

All three scripts were run again on 16 October 2026 against our device and backup:

- `build-dumper.sh` built from scratch. Same kernel config, same DTB and the same initramfs files (only the comments in `init` were translated to English) as the image we flashed on 15 October. The kernel binary differs only through the build timestamp. The fresh image itself has not been booted, because that needs the USB cable again.
- `patch-boot.sh` reproduced the flashed `new-boot.img` byte for byte.
- The module built by `build-module.sh` is the one now installed on our display, checked after two reboots.

## Credits

- [ShellyElevate](https://github.com/RapierXbox/ShellyElevate) by RapierXbox, for the app, the tap sequence and the wiki.
- [shelly-x2i-root](https://github.com/rtho782/shelly-x2i-root) by rtho782, the first Magisk root on a Gen2 display (X2i).
- [Magisk](https://github.com/topjohnwu/Magisk), [rockchip-linux/kernel](https://github.com/rockchip-linux/kernel), BusyBox.

Worked out together with an AI assistant (Claude).

## License

MIT for the scripts in this repository. The kernel you build is GPL-2.0, and its source is the pinned commit of rockchip-linux/kernel.
