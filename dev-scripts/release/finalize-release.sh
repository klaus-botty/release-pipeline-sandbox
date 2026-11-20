#!/usr/bin/env bash
# Step 3 of the release pipeline: the finalize workflow runs this. It verifies
# the signed draft release and publishes it.
#
# Usage:
#   finalize-release.sh stage --tag TAG --run-id ID --repo OWNER/NAME [--repo-root DIR]
#       Verifies the signatures on the draft release, adds the unchanged build
#       files from the build run, verifies the complete release, and prints
#       manifest_sha256=<sha256 of SHA256SUMS>.
#   finalize-release.sh fetch --tag TAG --repo OWNER/NAME --manifest-sha256 HEX --dir DIR [NAME...]
#       Downloads SHA256SUMS and the named release files (all files if no name
#       is given) into DIR, and checks them against the pinned manifest.
#   finalize-release.sh publish --tag TAG --run-id ID --repo OWNER/NAME --manifest-sha256 HEX [--repo-root DIR]
#       Verifies the draft release again and publishes it.
#
# Environment: GH_TOKEN (gh reads it). GITHUB_REF and GITHUB_OUTPUT if set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
	die "usage: finalize-release.sh stage --tag TAG --run-id ID --repo OWNER/NAME [--repo-root DIR]
       finalize-release.sh fetch --tag TAG --repo OWNER/NAME --manifest-sha256 HEX --dir DIR [NAME...]
       finalize-release.sh publish --tag TAG --run-id ID --repo OWNER/NAME --manifest-sha256 HEX [--repo-root DIR]"
}

[ $# -ge 1 ] || usage
command="$1"
shift
case "$command" in
stage | fetch | publish) ;;
*) usage ;;
esac

tag="" run_id="" repo="" manifest_sha256="" dir=""
names=()
while [ $# -gt 0 ]; do
	case "$1" in
	--tag | --run-id | --repo | --manifest-sha256 | --dir | --repo-root)
		[ $# -ge 2 ] || usage
		case "$1" in
		--tag) tag="$2" ;;
		--run-id) run_id="$2" ;;
		--repo) repo="$2" ;;
		--manifest-sha256) manifest_sha256="$2" ;;
		--dir) dir="$2" ;;
		--repo-root) REPO_ROOT="$2" ;;
		esac
		shift 2
		;;
	-*) usage ;;
	*)
		[ "$command" = fetch ] || usage
		valid_asset_name "$1" || die "file name is not allowed: $1"
		names+=("$1")
		shift
		;;
	esac
done

[ -n "$tag" ] && [ -n "$repo" ] || usage
valid_tag "$tag" || die "tag is not valid: $tag"
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "repository is not OWNER/NAME: $repo"
case "$command" in
stage | publish)
	[ -n "$run_id" ] || usage
	[[ "$run_id" =~ ^[0-9]+$ ]] || die "build run id is not a number: $run_id"
	[ -d "$REPO_ROOT" ] || die "not a directory: $REPO_ROOT"
	;;
*)
	[ -z "$run_id" ] || usage
	;;
esac
case "$command" in
fetch | publish)
	[[ "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || die "--manifest-sha256 is not a lowercase sha256: $manifest_sha256"
	;;
*)
	[ -z "$manifest_sha256" ] || usage
	;;
esac
if [ "$command" = fetch ]; then
	[ -n "$dir" ] || usage
else
	[ -z "$dir" ] || usage
fi
[ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN is not set"

if [ "$command" = fetch ]; then
	need_tools gh jq
else
	need_tools gh gpg jq minisign base64
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# check_draft: the checks that stage and publish share. Sets release, release_id,
# and commit.
check_draft() {
	local branch
	branch="${CFG_RELEASE_BRANCH:-}"
	if [ -z "$branch" ]; then
		branch="$(default_branch "$repo")" || die "cannot read the default branch of $repo"
		[ -n "$branch" ] || die "cannot read the default branch of $repo"
	fi
	# The allowlist and the signer keys come from the checkout of this run. Only
	# the release branch decides who can sign.
	if [ -n "${GITHUB_REF:-}" ] && [ "$GITHUB_REF" != "refs/heads/$branch" ]; then
		die "this workflow runs on $GITHUB_REF. Start it from the branch $branch."
	fi

	release="$(find_release "$repo" "$tag")"
	[ "$(printf '%s' "$release" | jq -r .draft)" = "true" ] ||
		die "release $tag is not a draft. It is published already."
	release_id="$(printf '%s' "$release" | jq -r .id)"
	[[ "$release_id" =~ ^[0-9]+$ ]] || die "the release has no valid id: $release_id"
	commit="$(printf '%s' "$release" | jq -r .target_commitish)"
	valid_commit "$commit" || die "the draft release targets '$commit'. The build workflow must set a full commit SHA."
	require_build_run "$repo" "$run_id" "$commit"
	require_commit_on_branch "$repo" "$commit" "$branch"
	require_tag_matches "$repo" "$tag" "$commit"
}

# in_list NAME LIST: true if the newline-separated LIST holds NAME.
in_list() {
	printf '%s\n' "$2" | grep -qxF -- "$1"
}

stage() {
	local staging="$work/staging" built="$work/built" manifest name present expected hash
	local upload=()
	load_config
	load_allowed_signers
	check_draft

	[ "$(printf '%s' "$release" | jq -r '.assets | length')" != 0 ] ||
		die "the draft release $tag has no files. The signing script has to run first."
	step "Downloading the draft release"
	download_release_assets "$repo" "$release" "$staging"

	step "Checking the signed manifest"
	make_verify_keyring "$work/keyring"
	manifest="$staging/$MANIFEST_NAME"
	[ -f "$manifest" ] || die "the draft release has no $MANIFEST_NAME. The signing script has to run first."
	verify_detached "$staging/$MANIFEST_SIG_NAME" "$manifest" ||
		die "$MANIFEST_NAME has no good signature from an allowed signer"
	check_manifest "$manifest"
	expected="$(manifest_names "$manifest")"

	present="$(list_dir "$staging")"
	while IFS= read -r name; do
		case "$name" in
		"" | "$MANIFEST_NAME" | "$MANIFEST_SIG_NAME") continue ;;
		esac
		in_list "$name" "$expected" || die "extra file on the draft release: $name"
	done <<<"$present"

	step "Adding the unchanged build files of run $run_id"
	download_build_artifacts "$repo" "$run_id" "$built"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		[ ! -e "$staging/$name" ] || continue
		[ -f "$built/$name" ] || die "$name is in $MANIFEST_NAME, but neither on the draft release nor in the build run"
		cp "$built/$name" "$staging/$name"
		upload+=("$staging/$name")
	done <<<"$expected"

	step "Verifying the complete release"
	"$SCRIPT_DIR/verify-release.sh" --dir "$staging" --repo "$repo" --tag "$tag" \
		--commit "$commit" --run-id "$run_id" --repo-root "$REPO_ROOT"

	if [ "${#upload[@]}" -gt 0 ]; then
		step "Uploading ${#upload[@]} build files to the draft release"
		gh release upload "$tag" --repo "$repo" "${upload[@]}" >/dev/null ||
			die "upload failed"
	fi

	hash="$(sha256_of "$manifest")"
	printf 'manifest_sha256=%s\n' "$hash"
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		printf 'manifest_sha256=%s\n' "$hash" >>"$GITHUB_OUTPUT"
	fi
}

fetch() {
	local release manifest name hash wanted=""
	release="$(find_release "$repo" "$tag")"
	mkdir -p "$dir"
	# Never replace a file that is in DIR already.
	[ ! -e "$dir/$MANIFEST_NAME" ] && [ ! -L "$dir/$MANIFEST_NAME" ] || die "$dir/$MANIFEST_NAME exists already"
	download_release_assets "$repo" "$release" "$dir" "$MANIFEST_NAME"
	manifest="$dir/$MANIFEST_NAME"
	hash="$(sha256_of "$manifest")"
	[ "$hash" = "$manifest_sha256" ] ||
		die "$MANIFEST_NAME of release $tag has the sha256 $hash, not the expected $manifest_sha256"
	check_manifest "$manifest"

	if [ "${#names[@]}" -eq 0 ]; then
		wanted="$(manifest_names "$manifest")"
	else
		for name in "${names[@]}"; do
			[ -n "$(manifest_hash "$manifest" "$name")" ] || die "$MANIFEST_NAME does not list $name"
			wanted="$wanted$name"$'\n'
		done
	fi
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		[ ! -e "$dir/$name" ] && [ ! -L "$dir/$name" ] || die "$dir/$name exists already"
		download_release_assets "$repo" "$release" "$dir" "$name"
		hash="$(sha256_of "$dir/$name")"
		[ "$hash" = "$(manifest_hash "$manifest" "$name")" ] ||
			die "hash mismatch for $name: the file does not match $MANIFEST_NAME"
	done <<<"$wanted"
	log "fetched and checked $(printf '%s' "$wanted" | grep -c . || true) files of $repo $tag"
}

publish() {
	local download="$work/release" hash after draft published_commit
	load_config
	load_allowed_signers
	check_draft

	step "Verifying the draft release again"
	download_release_assets "$repo" "$release" "$download"
	[ -f "$download/$MANIFEST_NAME" ] || die "the draft release has no $MANIFEST_NAME"
	hash="$(sha256_of "$download/$MANIFEST_NAME")"
	[ "$hash" = "$manifest_sha256" ] ||
		die "$MANIFEST_NAME changed after the stage step: sha256 is $hash, expected $manifest_sha256"
	"$SCRIPT_DIR/verify-release.sh" --dir "$download" --repo "$repo" --tag "$tag" \
		--commit "$commit" --run-id "$run_id" --repo-root "$REPO_ROOT"

	step "Publishing release $tag"
	require_tag_matches "$repo" "$tag" "$commit"
	gh api -X PATCH "repos/$repo/releases/$release_id" -F draft=false >/dev/null ||
		die "cannot publish release $tag"

	after="$(gh api "repos/$repo/releases/$release_id")" ||
		die "RELEASE $tag MAY BE PUBLISHED, BUT IT CANNOT BE READ BACK. A human must check it now."
	draft="$(printf '%s' "$after" | jq -r .draft)"
	published_commit="$(tag_commit "$repo" "$tag")" || published_commit=""
	if [ "$draft" != "false" ] || [ "$published_commit" != "$commit" ]; then
		die "RELEASE $tag NEEDS A HUMAN NOW: after the publish call, draft=$draft and the tag points to '${published_commit}', not to the release commit $commit."
	fi
	log "published $repo $tag at commit $commit"
}

"$command"
