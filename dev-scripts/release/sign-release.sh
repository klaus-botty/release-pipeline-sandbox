#!/usr/bin/env bash
# Step 2 of the release pipeline: sign a release on the machine of a maintainer.
#
# Step 1 (CI) built the release files and created a draft release.
# This script downloads the files, makes sure that they come from the expected
# build, signs them with the keys of the maintainer, uploads the signatures to
# the draft release, and starts step 3 (CI), which verifies and publishes.
#
# gpg asks for the passphrase one time, at the start. The script never sees the
# passphrase. After that, the script needs no input.
#
# Usage: sign-release.sh TAG [--repo OWNER/NAME] [--run-id ID] [--no-dispatch]
#                            [--keep-workdir]
#
# Environment:
#   RELEASE_SIGNING_KEY   fingerprint of the PGP key to sign with. Default: the
#                         one local secret key that is on the allowlist.
#   RELEASE_SECRETS_FILE  the encrypted secrets file. Default:
#                         ~/.config/release-signing/<owner>__<name>.json.gpg
#   RELEASE_TAURI_CLI     command that runs the Tauri CLI. Default: cargo-tauri,
#                         or "cargo tauri".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
	die "usage: sign-release.sh TAG [--repo OWNER/NAME] [--run-id ID] [--no-dispatch] [--keep-workdir]"
}

tag="" repo="" run_id="" dispatch=1 keep_workdir=0
while [ $# -gt 0 ]; do
	case "$1" in
	--repo)
		[ $# -ge 2 ] || usage
		repo="$2"
		shift
		;;
	--run-id)
		[ $# -ge 2 ] || usage
		run_id="$2"
		shift
		;;
	--no-dispatch) dispatch=0 ;;
	--keep-workdir) keep_workdir=1 ;;
	-*) usage ;;
	*)
		[ -z "$tag" ] || usage
		tag="$1"
		;;
	esac
	shift
done
[ -n "$tag" ] || usage
valid_tag "$tag" || die "tag is not valid: $tag"

started=$SECONDS
phase_started=$SECONDS
phase_done() {
	log "    ($1: $((SECONDS - phase_started)) s)"
	phase_started=$SECONDS
}

# ---------------------------------------------------------------------------
# Preflight: fail before the passphrase prompt if the release is not ready.
# ---------------------------------------------------------------------------
step "Checking tools, login, and the state of the release"
need_tools gh gpg jq minisign base64 tar
load_config
load_allowed_signers
repo="${repo:-$CFG_REPOSITORY}"
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "repository is not OWNER/NAME: $repo"

use_updater=0
[ "$(updater_target_count)" = 0 ] || use_updater=1
[ "$use_updater" = 0 ] || find_tauri_cli

gh auth status >/dev/null 2>&1 || die "gh is not logged in. Run: gh auth login"
[ "$(gh api "repos/$repo" --jq .permissions.push)" = "true" ] ||
	die "your GitHub login has no write access to $repo"

release="$(find_release "$repo" "$tag")"
[ "$(printf '%s' "$release" | jq -r .draft)" = "true" ] ||
	die "release $tag is already published. This script signs draft releases only."
commit="$(printf '%s' "$release" | jq -r .target_commitish)"
valid_commit "$commit" || die "the draft release targets '$commit'. The build workflow must set a full commit SHA."
release_url="$(printf '%s' "$release" | jq -r .html_url)"

branch="${CFG_RELEASE_BRANCH:-$(default_branch "$repo")}"
require_commit_on_branch "$repo" "$commit" "$branch"
require_tag_matches "$repo" "$tag" "$commit"

if [ -z "$run_id" ]; then
	run_id="$(gh api "repos/$repo/actions/workflows/$CFG_BUILD_WORKFLOW/runs?head_sha=$commit&status=success&per_page=100" \
		--jq '.workflow_runs | sort_by(.created_at) | last | .id // empty')" ||
		die "cannot list the runs of $CFG_BUILD_WORKFLOW"
	[ -n "$run_id" ] || die "no successful run of $CFG_BUILD_WORKFLOW for commit $commit. Wait for the build, or pass --run-id."
fi
[[ "$run_id" =~ ^[0-9]+$ ]] || die "build run id is not a number: $run_id"
require_build_run "$repo" "$run_id" "$commit"

work="$(mktemp -d)"
cleanup() {
	if [ "$keep_workdir" = 1 ]; then
		rm -rf "$work/keyring"
		log "work directory kept: $work"
	else
		rm -rf "$work"
	fi
}
trap cleanup EXIT
make_verify_keyring "$work/keyring"

select_signing_key

secrets_file="$(secrets_file_path "$repo")"
if [ "$use_updater" = 1 ] && [ ! -f "$secrets_file" ]; then
	die "secrets file not found: $secrets_file. Create it with: just release-signing-setup"
fi

log "    repository:  $repo"
log "    release:     $tag (draft)  $release_url"
log "    commit:      $commit (on $branch)"
log "    build run:   https://github.com/$repo/actions/runs/$run_id"
log "    signing key: $SIGNING_KEY"
phase_done "preflight"

# ---------------------------------------------------------------------------
# Unlock: the one moment where gpg can ask for the passphrase.
# ---------------------------------------------------------------------------
step "Unlocking your keys (gpg asks for your passphrase now)"
if [ -z "${GPG_TTY:-}" ] && [ -t 0 ]; then
	GPG_TTY="$(tty)"
	export GPG_TTY
fi

pgp_sign() {
	gpg --batch --yes --local-user "$SIGNING_KEY" --armor --detach-sign --output "$1.asc" "$1" </dev/null
}

updater_sign() {
	TAURI_SIGNING_PRIVATE_KEY="$tauri_key" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$tauri_key_password" \
		"${TAURI_CLI[@]}" signer sign "$1" >/dev/null </dev/null
}

tauri_key="" tauri_key_password=""
if [ "$use_updater" = 1 ]; then
	# The decrypted secrets stay in shell variables. They never reach the disk.
	secrets="$(gpg --quiet --decrypt "$secrets_file")" || die "cannot decrypt $secrets_file"
	tauri_key="$(printf '%s' "$secrets" | jq -er .TAURI_SIGNING_PRIVATE_KEY)" ||
		die "$secrets_file holds no TAURI_SIGNING_PRIVATE_KEY"
	tauri_key_password="$(printf '%s' "$secrets" | jq -r '.TAURI_SIGNING_PRIVATE_KEY_PASSWORD // ""')"
	unset secrets
fi

# Test both keys on a small file now. A wrong key then fails here, and not
# after the download.
printf 'release signing self-test\n' >"$work/selftest"
pgp_sign "$work/selftest" || die "gpg cannot sign with $SIGNING_KEY"
verify_detached "$work/selftest.asc" "$work/selftest" ||
	die "a signature of $SIGNING_KEY does not pass the release check (is the key expired, or missing in $CFG_SIGNER_KEYS_DIR?)"
if [ "$use_updater" = 1 ]; then
	write_updater_pubkey "$work/updater.pub"
	updater_sign "$work/selftest" || die "the Tauri CLI cannot sign with the updater key in $secrets_file"
	verify_updater_sig "$work/updater.pub" "$work/selftest.sig" "$work/selftest" ||
		die "the updater key in $secrets_file does not match the updater public key of the app"
fi
phase_done "unlock"

# ---------------------------------------------------------------------------
# Download the build output and make sure that it is the expected build.
# ---------------------------------------------------------------------------
step "Downloading the build output of run $run_id"
assets="$work/assets"
download_build_artifacts "$repo" "$run_id" "$assets"
phase_done "download"

step "Checking that the files come from the build workflow at commit $commit"
build_manifest="$work/$BUILD_MANIFEST_NAME"
[ -f "$assets/$BUILD_MANIFEST_NAME" ] || die "the build run has no $BUILD_MANIFEST_NAME"
mv "$assets/$BUILD_MANIFEST_NAME" "$build_manifest"
# The attestation proves that the build workflow of this repository made the
# build manifest, on a GitHub-hosted runner, from this commit.
gh attestation verify "$build_manifest" --repo "$repo" \
	--signer-workflow "$repo/.github/workflows/$CFG_BUILD_WORKFLOW" \
	--source-digest "$commit" --deny-self-hosted-runners >/dev/null ||
	die "$BUILD_MANIFEST_NAME has no valid attestation from $CFG_BUILD_WORKFLOW at commit $commit"
check_manifest "$build_manifest"
check_files_against_manifest "$assets" "$build_manifest"
check_build_info "$assets/$BUILD_INFO_NAME" "$repo" "$tag" "$commit" "$run_id"
phase_done "provenance check"

# ---------------------------------------------------------------------------
# Platform signing.
#
# Steps that change the bytes of a release file go here, before every other
# signature: macOS code signing with notarization, and Flatpak repository
# signing. Each step replaces files in "$assets". The steps below then sign the
# final bytes, and the upload step sends every file that differs from the build
# output.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Updater signatures and latest.json
# ---------------------------------------------------------------------------
if [ "$use_updater" = 1 ]; then
	step "Making the updater signatures"
	asset_names="$(list_dir "$assets")"
	latest="$work/latest.json"
	jq -n --arg version "${tag#v}" --arg notes "$(printf '%s' "$release" | jq -r '.body // ""')" \
		--arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{version: $version, notes: $notes, pub_date: $date, platforms: {}}' >"$latest"
	count="$(updater_target_count)"
	i=0
	while [ "$i" -lt "$count" ]; do
		pattern="$(updater_target_pattern "$i")"
		match=""
		while IFS= read -r name; do
			# shellcheck disable=SC2254 # the pattern is a glob on purpose
			case "$name" in
			$pattern)
				[ -z "$match" ] || die "the updater pattern $pattern matches two files: $match and $name"
				match="$name"
				;;
			esac
		done <<<"$asset_names"
		if [ -z "$match" ]; then
			log "    no file matches $pattern. latest.json gets no entry for it."
		else
			updater_sign "$assets/$match" || die "cannot make the updater signature of $match"
			verify_updater_sig "$work/updater.pub" "$assets/$match.sig" "$assets/$match" ||
				die "the new updater signature of $match is not valid"
			while IFS= read -r platform; do
				jq --arg p "$platform" --arg url "https://github.com/$repo/releases/download/$tag/$match" \
					--rawfile sig "$assets/$match.sig" \
					'.platforms[$p] = {signature: $sig, url: $url}' "$latest" >"$latest.tmp"
				mv "$latest.tmp" "$latest"
			done < <(updater_target_platforms "$i")
		fi
		i=$((i + 1))
	done
	if [ "$(jq -r '.platforms | length' "$latest")" != 0 ]; then
		mv "$latest" "$assets/latest.json"
	fi
	tauri_key="" tauri_key_password=""
	phase_done "updater signatures"
fi

# ---------------------------------------------------------------------------
# PGP signatures and the signed manifest
# ---------------------------------------------------------------------------
step "Making the PGP signatures"
asset_names="$(list_dir "$assets")"
while IFS= read -r name; do
	case "$name" in
	*.asc | *.sig) continue ;;
	esac
	pgp_sign "$assets/$name" || die "cannot sign $name"
done <<<"$asset_names"
write_manifest "$assets" "$assets/$MANIFEST_NAME"
pgp_sign "$assets/$MANIFEST_NAME" || die "cannot sign $MANIFEST_NAME"
phase_done "PGP signatures"

step "Checking the signed release, with the same check that CI runs"
"$SCRIPT_DIR/verify-release.sh" --dir "$assets" --repo "$repo" --tag "$tag" \
	--commit "$commit" --run-id "$run_id" --repo-root "$REPO_ROOT"
phase_done "self-check"

# ---------------------------------------------------------------------------
# Upload: only the files that this script made or changed. CI adds the
# unchanged build output itself, after it verified the signatures.
# ---------------------------------------------------------------------------
step "Uploading the signatures to the draft release"
upload=()
final_names="$(list_dir "$assets")"
while IFS= read -r name; do
	hash="$(sha256_of "$assets/$name")"
	if [ "$(manifest_hash "$build_manifest" "$name")" != "$hash" ]; then
		upload+=("$assets/$name")
	fi
done <<<"$final_names"

# The draft can hold files from an earlier run of this script, or from an
# earlier finalize run. Every such file must belong to this release. This
# script replaces its own files, but it never deletes a file that it does not
# know.
# find_release and list_dir run outside of a process substitution, so that a
# failure stops the script.
draft_names="$(find_release "$repo" "$tag" | jq -r '.assets[].name' | LC_ALL=C sort)"
final_names="$(list_dir "$assets")"
strays="$(LC_ALL=C comm -23 <(printf '%s\n' "$draft_names") <(printf '%s\n' "$final_names") | grep -v '^$' || true)"
[ -z "$strays" ] ||
	die "the draft release holds files that are not part of this release: $(printf '%s' "$strays" | tr '\n' ' '). Look at them, delete them by hand, then run this script again."

gh release upload "$tag" --repo "$repo" --clobber "${upload[@]}" >/dev/null ||
	die "upload failed. Run this script again."
log "    uploaded ${#upload[@]} files"
phase_done "upload"

# ---------------------------------------------------------------------------
# Start step 3.
# ---------------------------------------------------------------------------
if [ "$dispatch" = 1 ]; then
	step "Starting the finalize workflow"
	gh workflow run "$CFG_FINALIZE_WORKFLOW" --repo "$repo" --ref "$branch" \
		-f tag="$tag" -f build_run_id="$run_id" >&2 ||
		die "cannot start $CFG_FINALIZE_WORKFLOW. Start it by hand with tag=$tag and build_run_id=$run_id."
	log "CI now verifies the signatures and publishes the release."
	log "Runs: https://github.com/$repo/actions/workflows/$CFG_FINALIZE_WORKFLOW"
else
	log "Finalize workflow not started (--no-dispatch). Start it with:"
	log "  gh workflow run $CFG_FINALIZE_WORKFLOW --repo $repo --ref $branch -f tag=$tag -f build_run_id=$run_id"
fi
log ""
log "Done in $((SECONDS - started)) s."
