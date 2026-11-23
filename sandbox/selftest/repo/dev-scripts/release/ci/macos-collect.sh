#!/usr/bin/env bash
# Runs on a macOS build runner after an unsigned build. Writes the inputs of
# the Apple signing step (dev-scripts/release/apple.sh):
#   <app-base>.app.unsigned.tar   the .app directory at the top level
#   <dmg-base>.unsigned.dmg       a copy of the DMG
# Tested on GitHub macOS 15 runners (arm64 and x64) with /bin/bash 3.2.
#
# Usage: macos-collect.sh --app PATH/X.app --dmg PATH/FILE.dmg --app-base BASE
#                         --dmg-base BASE --out DIR
#
# Fails if a Mach-O file in the app carries a signature other than an ad hoc
# or linker signature, if the DMG has no HFS+ partition (the Linux rebuild of
# the DMG needs HFS+), and if the app tree breaks the rules for an app tree of
# apple.sh (one .app directory; only directories, regular files, and links
# that stay inside the app; no hard link). The signing machine treats these
# files as untrusted and applies the same rules, so a build that breaks them
# fails here first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$SCRIPT_DIR/../lib.sh"
# shellcheck source-path=SCRIPTDIR source=../apple.sh
. "$SCRIPT_DIR/../apple.sh"

usage() {
	die "usage: macos-collect.sh --app PATH/X.app --dmg PATH/FILE.dmg --app-base BASE --dmg-base BASE --out DIR"
}

app="" dmg="" app_base="" dmg_base="" out=""
while [ $# -gt 0 ]; do
	[ $# -ge 2 ] || usage
	case "$1" in
	--app) app="$2" ;;
	--dmg) dmg="$2" ;;
	--app-base) app_base="$2" ;;
	--dmg-base) dmg_base="$2" ;;
	--out) out="$2" ;;
	*) usage ;;
	esac
	shift 2
done
[ -n "$app" ] && [ -n "$dmg" ] && [ -n "$app_base" ] && [ -n "$dmg_base" ] && [ -n "$out" ] || usage
need_tools codesign hdiutil tar find sort od awk sed grep

app="${app%/}"
case "$app" in
*.app) ;;
*) die "--app must name a .app directory: $app" ;;
esac
[ -d "$app" ] && [ ! -L "$app" ] || die "not a directory: $app"
[ -f "$dmg" ] || die "not a file: $dmg"
valid_asset_name "$app_base$APPLE_UNSIGNED_APP_SUFFIX" || die "--app-base gives a file name that is not allowed: $app_base"
valid_asset_name "$dmg_base$APPLE_UNSIGNED_DMG_SUFFIX" || die "--dmg-base gives a file name that is not allowed: $dmg_base"
mkdir -p "$out"
app_out="$out/$app_base$APPLE_UNSIGNED_APP_SUFFIX"
dmg_out="$out/$dmg_base$APPLE_UNSIGNED_DMG_SUFFIX"
for f in "$app_out" "$dmg_out"; do
	[ ! -e "$f" ] && [ ! -L "$f" ] || die "$f exists already"
done
parent="$(cd "$(dirname "$app")" && pwd)"
name="$(basename "$app")"

# The build must not sign: only ad hoc and linker signatures are allowed.
step "Checking that $name is not signed"
machos="$(_apple_machos "$parent" "$name")" || die "cannot list the files of $name"
[ -n "$machos" ] || die "$name holds no Mach-O file"
while IFS= read -r m; do
	[ -n "$m" ] || continue
	rc=0
	info="$(codesign -d --verbose=2 "$parent/$name/$m" 2>&1)" || rc=$?
	if [ "$rc" != 0 ]; then
		printf '%s\n' "$info" | grep -q 'not signed at all' ||
			die "codesign cannot read the signature of $name/$m: $info"
		log "    $m: not signed"
		continue
	fi
	if printf '%s\n' "$info" | grep -q '^Authority='; then
		die "$name/$m carries a signature by $(printf '%s\n' "$info" | sed -n 's/^Authority=//p' | head -n 1). The build must not sign."
	fi
	printf '%s\n' "$info" | grep -q '^Signature=adhoc' ||
		die "$name/$m carries a signature that is not ad hoc: $(printf '%s\n' "$info" | tr '\n' ' ')"
	log "    $m: ad hoc or linker signature"
done <<EOF
$machos
EOF

step "Checking the file system of $(basename "$dmg")"
info="$(hdiutil imageinfo -plist "$dmg")" || die "hdiutil imageinfo fails for $dmg"
printf '%s\n' "$info" | grep -q '<string>Apple_HFS</string>' ||
	die "$dmg has no HFS+ partition (Apple_HFS). The Linux rebuild needs HFS+: build the DMG with -fs HFS+."
out_v="$(hdiutil verify "$dmg" 2>&1)" || die "hdiutil verify fails for $dmg: $out_v"

step "Writing ${app_out##*/} and ${dmg_out##*/}"
apple_tar_app "$parent" "$name" "$app_out" none
# The signing machine unpacks the archive with these checks: run them here.
check="$(mktemp -d "${TMPDIR:-/tmp}/macos-collect.XXXXXX")"
trap 'rm -rf "$check"' EXIT
got="$(_apple_unpack_app "$app_out" "$check/x")" || die "the signing machine would refuse ${app_out##*/}"
[ "$got" = "$name" ] || die "${app_out##*/} holds $got, expected $name"
_apple_manifest "$parent" "$name" "$check/want.manifest" || die "cannot list $name"
_apple_manifest "$check/x" "$name" "$check/got.manifest" || die "cannot list the unpacked $name"
_apple_same_manifest "$check/want.manifest" "$check/got.manifest" \
	"${app_out##*/} does not hold the app tree (first: tree, second: archive)" || die "${app_out##*/} is not a copy of $name"
rm -rf "$check"
cp "$dmg" "$dmg_out"
log "    $(sha256_of "$app_out")  ${app_out##*/}"
log "    $(sha256_of "$dmg_out")  ${dmg_out##*/}"
