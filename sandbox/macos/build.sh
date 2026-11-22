#!/bin/bash
# Builds the unsigned sandboxapp.app and an unsigned DMG on macOS, with a DMG
# layout like the one of Tauri's bundle_dmg.sh: HFS+, UDZO, the app, an
# Applications link, a .background directory with an image, and a
# .VolumeIcon.icns with the custom icon flag on the volume.
#
# Usage: build.sh ARCH OUT_DIR [VERSION]   (ARCH: aarch64 or x64; VERSION
# defaults to 1.2.3 and goes into Info.plist and the DMG name)
# Writes OUT_DIR/sandboxapp.app and OUT_DIR/sandboxapp_VERSION_ARCH.dmg.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
arch="$1" out="$2"
case "$arch" in
aarch64) clang_arch=arm64 ;;
x64) clang_arch=x86_64 ;;
*) echo "unknown architecture $arch" >&2; exit 1 ;;
esac
version="${3:-1.2.3}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must be like 1.2.3: $version" >&2; exit 1; }
mkdir -p "$out"
out="$(cd "$out" && pwd)"
work="$(mktemp -d)"

# Images: a plain PNG made with Python, converted with sips.
python3 - "$work" <<'PY'
import struct, sys, zlib
def png(path, w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)
png(sys.argv[1] + "/icon.png", 512, 512, (40, 110, 200))
png(sys.argv[1] + "/background.png", 660, 400, (230, 230, 230))
PY
sips -s format icns "$work/icon.png" --out "$work/icon.icns" >/dev/null

app="$out/sandboxapp.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
clang -arch "$clang_arch" -O2 -o "$app/Contents/MacOS/sandboxapp" "$here/app/main.c"
sed "s|<string>1\.2\.3</string>|<string>$version</string>|g" "$here/app/Info.plist" >"$app/Contents/Info.plist"
cp "$work/icon.icns" "$app/Contents/Resources/icon.icns"
cp "$here/app/resource.txt" "$app/Contents/Resources/resource.txt"
printf 'APPL????' >"$app/Contents/PkgInfo"
chmod -R u=rwX,go=rX "$app"
echo "== app tree"
(cd "$out" && find sandboxapp.app -print | sort)
echo "== codesign -d of the main executable"
codesign -d --verbose=2 "$app/Contents/MacOS/sandboxapp" 2>&1 || true
lipo -info "$app/Contents/MacOS/sandboxapp"

# DMG, the steps of bundle_dmg.sh.
src="$work/src" mnt="$work/mnt" rw="$work/rw.dmg"
mkdir "$src" "$mnt"
cp -R "$app" "$src/"
size_kb=$(($(du -sk "$src" | awk '{ print $1 }') + 20 * 1024))
hdiutil create -srcfolder "$src" -volname sandboxapp -fs HFS+ -fsargs "-c c=64,a=16,e=16" \
	-format UDRW -size "${size_kb}k" "$rw"
hdiutil attach -readwrite -noverify -noautoopen -nobrowse -mountpoint "$mnt" "$rw"
ln -s /Applications "$mnt/Applications"
mkdir "$mnt/.background"
cp "$work/background.png" "$mnt/.background/background.png"
cp "$work/icon.icns" "$mnt/.VolumeIcon.icns"
if command -v SetFile >/dev/null 2>&1; then
	SetFile -c icnC "$mnt/.VolumeIcon.icns"
	SetFile -a C "$mnt"
else
	echo "SetFile not found: no custom icon flag"
fi
rm -rf "$mnt/.fseventsd"
chmod -Rf go-w "$mnt" >/dev/null 2>&1 || true
echo "== DMG volume"
ls -la "$mnt"
sync
hdiutil detach "$mnt"
dmg="$out/sandboxapp_${version}_${arch}.dmg"
hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg"
rm -rf "$work"
hdiutil imageinfo "$dmg" | sed -n '/^Format/p;/partition-hint/p;/Apple_HFS/p'
