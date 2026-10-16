#!/bin/bash
# Build a Magisk module that installs ShellyElevate as a privileged system app,
# systemless (nothing on /system is written; remove the module to undo).
#
# Usage: shellyelevate-module/build-module.sh <ShellyElevateV2.apk> [out.zip]
# Host packages: sudo apt install aapt zip
set -euo pipefail

APK=$(realpath "${1:?usage: $0 <ShellyElevateV2.apk> [out.zip]}")
OUT=$(realpath -m "${2:-shellyelevate-privapp.zip}")
PKG=$(aapt dump badging "$APK" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")
VER=$(aapt dump badging "$APK" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p")
[ -n "$PKG" ] || { echo "cannot read package name from $APK"; exit 1; }

M=$(mktemp -d)
trap 'rm -r "$M"' EXIT
mkdir -p "$M/system/priv-app/ShellyElevateV2" "$M/system/etc/permissions"
cp "$APK" "$M/system/priv-app/ShellyElevateV2/ShellyElevateV2.apk"

cat > "$M/module.prop" <<EOF
id=shellyelevate_privapp
name=ShellyElevate as system app
version=v$VER
versionCode=1
author=community
description=Puts ShellyElevate into /system/priv-app systemless (remove the module to undo)
EOF

# Allow every android.permission.* the APK requests as a privileged permission
{
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<permissions>'
  echo "  <privapp-permissions package=\"$PKG\">"
  aapt dump permissions "$APK" | grep -oE "name='android\.permission\.[^']*'" \
    | sed "s/name='//;s/'//" | sort -u | while read -r p; do
      echo "    <permission name=\"$p\"/>"
    done
  echo '  </privapp-permissions>'
  echo '</permissions>'
} > "$M/system/etc/permissions/privapp-permissions-shellyelevate.xml"

cat > "$M/service.sh" <<'EOF'
#!/system/bin/sh
# Let ShellyElevate read touch input (swipe gestures over other apps)
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
for n in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -e /dev/input/event$n ] && chmod 0664 /dev/input/event$n; done
EOF
chmod 755 "$M/service.sh"

rm -f "$OUT"
(cd "$M" && zip -qr "$OUT" .)
echo "$OUT: $PKG $VER, $(grep -c '<permission ' "$M/system/etc/permissions/privapp-permissions-shellyelevate.xml") permissions"
