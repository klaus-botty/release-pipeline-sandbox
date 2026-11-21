#!/usr/bin/env bash
# Shared functions for the release pipeline scripts. Source this file.
#
# The scripts work with bash 3.2 (the bash of macOS) and later.
# Callers must set REPO_ROOT (a checkout that holds the release configuration)
# before they call load_config.
#
# Error handling: a function that fails calls die, or returns non-zero and
# logs the cause. Command substitutions do not inherit "set -e" in bash 3.2,
# so the functions check every command whose failure matters explicitly, and
# callers always assign "$(...)" to a variable before they use it.

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

# sha256_of FILE: prints the lowercase sha256 of FILE. Fails if it cannot.
sha256_of() {
	local out
	if command -v sha256sum >/dev/null 2>&1; then
		out="$(sha256sum "$1")" || return 1
	else
		out="$(shasum -a 256 "$1")" || return 1
	fi
	out="${out%% *}"
	[[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1
	printf '%s\n' "$out"
}

# size_of FILE: prints the size of FILE in bytes.
size_of() {
	local out
	out="$(wc -c <"$1")" || return 1
	out="$(printf '%s' "$out" | tr -d ' ')"
	[[ "$out" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$out"
}

# name_in_list NAME LIST: true if the newline-separated LIST holds NAME as a
# whole line. Pure shell, so it has no failure that a caller can miss.
name_in_list() {
	case $'\n'"$2"$'\n' in
	*$'\n'"$1"$'\n'*) return 0 ;;
	esac
	return 1
}

# ---------------------------------------------------------------------------
# Configuration
#
# config.json:
#   repository           OWNER/NAME
#   build_workflow       file name of the build workflow (step 1)
#   build_event          the event that starts the build workflow
#   finalize_workflow    file name of the finalize workflow (step 3)
#   artifact_pattern     glob: the build artifacts that the signer downloads
#   ci_artifact_pattern  glob: the build artifacts that only CI uses
#   signer_keys_dir      directory of the signer public keys (*.asc)
#   allowed_signers      file with the allowed primary key fingerprints
#   release_branch       optional, default: the default branch
#   updater              pubkey_file, pubkey_jq, version_file, version_jq
#   products             the exact list of files, see below
#
# Each product is {"name": ..., "origin": ..., "updater": [platform, ...]}.
# "{version}" in a name is the release version. "updater" is optional.
#   build   CI output. The signer downloads it. It is released unchanged.
#   input   CI output. The signer downloads it, and a local step consumes it.
#           It is never released.
#   ci      CI output in an artifact that matches ci_artifact_pattern. The
#           signer does not download it. It is never released.
#   local   The signer makes it. It is released.
# The pipeline adds these files itself: release-build-info.json, one .asc per
# released file, one .sig per product with updater platforms, latest.json if
# some product has updater platforms, SHA256SUMS, and SHA256SUMS.asc.
# ---------------------------------------------------------------------------

load_config() {
	[ -n "${REPO_ROOT:-}" ] || die "REPO_ROOT is not set"
	RELEASE_CONFIG="${RELEASE_CONFIG:-$REPO_ROOT/dev-scripts/release/config.json}"
	[ -f "$RELEASE_CONFIG" ] || die "configuration file not found: $RELEASE_CONFIG"
	validate_config
	CFG_REPOSITORY="$(cfg .repository)"
	CFG_BUILD_WORKFLOW="$(cfg .build_workflow)"
	CFG_BUILD_EVENT="$(cfg .build_event)"
	CFG_FINALIZE_WORKFLOW="$(cfg .finalize_workflow)"
	CFG_ARTIFACT_PATTERN="$(cfg .artifact_pattern)"
	CFG_CI_ARTIFACT_PATTERN="$(cfg .ci_artifact_pattern)"
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
	jq -r "$1 // empty" "$RELEASE_CONFIG" || die "cannot read $1 in $RELEASE_CONFIG"
}

# The structure check of the configuration. It prints one line per problem.
# shellcheck disable=SC2016 # a jq program, not shell
CONFIG_SCHEMA_JQ='
def nonempty_string: type == "string" and length > 0;
def need($k): if (.[$k] | nonempty_string) then empty else "\($k) must be a nonempty string" end;
if type != "object" then "the configuration is not a JSON object" else
	(["repository", "build_workflow", "build_event", "finalize_workflow", "artifact_pattern",
	  "ci_artifact_pattern", "signer_keys_dir", "allowed_signers"][] as $k | need($k)),
	(if has("release_branch") then need("release_branch") else empty end),
	(if (.repository | nonempty_string) and (.repository | test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$") | not)
	 then "repository is not OWNER/NAME: \(.repository)" else empty end),
	(if .artifact_pattern == .ci_artifact_pattern then "artifact_pattern and ci_artifact_pattern must differ" else empty end),
	(if (.updater | type) == "object" and (.updater | has("targets"))
	 then "updater.targets is no longer used. List every release file in products, with its updater platforms."
	 else empty end),
	(if (.products | type) != "array" or (.products | length) == 0 then "products must be a nonempty list"
	 else
		(.products | to_entries[] | .key as $i | .value |
			if type != "object" then "products[\($i)] is not an object"
			else
				((keys - ["name", "origin", "updater"])[] | "products[\($i)] has an unknown key: \(.)"),
				(if (.name | nonempty_string) then empty else "products[\($i)].name must be a nonempty string" end),
				(if (.origin | type) == "string" and (.origin as $o | ["build", "input", "ci", "local"] | any(. == $o)) then empty
				 else "products[\($i)].origin must be build, input, ci, or local" end),
				(if has("updater") | not then empty
				 elif (.updater | type) != "array" or (.updater | length) == 0
					or (.updater | any(type != "string" or (test("^[a-z0-9][a-z0-9_-]*$") | not)))
				 then "products[\($i)].updater must be a nonempty list of platform names ([a-z0-9_-])"
				 elif .origin == "input" or .origin == "ci"
				 then "products[\($i)] has the origin \(.origin). It is never released, so it cannot have updater platforms."
				 else empty end)
			end)
	 end),
	(if [.products[]? | objects | select(has("updater"))] | length == 0 then empty
	 elif (.updater | type) != "object" then "updater must be an object, because some products have updater platforms"
	 else .updater | (["pubkey_file", "pubkey_jq", "version_file", "version_jq"][] as $k |
		if (.[$k] | nonempty_string) then empty else "updater.\($k) must be a nonempty string" end)
	 end)
end'

# validate_config: checks the whole configuration once, and sets CFG_PRODUCTS
# to one line per product: "<origin> <name template> [<platform>...]".
validate_config() {
	local problems products origin name platforms platform names="" all_platforms="" sample
	problems="$(jq -r "$CONFIG_SCHEMA_JQ" "$RELEASE_CONFIG")" ||
		die "configuration file is not valid JSON: $RELEASE_CONFIG"
	[ -z "$problems" ] || die "the configuration $RELEASE_CONFIG has problems:
$(printf '%s\n' "$problems" | sed 's/^/    /')"
	products="$(jq -r '.products[] | [.origin, .name] + (.updater // []) | join(" ")' "$RELEASE_CONFIG")" ||
		die "cannot read the products of $RELEASE_CONFIG"
	problems=""
	while read -r origin name platforms; do
		[ -n "$origin" ] || continue
		# "{version}" is the only placeholder.
		sample="${name//\{version\}/1.2.3}"
		case "$sample" in
		*"{"* | *"}"*)
			problems="$problems"$'\n'"$name: {version} is the only placeholder"
			continue
			;;
		esac
		if ! valid_asset_name "$sample"; then
			problems="$problems"$'\n'"$name: not a valid release file name (letters, digits, . _ + -; no leading - or ., no trailing .)"
		elif is_reserved_name "$sample"; then
			problems="$problems"$'\n'"$name: the pipeline reserves this name (SHA256SUMS*, BUILD-SHA256SUMS*, latest.json*, $BUILD_INFO_NAME, *.asc, *.sig, *.minisig, *.tmp)"
		fi
		case "$origin $sample" in
		"build "*.unsigned.* | "local "*.unsigned.*)
			problems="$problems"$'\n'"$name: a released file cannot have .unsigned. in its name"
			;;
		esac
		if name_in_list "$name" "$names"; then
			problems="$problems"$'\n'"$name: the name occurs more than once"
		fi
		names="$names$name"$'\n'
		for platform in $platforms; do
			if name_in_list "$platform" "$all_platforms"; then
				problems="$problems"$'\n'"$name: the updater platform $platform belongs to more than one product"
			fi
			all_platforms="$all_platforms$platform"$'\n'
		done
	done <<EOF
$products
EOF
	[ -z "$problems" ] || die "the products in $RELEASE_CONFIG have problems:$(printf '%s' "$problems" | sed 's/^/    /')"
	CFG_PRODUCTS="$products"
}

# expand_product_name TEMPLATE: the name with the release version.
expand_product_name() {
	case "$1" in
	*"{version}"*)
		[ -n "${RELEASE_VERSION:-}" ] || die "internal error: the release version is not set (call set_release_version)"
		printf '%s\n' "${1//\{version\}/$RELEASE_VERSION}"
		;;
	*) printf '%s\n' "$1" ;;
	esac
}

# product_names ORIGIN...: the names of the products with these origins, one
# per line, in the order of the configuration.
product_names() {
	local origin name platforms want
	while read -r origin name platforms; do
		[ -n "$origin" ] || continue
		for want in "$@"; do
			[ "$origin" = "$want" ] || continue
			name="$(expand_product_name "$name")" || return 1
			printf '%s\n' "$name"
		done
	done <<EOF
$CFG_PRODUCTS
EOF
}

# product_origin NAME: the origin of the product NAME, or nothing.
product_origin() {
	local origin name platforms expanded
	while read -r origin name platforms; do
		[ -n "$origin" ] || continue
		expanded="$(expand_product_name "$name")" || return 1
		if [ "$expanded" = "$1" ]; then
			printf '%s\n' "$origin"
			return 0
		fi
	done <<EOF
$CFG_PRODUCTS
EOF
}

# updater_product_names: the names of the products with updater platforms.
updater_product_names() {
	local origin name platforms
	while read -r origin name platforms; do
		[ -n "$platforms" ] || continue
		name="$(expand_product_name "$name")" || return 1
		printf '%s\n' "$name"
	done <<EOF
$CFG_PRODUCTS
EOF
}

# product_updater_platforms NAME: the updater platforms of the product NAME,
# one per line. Prints nothing for a product without updater platforms.
product_updater_platforms() {
	local origin name platforms expanded platform
	while read -r origin name platforms; do
		[ -n "$origin" ] || continue
		expanded="$(expand_product_name "$name")" || return 1
		[ "$expanded" = "$1" ] || continue
		for platform in $platforms; do
			printf '%s\n' "$platform"
		done
		return 0
	done <<EOF
$CFG_PRODUCTS
EOF
}

# uses_updater: true if some product has updater platforms. Without them, the
# scripts make no updater signatures and no latest.json.
uses_updater() {
	local origin name platforms
	while read -r origin name platforms; do
		[ -z "$platforms" ] || return 0
	done <<EOF
$CFG_PRODUCTS
EOF
	return 1
}

# needs_release_version: true if the scripts need the release version: for
# updater signatures, or for a product name with {version}.
needs_release_version() {
	uses_updater && return 0
	case "$CFG_PRODUCTS" in
	*"{version}"*) return 0 ;;
	esac
	return 1
}

# Compatibility with the updater.targets interface of earlier versions: index
# I counts the products with updater platforms. The "pattern" is the exact
# name, or the name with "*" for {version} before set_release_version.
updater_target_count() {
	local origin name platforms count=0
	while read -r origin name platforms; do
		[ -z "$platforms" ] || count=$((count + 1))
	done <<EOF
$CFG_PRODUCTS
EOF
	printf '%s\n' "$count"
}
updater_target_line() {
	local origin name platforms i=0
	while read -r origin name platforms; do
		[ -n "$platforms" ] || continue
		if [ "$i" = "$1" ]; then
			printf '%s %s\n' "$name" "$platforms"
			return 0
		fi
		i=$((i + 1))
	done <<EOF
$CFG_PRODUCTS
EOF
	die "no updater product with index $1"
}
updater_target_pattern() {
	local line name
	line="$(updater_target_line "$1")" || return 1
	name="${line%% *}"
	if [ -n "${RELEASE_VERSION:-}" ]; then
		expand_product_name "$name"
	else
		printf '%s\n' "${name//\{version\}/*}"
	fi
}
updater_target_platforms() {
	local line platform
	line="$(updater_target_line "$1")" || return 1
	for platform in ${line#* }; do
		printf '%s\n' "$platform"
	done
}
# is_updater_asset NAME: true if NAME is a product with updater platforms.
is_updater_asset() {
	local names
	names="$(updater_product_names)" || die "cannot list the updater products"
	name_in_list "$1" "$names"
}

# released_names: the files that get a detached PGP signature: the build and
# local products, the build info, and latest.json if the updater is used.
released_names() {
	local names
	names="$(product_names build local)" || return 1
	[ -z "$names" ] || printf '%s\n' "$names"
	printf '%s\n' "$BUILD_INFO_NAME"
	if uses_updater; then
		printf 'latest.json\n'
	fi
}

# expected_names KIND: the exact set of names that one stage holds.
#   build-output     the build output: build + input + ci products
#   signer-download  the release artifacts: build + input + build info
#   build-manifest   BUILD-SHA256SUMS: build + input + ci + build info
#   before-signing   the signer after its local steps: build + local + build info
#   release-files    the release without SHA256SUMS and SHA256SUMS.asc
#   release          the complete release
expected_names() {
	local released updater name
	case "$1" in
	build-output) product_names build input ci ;;
	before-signing)
		product_names build local || return 1
		printf '%s\n' "$BUILD_INFO_NAME"
		;;
	signer-download | build-manifest)
		if [ "$1" = signer-download ]; then
			product_names build input || return 1
		else
			product_names build input ci || return 1
		fi
		printf '%s\n' "$BUILD_INFO_NAME"
		;;
	release-files | release)
		released="$(released_names)" || return 1
		updater="$(updater_product_names)" || return 1
		printf '%s\n' "$released"
		while IFS= read -r name; do
			[ -z "$name" ] || printf '%s.asc\n' "$name"
		done <<<"$released"
		while IFS= read -r name; do
			[ -z "$name" ] || printf '%s.sig\n' "$name"
		done <<<"$updater"
		if [ "$1" = release ]; then
			printf '%s\n%s\n' "$MANIFEST_NAME" "$MANIFEST_SIG_NAME"
		fi
		;;
	*) die "internal error: unknown name set $1" ;;
	esac
}

# require_product_set KIND WHERE NAMES: fails unless the newline-separated
# NAMES are exactly the names of expected_names KIND, each one time. The error
# lists every missing, unexpected, and duplicate name. WHERE says what NAMES
# describe, for the message.
require_product_set() {
	local kind="$1" where="$2" actual="$3" expected name origin seen="" problems="" dups=""
	expected="$(expected_names "$kind")" || die "cannot compute the expected file names ($kind)"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		if name_in_list "$name" "$seen"; then
			name_in_list "$name" "$dups" || problems="$problems"$'\n'"    duplicate: $name"
			dups="$dups$name"$'\n'
			continue
		fi
		seen="$seen$name"$'\n'
		name_in_list "$name" "$expected" && continue
		origin="$(product_origin "$name")" || die "cannot read the origin of $name"
		case "$kind:$origin:$name" in
		release*:input:* | release*:ci:*) problems="$problems"$'\n'"    not expected: $name (a product with origin $origin, never released)" ;;
		release*:*:*.unsigned.* | before-signing:*:*.unsigned.*) problems="$problems"$'\n'"    not expected: $name (an unsigned file, never released)" ;;
		before-signing:input:* | before-signing:ci:*) problems="$problems"$'\n'"    not expected: $name (a product with origin $origin, never released)" ;;
		build-output:local:* | signer-download:local:* | build-manifest:local:*)
			problems="$problems"$'\n'"    not expected: $name (a product with origin local: the signer makes it)"
			;;
		signer-download:ci:*)
			problems="$problems"$'\n'"    not expected: $name (a product with origin ci belongs in an artifact that matches $CFG_CI_ARTIFACT_PATTERN)"
			;;
		*) problems="$problems"$'\n'"    not expected: $name" ;;
		esac
	done <<<"$actual"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		name_in_list "$name" "$seen" || problems="$problems"$'\n'"    missing: $name"
	done <<<"$expected"
	[ -z "$problems" ] || die "$where does not hold exactly the files that the products in $RELEASE_CONFIG require ($kind):$problems"
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
# Release version
# ---------------------------------------------------------------------------

# Semantic version 2.0.0, without a leading "v".
SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

# set_release_version TAG: sets RELEASE_VERSION to the version of the release:
# TAG without one leading "v". Fails unless the rest is a semantic version.
# The updater signatures, latest.json, the product names, and every check use
# this one value.
set_release_version() {
	local version="${1#v}"
	[[ "$version" =~ $SEMVER_RE ]] ||
		die "tag $1 does not name a release version: '$version' is not a semantic version (expected v1.2.3 or 1.2.3)"
	RELEASE_VERSION="$version"
}

# valid_repo_path PATH: a relative path inside the repository, without "..".
valid_repo_path() {
	[[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] || return 1
	case "/$1/" in
	*/../* | */./* | *//*) return 1 ;;
	esac
}

# fetch_file_at_commit REPO COMMIT PATH: prints the file PATH as it is at
# COMMIT, read through the GitHub API, not from the local checkout. Redirect
# the output to a file for binary content.
fetch_file_at_commit() {
	local repo="$1" commit="$2" path="$3"
	valid_commit "$commit" || die "not a full commit SHA: $commit"
	valid_repo_path "$path" || die "not a plain relative repository path: $path"
	gh api -H "Accept: application/vnd.github.raw+json" "repos/$repo/contents/$path?ref=$commit" </dev/null ||
		die "cannot read $path at commit $commit from $repo"
}

# require_app_version REPO COMMIT VERSION: fails unless the app configuration
# of the release commit holds VERSION.
require_app_version() {
	local repo="$1" commit="$2" version="$3" path filter content app_version
	path="$(cfg .updater.version_file)"
	filter="$(cfg .updater.version_jq)"
	content="$(fetch_file_at_commit "$repo" "$commit" "$path")" || die "cannot read $path at commit $commit"
	app_version="$(printf '%s' "$content" | jq -er "$filter")" ||
		die "$path at commit $commit has no app version at $filter"
	[ "$app_version" = "$version" ] ||
		die "the app version in $path at commit $commit is $app_version, but the release version is $version. Set the version in the app and tag that commit."
}

# require_updater_pubkey_at_commit REPO COMMIT: fails unless the app
# configuration of the release commit holds the same updater public key as the
# checkout. The release must be signed for the key that the released app trusts.
require_updater_pubkey_at_commit() {
	local repo="$1" commit="$2" path filter content here there
	path="$(cfg .updater.pubkey_file)"
	filter="$(cfg .updater.pubkey_jq)"
	here="$(jq -er "$filter" "$REPO_ROOT/$path")" || die "no updater public key at $filter in $REPO_ROOT/$path"
	content="$(fetch_file_at_commit "$repo" "$commit" "$path")" || die "cannot read $path at commit $commit"
	there="$(printf '%s' "$content" | jq -er "$filter")" ||
		die "$path at commit $commit has no updater public key at $filter"
	[ "$here" = "$there" ] ||
		die "the updater public key in $path at the release commit $commit differs from the key in this checkout ($REPO_ROOT). The released app would reject these updater signatures, or this checkout trusts another key. Key at $commit: $there. Key here: $here."
}

# ---------------------------------------------------------------------------
# Updater signatures
#
# A Tauri updater key, public key, and .sig file are standard minisign files,
# encoded with base64 one more time. The trusted comment is the one that the
# Tauri CLI writes with --app-version:
#   timestamp:<unix seconds><TAB>file:<file name><TAB>version:<version>
# ---------------------------------------------------------------------------

UPDATER_UNTRUSTED_COMMENT="signature from tauri secret key"

# updater_sign KEY PASSWORD FILE VERSION: writes FILE.sig. KEY is the
# base64-encoded updater private key. The key reaches minisign through a pipe,
# and the password through stdin, so neither reaches the disk or a command line.
updater_sign() {
	local key="$1" password="$2" file="$3" version="$4" name comment raw out rc=0
	name="${file##*/}"
	raw="$file.sig.minisig"
	for out in "$file.sig" "$raw"; do
		[ ! -e "$out" ] && [ ! -L "$out" ] || die "$out exists already"
	done
	comment="timestamp:$(date +%s)"$'\t'"file:$name"$'\t'"version:$version"
	out="$(printf '%s\n' "$password" | minisign -S -s <(printf '%s' "$key" | base64 --decode) \
		-m "$file" -x "$raw" -t "$comment" -c "$UPDATER_UNTRUSTED_COMMENT" 2>&1)" || rc=$?
	if [ "$rc" != 0 ]; then
		rm -f "$raw"
		log "minisign cannot sign $name: $(printf '%s' "$out" | tr '\n' ' ')"
		return 1
	fi
	# Callers use "updater_sign ... || die", which turns off "set -e" here. So
	# every step checks its own result.
	if ! base64 <"$raw" | tr -d '\n' >"$file.sig"; then
		rm -f "$raw" "$file.sig"
		log "cannot write $name.sig"
		return 1
	fi
	rm -f "$raw"
}

# updater_sig_comment PUBKEY_FILE SIG_FILE FILE: prints the trusted comment of
# an updater signature. minisign prints it only after it verified the signature
# of FILE and the global signature that covers the trusted comment. The comment
# is never read from the file directly. Logs the cause and fails otherwise.
updater_sig_comment() {
	local pubkey="$1" sig="$2" file="$3" out rc=0
	if ! base64 --decode <"$sig" >/dev/null 2>&1; then
		log "${sig##*/} is not valid base64"
		return 1
	fi
	out="$(minisign -V -Q -p "$pubkey" -x <(base64 --decode <"$sig") -m "$file" 2>&1)" || rc=$?
	if [ "$rc" != 0 ]; then
		# With -Q, minisign prints no cause. Ask again without -Q, for the message only.
		out="$(minisign -V -p "$pubkey" -x <(base64 --decode <"$sig") -m "$file" 2>&1)" || true
		log "${sig##*/}: minisign rejects it for ${file##*/} with the updater public key of the app: $(printf '%s' "$out" | tr '\n' ' ')"
		return 1
	fi
	case "$out" in
	*$'\n'*)
		log "${sig##*/}: minisign printed more than one line: $(printf '%q' "$out")"
		return 1
		;;
	esac
	printf '%s\n' "$out"
}

# check_updater_comment SIG_NAME COMMENT FILE_NAME VERSION: fails unless the
# verified trusted COMMENT has exactly the fields timestamp, file, and version,
# in this order, for FILE_NAME and VERSION.
check_updater_comment() {
	local sig="$1" comment="$2" name="$3" version="$4"
	local re=$'^timestamp:([0-9]+)\tfile:([^\t]*)\tversion:([^\t]*)$'
	if ! [[ "$comment" =~ $re ]]; then
		case "$comment" in
		*$'\t'version:*) ;;
		*) die "$sig: the trusted comment has no version field (was it signed without the app version?): $(printf '%q' "$comment")" ;;
		esac
		die "$sig: the trusted comment is not 'timestamp:<digits><TAB>file:<name><TAB>version:<version>': $(printf '%q' "$comment")"
	fi
	[ "${BASH_REMATCH[2]}" = "$name" ] ||
		die "$sig: the trusted comment names the file $(printf '%q' "${BASH_REMATCH[2]}"), not $name"
	[ "${BASH_REMATCH[3]}" = "$version" ] ||
		die "$sig: the trusted comment names the version $(printf '%q' "${BASH_REMATCH[3]}"), but the release version is $version"
}

# verify_updater_sig PUBKEY_FILE SIG_FILE FILE VERSION: fails unless SIG_FILE
# is a good updater signature of FILE for VERSION.
verify_updater_sig() {
	local pubkey="$1" sig="$2" file="$3" version="$4" comment
	comment="$(updater_sig_comment "$pubkey" "$sig" "$file")" ||
		die "the updater signature ${sig##*/} of ${file##*/} is not valid for the updater public key of the app"
	check_updater_comment "${sig##*/}" "$comment" "${file##*/}" "$version"
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
# command line and out of the manifest format. GitHub renames an asset whose
# name ends with a period, so such a name is not allowed either.
valid_asset_name() {
	[[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || return 1
	case "$1" in
	*.) return 1 ;;
	esac
}

# is_reserved_name NAME: names that the pipeline makes itself, and the names of
# its temporary files. No product can use them.
is_reserved_name() {
	case "$1" in
	"$MANIFEST_NAME"* | "$BUILD_MANIFEST_NAME"* | latest.json* | "$BUILD_INFO_NAME"* | *.asc | *.sig | *.minisig | *.tmp)
		return 0
		;;
	esac
	return 1
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
	local file="$1" line names duplicates
	[ -s "$file" ] || die "manifest is missing or empty: $file"
	while IFS= read -r line || [ -n "$line" ]; do
		if ! [[ "$line" =~ ^[0-9a-f]{64}\ \ [A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || ! valid_asset_name "${line:66}"; then
			die "$file: line is not '<sha256>  <name>': $line"
		fi
	done <"$file"
	names="$(manifest_names "$file")" || die "cannot read the names in $file"
	duplicates="$(printf '%s\n' "$names" | uniq -d)" || die "cannot check $file for duplicate names"
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
# except the manifest and its signature. OUT_FILE.tmp is a temp file.
write_manifest() {
	local dir="$1" out="$2" names name hash
	names="$(list_dir "$dir")"
	[ ! -e "$out.tmp" ] && [ ! -L "$out.tmp" ] || die "$out.tmp exists already"
	: >"$out.tmp"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		case "$name" in
		"$MANIFEST_NAME" | "$MANIFEST_SIG_NAME" | "${out##*/}") continue ;;
		esac
		hash="$(sha256_of "$dir/$name")" || die "cannot hash $dir/$name"
		printf '%s  %s\n' "$hash" "$name" >>"$out.tmp"
	done <<EOF
$names
EOF
	mv "$out.tmp" "$out"
}

# check_present_files_against_manifest DIR MANIFEST [IGNORED_NAME...]: fails
# unless the manifest lists every file in DIR with the same hash. Files that
# the manifest lists may be absent.
check_present_files_against_manifest() {
	local dir="$1" manifest="$2" present listed name hash unlisted="" ignored=""
	shift 2
	for name in "$@"; do
		ignored="$ignored$name"$'\n'
	done
	present="$(list_dir "$dir")"
	listed="$(manifest_names "$manifest")" || die "cannot read the names in $manifest"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		name_in_list "$name" "$ignored" && continue
		name_in_list "$name" "$listed" || unlisted="$unlisted $name"
	done <<<"$present"
	[ -z "$unlisted" ] || die "files that the manifest does not list:$unlisted"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		[ -e "$dir/$name" ] || continue
		hash="$(sha256_of "$dir/$name")" || die "cannot hash $dir/$name"
		[ "$hash" = "$(manifest_hash "$manifest" "$name")" ] ||
			die "hash mismatch for $name: the file does not match the manifest"
	done <<<"$listed"
}

# check_files_against_manifest DIR MANIFEST [IGNORED_NAME...]: fails unless the
# files in DIR are exactly the files in MANIFEST, with the same hashes.
check_files_against_manifest() {
	local dir="$1" manifest="$2" listed name missing=""
	check_present_files_against_manifest "$@"
	listed="$(manifest_names "$manifest")" || die "cannot read the names in $manifest"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		[ -e "$dir/$name" ] || missing="$missing $name"
	done <<<"$listed"
	[ -z "$missing" ] || die "files that the manifest lists but that are missing:$missing"
}

# flatten_artifacts MODE SRC DST: puts the files of every artifact directory in
# SRC into DST. MODE "copy" leaves SRC as it is. MODE "move" moves the files,
# for a temp download that the caller owns. Fails on nested directories and on
# a name that occurs twice.
flatten_artifacts() {
	local mode="$1" src="$2" dst="$3" artifact
	case "$mode" in
	copy | move) ;;
	*) die "flatten_artifacts: unknown mode $mode" ;;
	esac
	mkdir -p "$dst"
	for artifact in "$src"/*; do
		[ -e "$artifact" ] || continue
		flatten_artifact "$mode" "$artifact" "$dst"
	done
}

# flatten_artifact MODE ARTIFACT_DIR DST: the same for one artifact directory.
flatten_artifact() {
	local mode="$1" artifact="$2" dst="$3" names name
	[ -d "$artifact" ] && [ ! -L "$artifact" ] || die "unexpected file outside an artifact directory: $artifact"
	names="$(list_dir "$artifact")"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		[ ! -e "$dst/$name" ] || die "two artifacts contain a file named $name"
		if [ "$mode" = move ]; then
			mv "$artifact/$name" "$dst/$name"
		else
			cp -p "$artifact/$name" "$dst/$name"
		fi
	done <<EOF
$names
EOF
}

# ---------------------------------------------------------------------------
# Signature verification
# ---------------------------------------------------------------------------

# load_allowed_signers: reads the fingerprint allowlist into ALLOWED_SIGNERS.
load_allowed_signers() {
	local fingerprint lines
	[ -f "$CFG_ALLOWED_SIGNERS" ] || die "allowlist not found: $CFG_ALLOWED_SIGNERS"
	lines="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$CFG_ALLOWED_SIGNERS" | tr 'a-f' 'A-F')" ||
		die "cannot read the allowlist $CFG_ALLOWED_SIGNERS"
	ALLOWED_SIGNERS=""
	while IFS= read -r fingerprint; do
		[ -n "$fingerprint" ] || continue
		[[ "$fingerprint" =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]] ||
			die "$CFG_ALLOWED_SIGNERS: not a full key fingerprint: $fingerprint"
		ALLOWED_SIGNERS="$ALLOWED_SIGNERS${ALLOWED_SIGNERS:+
}$fingerprint"
	done <<EOF
$lines
EOF
	[ -n "$ALLOWED_SIGNERS" ] || die "the allowlist holds no fingerprint: $CFG_ALLOWED_SIGNERS"
}

is_allowed_signer() {
	name_in_list "$1" "$ALLOWED_SIGNERS"
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
	local sig="$1" file="$2" status rc=0 good valid bad class primary unknown
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
		# ERRSIG with code 9 means: the public key is missing.
		unknown="$(printf '%s\n' "$status" | awk '
			$1 == "[GNUPG:]" && $2 == "NO_PUBKEY" { print $3 }
			$1 == "[GNUPG:]" && $2 == "ERRSIG" && $8 == "9" { print $3 }' | LC_ALL=C sort -u | tr '\n' ' ')"
		if [ -n "$unknown" ]; then
			log "${sig##*/}: an unknown key signed it (key id ${unknown% }). Its public key is not in the signer keys directory $CFG_SIGNER_KEYS_DIR."
		fi
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

# verify_manifest_dir DIR MANIFEST_SHA256 MODE: the offline check of a
# directory that holds release files. SHA256SUMS must have the pinned hash
# and one good signature from an allowed signer. MODE "exact": DIR holds
# exactly the files of SHA256SUMS. MODE "subset": files may be absent, but every
# present file is listed, with the right hash. Call make_verify_keyring first.
verify_manifest_dir() {
	local dir="$1" pinned="$2" mode="$3" manifest="$1/$MANIFEST_NAME" hash
	[ -f "$manifest" ] || die "$dir holds no $MANIFEST_NAME"
	hash="$(sha256_of "$manifest")" || die "cannot hash $manifest"
	[ "$hash" = "$pinned" ] || die "$MANIFEST_NAME in $dir has the sha256 $hash, not the pinned $pinned"
	verify_detached "$dir/$MANIFEST_SIG_NAME" "$manifest" ||
		die "$MANIFEST_NAME has no good signature from an allowed signer"
	check_manifest "$manifest"
	case "$mode" in
	exact) check_files_against_manifest "$dir" "$manifest" "$MANIFEST_NAME" "$MANIFEST_SIG_NAME" ;;
	subset) check_present_files_against_manifest "$dir" "$manifest" "$MANIFEST_NAME" "$MANIFEST_SIG_NAME" ;;
	*) die "internal error: unknown mode $mode" ;;
	esac
}

# ---------------------------------------------------------------------------
# GitHub
# ---------------------------------------------------------------------------

# release_assets REPO RELEASE_ID: prints the JSON list of all assets of the
# release, from the paginated assets endpoint: [{id, name, size, digest,
# state}]. The asset list inside a release object can be cut short, so the
# scripts never use it.
release_assets() {
	local repo="$1" id="$2" raw assets problem
	[[ "$id" =~ ^[0-9]+$ ]] || die "not a release id: $id"
	raw="$(gh api --paginate "repos/$repo/releases/$id/assets?per_page=100" </dev/null)" ||
		die "cannot list the assets of release $id in $repo"
	assets="$(printf '%s' "$raw" | jq -cs 'map(if type == "array" then .[] else error("not a list") end) | map({id, name, size, digest, state})')" ||
		die "the asset list of release $id is not valid"
	problem="$(printf '%s' "$assets" | jq -r '
		[.[] | select((.id | type) != "number" or (.name | type) != "string" or (.size | type) != "number")] |
		if length == 0 then "" else "an asset has no id, name, or size: \(.[0])" end')" ||
		die "cannot check the asset list of release $id"
	[ -z "$problem" ] || die "release $id: $problem"
	printf '%s\n' "$assets"
}

# release_asset_names RELEASE_JSON: the asset names of a release that
# find_release printed, one per line.
release_asset_names() {
	printf '%s' "$1" | jq -r '.assets[].name'
}

# find_release REPO TAG: prints the JSON of the one release with this tag.
# Draft releases are included. GitHub allows several drafts with one tag, so
# more than one match is an error. ".assets" holds the full list from
# release_assets, and every asset name is valid.
find_release() {
	local repo="$1" tag="$2" matches count id assets names name
	matches="$(gh api --paginate "repos/$repo/releases?per_page=100" </dev/null |
		jq -c --arg tag "$tag" '.[] | select(.tag_name == $tag)')" ||
		die "cannot list the releases of $repo"
	count="$(printf '%s' "$matches" | grep -c . || true)"
	[ "$count" != 0 ] || die "no release with tag $tag in $repo (a draft is visible only with write access)"
	[ "$count" = 1 ] || die "$count releases use the tag $tag in $repo. Keep exactly one."
	id="$(printf '%s' "$matches" | jq -r .id)" || die "cannot read the id of release $tag"
	assets="$(release_assets "$repo" "$id")" || die "cannot list the assets of release $tag"
	names="$(printf '%s' "$assets" | jq -r '.[].name')" || die "cannot read the asset names of release $tag"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		valid_asset_name "$name" || die "the release has an asset with a name that is not allowed: $name"
	done <<<"$names"
	printf '%s' "$matches" | jq -c --argjson assets "$assets" '.assets = $assets' ||
		die "cannot read release $tag"
}

# default_branch REPO
default_branch() {
	local branch
	branch="$(gh api "repos/$1" --jq .default_branch </dev/null)" || return 1
	[ -n "$branch" ] && [ "$branch" != null ] || return 1
	printf '%s\n' "$branch"
}

# require_current_trust_state REPO: the finalize workflow takes the scripts,
# the signer keys, and the allowlist from its own commit (GITHUB_SHA). Fails
# unless that commit is the head of the default branch right now, as the API
# reports it. A run of an older commit could use a revoked signer.
require_current_trust_state() {
	local repo="$1" branch head
	[ -n "${GITHUB_SHA:-}" ] ||
		die "GITHUB_SHA is not set. This step runs only in the finalize workflow, which sets it to the commit of its scripts."
	valid_commit "$GITHUB_SHA" || die "GITHUB_SHA is not a full commit SHA: $GITHUB_SHA"
	branch="$(default_branch "$repo")" || die "cannot read the default branch of $repo"
	head="$(gh api "repos/$repo/branches/$branch" --jq .commit.sha </dev/null)" ||
		die "cannot read the head of the branch $branch of $repo"
	valid_commit "$head" || die "the head of $branch is not a full commit SHA: $head"
	[ "$head" = "$GITHUB_SHA" ] ||
		die "this run uses the scripts, signer keys, and allowlist of commit $GITHUB_SHA, but the head of the default branch $branch is $head now. The trust state can have changed since (for example, a removed signer). Start the finalize workflow again on $branch."
}

# require_commit_on_branch REPO COMMIT BRANCH: fails unless COMMIT is BRANCH's
# head or one of its ancestors.
require_commit_on_branch() {
	local repo="$1" commit="$2" branch="$3" status
	status="$(gh api "repos/$repo/compare/$branch...$commit" --jq .status </dev/null)" ||
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
	ref="$(gh api "repos/$repo/git/matching-refs/tags/$tag" </dev/null |
		jq -c --arg ref "refs/tags/$tag" '.[] | select(.ref == $ref) | .object')" ||
		die "cannot read the tags of $repo"
	[ -n "$ref" ] || return 0
	type="$(printf '%s' "$ref" | jq -r .type)" || die "cannot read the tag $tag"
	sha="$(printf '%s' "$ref" | jq -r .sha)" || die "cannot read the tag $tag"
	while [ "$type" = "tag" ]; do
		ref="$(gh api "repos/$repo/git/tags/$sha" --jq .object </dev/null)" || die "cannot read tag object $sha"
		type="$(printf '%s' "$ref" | jq -r .type)" || die "cannot read tag object $sha"
		sha="$(printf '%s' "$ref" | jq -r .sha)" || die "cannot read tag object $sha"
	done
	[ "$type" = "commit" ] || die "tag $tag points to a $type, not to a commit"
	printf '%s\n' "$sha"
}

# require_tag_matches REPO TAG COMMIT: a published release uses an existing git
# tag as it is. So an existing tag must already point to the release commit.
require_tag_matches() {
	local existing
	existing="$(tag_commit "$1" "$2")" || die "cannot read the git tag $2"
	if [ -n "$existing" ] && [ "$existing" != "$3" ]; then
		die "git tag $2 exists and points to $existing, not to the release commit $3"
	fi
}

# require_build_run REPO RUN_ID COMMIT [BRANCH]: fails unless RUN_ID is a
# successful run of the build workflow, in this repository, for this commit,
# started by the configured event (and on BRANCH, if given). Sets
# BUILD_RUN_ATTEMPT to the latest attempt of the run.
require_build_run() {
	local repo="$1" run_id="$2" commit="$3" branch="${4:-}" run problem
	run="$(gh api "repos/$repo/actions/runs/$run_id" </dev/null)" || die "cannot read workflow run $run_id of $repo"
	problem="$(printf '%s' "$run" | jq -r \
		--arg repo "$repo" --arg commit "$commit" --arg path ".github/workflows/$CFG_BUILD_WORKFLOW" \
		--arg event "$CFG_BUILD_EVENT" --arg branch "$branch" '
		if .repository.full_name != $repo then "it belongs to \(.repository.full_name)"
		elif .head_repository.full_name != $repo then "its code comes from \(.head_repository.full_name)"
		elif (.path | split("@")[0]) != $path then "it is a run of \(.path)"
		elif .head_sha != $commit then "it built commit \(.head_sha), but the release is for \($commit)"
		elif .event != $event then "the event \(.event) started it, not \($event)"
		elif $branch != "" and .head_branch != $branch then "it ran on \(.head_branch), not on \($branch)"
		elif .status != "completed" or .conclusion != "success" then "its result is \(.status)/\(.conclusion)"
		elif (.run_attempt | type) != "number" then "it has no run attempt"
		else "" end')" || die "cannot read workflow run $run_id of $repo"
	[ -z "$problem" ] || die "workflow run $run_id is not the build of this release: $problem"
	BUILD_RUN_ATTEMPT="$(printf '%s' "$run" | jq -r .run_attempt)"
}

# verify_build_attestation MANIFEST REPO COMMIT SOURCE_REF RUN_ID RUN_ATTEMPT:
# fails unless MANIFEST has an attestation from the build workflow of REPO, on
# a GitHub-hosted runner, for COMMIT on SOURCE_REF, and every verified
# attestation names the configured event and exactly this run attempt.
verify_build_attestation() {
	local manifest="$1" repo="$2" commit="$3" ref="$4" run_id="$5" attempt="$6" out problem
	out="$(gh attestation verify "$manifest" --repo "$repo" \
		--signer-workflow "$repo/.github/workflows/$CFG_BUILD_WORKFLOW" \
		--source-digest "$commit" --source-ref "$ref" --deny-self-hosted-runners \
		--format json </dev/null)" ||
		die "${manifest##*/} has no valid attestation from $CFG_BUILD_WORKFLOW at commit $commit on $ref"
	problem="$(printf '%s' "$out" | jq -r --arg event "$CFG_BUILD_EVENT" --arg commit "$commit" --arg ref "$ref" \
		--arg run "https://github.com/$repo/actions/runs/$run_id/attempts/$attempt" '
		if type != "array" or length == 0 then "gh printed no verified attestation"
		else [.[] | .verificationResult.signature.certificate as $c |
			if ($c | type) != "object" then "an attestation has no certificate"
			elif $c.buildTrigger != $event then "an attestation comes from the event \($c.buildTrigger), not \($event)"
			elif $c.runInvocationURI != $run then "an attestation comes from the run \($c.runInvocationURI), not \($run)"
			elif $c.sourceRepositoryDigest != $commit then "an attestation names the commit \($c.sourceRepositoryDigest)"
			elif $c.sourceRepositoryRef != $ref then "an attestation names the ref \($c.sourceRepositoryRef)"
			else empty end] | first // "" end')" ||
		die "cannot read the attestation of ${manifest##*/}"
	[ -z "$problem" ] || die "the attestation of ${manifest##*/} does not match the build run $run_id, attempt $attempt: $problem"
}

# download_build_artifacts REPO RUN_ID DST [PATTERN]: downloads the artifacts
# of a build run whose names match PATTERN (default: artifact_pattern) and puts
# all files into DST.
#
# The downloads run in parallel, one per artifact. The temp download directory
# is DST.download, next to DST, so the cleanup of the caller removes it.
download_build_artifacts() {
	local repo="$1" run_id="$2" dst="$3" pattern="${4:-$CFG_ARTIFACT_PATTERN}" raw="$3.download"
	local all names="" name duplicates jobs="" pid failed=""
	[ ! -e "$raw" ] && [ ! -L "$raw" ] || die "$raw exists already"
	all="$(gh api --paginate "repos/$repo/actions/runs/$run_id/artifacts?per_page=100" --jq '.artifacts[].name' </dev/null)" ||
		die "cannot list the artifacts of run $run_id"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		# shellcheck disable=SC2254 # the pattern is a glob on purpose
		case "$name" in
		$pattern) ;;
		*) continue ;;
		esac
		valid_asset_name "$name" || die "run $run_id has an artifact with a name that is not allowed: $name"
		names="$names$name"$'\n'
	done <<EOF
$all
EOF
	[ -n "$names" ] || die "run $run_id has no artifact that matches $pattern"
	duplicates="$(printf '%s' "$names" | LC_ALL=C sort | uniq -d)" || die "cannot check the artifact names of run $run_id"
	[ -z "$duplicates" ] || die "run $run_id has more than one artifact named $duplicates"
	mkdir "$raw"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		gh run download "$run_id" --repo "$repo" --name "$name" --dir "$raw/$name" </dev/null >&2 &
		jobs="$jobs$! $name"$'\n'
	done <<EOF
$names
EOF
	while IFS=' ' read -r pid name; do
		[ -n "$pid" ] || continue
		wait "$pid" || failed="$failed $name"
	done <<EOF
$jobs
EOF
	[ -z "$failed" ] || die "cannot download these artifacts of run $run_id:$failed"
	flatten_artifacts move "$raw" "$dst"
	rm -rf "$raw"
}

# The structure of release-build-info.json.
# shellcheck disable=SC2016 # a jq program, not shell
BUILD_INFO_SCHEMA_JQ='
length == 1 and (.[0] |
	type == "object" and
	(keys == (["commit", "repository", "run_attempt", "run_id", "tag", "workflow_ref"] | sort)) and
	(.repository | type == "string") and
	(.tag | type == "string") and
	(.commit | type == "string" and test("^[0-9a-f]{40}$")) and
	(.run_id | type == "number" and . > 0 and . == floor) and
	(.run_attempt | type == "number" and . > 0 and . == floor) and
	(.workflow_ref | type == "string"))'

# check_build_info FILE REPO TAG COMMIT RUN_ID [HINT]: the build info file ties
# the files to one repository, tag, commit, build run, and build workflow. It
# must hold exactly one JSON object with exactly the fields that
# build-manifest.sh writes. HINT goes at the end of the error message.
check_build_info() {
	local file="$1" hint="${6:-}" problem
	[ -f "$file" ] || die "$BUILD_INFO_NAME is missing${hint:+. $hint}"
	jq -e -s "$BUILD_INFO_SCHEMA_JQ" "$file" >/dev/null 2>&1 ||
		die "$BUILD_INFO_NAME is not one JSON object with exactly the fields repository, tag, commit (full SHA), run_id (number), run_attempt (number), and workflow_ref${hint:+. $hint}"
	problem="$(jq -r --arg repo "$2" --arg tag "$3" --arg commit "$4" --arg run "$5" \
		--arg workflow "$2/.github/workflows/$CFG_BUILD_WORKFLOW@" '
		if .repository != $repo then "repository is \(.repository), not \($repo)"
		elif .tag != $tag then "tag is \(.tag), not \($tag)"
		elif .commit != $commit then "commit is \(.commit), not \($commit)"
		elif (.run_id | tostring) != $run then "build run is \(.run_id), not \($run)"
		elif (.workflow_ref | startswith($workflow) | not) then "workflow is \(.workflow_ref), not \($workflow)<ref>"
		else "" end' "$file")" || die "$BUILD_INFO_NAME is not valid JSON"
	[ -z "$problem" ] || die "$BUILD_INFO_NAME does not match this release: $problem${hint:+. $hint}"
}

# ---------------------------------------------------------------------------
# Build run selection. The tag in the build info of a run is a hint only: it
# picks the run before the passphrase prompt. The attested build manifest,
# after the full download, stays the proof.
# ---------------------------------------------------------------------------

BUILD_MANIFEST_ARTIFACT="release-build-manifest"

# build_run_tag REPO RUN_ID SCRATCH: downloads only the small build manifest
# artifact of a run into a new directory in SCRATCH, and prints the tag that
# its build info names.
build_run_tag() {
	local repo="$1" run_id="$2" dir="$3/run-$2-info" tag
	mkdir "$dir" || return 1
	gh run download "$run_id" --repo "$repo" --name "$BUILD_MANIFEST_ARTIFACT" --dir "$dir" </dev/null >/dev/null 2>&1 ||
		return 1
	tag="$(jq -er '.tag | strings' "$dir/$BUILD_INFO_NAME" 2>/dev/null)" || return 1
	valid_tag "$tag" || return 1
	printf '%s\n' "$tag"
}

# select_build_run REPO COMMIT TAG SCRATCH: sets BUILD_RUN_ID to the newest
# successful build run of COMMIT whose build info names TAG.
select_build_run() {
	local repo="$1" commit="$2" tag="$3" scratch="$4" runs id found_tag found=""
	runs="$(gh api --paginate "repos/$repo/actions/workflows/$CFG_BUILD_WORKFLOW/runs?head_sha=$commit&status=success&per_page=100" \
		--jq '.workflow_runs[] | "\(.created_at) \(.id)"' </dev/null)" ||
		die "cannot list the runs of $CFG_BUILD_WORKFLOW"
	runs="$(printf '%s\n' "$runs" | sed '/^$/d' | LC_ALL=C sort -k1,1r -k2,2nr | cut -d' ' -f2)" ||
		die "cannot sort the runs of $CFG_BUILD_WORKFLOW"
	[ -n "$runs" ] || die "no successful run of $CFG_BUILD_WORKFLOW for commit $commit. Wait for the build, or pass --run-id."
	BUILD_RUN_ID=""
	while IFS= read -r id; do
		[[ "$id" =~ ^[0-9]+$ ]] || die "the run list holds a run id that is not a number: $id"
		if found_tag="$(build_run_tag "$repo" "$id" "$scratch")"; then
			if [ "$found_tag" = "$tag" ]; then
				BUILD_RUN_ID="$id"
				return 0
			fi
			found="$found"$'\n'"    run $id: tag $found_tag"
		else
			found="$found"$'\n'"    run $id: no readable $BUILD_INFO_NAME"
		fi
	done <<EOF
$runs
EOF
	die "no successful run of $CFG_BUILD_WORKFLOW for commit $commit built tag $tag. The runs of this commit built:$found
Build tag $tag, or pass --run-id."
}

# require_run_tag REPO RUN_ID TAG SCRATCH: fails unless the build info of the
# run names TAG.
require_run_tag() {
	local repo="$1" run_id="$2" tag="$3" scratch="$4" found_tag
	found_tag="$(build_run_tag "$repo" "$run_id" "$scratch")" ||
		die "cannot read $BUILD_INFO_NAME (artifact $BUILD_MANIFEST_ARTIFACT) of build run $run_id"
	[ "$found_tag" = "$tag" ] ||
		die "build run $run_id built tag $found_tag, not tag $tag. Pass the --run-id of a build of $tag, or leave --run-id out."
}

# download_release_assets REPO RELEASE_JSON DST [NAME...]: downloads assets of
# a release into DST, by asset id. RELEASE_JSON is the output of find_release.
# With no NAME, it downloads all assets. A file whose bytes differ from the
# digest that GitHub lists for the asset fails.
download_release_assets() {
	local repo="$1" release="$2" dst="$3" assets wanted id name digest hash
	shift 3
	assets="$(printf '%s' "$release" | jq -r '.assets[] | "\(.id) \(.name) \(.digest // "none")"')" ||
		die "cannot read the asset list of the release"
	while IFS=' ' read -r id name digest; do
		[ -n "$id" ] || continue
		[[ "$id" =~ ^[0-9]+$ ]] || die "the release has an asset with a bad id: $id"
		valid_asset_name "$name" || die "the release has an asset with a name that is not allowed: $name"
	done <<EOF2
$assets
EOF2
	wanted=""
	if [ $# -eq 0 ]; then
		wanted="$(printf '%s\n' "$assets" | cut -s -d' ' -f2)" || die "cannot read the asset names"
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
		digest="$(printf '%s\n' "$assets" | awk -v name="$name" '$2 == name { print $3 }')"
		[ -n "$id" ] || die "the release has no asset named $name"
		gh api -H "Accept: application/octet-stream" "repos/$repo/releases/assets/$id" >"$dst/$name" </dev/null ||
			die "cannot download the asset $name"
		if [ "$digest" != none ]; then
			hash="$(sha256_of "$dst/$name")" || die "cannot hash $dst/$name"
			[ "$digest" = "sha256:$hash" ] ||
				die "the download of $name has the sha256 $hash, but GitHub lists $digest for it. The asset changed during the download."
		fi
	done <<EOF2
$wanted
EOF2
}

# asset_state ASSETS_JSON: one sorted line "name id size digest state" per
# asset. Two equal states mean: the same files, the same bytes, the same ids.
asset_state() {
	printf '%s' "$1" | jq -r '.[] | "\(.name) \(.id) \(.size) \(.digest // "none") \(.state // "none")"' | LC_ALL=C sort
}

# require_assets_match_dir ASSETS_JSON DIR WHAT: fails unless the assets are
# exactly the files in DIR, each uploaded, with its size and its sha256 as the
# digest. WHAT describes the assets, for the message.
require_assets_match_dir() {
	local assets="$1" dir="$2" what="$3" lines files name id size digest state hash problems="" asset_names=""
	lines="$(asset_state "$assets")" || die "cannot read the asset list of $what"
	files="$(list_dir "$dir")"
	while IFS=' ' read -r name id size digest state; do
		[ -n "$name" ] || continue
		asset_names="$asset_names$name"$'\n'
		if ! name_in_list "$name" "$files"; then
			problems="$problems"$'\n'"    not expected: $name (asset $id)"
			continue
		fi
		hash="$(sha256_of "$dir/$name")" || die "cannot hash $dir/$name"
		[ "$digest" = "sha256:$hash" ] || problems="$problems"$'\n'"    other bytes: $name (asset $id has the digest $digest, the verified file sha256:$hash)"
		[ "$size" = "$(size_of "$dir/$name")" ] || problems="$problems"$'\n'"    other size: $name (asset $id)"
		[ "$state" = uploaded ] || problems="$problems"$'\n'"    not uploaded: $name (asset $id, state $state)"
	done <<<"$lines"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		name_in_list "$name" "$asset_names" || problems="$problems"$'\n'"    missing: $name"
	done <<<"$files"
	[ -z "$problems" ] || die "$what does not hold exactly the verified files:$problems"
}

# require_draft REPO RELEASE_ID TAG COMMIT: reads the release again, right
# before a change. Fails unless it is still a draft with this tag and commit.
require_draft() {
	local repo="$1" id="$2" tag="$3" commit="$4" release problem
	release="$(gh api "repos/$repo/releases/$id" </dev/null)" || die "cannot read release $id of $repo"
	problem="$(printf '%s' "$release" | jq -r --arg tag "$tag" --arg commit "$commit" '
		if .draft != true then "it is not a draft any more (it was published)"
		elif .tag_name != $tag then "its tag is \(.tag_name) now"
		elif .target_commitish != $commit then "it targets \(.target_commitish) now"
		else "" end')" || die "cannot read release $id of $repo"
	[ -z "$problem" ] || die "release $tag (id $id) changed: $problem. Nothing more is changed. Look at the release before you continue."
}

# upload_release_asset REPO RELEASE_ID FILE: uploads FILE to the release by
# release id (not by tag), and checks the name, size, and digest that GitHub
# returns. The release must not hold an asset with this name. Logs the cause
# and fails if the upload is not right.
upload_release_asset() {
	local repo="$1" id="$2" file="$3" name response problem hash size asset_id
	name="${file##*/}"
	valid_asset_name "$name" || die "asset name is not allowed: $name"
	hash="$(sha256_of "$file")" || die "cannot hash $file"
	size="$(size_of "$file")" || die "cannot read the size of $file"
	# "+" is the only character of a valid name that a query string changes.
	if ! response="$(gh api -X POST -H "Content-Type: application/octet-stream" --input "$file" \
		"https://uploads.github.com/repos/$repo/releases/$id/assets?name=${name//+/%2B}" </dev/null)"; then
		log "the upload of $name to release $id failed"
		return 1
	fi
	asset_id="$(printf '%s' "$response" | jq -r '.id | numbers' 2>/dev/null)" || asset_id=""
	if [ -z "$asset_id" ]; then
		log "the upload of $name returned no asset id"
		return 1
	fi
	# GitHub can compute the digest after the upload. Then read the asset again.
	if [ "$(printf '%s' "$response" | jq -r '.digest // ""')" = "" ]; then
		if ! response="$(gh api "repos/$repo/releases/assets/$asset_id" </dev/null)"; then
			log "cannot read the uploaded asset $name ($asset_id)"
			return 1
		fi
	fi
	problem="$(printf '%s' "$response" | jq -r --arg name "$name" --arg digest "sha256:$hash" --argjson size "$size" '
		if .name != $name then "GitHub stored it as \(.name)"
		elif .size != $size then "GitHub stored \(.size) bytes, not \($size)"
		elif .digest != $digest then "GitHub reports the digest \(.digest), not \($digest)"
		elif .state != "uploaded" then "its state is \(.state)"
		else "" end')" || problem="GitHub returned no valid asset"
	if [ -n "$problem" ]; then
		log "the upload of $name is not right: $problem"
		return 1
	fi
}

# delete_release_asset REPO ASSET_ID NAME
delete_release_asset() {
	[[ "$2" =~ ^[0-9]+$ ]] || die "not an asset id: $2"
	gh api -X DELETE "repos/$1/releases/assets/$2" </dev/null >/dev/null || die "cannot delete the asset $3 ($2)"
}

# ---------------------------------------------------------------------------
# Local signing setup
# ---------------------------------------------------------------------------

# require_clean_checkout PATH...: the signing scripts and the files that they
# trust must come from a clean git checkout. Fails unless REPO_ROOT is the top
# of a git checkout and git reports no change, untracked file, or ignored file
# under any PATH. Sets CHECKOUT_COMMIT to the commit of the checkout.
require_clean_checkout() {
	local top status
	need_tools git
	top="$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)" ||
		die "$REPO_ROOT is not a git checkout. Run the signing script from a clean clone."
	[ "$(cd "$top" && pwd -P)" = "$(cd "$REPO_ROOT" && pwd -P)" ] ||
		die "$REPO_ROOT is not the top of its git checkout ($top). Run the signing script from a clean clone."
	CHECKOUT_COMMIT="$(git -C "$top" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" ||
		die "the checkout $top has no commit"
	status="$(git -C "$top" status --porcelain=v1 --untracked-files=all --ignored=matching -- "$@")" ||
		die "git status fails in $top"
	[ -z "$status" ] || die "the checkout $top has changed, untracked, or ignored files where the signing script reads its code and trust settings. Commit or remove them, then run the script again:
$(printf '%s\n' "$status" | sed 's/^/    /')"
}

# select_signing_key: sets SIGNING_KEY to the primary fingerprint of the PGP
# key to sign with: RELEASE_SIGNING_KEY, or the one local secret key that the
# allowlist names. Call load_allowed_signers first.
select_signing_key() {
	local secret_keys key matches=""
	if [ -n "${RELEASE_SIGNING_KEY:-}" ]; then
		# gpg fails if it has no such key. The empty result says so below.
		SIGNING_KEY="$(gpg --batch --list-secret-keys --with-colons "$RELEASE_SIGNING_KEY" 2>/dev/null |
			awk -F: '$1 == "fpr" { print $10; exit }')" || true
		[ -n "$SIGNING_KEY" ] || die "no secret key for RELEASE_SIGNING_KEY=$RELEASE_SIGNING_KEY"
	else
		secret_keys="$(gpg --batch --list-secret-keys --with-colons 2>/dev/null |
			awk -F: '$1 == "sec" { want = 1 } $1 == "fpr" && want { print $10; want = 0 }')" ||
			die "gpg cannot list your secret keys"
		while IFS= read -r key; do
			[ -n "$key" ] || continue
			is_allowed_signer "$key" && matches="$matches$key"$'\n'
		done <<<"$secret_keys"
		[ -n "$matches" ] || die "none of your secret keys is on the allowlist ($CFG_ALLOWED_SIGNERS)"
		[ "$(printf '%s' "$matches" | grep -c .)" = 1 ] ||
			die "several of your secret keys are on the allowlist. Set RELEASE_SIGNING_KEY."
		SIGNING_KEY="${matches%$'\n'}"
	fi
	is_allowed_signer "$SIGNING_KEY" || die "your key $SIGNING_KEY is not on the allowlist ($CFG_ALLOWED_SIGNERS)"
}

# secrets_file_path REPO: prints the path of the encrypted secrets file.
secrets_file_path() {
	printf '%s\n' "${RELEASE_SECRETS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/release-signing/${1/\//__}.json.gpg}"
}
