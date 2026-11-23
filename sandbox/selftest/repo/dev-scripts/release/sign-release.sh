#!/usr/bin/env bash
# Step 2 of the release pipeline: sign a release on the machine of a maintainer.
#
# Step 1 (CI) built the release files and created a draft release.
# This script downloads the files, makes sure that they come from the expected
# build, signs them with the keys of the maintainer, uploads the signatures to
# the draft release, and starts step 3 (CI), which verifies and publishes.
#
# The script runs only from a clean git checkout at the current head of the
# default branch of the repository (as the GitHub API reports it): its code,
# the configuration, the signer keys, the allowlist, and the Homebrew
# generator must be committed, with no change and no untracked or ignored file.
#
# gpg asks for the passphrase one time, at the start. The script never sees the
# passphrase. After that, the script needs no input. While the script runs, a
# background job uses the unlocked key once a minute (it never asks for the
# passphrase), so that gpg-agent keeps it unlocked during long steps such as
# notarization. gpg-agent still forgets it after max-cache-ttl (default 2 h).
#
# The local steps, if config.json has their section: Apple code signing and
# notarization (apple.sh), Flatpak repository signing (flatpak.sh), and the
# Homebrew cask (homebrew.generator of this checkout, run on the final DMG
# files before the manifest is signed). Notarization follows apple.notarize in
# the committed configuration only.
#
# The script also makes the git tag of the release, after every check and
# upload passed and before it starts step 3: a signed annotated tag on the
# release commit, made with the release key and pushed with the git
# credentials of your gh login. If that is not possible without a second
# passphrase prompt or a large fetch, it makes a plain tag through the API.
# An existing tag must point to the release commit.
#
# Usage: sign-release.sh TAG [--repo OWNER/NAME] [--run-id ID] [--no-dispatch]
#                            [--keep-workdir]
#
# Environment:
#   RELEASE_SIGNING_KEY   fingerprint of the PGP key to sign with. Default: the
#                         one local secret key that is on the allowlist.
#   RELEASE_SECRETS_FILE  the encrypted secrets file. Default:
#                         ~/.config/release-signing/<owner>__<name>.json.gpg
#
# Without --run-id, the script takes the newest successful build run of the
# release commit whose build info names TAG.
#
# A second run after an interruption continues: it skips every file that the
# draft holds with the same bytes, and replaces a file with other bytes (an
# earlier approval). The signed manifest is always the last upload.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source-path=SCRIPTDIR source=apple.sh
. "$SCRIPT_DIR/apple.sh"
# shellcheck source-path=SCRIPTDIR source=flatpak.sh
. "$SCRIPT_DIR/flatpak.sh"

# The Apple secrets live in these shell variables only (apple.sh reads them).
# An exported variable of the same name would pass them on to every child, so
# the script drops any inherited value and its export flag first.
unset APPLE_P12_BASE64 APPLE_P12_PASSWORD APPLE_API_KEY_JSON_BASE64

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
step "Checking the signing checkout, tools, login, and the state of the release"
need_tools gh gpg jq minisign base64 tar git
[ -z "${RELEASE_CONFIG:-}" ] || die "RELEASE_CONFIG is set. The signing script reads its configuration only from its own checkout."
load_config
# The tools of the local steps. These checks need no secret.
[ "$CFG_HAS_APPLE" = 0 ] || apple_preflight tools
[ "$CFG_HAS_FLATPAK" = 0 ] || flatpak_preflight "$CFG_FLATPAK_FINGERPRINT"
# The code of this script and every file that it trusts or runs come from one
# clean checkout. The commit goes into the log.
trusted_paths=("$SCRIPT_DIR" "$CFG_SIGNER_KEYS_DIR" "$CFG_ALLOWED_SIGNERS")
if uses_updater; then
	trusted_paths+=("$REPO_ROOT/$(cfg .updater.pubkey_file)")
fi
if [ "$CFG_HAS_HOMEBREW" = 1 ]; then
	# The generator and the files next to it (its template).
	homebrew_generator="$REPO_ROOT/$CFG_HOMEBREW_GENERATOR"
	[ -f "$homebrew_generator" ] && [ ! -L "$homebrew_generator" ] ||
		die "homebrew.generator $CFG_HOMEBREW_GENERATOR is not a regular file in $REPO_ROOT"
	trusted_paths+=("$(dirname "$homebrew_generator")")
fi
require_clean_checkout "${trusted_paths[@]}"
load_allowed_signers
repo="${repo:-$CFG_REPOSITORY}"
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "repository is not OWNER/NAME: $repo"

if needs_release_version || [ "$CFG_HAS_HOMEBREW" = 1 ]; then
	set_release_version "$tag"
fi

gh auth status >/dev/null 2>&1 || die "gh is not logged in. Run: gh auth login"
[ "$(gh api "repos/$repo" --jq .permissions.push)" = "true" ] ||
	die "your GitHub login has no write access to $repo"
# Next to the check for local changes: the checkout must also be the current
# head of the default branch, so that a revoked signer or an outdated step
# cannot come from an old checkout.
require_checkout_at_default_head "$repo"
log "    signing scripts: commit $CHECKOUT_COMMIT of $REPO_ROOT (clean, head of $DEFAULT_BRANCH)"

release="$(find_release "$repo" "$tag")"
[ "$(printf '%s' "$release" | jq -r .draft)" = "true" ] ||
	die "release $tag is already published. This script signs draft releases only."
release_id="$(printf '%s' "$release" | jq -r .id)"
[[ "$release_id" =~ ^[0-9]+$ ]] || die "the release has no valid id: $release_id"
commit="$(printf '%s' "$release" | jq -r .target_commitish)"
valid_commit "$commit" || die "the draft release targets '$commit'. The build workflow must set a full commit SHA."
release_url="$(printf '%s' "$release" | jq -r .html_url)"

# The release commit, as GitHub knows it. The maintainer compares it with the
# intended commit in the log below.
commit_json="$(gh api "repos/$repo/commits/$commit")" || die "cannot read commit $commit of $repo"
[ "$(printf '%s' "$commit_json" | jq -r .sha)" = "$commit" ] || die "GitHub returns another commit for $commit"
commit_subject="$(printf '%s' "$commit_json" | jq -r '.commit.message | strings | split("\n")[0]')" ||
	die "cannot read the message of commit $commit"
commit_date="$(printf '%s' "$commit_json" | jq -r '.commit.committer.date | strings')" ||
	die "cannot read the date of commit $commit"

branch="${CFG_RELEASE_BRANCH:-}"
if [ -z "$branch" ]; then
	branch="$(default_branch "$repo")" || die "cannot read the default branch of $repo"
fi
require_commit_on_branch "$repo" "$commit" "$branch"
tag_state="$(require_tag_matches "$repo" "$tag" "$commit")" || die "cannot check the git tag $tag"
if uses_updater; then
	require_app_version "$repo" "$commit" "$RELEASE_VERSION"
	require_updater_pubkey_at_commit "$repo" "$commit"
fi

work="$(mktemp -d)"
keepalive_pid=""
cleanup() {
	if [ -n "$keepalive_pid" ]; then
		kill "$keepalive_pid" 2>/dev/null || true
		wait "$keepalive_pid" 2>/dev/null || true
	fi
	if [ "$keep_workdir" = 1 ]; then
		rm -rf "$work/keyring"
		log "work directory kept: $work"
	else
		rm -rf "$work"
	fi
}
trap cleanup EXIT
mkdir "$work/runs"

# The tag in the build info of a run is a hint that picks the run. The attested
# build manifest, after the download, is the proof.
if [ -z "$run_id" ]; then
	select_build_run "$repo" "$commit" "$tag" "$work/runs"
	run_id="$BUILD_RUN_ID"
else
	[[ "$run_id" =~ ^[0-9]+$ ]] || die "build run id is not a number: $run_id"
	require_run_tag "$repo" "$run_id" "$tag" "$work/runs"
fi
require_build_run "$repo" "$run_id" "$commit" "$branch"
make_verify_keyring "$work/keyring"

select_signing_key

# The inputs of the local steps, from the release commit, not from this
# checkout: the release must be signed with the settings of the released code.
if [ "$CFG_HAS_APPLE" = 1 ]; then
	fetch_file_at_commit "$repo" "$commit" "$CFG_APPLE_ENTITLEMENTS" >"$work/entitlements.plist" ||
		die "cannot read $CFG_APPLE_ENTITLEMENTS at the release commit"
	[ -s "$work/entitlements.plist" ] || die "$CFG_APPLE_ENTITLEMENTS is empty at the release commit $commit"
fi
if [ "$CFG_HAS_FLATPAK" = 1 ]; then
	flatpak_extra_refs_file "$work/flatpak-extra-refs"
	flatpak_expected_refs "$CFG_FLATPAK_APP_ID" "$CFG_FLATPAK_ARCH" "$CFG_FLATPAK_BRANCH" "$work/flatpak-extra-refs" \
		>"$work/flatpak-expected-refs" || die "cannot make the list of the expected Flatpak refs"
fi

secrets_file="$(secrets_file_path "$repo")"
needs_secrets=0
if uses_updater || [ "$CFG_HAS_APPLE" = 1 ]; then
	needs_secrets=1
fi
if [ "$needs_secrets" = 1 ] && [ ! -f "$secrets_file" ]; then
	die "secrets file not found: $secrets_file. Create it with: just release-signing-setup"
fi

# The git tag: a signed tag needs the release commit in this checkout. A
# shallow checkout without it would need a fetch of unknown size.
tag_plan=signed tag_plan_reason=""
if [ "$tag_state" = present ]; then
	tag_plan=exists
elif ! git -C "$REPO_ROOT" cat-file -e "$commit^{commit}" 2>/dev/null &&
	[ "$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
	tag_plan=api
	tag_plan_reason="this checkout is shallow and does not hold the release commit, so a signed tag would need a fetch of unknown size"
fi

log "    repository:  $repo"
log "    release:     $tag (draft)  $release_url"
[ -z "${RELEASE_VERSION:-}" ] || log "    version:     $RELEASE_VERSION"
log "    commit:      $commit (on $branch)"
log "      subject:   $commit_subject"
log "      date:      $commit_date"
log "    build run:   https://github.com/$repo/actions/runs/$run_id (attempt $BUILD_RUN_ATTEMPT)"
log "    signing key: $SIGNING_KEY"
[ "$CFG_HAS_APPLE" = 0 ] || log "    Apple:       sign, notarize=$CFG_APPLE_NOTARIZE (from config.json), entitlements $CFG_APPLE_ENTITLEMENTS at the release commit"
[ "$CFG_HAS_FLATPAK" = 0 ] || log "    Flatpak:     sign $CFG_FLATPAK_TO_SIGN with $CFG_FLATPAK_FINGERPRINT, refs: $(tr '\n' ' ' <"$work/flatpak-expected-refs")"
[ "$CFG_HAS_HOMEBREW" = 0 ] || log "    Homebrew:    $(expand_product_name "$CFG_HOMEBREW_OUTPUT") by $CFG_HOMEBREW_GENERATOR of this checkout"
case "$tag_plan" in
exists) log "    git tag:     $tag exists already on the release commit" ;;
signed) log "    git tag:     a signed tag $tag on the release commit, after the upload" ;;
api) log "    git tag:     a plain tag $tag through the API after the upload, because $tag_plan_reason" ;;
esac
log "    Check that $commit is the commit that you intend to release. The draft,"
log "    the build run, and (after the download) the attestation must all name it."
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

tauri_key="" tauri_key_password=""
if [ "$needs_secrets" = 1 ]; then
	# The decrypted secrets stay in shell variables that are never exported.
	# They never reach the disk, an argument list, or the environment of a
	# child.
	secrets="$(gpg --quiet --decrypt "$secrets_file")" || die "cannot decrypt $secrets_file"
	if uses_updater; then
		tauri_key="$(printf '%s' "$secrets" | jq -er .TAURI_SIGNING_PRIVATE_KEY)" ||
			die "$secrets_file holds no TAURI_SIGNING_PRIVATE_KEY"
		tauri_key_password="$(printf '%s' "$secrets" | jq -r '.TAURI_SIGNING_PRIVATE_KEY_PASSWORD // ""')"
	fi
	if [ "$CFG_HAS_APPLE" = 1 ]; then
		apple_keys="APPLE_P12_BASE64 APPLE_P12_PASSWORD"
		[ "$CFG_APPLE_NOTARIZE" = false ] || apple_keys="$apple_keys APPLE_API_KEY_JSON_BASE64"
		missing=""
		for key in $apple_keys; do
			printf '%s' "$secrets" | jq -e --arg k "$key" 'has($k) and (.[$k] | type == "string")' >/dev/null 2>&1 ||
				missing="$missing $key"
		done
		[ -z "$missing" ] ||
			die "$secrets_file holds no Apple signing secrets ($(printf '%s' "${missing# }" | sed 's/ /, /g')), but config.json has an apple section (notarize=$CFG_APPLE_NOTARIZE). Add them with: just release-signing-setup"
		APPLE_P12_BASE64="$(printf '%s' "$secrets" | jq -r .APPLE_P12_BASE64)"
		APPLE_P12_PASSWORD="$(printf '%s' "$secrets" | jq -r .APPLE_P12_PASSWORD)"
		APPLE_API_KEY_JSON_BASE64="$(printf '%s' "$secrets" | jq -r '.APPLE_API_KEY_JSON_BASE64 // ""')"
		# The team check of step 3, before any signature: a certificate of
		# another team stops here, not after the signing and notarization.
		apple_preflight secrets "$CFG_APPLE_NOTARIZE" "$CFG_APPLE_TEAM_ID"
	fi
	unset secrets
fi

# Test both keys on a small file now. A wrong key then fails here, and not
# after the download.
printf 'release signing self-test\n' >"$work/selftest"
pgp_sign "$work/selftest" || die "gpg cannot sign with $SIGNING_KEY"
verify_detached "$work/selftest.asc" "$work/selftest" ||
	die "a signature of $SIGNING_KEY does not pass the release check (is the key expired, or missing in $CFG_SIGNER_KEYS_DIR?)"
# The keys that sign later: the release key, and the Flatpak key if it is
# another key. Unlock the Flatpak key now as well, not in the middle of the run.
unlocked_keys="$SIGNING_KEY"
if [ "$CFG_HAS_FLATPAK" = 1 ] && [ "$CFG_FLATPAK_FINGERPRINT" != "$SIGNING_KEY" ]; then
	gpg --batch --yes --local-user "$CFG_FLATPAK_FINGERPRINT" --detach-sign --output "$work/selftest.flatpak.sig" \
		"$work/selftest" </dev/null || die "gpg cannot sign with the Flatpak key $CFG_FLATPAK_FINGERPRINT"
	unlocked_keys="$unlocked_keys $CFG_FLATPAK_FINGERPRINT"
fi
# keepalive: uses each unlocked key once a minute, so that gpg-agent does not
# forget it (default-cache-ttl) during a long step. It never asks for a
# passphrase (--pinentry-mode error).
keepalive() {
	local key
	while :; do
		sleep 60
		for key in $unlocked_keys; do
			gpg --batch --yes --pinentry-mode error --local-user "$key" --detach-sign \
				--output "$work/keepalive.sig" "$work/selftest" </dev/null >/dev/null 2>&1 || true
		done
	done
}
keepalive </dev/null >/dev/null 2>&1 &
keepalive_pid=$!
if uses_updater; then
	write_updater_pubkey "$work/updater.pub"
	updater_sign "$tauri_key" "$tauri_key_password" "$work/selftest" "$RELEASE_VERSION" ||
		die "minisign cannot sign with the updater key in $secrets_file"
	selftest_comment="$(updater_sig_comment "$work/updater.pub" "$work/selftest.sig" "$work/selftest")" ||
		die "the updater key in $secrets_file does not match the updater public key of the app"
	check_updater_comment selftest.sig "$selftest_comment" selftest "$RELEASE_VERSION"
fi
phase_done "unlock"

# ---------------------------------------------------------------------------
# Download the build output and make sure that it is the expected build.
# ---------------------------------------------------------------------------
step "Downloading the build output of run $run_id"
download="$work/download"
download_build_artifacts "$repo" "$run_id" "$download"
phase_done "download"

step "Checking that the files come from the build workflow at commit $commit"
build_manifest="$work/$BUILD_MANIFEST_NAME"
[ -f "$download/$BUILD_MANIFEST_NAME" ] || die "the build run has no $BUILD_MANIFEST_NAME"
mv "$download/$BUILD_MANIFEST_NAME" "$build_manifest"
check_manifest "$build_manifest"
build_listed="$(manifest_names "$build_manifest")" || die "cannot read $BUILD_MANIFEST_NAME"
require_product_set build-manifest "$BUILD_MANIFEST_NAME of build run $run_id" "$build_listed"
check_present_files_against_manifest "$download" "$build_manifest"
downloaded="$(list_dir "$download")"
require_product_set signer-download "the artifacts of build run $run_id that match $CFG_ARTIFACT_PATTERN" "$downloaded"
check_build_info "$download/$BUILD_INFO_NAME" "$repo" "$tag" "$commit" "$run_id" \
	"Build run $run_id is not the build of $tag. Pass --run-id with the build run of $tag."
info_attempt="$(jq -r .run_attempt "$download/$BUILD_INFO_NAME")" || die "cannot read $BUILD_INFO_NAME"
info_workflow_ref="$(jq -r .workflow_ref "$download/$BUILD_INFO_NAME")" || die "cannot read $BUILD_INFO_NAME"
[ "$info_workflow_ref" = "$repo/.github/workflows/$CFG_BUILD_WORKFLOW@refs/heads/$branch" ] ||
	die "$BUILD_INFO_NAME names the workflow $info_workflow_ref, not $repo/.github/workflows/$CFG_BUILD_WORKFLOW@refs/heads/$branch"
[ "$info_attempt" = "$BUILD_RUN_ATTEMPT" ] ||
	die "$BUILD_INFO_NAME comes from attempt $info_attempt of build run $run_id, but the latest attempt of the run is $BUILD_RUN_ATTEMPT"
# The attestation proves that the build workflow of this repository made the
# build manifest, on a GitHub-hosted runner, from this commit on the release
# branch, in exactly the run attempt that the build info names.
verify_build_attestation "$build_manifest" "$repo" "$commit" "refs/heads/$branch" "$run_id" "$info_attempt"
log "    the draft, build run $run_id (attempt $info_attempt), and its attestation all name commit $commit"

# The release directory gets the build products and the build info. The input
# products go to their own directory: they are never released.
assets="$work/release" inputs="$work/input"
mkdir "$assets" "$inputs"
names="$(product_names input)" || die "cannot list the input products"
while IFS= read -r name; do
	[ -z "$name" ] || mv "$download/$name" "$inputs/$name"
done <<<"$names"
names="$(product_names build)" || die "cannot list the build products"
while IFS= read -r name; do
	[ -z "$name" ] || mv "$download/$name" "$assets/$name"
done <<<"$names"
mv "$download/$BUILD_INFO_NAME" "$assets/$BUILD_INFO_NAME"
[ -z "$(list_dir "$download")" ] || die "internal error: unsorted files in $download"
phase_done "provenance check"

# ---------------------------------------------------------------------------
# Platform signing and the other local steps.
#
# "$inputs" holds the products with origin input. They are never released.
# "$assets" holds the build products and the build info, as the build made them.
#
# Steps that make a product with origin local read their inputs from "$inputs"
# and write the product into "$assets": macOS code signing with notarization,
# Flatpak repository signing, the Homebrew formula. A step that changes the
# bytes of a build product replaces it in "$assets". The steps below then sign
# the final bytes, and the upload step sends every file that differs from the
# build output.
# ---------------------------------------------------------------------------

if [ "$CFG_HAS_APPLE" = 1 ]; then
	step "Apple: signing the apps and the DMG files (notarize=$CFG_APPLE_NOTARIZE)"
	apple_process_all "$inputs" "$work/entitlements.plist" "$CFG_APPLE_NOTARIZE" "$assets"
	APPLE_P12_BASE64="" APPLE_P12_PASSWORD="" APPLE_API_KEY_JSON_BASE64=""
	unset APPLE_P12_BASE64 APPLE_P12_PASSWORD APPLE_API_KEY_JSON_BASE64
	phase_done "Apple"
fi
if [ "$CFG_HAS_FLATPAK" = 1 ]; then
	step "Flatpak: checking the refs and signing the repository with $CFG_FLATPAK_FINGERPRINT"
	flatpak_sign "$inputs/$CFG_FLATPAK_TO_SIGN" "$CFG_FLATPAK_FINGERPRINT" "$assets/$CFG_FLATPAK_SIGNATURES" \
		"$work/flatpak-expected-refs" || die "Flatpak signing failed"
	phase_done "Flatpak"
fi
if [ "$CFG_HAS_HOMEBREW" = 1 ]; then
	homebrew_out="$(expand_product_name "$CFG_HOMEBREW_OUTPUT")" || die "cannot expand homebrew.output"
	homebrew_aarch64="$(expand_product_name "$CFG_HOMEBREW_DMG_AARCH64")" || die "cannot expand homebrew.dmg.aarch64"
	homebrew_x64="$(expand_product_name "$CFG_HOMEBREW_DMG_X64")" || die "cannot expand homebrew.dmg.x64"
	step "Homebrew: writing $homebrew_out from the final DMG files with $CFG_HOMEBREW_GENERATOR"
	for name in "$homebrew_aarch64" "$homebrew_x64"; do
		[ -f "$assets/$name" ] || die "Homebrew: the DMG $name is missing in the release directory"
	done
	bash "$homebrew_generator" "$tag" "$assets/$homebrew_aarch64" "$assets/$homebrew_x64" "$assets/$homebrew_out" </dev/null ||
		die "$CFG_HOMEBREW_GENERATOR failed"
	[ -f "$assets/$homebrew_out" ] || die "$CFG_HOMEBREW_GENERATOR wrote no $homebrew_out"
	log "    $homebrew_out: sha256 $(sha256_of "$assets/$homebrew_out")"
	phase_done "Homebrew"
fi

# (end of the local steps)
before="$(list_dir "$assets")"
require_product_set before-signing "the release directory after the local steps" "$before"

# ---------------------------------------------------------------------------
# Updater signatures and latest.json. The products come from the
# configuration, never from the files that happen to be present.
# ---------------------------------------------------------------------------
if uses_updater; then
	step "Making the updater signatures"
	updater_names="$(updater_product_names)" || die "cannot list the updater products"
	latest="$work/latest.json"
	notes="$(printf '%s' "$release" | jq -r '.body // ""')" || die "cannot read the release notes"
	jq -n --arg version "$RELEASE_VERSION" --arg notes "$notes" \
		--arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{version: $version, notes: $notes, pub_date: $date, platforms: {}}' >"$latest"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		updater_sign "$tauri_key" "$tauri_key_password" "$assets/$name" "$RELEASE_VERSION" ||
			die "cannot make the updater signature of $name"
		verify_updater_sig "$work/updater.pub" "$assets/$name.sig" "$assets/$name" "$RELEASE_VERSION"
		platforms="$(product_updater_platforms "$name")" || die "cannot list the updater platforms of $name"
		[ -n "$platforms" ] || die "internal error: $name has no updater platforms"
		while IFS= read -r platform; do
			jq --arg p "$platform" --arg url "https://github.com/$repo/releases/download/$tag/$name" \
				--rawfile sig "$assets/$name.sig" \
				'.platforms[$p] = {signature: $sig, url: $url}' "$latest" >"$latest.tmp"
			mv "$latest.tmp" "$latest"
		done <<<"$platforms"
	done <<<"$updater_names"
	mv "$latest" "$assets/latest.json"
	tauri_key="" tauri_key_password=""
	phase_done "updater signatures"
fi

# ---------------------------------------------------------------------------
# PGP signatures and the signed manifest
# ---------------------------------------------------------------------------
step "Making the PGP signatures"
released="$(released_names)" || die "cannot list the released files"
while IFS= read -r name; do
	[ -n "$name" ] || continue
	pgp_sign "$assets/$name" || die "cannot sign $name"
done <<<"$released"
names="$(list_dir "$assets")"
require_product_set release-files "the signed release before $MANIFEST_NAME" "$names"
write_manifest "$assets" "$assets/$MANIFEST_NAME"
pgp_sign "$assets/$MANIFEST_NAME" || die "cannot sign $MANIFEST_NAME"
phase_done "PGP signatures"

step "Checking the signed release, with the same check that CI runs"
"$SCRIPT_DIR/verify-release.sh" --dir "$assets" --repo "$repo" --tag "$tag" \
	--commit "$commit" --run-id "$run_id" --repo-root "$REPO_ROOT"
phase_done "self-check"

# ---------------------------------------------------------------------------
# Upload: every file that the build did not make, or that differs from the
# build output. CI adds the unchanged build output itself, after it verified
# the signatures. Every upload goes to the release id, and GitHub's digest of
# each upload must match. The files upload in parallel; SHA256SUMS and
# SHA256SUMS.asc go last, each alone.
# ---------------------------------------------------------------------------
step "Uploading to the draft release"
final_names="$(list_dir "$assets")"
upload_names=""
while IFS= read -r name; do
	[ -n "$name" ] || continue
	hash="$(sha256_of "$assets/$name")" || die "cannot hash $name"
	if [ "$(manifest_hash "$build_manifest" "$name")" != "$hash" ]; then
		upload_names="$upload_names$name"$'\n'
	fi
done <<<"$final_names"

# The draft can hold files from an earlier run of this script, or from an
# earlier finalize run. Every such file must belong to this release. This
# script replaces its own files, but it never deletes a file that it does not
# know.
require_draft "$repo" "$release_id" "$tag" "$commit"
draft_assets="$(release_assets "$repo" "$release_id")"
draft_state="$(asset_state "$draft_assets")" || die "cannot read the asset list of the draft"
strays=""
while IFS=' ' read -r name _; do
	[ -n "$name" ] || continue
	name_in_list "$name" "$final_names" || strays="$strays $name"
done <<<"$draft_state"
[ -z "$strays" ] ||
	die "the draft release holds files that are not part of this release:$strays. Look at them, delete them by hand, then run this script again."

uploaded=0 skipped=0
# prepare_asset NAME: makes the draft ready for NAME, and adds NAME to
# to_upload if this run must upload it. A file that is on the draft with the
# same digest stays. A file with other bytes is an earlier approval: this run
# deletes it now and uploads its own. A build file that this run does not
# upload is deleted, and the finalize workflow adds it from the build.
prepare_asset() {
	local name="$1" line id digest want
	want="sha256:$(sha256_of "$assets/$name")" || die "cannot hash $name"
	line="$(printf '%s\n' "$draft_state" | awk -v name="$name" '$1 == name')"
	if [ -n "$line" ]; then
		id="$(printf '%s' "$line" | cut -d' ' -f2)"
		digest="$(printf '%s' "$line" | cut -d' ' -f4)"
		if [ "$digest" = "$want" ] && [ "$(printf '%s' "$line" | cut -d' ' -f5)" = uploaded ]; then
			skipped=$((skipped + 1))
			log "    on the draft already, same bytes: $name"
			return 0
		fi
		log "    REPLACING AN EARLIER APPROVAL: the draft holds other bytes for $name (digest $digest, this run: $want)."
		require_draft "$repo" "$release_id" "$tag" "$commit"
		delete_release_asset "$repo" "$id" "$name"
		if ! name_in_list "$name" "$upload_names"; then
			log "    $name is unchanged build output: the finalize workflow adds it again from build run $run_id."
		fi
	fi
	if name_in_list "$name" "$upload_names"; then
		to_upload+=("$name")
	fi
}

# upload_assets NAME...: uploads the files, UPLOAD_JOBS at a time. Each upload
# checks the draft first, and then the name, size, and digest that GitHub
# reports (upload_release_asset). The log of each upload appears when it ends.
# After the first failure, no new upload starts. The function waits for the
# running uploads, then fails with the names of the files that did not arrive.
UPLOAD_JOBS=4
upload_assets() {
	local logs="$work/upload-logs" name failed="" started=0 done_count=0
	local -a pids names
	pids=() names=()
	mkdir -p "$logs"
	# upload_reap: waits for the oldest running upload and shows its log.
	upload_reap() {
		local rc=0
		wait "${pids[done_count]}" || rc=$?
		sed 's/^/    /' "$logs/$done_count.log" >&2
		if [ "$rc" = 0 ]; then
			uploaded=$((uploaded + 1))
			log "    uploaded: ${names[done_count]}"
		else
			failed="$failed ${names[done_count]}"
		fi
		done_count=$((done_count + 1))
	}
	for name in "$@"; do
		[ -z "$failed" ] || break
		[ $((started - done_count)) -lt "$UPLOAD_JOBS" ] || upload_reap
		[ -z "$failed" ] || break
		(
			require_draft "$repo" "$release_id" "$tag" "$commit"
			upload_release_asset "$repo" "$release_id" "$assets/$name"
		) </dev/null >"$logs/$started.log" 2>&1 &
		pids[started]=$!
		names[started]="$name"
		started=$((started + 1))
	done
	while [ "$done_count" -lt "$started" ]; do
		upload_reap
	done
	[ -z "$failed" ] ||
		die "upload of${failed} failed. The draft has no new $MANIFEST_NAME. Run this script again: it keeps the files that arrived."
}

# An earlier manifest goes first, so that the draft never holds an earlier
# approval next to new files. The new manifest goes last: an interrupted
# upload leaves no new manifest on the draft, and the finalize workflow
# refuses the draft.
for name in "$MANIFEST_NAME" "$MANIFEST_SIG_NAME"; do
	line="$(printf '%s\n' "$draft_state" | awk -v name="$name" '$1 == name')"
	[ -n "$line" ] || continue
	digest="$(printf '%s' "$line" | cut -d' ' -f4)"
	hash="$(sha256_of "$assets/$name")" || die "cannot hash $name"
	[ "$digest" != "sha256:$hash" ] || continue
	log "    REPLACING AN EARLIER APPROVAL: the draft holds an earlier $name. This run removes it first, and uploads its own last."
	require_draft "$repo" "$release_id" "$tag" "$commit"
	delete_release_asset "$repo" "$(printf '%s' "$line" | cut -d' ' -f2)" "$name"
	draft_state="$(printf '%s\n' "$draft_state" | awk -v name="$name" '$1 != name')"
done
to_upload=()
while IFS= read -r name; do
	case "$name" in
	"" | "$MANIFEST_NAME" | "$MANIFEST_SIG_NAME") continue ;;
	esac
	prepare_asset "$name"
done <<<"$final_names"
upload_assets ${to_upload[@]+"${to_upload[@]}"}
# The manifest and its signature: each alone, after every other file arrived.
for name in "$MANIFEST_NAME" "$MANIFEST_SIG_NAME"; do
	to_upload=()
	prepare_asset "$name"
	upload_assets ${to_upload[@]+"${to_upload[@]}"}
done

# The draft must now hold every file of this run with the same digest, and
# nothing else.
draft_assets="$(release_assets "$repo" "$release_id")"
draft_state="$(asset_state "$draft_assets")" || die "cannot read the asset list of the draft"
problems=""
while IFS=' ' read -r name _ _ digest _; do
	[ -n "$name" ] || continue
	if ! name_in_list "$name" "$final_names"; then
		problems="$problems $name (not part of this release)"
		continue
	fi
	hash="$(sha256_of "$assets/$name")" || die "cannot hash $name"
	[ "$digest" = "sha256:$hash" ] || problems="$problems $name (other bytes)"
done <<<"$draft_state"
while IFS= read -r name; do
	[ -n "$name" ] || continue
	printf '%s\n' "$draft_state" | awk -v name="$name" '$1 == name { found = 1 } END { exit !found }' ||
		problems="$problems $name (missing)"
done <<<"$upload_names"
[ -z "$problems" ] || die "after the upload, the draft does not hold the files of this run:$problems. Another writer changed the draft. Look at it, then run this script again."
log "    uploaded $uploaded files, $skipped were on the draft already"
phase_done "upload"

# ---------------------------------------------------------------------------
# The git tag. Only now: every check passed, and the draft holds the signed
# files. Step 3 never creates a tag.
# ---------------------------------------------------------------------------
# tag_by_api REASON: a plain (lightweight, unsigned) tag through the API, with
# the gh login of the maintainer.
tag_by_api() {
	log "    FALLBACK: a plain tag through the API, because $1."
	gh api -X POST "repos/$repo/git/refs" -f ref="refs/tags/$tag" -f sha="$commit" </dev/null >/dev/null ||
		log "    the API refused to create the tag"
}

# signed_tag: makes a signed annotated tag object with the release key, and
# pushes it to refs/tags/TAG. Writes only objects into the git object store of
# this checkout: no ref, no branch, no work tree file changes. Returns 2 if a
# step before the push fails (the caller falls back to the API), 1 if the push
# fails.
signed_tag() {
	local url="https://github.com/$repo.git" uid uid_re tagger started=$SECONDS t object
	local -a git_gh
	# The credentials of the gh login, for github.com only. No other helper.
	git_gh=(git -C "$REPO_ROOT" -c credential.helper= -c "credential.https://github.com.helper=!gh auth git-credential")
	uid="$(gpg --batch --with-colons --list-keys "$SIGNING_KEY" 2>/dev/null |
		awk -F: '$1 == "uid" && $2 !~ /[rei]/ { print $10; exit }')" || uid=""
	uid_re='^[^<>]+ <[^<> ]+>$'
	if ! [[ "$uid" =~ $uid_re ]]; then
		tag_fallback_reason="the release key has no valid user id 'Name <email>' for the tagger: '$uid'"
		return 2
	fi
	if ! git -C "$REPO_ROOT" cat-file -e "$commit^{commit}" 2>/dev/null; then
		t=$SECONDS
		if ! "${git_gh[@]}" fetch --quiet --no-tags --no-write-fetch-head --no-recurse-submodules "$url" "$commit" </dev/null >&2; then
			tag_fallback_reason="git cannot fetch the release commit from $url"
			return 2
		fi
		log "    fetched the release commit into $REPO_ROOT in $((SECONDS - t)) s"
	fi
	tagger="$uid $(date +%s) +0000"
	printf 'object %s\ntype commit\ntag %s\ntagger %s\n\nRelease %s\n\nCommit: %s\n%s: %s\nBuild run: https://github.com/%s/actions/runs/%s\n' \
		"$commit" "$tag" "$tagger" "$tag" "$commit" "$MANIFEST_NAME" "$manifest_sha256" "$repo" "$run_id" >"$work/tag.payload"
	rm -f "$work/tag.payload.asc"
	# --pinentry-mode error: gpg fails instead of a second passphrase prompt.
	if ! gpg --batch --yes --pinentry-mode error --local-user "$SIGNING_KEY" --armor --detach-sign \
		--output "$work/tag.payload.asc" "$work/tag.payload" </dev/null; then
		tag_fallback_reason="gpg-agent no longer holds the unlocked release key, and a signed tag would need a second passphrase prompt"
		return 2
	fi
	verify_detached "$work/tag.payload.asc" "$work/tag.payload" || {
		tag_fallback_reason="the tag signature does not pass the release check"
		return 2
	}
	cat "$work/tag.payload" "$work/tag.payload.asc" >"$work/tag.object"
	object="$(git -C "$REPO_ROOT" mktag <"$work/tag.object")" || {
		tag_fallback_reason="git mktag refuses the tag object"
		return 2
	}
	"${git_gh[@]}" push --quiet --no-verify "$url" "$object:refs/tags/$tag" </dev/null >&2 || return 1
	log "    pushed the signed tag object $object (key $SIGNING_KEY, tagger $uid) in $((SECONDS - started)) s"
}

step "Making the git tag $tag on the release commit"
manifest_sha256="$(sha256_of "$assets/$MANIFEST_NAME")" || die "cannot hash $MANIFEST_NAME"
tag_fallback_reason=""
case "$tag_plan" in
exists) log "    $tag exists already and points to $commit" ;;
api) tag_by_api "$tag_plan_reason" ;;
signed)
	rc=0
	signed_tag || rc=$?
	case "$rc" in
	0) ;;
	2) tag_by_api "$tag_fallback_reason" ;;
	*) tag_by_api "git push of the signed tag failed" ;;
	esac
	;;
esac
# The result counts, not the way: GitHub must now show the tag on the commit.
# Another maintainer can have made it at the same time.
tag_now="$(tag_commit "$repo" "$tag")" || die "cannot read the git tag $tag"
[ -n "$tag_now" ] ||
	die "cannot create the git tag $tag. The draft holds the signed files. Run this script again, or create the tag on $commit by hand (git push <remote> $commit:refs/tags/$tag), then start $CFG_FINALIZE_WORKFLOW."
[ "$tag_now" = "$commit" ] ||
	die "the git tag $tag points to $tag_now, not to the release commit $commit. $(release_retry_hint "$tag")"
phase_done "git tag"

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
