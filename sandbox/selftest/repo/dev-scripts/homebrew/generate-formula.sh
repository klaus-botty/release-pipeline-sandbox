#!/usr/bin/env bash
# Writes the Homebrew cask sampleapp.rb for one release.
#
# The output depends only on the arguments and on the template next to this
# script: the same tag and the same two DMG files always give the same bytes.
# The local signing script runs this script, so that sampleapp.rb becomes a
# signed release file. It must run on the final DMG files, before the
# manifest is signed. Anyone can check a release by running it again on the
# released DMG files and comparing the output with the released sampleapp.rb.
#
# Usage: generate-formula.sh TAG AARCH64_DMG X64_DMG OUTPUT
#
#   TAG          the release tag. The release version is TAG without one
#                leading "v" and must be a semantic version.
#   AARCH64_DMG  sampleapp_<version>_aarch64.dmg
#   X64_DMG      sampleapp_<version>_x64.dmg
#   OUTPUT       the file to write (normally sampleapp.rb). It must not exist.
#
# Works with bash 3.2 (macOS) and later.

set -euo pipefail

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

[ $# -eq 4 ] || die "usage: generate-formula.sh TAG AARCH64_DMG X64_DMG OUTPUT"
tag="$1" aarch64_dmg="$2" x64_dmg="$3" output="$4"

template="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sampleapp.rb.template"
[ -f "$template" ] || die "template not found: $template"

# The values go into a URL path and into sed. The patterns keep out every
# character that has a meaning there.
version="${tag#v}"
semver_re='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
[[ "$version" =~ $semver_re ]] ||
	die "tag $tag does not name a release version: '$version' is not a semantic version"

check_dmg() {
	local path="$1" arch="$2" expected
	expected="sampleapp_${version}_${arch}.dmg"
	[ -f "$path" ] && [ ! -L "$path" ] || die "not a regular file: $path"
	[ "${path##*/}" = "$expected" ] || die "the $arch DMG must be named $expected, not ${path##*/}"
}
check_dmg "$aarch64_dmg" aarch64
check_dmg "$x64_dmg" x64

[ ! -e "$output" ] && [ ! -L "$output" ] || die "$output exists already"

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}
aarch64_sha256="$(sha256_of "$aarch64_dmg")"
x64_sha256="$(sha256_of "$x64_dmg")"
[[ "$aarch64_sha256" =~ ^[0-9a-f]{64}$ ]] || die "cannot hash $aarch64_dmg"
[[ "$x64_sha256" =~ ^[0-9a-f]{64}$ ]] || die "cannot hash $x64_dmg"

for placeholder in VERSION_PLACEHOLDER TAG_PLACEHOLDER AARCH64_SHA256_PLACEHOLDER X64_SHA256_PLACEHOLDER; do
	grep -q "$placeholder" "$template" || die "the template has no $placeholder"
done

LC_ALL=C sed \
	-e "s|AARCH64_SHA256_PLACEHOLDER|$aarch64_sha256|g" \
	-e "s|X64_SHA256_PLACEHOLDER|$x64_sha256|g" \
	-e "s|VERSION_PLACEHOLDER|$version|g" \
	-e "s|TAG_PLACEHOLDER|$tag|g" \
	"$template" >"$output.tmp"
if grep -q '_PLACEHOLDER' "$output.tmp"; then
	rm -f "$output.tmp"
	die "the template has a placeholder that this script does not fill"
fi
mv "$output.tmp" "$output"
