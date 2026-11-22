#!/usr/bin/env bash
# Step 1 of the release pipeline: the build workflow runs this after all build
# jobs. It writes the build manifest that the signing script checks.
#
# The script reads the build output, one subdirectory per downloaded workflow
# artifact. Every artifact name matches artifact_pattern (the files that the
# signer downloads: products with origin build and input) or
# ci_artifact_pattern (products with origin ci). The files must be exactly the
# build, input, and ci products of config.json. The script writes two files to
# the output directory:
#   release-build-info.json  the repository, tag, commit, and build run
#   BUILD-SHA256SUMS         the hash of every build file and of the info file
#
# Usage: build-manifest.sh --artifacts DIR --out DIR --tag TAG
#
# Environment (GitHub Actions sets these): GITHUB_REPOSITORY, GITHUB_SHA,
# GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, GITHUB_WORKFLOW_REF.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
	die "usage: build-manifest.sh --artifacts DIR --out DIR --tag TAG"
}

artifacts="" out="" tag=""
while [ $# -gt 0 ]; do
	[ $# -ge 2 ] || usage
	case "$1" in
	--artifacts) artifacts="$2" ;;
	--out) out="$2" ;;
	--tag) tag="$2" ;;
	*) usage ;;
	esac
	shift 2
done
[ -n "$artifacts" ] && [ -n "$out" ] && [ -n "$tag" ] || usage
[ -d "$artifacts" ] || die "not a directory: $artifacts"
valid_tag "$tag" || die "tag is not valid: $tag"

for var in GITHUB_REPOSITORY GITHUB_SHA GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_WORKFLOW_REF; do
	[ -n "${!var:-}" ] || die "$var is not set"
done
[[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "GITHUB_REPOSITORY is not OWNER/NAME: $GITHUB_REPOSITORY"
valid_commit "$GITHUB_SHA" || die "GITHUB_SHA is not a full commit SHA: $GITHUB_SHA"
[[ "$GITHUB_RUN_ID" =~ ^[1-9][0-9]*$ ]] || die "GITHUB_RUN_ID is not a number: $GITHUB_RUN_ID"
[[ "$GITHUB_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]] || die "GITHUB_RUN_ATTEMPT is not a number: $GITHUB_RUN_ATTEMPT"

need_tools jq
load_config
needs_release_version && set_release_version "$tag"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
files="$work/files" release_files="$work/release" ci_files="$work/ci"
mkdir "$release_files" "$ci_files"
# Each artifact belongs to exactly one of the two groups. The signer downloads
# only the first group, so a file in the wrong group fails here, early.
for artifact in "$artifacts"/*; do
	[ -e "$artifact" ] || continue
	name="${artifact##*/}"
	# shellcheck disable=SC2254 # the patterns are globs on purpose
	case "$name" in
	$CFG_ARTIFACT_PATTERN) flatten_artifact copy "$artifact" "$release_files" ;;
	$CFG_CI_ARTIFACT_PATTERN) flatten_artifact copy "$artifact" "$ci_files" ;;
	*) die "the artifact $name matches neither $CFG_ARTIFACT_PATTERN nor $CFG_CI_ARTIFACT_PATTERN" ;;
	esac
done
release_names="$(list_dir "$release_files")"
ci_names="$(list_dir "$ci_files")"
[ -n "$release_names$ci_names" ] || die "the build output is empty: $artifacts"
expected_ci="$(product_names ci)" || die "cannot list the ci products"
while IFS= read -r name; do
	[ -n "$name" ] || continue
	name_in_list "$name" "$expected_ci" ||
		die "the artifacts that match $CFG_CI_ARTIFACT_PATTERN hold $name. Only the products with origin ci go there."
	[ ! -e "$release_files/$name" ] || die "two artifacts contain a file named $name"
done <<<"$ci_names"
while IFS= read -r name; do
	[ -n "$name" ] || continue
	! name_in_list "$name" "$expected_ci" ||
		die "the artifacts that match $CFG_ARTIFACT_PATTERN hold $name, a product with origin ci. It belongs in an artifact that matches $CFG_CI_ARTIFACT_PATTERN, which the signer does not download."
done <<<"$release_names"
mkdir "$files"
flatten_artifact move "$release_files" "$files"
flatten_artifact move "$ci_files" "$files"
names="$(list_dir "$files")"

# The names that later steps add. The build must not make them.
while IFS= read -r name; do
	case "$name" in
	"") ;;
	*.sig) die "the build output holds $name. The build has to drop the throwaway updater signatures: the signing step makes the real ones." ;;
	*.asc) die "the build output holds $name. Signatures come from the signing step only." ;;
	esac
	if is_reserved_name "$name"; then
		die "the build output holds $name. This name is reserved for the release pipeline."
	fi
done <<<"$names"
require_product_set build-output "the build output $artifacts" "$names"

jq -n \
	--arg repository "$GITHUB_REPOSITORY" \
	--arg tag "$tag" \
	--arg commit "$GITHUB_SHA" \
	--argjson run_id "$GITHUB_RUN_ID" \
	--argjson run_attempt "$GITHUB_RUN_ATTEMPT" \
	--arg workflow_ref "$GITHUB_WORKFLOW_REF" \
	'{repository: $repository, tag: $tag, commit: $commit, run_id: $run_id, run_attempt: $run_attempt, workflow_ref: $workflow_ref}' \
	>"$files/$BUILD_INFO_NAME"

mkdir -p "$work/out"
write_manifest "$files" "$work/out/$BUILD_MANIFEST_NAME"
check_manifest "$work/out/$BUILD_MANIFEST_NAME"

# Never replace a file in the output directory.
mkdir -p "$out"
for name in "$BUILD_INFO_NAME" "$BUILD_MANIFEST_NAME"; do
	[ ! -e "$out/$name" ] && [ ! -L "$out/$name" ] || die "$out/$name exists already"
done
cp "$files/$BUILD_INFO_NAME" "$out/$BUILD_INFO_NAME"
cp "$work/out/$BUILD_MANIFEST_NAME" "$out/$BUILD_MANIFEST_NAME"

log "wrote $out/$BUILD_MANIFEST_NAME ($(wc -l <"$out/$BUILD_MANIFEST_NAME" | tr -d ' ') files) and $out/$BUILD_INFO_NAME"
