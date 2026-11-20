#!/usr/bin/env bash
# Step 1 of the release pipeline: the build workflow runs this after all build
# jobs. It writes the build manifest that the signing script checks.
#
# The script reads the build output, one subdirectory per downloaded workflow
# artifact, and writes two files to the output directory:
#   release-build-info.json  the repository, tag, commit, and build run
#   BUILD-SHA256SUMS         the hash of every build file and of the info file
#
# Usage: build-manifest.sh --artifacts DIR --out DIR --tag TAG
#
# Environment (GitHub Actions sets these): GITHUB_REPOSITORY, GITHUB_SHA,
# GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, GITHUB_WORKFLOW_REF.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
[[ "$GITHUB_RUN_ID" =~ ^[0-9]+$ ]] || die "GITHUB_RUN_ID is not a number: $GITHUB_RUN_ID"
[[ "$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+$ ]] || die "GITHUB_RUN_ATTEMPT is not a number: $GITHUB_RUN_ATTEMPT"

need_tools jq

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
files="$work/files"
flatten_artifacts copy "$artifacts" "$files"

# The names that later steps add. The build must not make them.
names="$(list_dir "$files")"
while IFS= read -r name; do
	case "$name" in
	"") ;;
	*.sig) die "the build output holds $name. The build has to drop the throwaway updater signatures: the signing step makes the real ones." ;;
	*.asc) die "the build output holds $name. Signatures come from the signing step only." ;;
	"$MANIFEST_NAME" | "$MANIFEST_SIG_NAME" | "$BUILD_MANIFEST_NAME" | "$BUILD_INFO_NAME" | latest.json)
		die "the build output holds $name. This name is reserved for the release pipeline."
		;;
	esac
done <<<"$names"
[ -n "$names" ] || die "the build output is empty: $artifacts"

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
