#!/usr/bin/env bash
# Verifies a directory that holds the complete set of files of one release.
#
# The local signing script runs this before it uploads anything. The finalize
# workflow runs it before it publishes anything. The script succeeds only if:
#   - SHA256SUMS has one good signature from an allowed signer,
#   - the directory holds exactly the files that SHA256SUMS lists, with the
#     same hashes,
#   - these files are exactly the release files that the products in
#     config.json require: the build and local products, the build info,
#     latest.json (if a product has updater platforms), the .asc and .sig
#     files, and no input or ci product,
#   - release-build-info.json names this repository, tag, commit, and build run,
#   - every released file has a good detached signature (<file>.asc),
#   - every product with updater platforms has a good updater signature
#     (<file>.sig), and its trusted comment names exactly this file and the
#     release version,
#   - latest.json matches the release version, and lists exactly the updater
#     platforms of the configuration, each with its file and signature.
#
# The release version is the tag without one leading "v".
#
# Usage: verify-release.sh --dir DIR --repo OWNER/NAME --tag TAG --commit SHA
#                          --run-id ID [--repo-root DIR]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$SCRIPT_DIR/lib.sh"

dir="" repo="" tag="" commit="" run_id=""
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
while [ $# -gt 0 ]; do
	[ $# -ge 2 ] || die "missing value for $1"
	case "$1" in
	--dir) dir="$2" ;;
	--repo) repo="$2" ;;
	--tag) tag="$2" ;;
	--commit) commit="$2" ;;
	--run-id) run_id="$2" ;;
	--repo-root) REPO_ROOT="$2" ;;
	*) die "unknown argument: $1" ;;
	esac
	shift 2
done
[ -n "$dir" ] && [ -n "$repo" ] && [ -n "$tag" ] && [ -n "$commit" ] && [ -n "$run_id" ] ||
	die "usage: verify-release.sh --dir DIR --repo OWNER/NAME --tag TAG --commit SHA --run-id ID [--repo-root DIR]"
valid_tag "$tag" || die "tag is not valid: $tag"
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "repository is not OWNER/NAME: $repo"
valid_commit "$commit" || die "commit is not a full SHA: $commit"
[[ "$run_id" =~ ^[0-9]+$ ]] || die "build run id is not a number: $run_id"

need_tools gpg jq minisign base64
load_config
load_allowed_signers
if needs_release_version; then
	set_release_version "$tag"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
make_verify_keyring "$work/keyring"

manifest="$dir/$MANIFEST_NAME"

# 1. The manifest and its signature. Nothing else is trusted before this check.
[ -f "$manifest" ] || die "$MANIFEST_NAME is missing"
verify_detached "$dir/$MANIFEST_SIG_NAME" "$manifest" ||
	die "$MANIFEST_NAME has no good signature from an allowed signer"
check_manifest "$manifest"

# 2. The directory holds exactly the files of the manifest, and these are
# exactly the files that the products require.
check_files_against_manifest "$dir" "$manifest" "$MANIFEST_NAME" "$MANIFEST_SIG_NAME"
names="$(list_dir "$dir")"
while IFS= read -r name; do
	case "$name" in
	*.unsigned.*) die "$name is an unsigned file. A release never holds one." ;;
	esac
done <<<"$names"
require_product_set release "the release" "$names"

# 3. The files belong to this release.
check_build_info "$dir/$BUILD_INFO_NAME" "$repo" "$tag" "$commit" "$run_id"

# 4. Detached signatures of every released file.
released="$(released_names)" || die "cannot list the released files"
while IFS= read -r name; do
	[ -n "$name" ] || continue
	verify_detached "$dir/$name.asc" "$dir/$name" ||
		die "$name has no good signature from an allowed signer"
done <<<"$released"

# 5. Updater signatures and latest.json. The list comes from the
# configuration, never from the files that happen to be present.
if uses_updater; then
	pubkey="$work/updater.pub"
	write_updater_pubkey "$pubkey"
	updater_names="$(updater_product_names)" || die "cannot list the updater products"
	latest="$dir/latest.json"
	latest_version="$(jq -r '.version | strings' "$latest")" || die "latest.json is not valid JSON"
	[ "$latest_version" = "$RELEASE_VERSION" ] ||
		die "latest.json has the wrong version: $latest_version, but the release version is $RELEASE_VERSION"
	expected_platforms=""
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		verify_updater_sig "$pubkey" "$dir/$name.sig" "$dir/$name" "$RELEASE_VERSION"
		platforms="$(product_updater_platforms "$name")" || die "cannot list the updater platforms of $name"
		[ -n "$platforms" ] || die "internal error: $name has no updater platforms"
		url="https://github.com/$repo/releases/download/$tag/$name"
		while IFS= read -r platform; do
			expected_platforms="$expected_platforms$platform"$'\n'
			jq -e --arg p "$platform" --arg url "$url" --rawfile sig "$dir/$name.sig" \
				'.platforms[$p] == {signature: $sig, url: $url}' "$latest" >/dev/null ||
				die "latest.json has a wrong entry for $platform"
		done <<<"$platforms"
	done <<<"$updater_names"
	actual_platforms="$(jq -r '.platforms | keys[]' "$latest" | LC_ALL=C sort)" ||
		die "latest.json has no platform list"
	expected_platforms="$(printf '%s' "$expected_platforms" | LC_ALL=C sort)"
	[ "$actual_platforms" = "$expected_platforms" ] ||
		die "latest.json does not list exactly the updater platforms of the configuration"
fi

log "verified: $(wc -l <"$manifest" | tr -d ' ') files of $repo $tag at commit $commit, build run $run_id"
