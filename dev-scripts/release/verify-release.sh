#!/usr/bin/env bash
# Verifies a directory that holds the complete set of files of one release.
#
# The local signing script runs this before it uploads anything. The finalize
# workflow runs it before it publishes anything. The script succeeds only if:
#   - SHA256SUMS has one good signature from an allowed signer,
#   - the directory holds exactly the files that SHA256SUMS lists, with the
#     same hashes,
#   - release-build-info.json names this repository, tag, commit, and build run,
#   - every release file has a good detached signature (<file>.asc),
#   - every updater file has a good updater signature (<file>.sig),
#   - latest.json matches the updater files and their signatures.
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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
make_verify_keyring "$work/keyring"

manifest="$dir/$MANIFEST_NAME"

# 1. The manifest and its signature. Nothing else is trusted before this check.
[ -f "$manifest" ] || die "$MANIFEST_NAME is missing"
verify_detached "$dir/$MANIFEST_SIG_NAME" "$manifest" ||
	die "$MANIFEST_NAME has no good signature from an allowed signer"
check_manifest "$manifest"

# 2. The directory holds exactly the files of the manifest.
check_files_against_manifest "$dir" "$manifest" "$MANIFEST_NAME" "$MANIFEST_SIG_NAME"

# 3. The files belong to this release.
check_build_info "$dir/$BUILD_INFO_NAME" "$repo" "$tag" "$commit" "$run_id"

# 4. Detached signatures and updater signatures.
names="$(manifest_names "$manifest")"
has_updater_assets=0
pubkey="$work/updater.pub"
while IFS= read -r name; do
	case "$name" in
	*.asc)
		grep -qxF -- "${name%.asc}" <<<"$names" || die "$name has no file that it signs"
		case "${name%.asc}" in
		*.asc | *.sig) die "$name signs a signature file" ;;
		esac
		;;
	*.sig)
		grep -qxF -- "${name%.sig}" <<<"$names" || die "$name has no file that it signs"
		is_updater_asset "${name%.sig}" || die "$name signs a file that is not an updater file"
		;;
	*)
		verify_detached "$dir/$name.asc" "$dir/$name" ||
			die "$name has no good signature from an allowed signer"
		if is_updater_asset "$name"; then
			if [ "$has_updater_assets" = 0 ]; then
				write_updater_pubkey "$pubkey"
				has_updater_assets=1
			fi
			[ -f "$dir/$name.sig" ] || die "$name has no updater signature ($name.sig)"
			verify_updater_sig "$pubkey" "$dir/$name.sig" "$dir/$name" ||
				die "the updater signature of $name does not match the updater public key of the app"
		fi
		;;
	esac
done <<<"$names"

# 5. latest.json matches the updater files.
if [ "$has_updater_assets" = 1 ]; then
	latest="$dir/latest.json"
	[ -f "$latest" ] || die "latest.json is missing"
	[ "$(jq -r .version "$latest")" = "${tag#v}" ] || die "latest.json has the wrong version"
	expected_platforms=""
	count="$(updater_target_count)"
	i=0
	while [ "$i" -lt "$count" ]; do
		pattern="$(updater_target_pattern "$i")"
		while IFS= read -r name; do
			# shellcheck disable=SC2254 # the pattern is a glob on purpose
			case "$name" in
			*.asc | *.sig) continue ;;
			$pattern) ;;
			*) continue ;;
			esac
			while IFS= read -r platform; do
				expected_platforms="$expected_platforms$platform"$'\n'
				url="https://github.com/$repo/releases/download/$tag/$name"
				jq -e --arg p "$platform" --arg url "$url" --rawfile sig "$dir/$name.sig" \
					'.platforms[$p].url == $url and .platforms[$p].signature == $sig' "$latest" >/dev/null ||
					die "latest.json has a wrong entry for $platform"
			done < <(updater_target_platforms "$i")
		done <<<"$names"
		i=$((i + 1))
	done
	actual_platforms="$(jq -r '.platforms | keys[]' "$latest" | LC_ALL=C sort)"
	expected_platforms="$(printf '%s' "$expected_platforms" | LC_ALL=C sort)"
	[ "$actual_platforms" = "$expected_platforms" ] ||
		die "latest.json does not list exactly the platforms of the updater files"
fi

log "verified: $(wc -l <"$manifest" | tr -d ' ') files of $repo $tag at commit $commit, build run $run_id"
