#!/usr/bin/env bash
# Step 3 check of the signed Apple files: the gate before publishing. Runs on
# a macOS runner with no secrets. UNTESTED: written without access to a
# macOS host. Needs macOS 12 or later (plutil -extract raw, codesign --xml).
#
# Usage: verify-macos.sh --dir DIR --requirement REQUIREMENT --notarized true|false
#                        --team-id TEAMID --bundle-id ID --version VERSION
#                        --entitlements PLIST [--unsigned-dir DIR]
#
# DIR holds the final <base>.dmg and <base>.app.tar.gz files. A DMG and an
# updater archive form a pair when their base names end with the same part
# after the last "_" (the architecture: aarch64 or x64). REQUIREMENT is a
# code signing requirement in text form, for example:
#   anchor apple generic and certificate leaf[subject.OU] = "TEAMID"
# PLIST is the committed entitlements file of the main executable.
# With --unsigned-dir, the script also compares the signed app with the
# unsigned app of the build (<base>.app.unsigned.tar).
#
# For the app in each DMG and the app in each updater archive:
#   - both have the same code directory hash (CDHash), so both hold the same
#     signed app; the file trees are also compared
#   - codesign --verify --deep --strict passes with REQUIREMENT (nested code
#     and the sealed contents)
#   - team identifier, bundle identifier (signature and Info.plist), and
#     CFBundleShortVersionString are the expected values
#   - the main executable is a single-architecture Mach-O file for the
#     architecture of the asset name
#   - the entitlements of the main executable equal PLIST (parsed values)
#   - every Mach-O file has the hardened runtime flag
#   - with --notarized true: the stapled ticket validates, and Gatekeeper
#     (spctl) accepts the app
# For each DMG: hdiutil verify, and a valid signature that meets REQUIREMENT.
# The DMG is signed, but not notarized (decision, as in production today):
# the app inside carries the notarization ticket.
#
# The archives are untrusted input: they are checked with the rules for an
# app tree of apple.sh before and after extraction.
#
# The script stops with a message at the first failed check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source-path=SCRIPTDIR source=apple.sh
. "$SCRIPT_DIR/apple.sh"

usage() {
	die "usage: verify-macos.sh --dir DIR --requirement REQUIREMENT --notarized true|false --team-id TEAMID --bundle-id ID --version VERSION --entitlements PLIST [--unsigned-dir DIR]"
}

dir="" requirement="" notarized="" unsigned_dir="" team_id="" bundle_id="" version="" entitlements=""
while [ $# -gt 0 ]; do
	case "$1" in
	--dir | --requirement | --notarized | --unsigned-dir | --team-id | --bundle-id | --version | --entitlements)
		[ $# -ge 2 ] || usage
		case "$1" in
		--dir) dir="$2" ;;
		--requirement) requirement="$2" ;;
		--notarized) notarized="$2" ;;
		--unsigned-dir) unsigned_dir="$2" ;;
		--team-id) team_id="$2" ;;
		--bundle-id) bundle_id="$2" ;;
		--version) version="$2" ;;
		--entitlements) entitlements="$2" ;;
		esac
		shift
		;;
	*) usage ;;
	esac
	shift
done
[ -n "$dir" ] && [ -n "$requirement" ] && [ -n "$notarized" ] && [ -n "$team_id" ] &&
	[ -n "$bundle_id" ] && [ -n "$version" ] && [ -n "$entitlements" ] || usage
_apple_check_notarize_arg "$notarized"
[ -d "$dir" ] || die "not a directory: $dir"
[ -z "$unsigned_dir" ] || [ -d "$unsigned_dir" ] || die "not a directory: $unsigned_dir"
[ -f "$entitlements" ] || die "not a file: $entitlements"
[ "$(uname -s)" = Darwin ] || die "verify-macos.sh runs on macOS only"
need_tools hdiutil codesign lipo plutil jq tar find awk sed diff cmp shasum od
[ "$notarized" = false ] || need_tools xcrun spctl

work="$(mktemp -d "${TMPDIR:-/tmp}/verify-macos.XXXXXX")"
cleanup() {
	_apple_detach || true
	rm -rf "$work"
}
trap cleanup EXIT

# canonical_plist FILE: prints the parsed values of the property list FILE as
# JSON with sorted keys, so that two files with the same values compare equal.
canonical_plist() {
	plutil -convert json -o - "$1" | jq -S -c .
}
want_entitlements="$(canonical_plist "$entitlements")" ||
	die "cannot read $entitlements as a property list (with values that JSON can hold)"

# expected_arch KEY: the Mach-O architecture that the asset name promises.
# Only single-architecture builds are released.
expected_arch() {
	case "$1" in
	aarch64 | arm64) printf 'arm64\n' ;;
	x64 | x86_64 | amd64) printf 'x86_64\n' ;;
	*) die "unknown architecture '$1' in an asset name" ;;
	esac
}

# signature_field INFO NAME: the value of the line NAME=... in the output of
# codesign -d. Fails unless there is exactly one such line.
signature_field() {
	local values
	values="$(printf '%s\n' "$1" | sed -n "s/^$2=//p")"
	[ -n "$values" ] && [ "$(printf '%s\n' "$values" | grep -c .)" = 1 ] || return 1
	printf '%s\n' "$values"
}

# plist_value APP KEY: a string value of Contents/Info.plist.
plist_value() {
	plutil -extract "$2" raw -o - "$1/Contents/Info.plist"
}

# check_app APP LABEL KEY: all app checks (see the head of this file). Sets
# CDHASH to the code directory hash of the app.
CDHASH=""
check_app() {
	local app="$1" label="$2" key="$3" parent name out info value exe arch machos m got
	parent="${app%/*}" name="${app##*/}"
	_apple_check_tree "$parent" "$name" "$label" || die "$label: the app tree breaks the rules for an app tree"

	out="$(codesign --verify --deep --strict "-R=$requirement" "$app" 2>&1)" ||
		die "$label: codesign --verify --deep --strict with the requirement fails: $out"
	info="$(codesign -d --verbose=4 "$app" 2>&1)" || die "$label: codesign cannot read the signature: $info"
	CDHASH="$(signature_field "$info" CDHash)" || die "$label: no single CDHash in the signature"
	value="$(signature_field "$info" TeamIdentifier)" || die "$label: no single TeamIdentifier in the signature"
	[ "$value" = "$team_id" ] || die "$label: the team identifier is '$value', expected '$team_id'"
	value="$(signature_field "$info" Identifier)" || die "$label: no single Identifier in the signature"
	[ "$value" = "$bundle_id" ] || die "$label: the signing identifier is '$value', expected '$bundle_id'"
	value="$(plist_value "$app" CFBundleIdentifier)" || die "$label: Info.plist has no CFBundleIdentifier"
	[ "$value" = "$bundle_id" ] || die "$label: CFBundleIdentifier is '$value', expected '$bundle_id'"
	value="$(plist_value "$app" CFBundleShortVersionString)" || die "$label: Info.plist has no CFBundleShortVersionString"
	[ "$value" = "$version" ] || die "$label: CFBundleShortVersionString is '$value', expected '$version'"

	exe="$(plist_value "$app" CFBundleExecutable)" || die "$label: Info.plist has no CFBundleExecutable"
	case "$exe" in
	"" | . | .. | */*) die "$label: CFBundleExecutable is not a plain file name: '$exe'" ;;
	esac
	exe="$app/Contents/MacOS/$exe"
	[ -f "$exe" ] && [ ! -L "$exe" ] || die "$label: the main executable ${exe#"$parent"/} is missing"
	out="$(lipo -info "$exe" 2>&1)" || die "$label: lipo cannot read the main executable: $out"
	case "$out" in
	"Non-fat file: "*) ;;
	*) die "$label: the main executable is not a single-architecture file: $out" ;;
	esac
	arch="$(lipo -archs "$exe")" || die "$label: lipo cannot read the architecture of the main executable"
	[ "$arch" = "$(expected_arch "$key")" ] ||
		die "$label: the main executable is for '$arch', but the asset name says '$(expected_arch "$key")'"

	codesign -d --entitlements - --xml "$exe" >"$work/entitlements.plist" 2>/dev/null ||
		die "$label: codesign cannot read the entitlements of the main executable"
	got="$(canonical_plist "$work/entitlements.plist")" ||
		die "$label: the main executable has no readable entitlements"
	[ "$got" = "$want_entitlements" ] ||
		die "$label: the entitlements differ from $entitlements: got $got, expected $want_entitlements"
	rm -f "$work/entitlements.plist"

	machos="$(_apple_machos "$parent" "$name")" || die "$label: cannot list the Mach-O files"
	[ -n "$machos" ] || die "$label: no Mach-O file"
	while IFS= read -r m; do
		[ -n "$m" ] || continue
		out="$(codesign -d --verbose=2 "$app/$m" 2>&1)" || die "$label: codesign cannot read the signature of $m: $out"
		printf '%s\n' "$out" | grep -E -q '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' ||
			die "$label: $m has no hardened runtime flag: $(printf '%s\n' "$out" | grep '^CodeDirectory' || true)"
	done <<EOF
$machos
EOF

	got=""
	if [ "$notarized" = true ]; then
		out="$(xcrun stapler validate "$app" 2>&1)" || die "$label: no valid stapled notarization ticket: $out"
		out="$(spctl --assess --type execute -vv "$app" 2>&1)" || die "$label: Gatekeeper rejects the app: $out"
		log "    $label: $(printf '%s\n' "$out" | tr '\n' ' ')"
		got=", stapled ticket, Gatekeeper"
	fi
	log "    $label: signature, requirement, team, bundle ID, version $version, architecture $arch, entitlements, hardened runtime$got: ok"
}

# is_signature_path PATH: true for the files that code signing adds or
# changes besides Mach-O files.
is_signature_path() {
	case "/$1/" in
	*/_CodeSignature/* | */Contents/CodeResources/) return 0 ;;
	esac
	return 1
}

# compare_unsigned BASE APP SIGNED_PARENT: every file of the unsigned app is
# unchanged in the signed app, except Mach-O files and signature files.
compare_unsigned() {
	local base="$1" app="$2" signed_parent="$3" tarfile u name diffs what path m1 m2
	tarfile="$unsigned_dir/$base$APPLE_UNSIGNED_APP_SUFFIX"
	[ -f "$tarfile" ] || die "$base: the unsigned app $tarfile is missing"
	u="$work/$base.unsigned"
	name="$(_apple_unpack_app "$tarfile" "$u")" || die "$base: the unsigned app archive is not usable"
	[ "$name" = "$app" ] || die "$base: the unsigned archive holds $name, the signed one $app"
	_apple_manifest "$u" "$app" "$u.manifest" || die "$base: cannot list the unsigned app"
	_apple_manifest "$signed_parent" "$app" "$work/$base.signed.manifest" || die "$base: cannot list the signed app"
	# One line per difference: "content PATH", "other PATH" (kind or mode),
	# "missing PATH", "extra PATH".
	diffs="$(awk -F '\t' '
		NR == FNR { kind[$1] = $2; perm[$1] = $3; value[$1] = $5; next }
		{
			seen[$1] = 1
			if (!($1 in kind)) { print "extra\t" $1; next }
			if (kind[$1] != $2 || perm[$1] != $3) print "other\t" $1
			else if (value[$1] != $5) print "content\t" $1
		}
		END { for (p in kind) if (!(p in seen)) print "missing\t" p }
		' "$u.manifest" "$work/$base.signed.manifest")"
	while IFS="$_APPLE_TAB" read -r what path; do
		[ -n "$what" ] || continue
		! is_signature_path "${path#"$app"/}" || continue
		case "$what" in
		missing) die "$base: $path of the unsigned app is missing in the signed app" ;;
		extra) die "$base: the signed app has $path, which the unsigned app does not have" ;;
		other) die "$base: $path has another type or mode in the signed app" ;;
		esac
		if ! _apple_is_macho "$u/$path" || ! _apple_is_macho "$signed_parent/$path"; then
			die "$base: $path differs between the unsigned and the signed app, and it is not a Mach-O file"
		fi
		# Mach-O: compare without signatures. Nobody has proven yet that this
		# comparison is stable, so a difference is a warning only.
		m1="$work/macho.unsigned" m2="$work/macho.signed"
		rm -f "$m1" "$m2"
		cp "$u/$path" "$m1"
		cp "$signed_parent/$path" "$m2"
		if codesign --remove-signature "$m1" 2>/dev/null && codesign --remove-signature "$m2" 2>/dev/null; then
			if cmp -s "$m1" "$m2"; then
				log "    $base: $path: same as the unsigned build without signatures"
			else
				log "    warning: $base: $path differs from the unsigned build after codesign --remove-signature (this comparison is not proven to be stable)"
			fi
		else
			log "    warning: $base: codesign --remove-signature failed for $path, no comparison"
		fi
		rm -f "$m1" "$m2"
	done <<EOF
$diffs
EOF
	log "    $base: every file of the unsigned app is unchanged, except Mach-O and signature files: ok"
}

# ---------------------------------------------------------------------------
# Pairs
# ---------------------------------------------------------------------------
pairs=""
for f in "$dir"/*"$APPLE_APP_SUFFIX"; do
	[ -f "$f" ] || continue
	name="${f##*/}"
	key="$(_apple_arch_key "${name%"$APPLE_APP_SUFFIX"}")"
	dmg=""
	for d in "$dir"/*"$APPLE_DMG_SUFFIX"; do
		[ -f "$d" ] || continue
		[ "$(_apple_arch_key "$(basename "$d" "$APPLE_DMG_SUFFIX")")" = "$key" ] || continue
		[ -z "$dmg" ] || die "two DMG files for architecture $key: ${dmg##*/} and ${d##*/}"
		dmg="$d"
	done
	[ -n "$dmg" ] || die "no DMG for $name (architecture $key)"
	pairs="$pairs$key $name ${dmg##*/}$_APPLE_NL"
done
[ -n "$pairs" ] || die "no *$APPLE_APP_SUFFIX file in $dir"
for d in "$dir"/*"$APPLE_DMG_SUFFIX"; do
	[ -f "$d" ] || continue
	key="$(_apple_arch_key "$(basename "$d" "$APPLE_DMG_SUFFIX")")"
	printf '%s' "$pairs" | awk -v k="$key" '$1 == k { found = 1 } END { exit !found }' ||
		die "no updater archive for ${d##*/} (architecture $key)"
done
f="$(printf '%s' "$pairs" | cut -d' ' -f1 | LC_ALL=C sort | uniq -d)"
[ -z "$f" ] || die "more than one updater archive for: $f"

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
while IFS=' ' read -r key tgz dmg; do
	[ -n "$key" ] || continue
	base="${tgz%"$APPLE_APP_SUFFIX"}"
	step "Checking $dmg and $tgz"

	out="$(hdiutil verify "$dir/$dmg" 2>&1)" || die "$dmg: hdiutil verify fails: $out"
	out="$(codesign --verify --strict "-R=$requirement" "$dir/$dmg" 2>&1)" ||
		die "$dmg: codesign --verify with the requirement fails: $out"
	info="$(codesign -d --verbose=2 "$dir/$dmg" 2>&1)" || die "$dmg: codesign cannot read the signature: $info"
	value="$(signature_field "$info" TeamIdentifier)" || die "$dmg: no single TeamIdentifier in the signature"
	[ "$value" = "$team_id" ] || die "$dmg: the team identifier is '$value', expected '$team_id'"
	log "    $dmg: hdiutil verify, signature, requirement, team: ok (not notarized, by decision)"

	mnt="$work/mnt-$key"
	mkdir "$mnt"
	out="$(hdiutil attach "$dir/$dmg" -readonly -nobrowse -noautoopen -mountpoint "$mnt" 2>&1)" ||
		die "$dmg: hdiutil attach fails: $out"
	_APPLE_ATTACHED="$mnt"
	apps="$(cd "$mnt" && find . -maxdepth 1 -name '*.app' -print | sed 's#^\./##')"
	[ -n "$apps" ] || die "$dmg: no .app at the top level"
	[ "$(printf '%s\n' "$apps" | grep -c .)" = 1 ] || die "$dmg: more than one .app: $(printf '%s' "$apps" | tr '\n' ' ')"
	app="$apps"
	[ -d "$mnt/$app" ] && [ ! -L "$mnt/$app" ] || die "$dmg: $app is not a directory"
	check_app "$mnt/$app" "$dmg: $app" "$key"
	dmg_cdhash="$CDHASH"

	unpacked="$work/$key.unpacked"
	name="$(_apple_unpack_app "$dir/$tgz" "$unpacked")" || die "$tgz: the archive is not usable"
	[ "$name" = "$app" ] || die "$tgz holds $name, but the DMG holds $app"
	check_app "$unpacked/$app" "$tgz: $app" "$key"
	[ "$CDHASH" = "$dmg_cdhash" ] ||
		die "$dmg and $tgz hold apps with different code directory hashes: $dmg_cdhash and $CDHASH"
	log "    $dmg and $tgz hold the same signed app (CDHash $CDHASH): ok"

	_apple_manifest "$mnt" "$app" "$work/$key.dmg.manifest" || die "$dmg: cannot list the app"
	_apple_manifest "$unpacked" "$app" "$work/$key.tgz.manifest" || die "$tgz: cannot list the app"
	_apple_same_manifest "$work/$key.dmg.manifest" "$work/$key.tgz.manifest" \
		"the app in $dmg (first) differs from the app in $tgz (second)" || die "$dmg and $tgz hold different apps"
	log "    $dmg and $tgz hold the same app tree (names, types, modes, content, link targets): ok"
	_apple_detach || die "cannot detach $dmg"

	[ -z "$unsigned_dir" ] || compare_unsigned "$base" "$app" "$unpacked"
	rm -rf "$unpacked" "$mnt"
done <<EOF
$pairs
EOF

log ""
log "All Apple checks passed."
