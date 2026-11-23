#!/usr/bin/env bash
# Step 3 of the release pipeline: the finalize workflow runs this. It verifies
# the signed draft release and publishes it.
#
# Usage:
#   finalize-release.sh stage --tag TAG --run-id ID --repo OWNER/NAME [--repo-root DIR] [--out DIR]
#       Verifies the signatures on the draft release, adds the unchanged build
#       files from the build run, verifies the complete release, checks that
#       the draft holds exactly these files, and prints
#       manifest_sha256=<sha256 of SHA256SUMS>. With --out, it also leaves the
#       complete verified set in DIR (new or empty), for example to hand it to
#       other jobs as a workflow artifact. Those jobs check it with check-set.
#       A release that is published already (a re-run of the finalize
#       workflow) gets the same checks, including the head check of
#       GITHUB_SHA and the tag check, but no upload: it must hold every file
#       of the signed manifest already, each with the digest of the manifest.
#       So the workflow calls stage for both states.
#   finalize-release.sh require-newest --tag TAG --repo OWNER/NAME
#       Fails if a published release of REPO has a higher version than TAG,
#       by the precedence rules of Semantic Versioning (TAG without one leading
#       "v"). A job calls it right before it pushes TAG to a channel outside
#       GitHub, so that no channel moves back to an older version. For a
#       release version (no pre-release part), only published release versions
#       count: a published pre-release such as 2.0.0-rc.1 does not block
#       1.9.1. For a pre-release, every published version counts, so
#       1.2.0-rc.2 is refused after 1.2.0. Tags that are not semantic versions
#       and draft releases do not count.
#   finalize-release.sh fetch --tag TAG --repo OWNER/NAME --manifest-sha256 HEX --dir DIR [NAME...]
#       Downloads SHA256SUMS and the named release files (all files if no name
#       is given) into DIR, and checks them against the pinned manifest.
#   finalize-release.sh publish --tag TAG --run-id ID --repo OWNER/NAME --manifest-sha256 HEX [--repo-root DIR]
#       Verifies the draft release again and publishes it. It compares the full
#       asset list (ids, names, sizes, digests) with the signed manifest right
#       before and right after the change of the draft flag.
#   finalize-release.sh check-set --dir DIR --manifest-sha256 HEX [--subset] [--repo-root DIR]
#       Offline: no token, no network. Checks that SHA256SUMS in DIR has the
#       pinned hash and a good signature from an allowed signer, and that DIR
#       holds exactly the files of SHA256SUMS with the right hashes. With
#       --subset, files may be absent, but every present file must be listed
#       and correct. SHA256SUMS and SHA256SUMS.asc are always required.
#   finalize-release.sh verify-macos --tag TAG --dir DIR [--manifest-sha256 HEX] [--unsigned-dir DIR] [--repo-root DIR]
#       On a macOS runner. Checks DIR like check-set --subset: SHA256SUMS needs
#       a good signature from an allowed signer, and every file in DIR must be
#       listed with its hash. --manifest-sha256 also pins SHA256SUMS; without
#       it, the command prints the hash of the SHA256SUMS that it checked. DIR
#       must hold release-build-info.json and every app archive and DMG that
#       the Apple step makes. The tag of the verified build info must be TAG.
#       Then fetches apple.entitlements_file at the release commit of the build
#       info (with GH_TOKEN through the API; without GH_TOKEN from
#       raw.githubusercontent.com, which works for a public repository only),
#       and runs verify-macos.sh with the values of the apple section of
#       config.json.
#   finalize-release.sh flatpak --dir DIR --manifest-sha256 HEX --repo-tar FILE --out DIR [--tag TAG] [--repo-root DIR]
#       The check-set --subset check on DIR, which must hold the Flatpak
#       signatures archive. Exports the public key flatpak.fingerprint from the
#       committed signer keys, writes the expected refs, copies the files of
#       flatpak.pages from the repository root into one directory, and runs
#       flatpak-finalize.sh with the values of the flatpak section of
#       config.json. --out is the new gh-pages directory. No token, no network.
#
# stage and publish never create the git tag: the signing script makes it.
# Both require that it exists and points to the release commit, and publish
# checks it again right before it publishes the draft.
#
# Environment: GH_TOKEN (gh reads it; check-set and flatpak need none,
# verify-macos uses it if set). GITHUB_SHA: stage
# and publish refuse to run unless it is the head of the default branch, so
# that they use the current scripts, signer keys, and allowlist. This holds
# for a published release too: an old run must not hand an old release to the
# later jobs. GITHUB_REF and
# GITHUB_OUTPUT if set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source-path=SCRIPTDIR source=flatpak.sh
. "$SCRIPT_DIR/flatpak.sh"

usage() {
	die "usage: finalize-release.sh stage --tag TAG --run-id ID --repo OWNER/NAME [--repo-root DIR] [--out DIR]
       finalize-release.sh fetch --tag TAG --repo OWNER/NAME --manifest-sha256 HEX --dir DIR [NAME...]
       finalize-release.sh require-newest --tag TAG --repo OWNER/NAME
       finalize-release.sh publish --tag TAG --run-id ID --repo OWNER/NAME --manifest-sha256 HEX [--repo-root DIR]
       finalize-release.sh check-set --dir DIR --manifest-sha256 HEX [--subset] [--repo-root DIR]
       finalize-release.sh verify-macos --tag TAG --dir DIR [--manifest-sha256 HEX] [--unsigned-dir DIR] [--repo-root DIR]
       finalize-release.sh flatpak --dir DIR --manifest-sha256 HEX --repo-tar FILE --out DIR [--tag TAG] [--repo-root DIR]"
}

[ $# -ge 1 ] || usage
command="$1"
shift
# The options that each command requires, and the ones that it allows.
case "$command" in
stage) required="tag run-id repo" allowed="repo-root out" ;;
fetch) required="tag repo manifest-sha256 dir" allowed="" ;;
require-newest) required="tag repo" allowed="" ;;
publish) required="tag run-id repo manifest-sha256" allowed="repo-root" ;;
check-set) required="dir manifest-sha256" allowed="subset repo-root" ;;
verify-macos) required="tag dir" allowed="manifest-sha256 unsigned-dir repo-root" ;;
flatpak) required="dir manifest-sha256 repo-tar out" allowed="tag repo-root" ;;
*) usage ;;
esac

tag="" run_id="" repo="" manifest_sha256="" dir="" out="" unsigned_dir="" repo_tar="" subset=0 given=""
names=()
while [ $# -gt 0 ]; do
	case "$1" in
	--tag | --run-id | --repo | --manifest-sha256 | --dir | --repo-root | --out | --unsigned-dir | --repo-tar)
		[ $# -ge 2 ] || usage
		case " $given " in
		*" ${1#--} "*) die "$1 is given twice" ;;
		esac
		given="$given ${1#--}"
		case "$1" in
		--tag) tag="$2" ;;
		--run-id) run_id="$2" ;;
		--repo) repo="$2" ;;
		--manifest-sha256) manifest_sha256="$2" ;;
		--dir) dir="$2" ;;
		--repo-root) REPO_ROOT="$2" ;;
		--out) out="$2" ;;
		--unsigned-dir) unsigned_dir="$2" ;;
		--repo-tar) repo_tar="$2" ;;
		esac
		shift 2
		;;
	--subset)
		given="$given subset"
		subset=1
		shift
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
for option in $required; do
	case " $given " in
	*" $option "*) ;;
	*) usage ;;
	esac
done
for option in $given; do
	case " $required $allowed " in
	*" $option "*) ;;
	*) die "$command does not take --$option" ;;
	esac
done

[ -z "$tag" ] || valid_tag "$tag" || die "tag is not valid: $tag"
[ -z "$repo" ] || [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "repository is not OWNER/NAME: $repo"
[ -z "$run_id" ] || [[ "$run_id" =~ ^[0-9]+$ ]] || die "build run id is not a number: $run_id"
[ -z "$manifest_sha256" ] || [[ "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] ||
	die "--manifest-sha256 is not a lowercase sha256: $manifest_sha256"
[ -d "$REPO_ROOT" ] || die "not a directory: $REPO_ROOT"

case "$command" in
check-set) need_tools gpg jq ;;
flatpak) need_tools gpg jq tar ;;
verify-macos)
	# The entitlements file at the release commit: through the API with a
	# token, or from raw.githubusercontent.com without one.
	if [ -n "${GH_TOKEN:-}" ]; then need_tools gh gpg jq; else need_tools curl gpg jq; fi
	;;
fetch | require-newest)
	[ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN is not set"
	need_tools gh jq
	;;
*)
	[ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN is not set"
	need_tools gh gpg jq minisign base64
	;;
esac

work="$(mktemp -d)"
published_flip=0
on_exit() {
	local rc=$?
	if [ "$rc" != 0 ] && [ "$published_flip" = 1 ]; then
		recovery_text >&2
	fi
	rm -rf "$work"
}
trap on_exit EXIT

# check_release STATES: the checks that stage and publish share. STATES is
# "draft" (publish) or "draft published" (stage): the states of the release
# that the caller accepts. Sets release, release_id, release_published (0 or
# 1), branch, and commit. With updater products, it also sets RELEASE_VERSION
# and makes sure that the app configuration at the release commit has this
# version and the updater public key of this checkout.
check_release() {
	local states="$1" draft
	# The allowlist and the signer keys come from the checkout of this run. Only
	# the current head of the default branch decides who can sign.
	require_current_trust_state "$repo"
	branch="${CFG_RELEASE_BRANCH:-}"
	if [ -z "$branch" ]; then
		branch="$(default_branch "$repo")" || die "cannot read the default branch of $repo"
	fi
	if [ -n "${GITHUB_REF:-}" ] && [ "$GITHUB_REF" != "refs/heads/$branch" ]; then
		die "this workflow runs on $GITHUB_REF. Start it from the branch $branch."
	fi

	release="$(find_release "$repo" "$tag")"
	draft="$(printf '%s' "$release" | jq -r .draft)" || die "cannot read the draft state of release $tag"
	case "$draft" in
	true) release_published=0 ;;
	false)
		case " $states " in
		*" published "*) release_published=1 ;;
		*) die "release $tag is not a draft. It is published already." ;;
		esac
		;;
	*) die "cannot read the draft state of release $tag: '$draft'" ;;
	esac
	release_id="$(printf '%s' "$release" | jq -r .id)"
	[[ "$release_id" =~ ^[0-9]+$ ]] || die "the release has no valid id: $release_id"
	commit="$(printf '%s' "$release" | jq -r .target_commitish)"
	valid_commit "$commit" || die "the release $tag targets '$commit'. The build workflow must set a full commit SHA."
	require_build_run "$repo" "$run_id" "$commit" "$branch"
	require_commit_on_branch "$repo" "$commit" "$branch"
	require_tag_on_commit "$repo" "$tag" "$commit"
	if needs_release_version; then
		set_release_version "$tag"
	fi
	if uses_updater; then
		require_app_version "$repo" "$commit" "$RELEASE_VERSION"
		require_updater_pubkey_at_commit "$repo" "$commit"
	fi
}

stage() {
	local staging="$work/staging" built="$work/built" manifest name present expected hash rerun upload_names="" now what
	load_config
	load_allowed_signers
	if [ -n "$out" ]; then
		[ ! -L "$out" ] || die "$out is a symbolic link"
		if [ -e "$out" ]; then
			[ -d "$out" ] && [ -z "$(ls -A "$out")" ] || die "$out exists and is not an empty directory"
		fi
	fi
	check_release "draft published"

	if [ "$release_published" = 1 ]; then
		# A published release cannot change. Check it as it is: the same
		# checks as for a draft, but no file comes from the build run, and
		# nothing is uploaded.
		what="the published release $tag"
		rerun="A published release cannot change, so a human must look at it. $(release_retry_hint "$tag")"
		log "release $tag is published already: checking it as it is, without any upload"
	else
		what="the draft release"
		rerun="The signing script has to run again."
		[ "$(printf '%s' "$release" | jq -r '.assets | length')" != 0 ] ||
			die "the draft release $tag has no files. The signing script has to run first."
	fi
	step "Downloading $what"
	download_release_assets "$repo" "$release" "$staging"

	step "Checking the signed manifest"
	make_verify_keyring "$work/keyring"
	manifest="$staging/$MANIFEST_NAME"
	[ -f "$manifest" ] || die "$what has no $MANIFEST_NAME. $rerun"
	verify_detached "$staging/$MANIFEST_SIG_NAME" "$manifest" ||
		die "$MANIFEST_NAME has no good signature from an allowed signer"
	check_manifest "$manifest"
	expected="$(manifest_names "$manifest")" || die "cannot read $MANIFEST_NAME"

	present="$(list_dir "$staging")"
	while IFS= read -r name; do
		case "$name" in
		"" | "$MANIFEST_NAME" | "$MANIFEST_SIG_NAME") continue ;;
		esac
		name_in_list "$name" "$expected" || die "extra file on $what: $name. $rerun"
		# Refuse a changed file before the large download of the build output.
		hash="$(sha256_of "$staging/$name")" || die "cannot hash $name"
		[ "$hash" = "$(manifest_hash "$manifest" "$name")" ] ||
			die "hash mismatch for $name on $what: the file does not match $MANIFEST_NAME. $rerun"
	done <<<"$present"

	if [ "$release_published" = 1 ]; then
		while IFS= read -r name; do
			[ -z "$name" ] || [ -e "$staging/$name" ] ||
				die "$name is in $MANIFEST_NAME, but not on $what. $rerun"
		done <<<"$expected"
	else
		step "Adding the unchanged build files of run $run_id"
		download_build_artifacts "$repo" "$run_id" "$built"
		check_build_info "$built/$BUILD_INFO_NAME" "$repo" "$tag" "$commit" "$run_id" \
			"The build output of run $run_id does not belong to release $tag."
		while IFS= read -r name; do
			[ -n "$name" ] || continue
			[ ! -e "$staging/$name" ] || continue
			[ -f "$built/$name" ] || die "$name is in $MANIFEST_NAME, but neither on the draft release nor in the build run. $rerun"
			mv "$built/$name" "$staging/$name"
			upload_names="$upload_names$name"$'\n'
		done <<<"$expected"
	fi

	step "Verifying the complete release"
	"$SCRIPT_DIR/verify-release.sh" --dir "$staging" --repo "$repo" --tag "$tag" \
		--commit "$commit" --run-id "$run_id" --repo-root "$REPO_ROOT"

	if [ -n "$upload_names" ]; then
		step "Uploading $(printf '%s' "$upload_names" | grep -c .) build files to the draft release"
		while IFS= read -r name; do
			[ -n "$name" ] || continue
			require_draft "$repo" "$release_id" "$tag" "$commit"
			upload_release_asset "$repo" "$release_id" "$staging/$name" ||
				die "upload of $name failed. Run the finalize workflow again."
		done <<<"$upload_names"
	fi

	# The release must now hold exactly the verified files.
	now="$(release_assets "$repo" "$release_id")"
	require_assets_match_dir "$now" "$staging" "$what"

	if [ -n "$out" ]; then
		mkdir -p "$out"
		present="$(list_dir "$staging")"
		while IFS= read -r name; do
			[ -z "$name" ] || cp -p "$staging/$name" "$out/$name"
		done <<<"$present"
		log "the complete verified release is in $out"
	fi

	hash="$(sha256_of "$manifest")" || die "cannot hash $MANIFEST_NAME"
	printf 'manifest_sha256=%s\n' "$hash"
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		printf 'manifest_sha256=%s\n' "$hash" >>"$GITHUB_OUTPUT"
	fi
}

# require-newest: fails if a published release has a higher version than TAG.
# The release of TAG itself can be a draft or published, and it does not need
# to be visible: a token with read access sees no drafts.
require_newest() {
	local version list other_tag other draft order newer="" counted=0
	set_release_version "$tag"
	version="$RELEASE_VERSION"
	list="$(gh api --paginate "repos/$repo/releases?per_page=100" </dev/null |
		jq -r '.[] | "\(.tag_name) \(.draft)"')" || die "cannot list the releases of $repo"
	while IFS=' ' read -r other_tag draft; do
		[ -n "$other_tag" ] || continue
		[ "$draft" = false ] || continue
		other="${other_tag#v}"
		[[ "$other" =~ $SEMVER_RE ]] || continue
		# A release version competes only with release versions: a published
		# pre-release never blocks a release version.
		[[ "${version%%+*}" == *-* ]] || [[ "${other%%+*}" != *-* ]] || continue
		counted=$((counted + 1))
		order="$(semver_cmp "$other" "$version")" || die "cannot compare the versions $other and $version"
		[ "$order" != 1 ] || newer="$newer $other_tag"
	done <<<"$list"
	[ -z "$newer" ] ||
		die "release $tag (version $version) is not the newest published version of $repo. Newer published releases:$newer. Refusing to move a channel back to an older version."
	log "release $tag (version $version) is the newest: no published release of $repo has a higher version ($counted compared)"
}

fetch() {
	local release manifest name hash wanted=""
	release="$(find_release "$repo" "$tag")"
	mkdir -p "$dir"
	# Never replace a file that is in DIR already.
	[ ! -e "$dir/$MANIFEST_NAME" ] && [ ! -L "$dir/$MANIFEST_NAME" ] || die "$dir/$MANIFEST_NAME exists already"
	download_release_assets "$repo" "$release" "$dir" "$MANIFEST_NAME"
	manifest="$dir/$MANIFEST_NAME"
	hash="$(sha256_of "$manifest")" || die "cannot hash $MANIFEST_NAME"
	[ "$hash" = "$manifest_sha256" ] ||
		die "$MANIFEST_NAME of release $tag has the sha256 $hash, not the expected $manifest_sha256"
	check_manifest "$manifest"

	if [ "${#names[@]}" -eq 0 ]; then
		wanted="$(manifest_names "$manifest")" || die "cannot read $MANIFEST_NAME"
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
		hash="$(sha256_of "$dir/$name")" || die "cannot hash $name"
		[ "$hash" = "$(manifest_hash "$manifest" "$name")" ] ||
			die "hash mismatch for $name: the file does not match $MANIFEST_NAME"
	done <<<"$wanted"
	log "fetched and checked $(printf '%s' "$wanted" | grep -c . || true) files of $repo $tag"
}

# checked_set MODE [unpinned]: the check of check-set on DIR. Loads the
# configuration. With "unpinned", an empty --manifest-sha256 is allowed: the
# check then skips only the hash pin of SHA256SUMS.
checked_set() {
	local mode="$1" pin="$manifest_sha256" count present
	if [ -z "$pin" ]; then
		[ "${2:-}" = unpinned ] || die "internal error: no --manifest-sha256"
		pin=unpinned
	fi
	load_config
	load_allowed_signers
	make_verify_keyring "$work/keyring"
	[ -d "$dir" ] || die "not a directory: $dir"
	verify_manifest_dir "$dir" "$pin" "$mode"
	present="$(list_dir "$dir")"
	count="$(printf '%s\n' "$present" | grep -c .)" || count=0
	log "checked ($mode): $count files in $dir match $MANIFEST_NAME $(sha256_of "$dir/$MANIFEST_NAME")"
}

check_set() {
	if [ "$subset" = 1 ]; then checked_set subset; else checked_set exact; fi
}

# require_in_set NAME...: after checked_set subset, fails unless DIR holds each
# NAME. The manifest lists every present file with its hash.
require_in_set() {
	local name missing=""
	for name in "$@"; do
		[ -f "$dir/$name" ] || missing="$missing $name"
	done
	[ -z "$missing" ] || die "$dir lacks files that this check needs:$missing"
}

# verified_build_info: reads the checked build info in DIR. Sets info_repo,
# info_tag, info_commit, and RELEASE_VERSION.
verified_build_info() {
	local file="$dir/$BUILD_INFO_NAME"
	require_in_set "$BUILD_INFO_NAME"
	jq -e -s "$BUILD_INFO_SCHEMA_JQ" "$file" >/dev/null 2>&1 ||
		die "$BUILD_INFO_NAME is not one JSON object with exactly the fields of the build info"
	info_repo="$(jq -r .repository "$file")" || die "cannot read $BUILD_INFO_NAME"
	info_tag="$(jq -r .tag "$file")" || die "cannot read $BUILD_INFO_NAME"
	info_commit="$(jq -r .commit "$file")" || die "cannot read $BUILD_INFO_NAME"
	[[ "$info_repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "$BUILD_INFO_NAME names a repository that is not OWNER/NAME: $info_repo"
	valid_tag "$info_tag" || die "$BUILD_INFO_NAME names a tag that is not valid: $info_tag"
	valid_commit "$info_commit" || die "$BUILD_INFO_NAME names a commit that is not a full SHA: $info_commit"
	[ -z "$tag" ] || [ "$tag" = "$info_tag" ] ||
		die "--tag is $tag, but the verified $BUILD_INFO_NAME names the tag $info_tag"
	set_release_version "$info_tag"
}

# verify-macos: the Apple tools check of the verified macOS files.
verify_macos() {
	local names name
	checked_set subset unpinned
	[ "$CFG_HAS_APPLE" = 1 ] || die "the configuration $RELEASE_CONFIG has no apple section"
	verified_build_info
	names="$(apple_output_names)" || die "cannot list the Apple products"
	# shellcheck disable=SC2086 # the names have no white space
	require_in_set $names
	[ -z "$unsigned_dir" ] || [ -d "$unsigned_dir" ] || die "not a directory: $unsigned_dir"
	if [ -n "${GH_TOKEN:-}" ]; then
		fetch_file_at_commit "$info_repo" "$info_commit" "$CFG_APPLE_ENTITLEMENTS" >"$work/entitlements.plist" ||
			die "cannot read $CFG_APPLE_ENTITLEMENTS at the release commit"
	else
		log "GH_TOKEN is not set: reading $CFG_APPLE_ENTITLEMENTS at $info_commit from raw.githubusercontent.com"
		fetch_public_file_at_commit "$info_repo" "$info_commit" "$CFG_APPLE_ENTITLEMENTS" >"$work/entitlements.plist" ||
			die "cannot read $CFG_APPLE_ENTITLEMENTS at the release commit"
	fi
	[ -s "$work/entitlements.plist" ] || die "$CFG_APPLE_ENTITLEMENTS is empty at the release commit $info_commit"
	step "Checking the macOS files of $info_tag (commit $info_commit) with verify-macos.sh"
	"$SCRIPT_DIR/verify-macos.sh" --dir "$dir" --requirement "$CFG_APPLE_REQUIREMENT" \
		--notarized "$CFG_APPLE_NOTARIZE" --team-id "$CFG_APPLE_TEAM_ID" --bundle-id "$CFG_APPLE_BUNDLE_ID" \
		--version "$RELEASE_VERSION" --entitlements "$work/entitlements.plist" \
		${unsigned_dir:+--unsigned-dir "$unsigned_dir"}
}

# flatpak_cmd: the flatpak command: the signed Flatpak repository for gh-pages.
flatpak_cmd() {
	local pubkey="$work/flatpak-key.asc" primaries page
	checked_set subset
	[ "$CFG_HAS_FLATPAK" = 1 ] || die "the configuration $RELEASE_CONFIG has no flatpak section"
	[ -z "$tag" ] || verified_build_info
	require_in_set "$CFG_FLATPAK_SIGNATURES"
	[ -f "$repo_tar" ] || die "not a file: $repo_tar"
	# The public key comes from the committed signer keys, the same keys that
	# verified SHA256SUMS above.
	gpg --homedir "$VERIFY_KEYRING" --batch --no-tty --armor --export "$CFG_FLATPAK_FINGERPRINT" >"$pubkey" 2>/dev/null ||
		die "cannot export the Flatpak key $CFG_FLATPAK_FINGERPRINT"
	primaries="$(gpg --homedir "$VERIFY_KEYRING" --batch --no-tty --with-colons --list-keys "$CFG_FLATPAK_FINGERPRINT" 2>/dev/null |
		awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }')" || primaries=""
	[ -s "$pubkey" ] && [ "$primaries" = "$CFG_FLATPAK_FINGERPRINT" ] ||
		die "the signer keys in $CFG_SIGNER_KEYS_DIR hold no key $CFG_FLATPAK_FINGERPRINT (flatpak.fingerprint)"
	# The files of the Pages site, from the repository root of this run (the
	# old production job copied flatpak/index.html, flatpak/*.flatpakre*,
	# src-tauri/icons/icon.png, and README.md the same way).
	mkdir "$work/pages"
	while IFS= read -r page; do
		[ -n "$page" ] || continue
		[ -f "$REPO_ROOT/$page" ] && [ ! -L "$REPO_ROOT/$page" ] ||
			die "flatpak.pages lists $page, which is not a regular file in $REPO_ROOT"
		cp "$REPO_ROOT/$page" "$work/pages/${page##*/}" || die "cannot copy $page"
	done <<<"$CFG_FLATPAK_PAGES"
	flatpak_extra_refs_file "$work/flatpak-extra-refs"
	flatpak_expected_refs "$CFG_FLATPAK_APP_ID" "$CFG_FLATPAK_ARCH" "$CFG_FLATPAK_BRANCH" "$work/flatpak-extra-refs" \
		>"$work/flatpak-expected-refs"
	step "Building the signed Flatpak repository with flatpak-finalize.sh"
	"$SCRIPT_DIR/flatpak-finalize.sh" --repo-tar "$repo_tar" --signatures-tar "$dir/$CFG_FLATPAK_SIGNATURES" \
		--pubkey "$pubkey" --fingerprint "$CFG_FLATPAK_FINGERPRINT" --app-id "$CFG_FLATPAK_APP_ID" \
		--arch "$CFG_FLATPAK_ARCH" --branch "$CFG_FLATPAK_BRANCH" --expected-refs "$work/flatpak-expected-refs" \
		--bundle-name "$CFG_FLATPAK_BUNDLE_NAME" --templates "$work/pages" \
		--url "$CFG_FLATPAK_URL" --homepage "$CFG_FLATPAK_HOMEPAGE" --out "$out"
}

# recovery_text: what a human must do if the release is public, but its state
# is not the verified state.
recovery_text() {
	cat <<EOF

RELEASE $tag ($repo, release id $release_id) MAY BE PUBLIC WITH FILES THAT ARE NOT THE SIGNED RELEASE.
The release is immutable once it is published: nobody can make it a draft again, or change, add, or
remove its files, and its tag cannot move. A human must act now:
  1. Do not publish to any other channel. The later jobs of the finalize workflow do not run after
     this failure. Do not start them by hand.
  2. Compare the public files with the signed manifest (sha256 $manifest_sha256):
       gh api --paginate "repos/$repo/releases/$release_id/assets?per_page=100" --jq '.[] | [.id, .name, .size, .digest] | @tsv'
     Find out who changed the release (organization audit log) before you trust any file on it.
  3. If a file differs or is extra, stop the downloads: delete the release
       gh api -X DELETE repos/$repo/releases/$release_id
     The name $tag stays used. Tell the users who can have downloaded a file.
  4. Release the same code again with a new version number: build, sign, and finalize it.
  $(release_retry_hint "$tag")
EOF
}

publish() {
	local download="$work/release" hash before now after after_release problem published_commit
	load_config
	load_allowed_signers
	check_release draft

	step "Verifying the draft release again"
	# find_release read the full asset list. These are the assets that the
	# checks below cover.
	before="$(printf '%s' "$release" | jq -c .assets)" || die "cannot read the asset list of release $tag"
	download_release_assets "$repo" "$release" "$download"
	[ -f "$download/$MANIFEST_NAME" ] || die "the draft release has no $MANIFEST_NAME. The signing script has to run again."
	hash="$(sha256_of "$download/$MANIFEST_NAME")" || die "cannot hash $MANIFEST_NAME"
	[ "$hash" = "$manifest_sha256" ] ||
		die "$MANIFEST_NAME changed after the stage step: sha256 is $hash, expected $manifest_sha256"
	"$SCRIPT_DIR/verify-release.sh" --dir "$download" --repo "$repo" --tag "$tag" \
		--commit "$commit" --run-id "$run_id" --repo-root "$REPO_ROOT"
	require_assets_match_dir "$before" "$download" "the draft release $tag"

	step "Publishing release $tag"
	# The last reads before the change: the trust state, the tag, the draft,
	# and the full asset list, which must be the verified list.
	require_current_trust_state "$repo"
	require_tag_on_commit "$repo" "$tag" "$commit"
	require_draft "$repo" "$release_id" "$tag" "$commit"
	now="$(release_assets "$repo" "$release_id")"
	[ "$(asset_state "$now")" = "$(asset_state "$before")" ] ||
		die "the files of the draft release $tag changed after the check. Nothing is published. Run the finalize workflow again.
before:
$(asset_state "$before" | sed 's/^/    /')
now:
$(asset_state "$now" | sed 's/^/    /')"

	published_flip=1
	gh api -X PATCH "repos/$repo/releases/$release_id" -F draft=false >/dev/null ||
		die "cannot publish release $tag"

	after_release="$(gh api "repos/$repo/releases/$release_id")" ||
		die "RELEASE $tag MAY BE PUBLISHED, BUT IT CANNOT BE READ BACK. A human must check it now."
	after="$(release_assets "$repo" "$release_id")"
	published_commit="$(tag_commit "$repo" "$tag")" || published_commit=""
	problem="$(printf '%s' "$after_release" | jq -r --arg tag "$tag" '
		if .draft != false then "it is still a draft (draft=\(.draft))"
		elif .tag_name != $tag then "its tag is \(.tag_name)"
		else "" end')" || problem="cannot read the release"
	if [ -z "$problem" ] && [ "$published_commit" != "$commit" ]; then
		problem="the tag points to '$published_commit', not to the release commit $commit"
	fi
	if [ -z "$problem" ] && [ "$(asset_state "$after")" != "$(asset_state "$before")" ]; then
		problem="its files differ from the verified files.
verified (before the publish call):
$(asset_state "$before" | sed 's/^/    /')
public now:
$(asset_state "$after" | sed 's/^/    /')"
	fi
	[ -z "$problem" ] || die "RELEASE $tag NEEDS A HUMAN NOW: after the publish call, $problem. $(release_retry_hint "$tag")"
	published_flip=0
	log "published $repo $tag at commit $commit: $(printf '%s' "$after" | jq length) files, each with the digest of the signed manifest"
}

case "$command" in
check-set) check_set ;;
require-newest) require_newest ;;
verify-macos) verify_macos ;;
flatpak) flatpak_cmd ;;
*) "$command" ;;
esac
