#!/usr/bin/env bash
# Shared functions for the release pipeline scripts. Source this file.
#
# The scripts work with bash 3.2 (the bash of macOS) and later.
# Callers must set REPO_ROOT (a checkout that holds the release configuration)
# before they call load_config.

# Other scripts use the variables that this file sets.
# shellcheck disable=SC2034

set -euo pipefail

log() { printf '%s\n' "$*" >&2; }
step() { printf '\n==> %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

need_tools() {
	local tool missing=""
	for tool in "$@"; do
		command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
	done
	[ -z "$missing" ] || die "missing tools:$missing"
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

load_config() {
	[ -n "${REPO_ROOT:-}" ] || die "REPO_ROOT is not set"
	RELEASE_CONFIG="${RELEASE_CONFIG:-$REPO_ROOT/dev-scripts/release/config.json}"
	[ -f "$RELEASE_CONFIG" ] || die "configuration file not found: $RELEASE_CONFIG"
	jq -e . "$RELEASE_CONFIG" >/dev/null || die "configuration file is not valid JSON: $RELEASE_CONFIG"
	CFG_REPOSITORY="$(cfg .repository)"
	CFG_BUILD_WORKFLOW="$(cfg .build_workflow)"
	CFG_FINALIZE_WORKFLOW="$(cfg .finalize_workflow)"
	CFG_ARTIFACT_PATTERN="$(cfg .artifact_pattern)"
	CFG_SIGNER_KEYS_DIR="$REPO_ROOT/$(cfg .signer_keys_dir)"
	CFG_ALLOWED_SIGNERS="$REPO_ROOT/$(cfg .allowed_signers)"
	CFG_RELEASE_BRANCH="$(cfg_opt .release_branch)"
}

# cfg FILTER: prints a required configuration value.
cfg() {
	jq -er "$1" "$RELEASE_CONFIG" || die "configuration value $1 is missing in $RELEASE_CONFIG"
}

# cfg_opt FILTER: prints an optional configuration value, or nothing.
cfg_opt() {
	jq -r "$1 // empty" "$RELEASE_CONFIG"
}

# updater_target_count: number of updater target rules in the configuration.
updater_target_count() {
	jq -r '(.updater.targets // []) | length' "$RELEASE_CONFIG"
}

# updater_target_pattern INDEX / updater_target_platforms INDEX
updater_target_pattern() {
	jq -er --argjson i "$1" '.updater.targets[$i].pattern' "$RELEASE_CONFIG"
}
updater_target_platforms() {
	jq -er --argjson i "$1" '.updater.targets[$i].platforms[]' "$RELEASE_CONFIG"
}

# is_updater_asset NAME: true if NAME matches one updater target pattern.
is_updater_asset() {
	local name="$1" count i pattern
	count="$(updater_target_count)"
	i=0
	while [ "$i" -lt "$count" ]; do
		pattern="$(updater_target_pattern "$i")"
		# shellcheck disable=SC2254 # the pattern is a glob on purpose
		case "$name" in
		$pattern) return 0 ;;
		esac
		i=$((i + 1))
	done
	return 1
}

# write_updater_pubkey OUT_FILE: writes the minisign public key of the updater.
write_updater_pubkey() {
	local file filter value
	file="$REPO_ROOT/$(cfg .updater.pubkey_file)"
	filter="$(cfg .updater.pubkey_jq)"
	[ -f "$file" ] || die "updater public key file not found: $file"
	value="$(jq -er "$filter" "$file")" || die "no updater public key at $filter in $file"
	printf '%s' "$value" | base64 --decode >"$1" || die "the updater public key in $file is not valid base64"
}

# ---------------------------------------------------------------------------
# Names, directories, and manifests
# ---------------------------------------------------------------------------

MANIFEST_NAME="SHA256SUMS"
MANIFEST_SIG_NAME="SHA256SUMS.asc"
BUILD_MANIFEST_NAME="BUILD-SHA256SUMS"
BUILD_INFO_NAME="release-build-info.json"

# valid_asset_name NAME: the only characters that a release file name can use.
# The rule keeps path separators, leading dashes, and white space out of every
# command line and out of the manifest format.
valid_asset_name() {
	[[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
}

valid_tag() {
	[[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
}

valid_commit() {
	[[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

# list_dir DIR: prints the sorted names of the files in DIR, one per line.
# Fails if DIR holds anything that is not a regular file with a valid name.
list_dir() {
	local dir="$1" path name names=""
	[ -d "$dir" ] || die "not a directory: $dir"
	# The checks run outside of the pipeline, so that die stops the caller.
	for path in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
		[ -e "$path" ] || [ -L "$path" ] || continue
		name="${path##*/}"
		if [ -L "$path" ] || [ ! -f "$path" ]; then
			die "$dir: $name is not a regular file"
		fi
		valid_asset_name "$name" || die "$dir: file name is not allowed: $name"
		names="$names$name"$'\n'
	done
	[ -z "$names" ] || printf '%s' "$names" | LC_ALL=C sort
}

# check_manifest FILE: fails unless every line is "<sha256>  <name>" with a
# valid name, and no name occurs twice.
check_manifest() {
	local file="$1" line duplicates
	[ -s "$file" ] || die "manifest is missing or empty: $file"
	while IFS= read -r line || [ -n "$line" ]; do
		[[ "$line" =~ ^[0-9a-f]{64}\ \ [A-Za-z0-9][A-Za-z0-9._+-]*$ ]] ||
			die "$file: line is not '<sha256>  <name>': $line"
	done <"$file"
	duplicates="$(manifest_names "$file" | uniq -d)"
	[ -z "$duplicates" ] || die "$file: name occurs more than once: $duplicates"
}

# manifest_names FILE: prints the sorted names in a checked manifest.
manifest_names() {
	cut -c67- "$1" | LC_ALL=C sort
}

# manifest_hash FILE NAME: prints the hash of NAME, or nothing.
manifest_hash() {
	awk -v name="$2" '$2 == name { print $1 }' "$1"
}

# write_manifest DIR OUT_FILE: writes "<sha256>  <name>" for every file in DIR,
# except the manifest and its signature.
write_manifest() {
	local dir="$1" out="$2" names name hash
	names="$(list_dir "$dir")"
	: >"$out.tmp"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		case "$name" in
		"$MANIFEST_NAME" | "$MANIFEST_SIG_NAME" | "${out##*/}" | "${out##*/}.tmp") continue ;;
		esac
		hash="$(sha256_of "$dir/$name")"
		printf '%s  %s\n' "$hash" "$name" >>"$out.tmp"
	done <<EOF
$names
EOF
	mv "$out.tmp" "$out"
}

# check_files_against_manifest DIR MANIFEST IGNORED_NAMES...: fails unless the
# files in DIR are exactly the files in MANIFEST, with the same hashes.
check_files_against_manifest() {
	local dir="$1" manifest="$2" present expected name hash ignored skip
	shift 2
	present="$(list_dir "$dir")"
	for ignored in "$@"; do
		present="$(printf '%s\n' "$present" | grep -vxF -- "$ignored" || true)"
	done
	expected="$(manifest_names "$manifest")"
	skip="$(LC_ALL=C comm -23 <(printf '%s\n' "$present") <(printf '%s\n' "$expected"))"
	[ -z "$skip" ] || die "files that the manifest does not list: $(printf '%s' "$skip" | tr '\n' ' ')"
	skip="$(LC_ALL=C comm -13 <(printf '%s\n' "$present") <(printf '%s\n' "$expected"))"
	[ -z "$skip" ] || die "files that the manifest lists but that are missing: $(printf '%s' "$skip" | tr '\n' ' ')"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		hash="$(sha256_of "$dir/$name")"
		[ "$hash" = "$(manifest_hash "$manifest" "$name")" ] ||
			die "hash mismatch for $name: the file does not match the manifest"
	done <<EOF
$expected
EOF
}

# flatten_artifacts SRC DST: copies the files of every artifact directory in SRC
# into DST. SRC stays as it is. Fails on nested directories and on a name that occurs twice.
flatten_artifacts() {
	local src="$1" dst="$2" artifact names name
	mkdir -p "$dst"
	for artifact in "$src"/*; do
		[ -e "$artifact" ] || continue
		[ -d "$artifact" ] && [ ! -L "$artifact" ] || die "unexpected file outside an artifact directory: $artifact"
		names="$(list_dir "$artifact")"
		while IFS= read -r name; do
			[ -n "$name" ] || continue
			[ ! -e "$dst/$name" ] || die "two artifacts contain a file named $name"
			cp -p "$artifact/$name" "$dst/$name"
		done <<EOF
$names
EOF
	done
}

# ---------------------------------------------------------------------------
# Signature verification
# ---------------------------------------------------------------------------

# load_allowed_signers: reads the fingerprint allowlist into ALLOWED_SIGNERS.
load_allowed_signers() {
	local fingerprint
	[ -f "$CFG_ALLOWED_SIGNERS" ] || die "allowlist not found: $CFG_ALLOWED_SIGNERS"
	ALLOWED_SIGNERS="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$CFG_ALLOWED_SIGNERS" | tr 'a-f' 'A-F' | grep -v '^$' || true)"
	[ -n "$ALLOWED_SIGNERS" ] || die "the allowlist holds no fingerprint: $CFG_ALLOWED_SIGNERS"
	while IFS= read -r fingerprint; do
		[[ "$fingerprint" =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]] ||
			die "$CFG_ALLOWED_SIGNERS: not a full key fingerprint: $fingerprint"
	done <<EOF
$ALLOWED_SIGNERS
EOF
}

is_allowed_signer() {
	printf '%s\n' "$ALLOWED_SIGNERS" | grep -qxF -- "$1"
}

# make_verify_keyring DIR: fills the new keyring DIR with the committed signer
# keys only. Verification never uses the keyring of the user.
make_verify_keyring() {
	local home="$1" key found=0
	mkdir -p "$home"
	chmod 700 "$home"
	for key in "$CFG_SIGNER_KEYS_DIR"/*.asc; do
		[ -f "$key" ] || continue
		found=1
		gpg --homedir "$home" --batch --no-tty --quiet --import "$key" 2>/dev/null ||
			die "cannot import signer key $key"
	done
	[ "$found" = 1 ] || die "no signer key files (*.asc) in $CFG_SIGNER_KEYS_DIR"
	VERIFY_KEYRING="$home"
}

# verify_detached SIGNATURE FILE: succeeds only if SIGNATURE is exactly one good
# detached signature on FILE from a key on the allowlist. An expired key, a
# revoked key, and a second signature all fail.
verify_detached() {
	local sig="$1" file="$2" status rc=0 good valid bad class primary
	[ -f "$sig" ] || {
		log "signature file is missing: ${sig##*/}"
		return 1
	}
	status="$(gpg --homedir "$VERIFY_KEYRING" --batch --no-tty --trust-model always \
		--status-fd 1 --verify "$sig" "$file" 2>/dev/null)" || rc=$?
	good="$(printf '%s\n' "$status" | grep -c '^\[GNUPG:\] GOODSIG ' || true)"
	valid="$(printf '%s\n' "$status" | grep -c '^\[GNUPG:\] VALIDSIG ' || true)"
	bad="$(printf '%s\n' "$status" | grep -cE '^\[GNUPG:\] (BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG|NO_PUBKEY) ' || true)"
	if [ "$rc" != 0 ] || [ "$good" != 1 ] || [ "$valid" != 1 ] || [ "$bad" != 0 ]; then
		log "no single good signature in ${sig##*/} for ${file##*/}"
		return 1
	fi
	class="$(printf '%s\n' "$status" | awk '/^\[GNUPG:\] VALIDSIG /{ print $11 }')"
	primary="$(printf '%s\n' "$status" | awk '/^\[GNUPG:\] VALIDSIG /{ print $NF }')"
	if [ "$class" != "00" ]; then
		log "${sig##*/} is not a signature on a binary document"
		return 1
	fi
	if ! is_allowed_signer "$primary"; then
		log "${sig##*/} is signed by $primary, which is not an allowed signer"
		return 1
	fi
	return 0
}

# verify_updater_sig PUBKEY_FILE SIG_FILE FILE: checks a Tauri updater
# signature. SIG_FILE holds a base64-encoded minisign signature.
verify_updater_sig() {
	local pubkey="$1" sig="$2" file="$3" decoded rc=0
	decoded="$(mktemp)"
	if ! base64 --decode <"$sig" >"$decoded" 2>/dev/null; then
		rm -f "$decoded"
		return 1
	fi
	minisign -V -q -p "$pubkey" -x "$decoded" -m "$file" >/dev/null 2>&1 || rc=$?
	rm -f "$decoded"
	return "$rc"
}

# ---------------------------------------------------------------------------
# GitHub
# ---------------------------------------------------------------------------

# find_release REPO TAG: prints the JSON of the one release with this tag.
# Draft releases are included. GitHub allows several drafts with one tag, so
# more than one match is an error.
find_release() {
	local repo="$1" tag="$2" matches count
	matches="$(gh api --paginate "repos/$repo/releases?per_page=100" |
		jq -c --arg tag "$tag" '.[] | select(.tag_name == $tag)')" ||
		die "cannot list the releases of $repo"
	count="$(printf '%s' "$matches" | grep -c . || true)"
	[ "$count" != 0 ] || die "no release with tag $tag in $repo (a draft is visible only with write access)"
	[ "$count" = 1 ] || die "$count releases use the tag $tag in $repo. Keep exactly one."
	printf '%s\n' "$matches"
}

# default_branch REPO
default_branch() {
	gh api "repos/$1" --jq .default_branch
}

# require_commit_on_branch REPO COMMIT BRANCH: fails unless COMMIT is BRANCH's
# head or one of its ancestors.
require_commit_on_branch() {
	local repo="$1" commit="$2" branch="$3" status
	status="$(gh api "repos/$repo/compare/$branch...$commit" --jq .status)" ||
		die "cannot compare $commit with $branch in $repo"
	case "$status" in
	identical | behind) ;;
	*) die "commit $commit is not on the branch $branch (compare status: $status)" ;;
	esac
}

# tag_commit REPO TAG: prints the commit that the git tag points to, or nothing
# if the tag does not exist yet.
tag_commit() {
	local repo="$1" tag="$2" ref type sha
	ref="$(gh api "repos/$repo/git/matching-refs/tags/$tag" |
		jq -c --arg ref "refs/tags/$tag" '.[] | select(.ref == $ref) | .object')" ||
		die "cannot read the tags of $repo"
	[ -n "$ref" ] || return 0
	type="$(printf '%s' "$ref" | jq -r .type)"
	sha="$(printf '%s' "$ref" | jq -r .sha)"
	while [ "$type" = "tag" ]; do
		ref="$(gh api "repos/$repo/git/tags/$sha" --jq .object)" || die "cannot read tag object $sha"
		type="$(printf '%s' "$ref" | jq -r .type)"
		sha="$(printf '%s' "$ref" | jq -r .sha)"
	done
	[ "$type" = "commit" ] || die "tag $tag points to a $type, not to a commit"
	printf '%s\n' "$sha"
}

# require_tag_matches REPO TAG COMMIT: a published release uses an existing git
# tag as it is. So an existing tag must already point to the release commit.
require_tag_matches() {
	local existing
	existing="$(tag_commit "$1" "$2")"
	if [ -n "$existing" ] && [ "$existing" != "$3" ]; then
		die "git tag $2 exists and points to $existing, not to the release commit $3"
	fi
}

# require_build_run REPO RUN_ID COMMIT: fails unless RUN_ID is a successful run
# of the build workflow, in this repository, for this commit.
require_build_run() {
	local repo="$1" run_id="$2" commit="$3" run problem
	run="$(gh api "repos/$repo/actions/runs/$run_id")" || die "cannot read workflow run $run_id of $repo"
	problem="$(printf '%s' "$run" | jq -r \
		--arg repo "$repo" --arg commit "$commit" --arg path ".github/workflows/$CFG_BUILD_WORKFLOW" '
		if .repository.full_name != $repo then "it belongs to \(.repository.full_name)"
		elif .head_repository.full_name != $repo then "its code comes from \(.head_repository.full_name)"
		elif (.path | split("@")[0]) != $path then "it is a run of \(.path)"
		elif .head_sha != $commit then "it built commit \(.head_sha), but the release is for \($commit)"
		elif .status != "completed" or .conclusion != "success" then "its result is \(.status)/\(.conclusion)"
		else "" end')"
	[ -z "$problem" ] || die "workflow run $run_id is not the build of this release: $problem"
}

# download_build_artifacts REPO RUN_ID DST: downloads the release artifacts of a
# build run and puts all files into DST.
download_build_artifacts() {
	local repo="$1" run_id="$2" dst="$3" raw
	raw="$(mktemp -d)"
	gh run download "$run_id" --repo "$repo" --dir "$raw" --pattern "$CFG_ARTIFACT_PATTERN" ||
		die "cannot download the artifacts of run $run_id"
	flatten_artifacts "$raw" "$dst"
	rm -rf "$raw"
}

# check_build_info FILE REPO TAG COMMIT RUN_ID: the build info file ties the
# files to one repository, tag, commit, and build run.
check_build_info() {
	local file="$1" problem
	[ -f "$file" ] || die "$BUILD_INFO_NAME is missing"
	problem="$(jq -r --arg repo "$2" --arg tag "$3" --arg commit "$4" --arg run "$5" '
		if .repository != $repo then "repository is \(.repository)"
		elif .tag != $tag then "tag is \(.tag)"
		elif .commit != $commit then "commit is \(.commit)"
		elif (.run_id | tostring) != $run then "build run is \(.run_id)"
		else "" end' "$file")" || die "$BUILD_INFO_NAME is not valid JSON"
	[ -z "$problem" ] || die "$BUILD_INFO_NAME does not match this release: $problem"
}

# download_release_assets REPO RELEASE_JSON DST [NAME...]: downloads assets of
# a release into DST, by asset id. RELEASE_JSON is the output of find_release.
# With no NAME, it downloads all assets.
download_release_assets() {
	local repo="$1" release="$2" dst="$3" assets wanted id name
	shift 3
	assets="$(printf '%s' "$release" | jq -r '.assets[] | "\(.id) \(.name)"')" ||
		die "cannot read the asset list of the release"
	while IFS=' ' read -r id name; do
		[ -n "$id" ] || continue
		[[ "$id" =~ ^[0-9]+$ ]] || die "the release has an asset with a bad id: $id"
		valid_asset_name "$name" || die "the release has an asset with a name that is not allowed: $name"
	done <<EOF2
$assets
EOF2
	wanted=""
	if [ $# -eq 0 ]; then
		wanted="$(printf '%s\n' "$assets" | cut -s -d' ' -f2)"
	else
		for name in "$@"; do
			valid_asset_name "$name" || die "asset name is not allowed: $name"
			wanted="$wanted$name"$'\n'
		done
	fi
	mkdir -p "$dst"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		id="$(printf '%s\n' "$assets" | awk -v name="$name" '$2 == name { print $1 }')"
		[ -n "$id" ] || die "the release has no asset named $name"
		gh api -H "Accept: application/octet-stream" "repos/$repo/releases/assets/$id" >"$dst/$name" </dev/null ||
			die "cannot download the asset $name"
	done <<EOF2
$wanted
EOF2
}

# ---------------------------------------------------------------------------
# Local signing setup
# ---------------------------------------------------------------------------

# find_tauri_cli: sets the array TAURI_CLI to the command that runs the Tauri
# CLI: RELEASE_TAURI_CLI, else cargo-tauri, else "cargo tauri".
find_tauri_cli() {
	if [ -n "${RELEASE_TAURI_CLI:-}" ]; then
		read -r -a TAURI_CLI <<<"$RELEASE_TAURI_CLI"
	elif command -v cargo-tauri >/dev/null 2>&1; then
		TAURI_CLI=(cargo-tauri)
	elif cargo tauri --version >/dev/null 2>&1; then
		TAURI_CLI=(cargo tauri)
	else
		die "the Tauri CLI is missing. Install cargo-tauri, or set RELEASE_TAURI_CLI."
	fi
}

# select_signing_key: sets SIGNING_KEY to the primary fingerprint of the PGP
# key to sign with: RELEASE_SIGNING_KEY, or the one local secret key that the
# allowlist names. Call load_allowed_signers first.
select_signing_key() {
	local secret_keys
	if [ -n "${RELEASE_SIGNING_KEY:-}" ]; then
		SIGNING_KEY="$(gpg --batch --list-secret-keys --with-colons "$RELEASE_SIGNING_KEY" 2>/dev/null |
			awk -F: '$1 == "fpr" { print $10; exit }')" || true
		[ -n "$SIGNING_KEY" ] || die "no secret key for RELEASE_SIGNING_KEY=$RELEASE_SIGNING_KEY"
	else
		secret_keys="$(gpg --batch --list-secret-keys --with-colons 2>/dev/null |
			awk -F: '$1 == "sec" { want = 1 } $1 == "fpr" && want { print $10; want = 0 }')" || true
		SIGNING_KEY="$(LC_ALL=C comm -12 <(printf '%s\n' "$secret_keys" | LC_ALL=C sort) <(printf '%s\n' "$ALLOWED_SIGNERS" | LC_ALL=C sort))"
		[ -n "$SIGNING_KEY" ] || die "none of your secret keys is on the allowlist ($CFG_ALLOWED_SIGNERS)"
		[ "$(printf '%s\n' "$SIGNING_KEY" | wc -l | tr -d ' ')" = 1 ] ||
			die "several of your secret keys are on the allowlist. Set RELEASE_SIGNING_KEY."
	fi
	is_allowed_signer "$SIGNING_KEY" || die "your key $SIGNING_KEY is not on the allowlist ($CFG_ALLOWED_SIGNERS)"
}

# secrets_file_path REPO: prints the path of the encrypted secrets file.
secrets_file_path() {
	printf '%s\n' "${RELEASE_SECRETS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/release-signing/${1/\//__}.json.gpg}"
}
