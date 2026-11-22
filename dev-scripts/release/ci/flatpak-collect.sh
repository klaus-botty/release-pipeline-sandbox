#!/usr/bin/env bash
# Step 1 of the release pipeline, after the unsigned Flatpak build:
#
#   flatpak-builder ... --repo=<repo_dir> <manifest>
#   flatpak build-update-repo --default-branch=<branch> --prune <repo_dir>
#
# Usage: flatpak-collect.sh REPO_DIR OUT_DIR
#
# Writes into OUT_DIR:
#   flatpak-repo.tar     the complete repository
#   flatpak-to-sign.tar  summary, summary.idx, every commit object (paths
#                        relative to the repository), and refs.txt: one line
#                        "<ref> <commit id>" per ref of the repository,
#                        sorted. The maintainer checks refs.txt against the
#                        expected refs and signs summary, summary.idx, and the
#                        commits of refs.txt (flatpak_sign in flatpak.sh).
#
# Fails if a commit object has no ref: the maintainer signs only the commits
# of refs.txt, and a commit without a ref would stay unsigned.
#
# Fails if the repository already holds static deltas or signatures: a delta
# superblock embeds the commit signature, and the summary must stay exactly as
# the maintainer signs it. Both archives are deterministic: sorted names,
# owner 0, mtime 0, and fixed file modes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$SCRIPT_DIR/../lib.sh"
# shellcheck source-path=SCRIPTDIR source=../flatpak.sh
. "$SCRIPT_DIR/../flatpak.sh"

[ $# -eq 2 ] || die "usage: flatpak-collect.sh REPO_DIR OUT_DIR"
repo="$1" out="$2"
need_tools tar find sort comm

flatpak_check_unsigned_repo "$repo"
mkdir -p "$out"
for name in flatpak-repo.tar flatpak-to-sign.tar; do
	[ ! -e "$out/$name" ] && [ ! -L "$out/$name" ] || die "$out/$name exists already"
done
out="$(cd "$out" && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# deterministic_tar LIST OUT: packs the repository paths in LIST (one per line,
# sorted) into OUT. pax format: delta and summary names exceed the 100
# characters of ustar.
deterministic_tar() {
	(cd "$repo" && LC_ALL=C tar --format=posix --pax-option=delete=atime,delete=ctime \
		--no-recursion --owner=0 --group=0 --numeric-owner --mtime=@0 \
		--mode='u=rwX,go=rX' -cf "$2" -T "$1") || die "cannot write $2"
}

# refs.txt, from the refs of the repository itself.
mkdir "$work/meta"
flatpak_repo_refs "$repo" >"$work/meta/refs.txt" || die "cannot read the refs of $repo"
flatpak_read_refs "$work/meta/refs.txt" >/dev/null || die "the refs of $repo do not form a valid refs.txt"
while read -r _ commit; do
	flatpak_commit_path "$commit"
done <"$work/meta/refs.txt" | LC_ALL=C sort >"$work/ref-commits"
(cd "$repo" && find objects -type f -name '*.commit' -print) | LC_ALL=C sort >"$work/commits"
missing="$(LC_ALL=C comm -23 "$work/ref-commits" "$work/commits")"
[ -z "$missing" ] || die "$repo has refs whose commit object is missing: $missing"
orphans="$(LC_ALL=C comm -13 "$work/ref-commits" "$work/commits")"
[ -z "$orphans" ] ||
	die "$repo holds commit objects that no ref names (old history?): $(printf '%s' "$orphans" | tr '\n' ' '). Build the repository fresh and run 'flatpak build-update-repo --prune'."

# Directories too, so that the empty directories of the repository (tmp,
# refs/remotes, ...) survive.
(cd "$repo" && find . -mindepth 1 -print | sed 's|^\./||' | LC_ALL=C sort) >"$work/all"
deterministic_tar "$work/all" "$out/flatpak-repo.tar.tmp"
mv "$out/flatpak-repo.tar.tmp" "$out/flatpak-repo.tar"

{
	printf '%s\n' summary summary.idx
	cat "$work/commits"
} | LC_ALL=C sort >"$work/sign"
while IFS= read -r name; do
	flatpak_valid_sign_member "$name" || die "unexpected commit object name: $name"
done <"$work/sign"
# ustar: the names are short, and macOS tar reads it without surprises.
# refs.txt comes from the work directory; the repository holds no such file.
(LC_ALL=C tar --format=ustar --no-recursion --owner=0 --group=0 --numeric-owner \
	--mtime=@0 --mode='u=rw,go=r' -cf "$out/flatpak-to-sign.tar.tmp" \
	-C "$repo" -T "$work/sign" -C "$work/meta" refs.txt) ||
	die "cannot write $out/flatpak-to-sign.tar"
mv "$out/flatpak-to-sign.tar.tmp" "$out/flatpak-to-sign.tar"

log "flatpak-repo.tar:    $(wc -l <"$work/all" | tr -d ' ') entries, sha256 $(sha256_of "$out/flatpak-repo.tar")"
log "flatpak-to-sign.tar: $(($(wc -l <"$work/sign") + 1)) files ($(($(wc -l <"$work/sign") - 2)) commits, refs.txt), sha256 $(sha256_of "$out/flatpak-to-sign.tar")"
sed 's/^/    /' "$work/meta/refs.txt" >&2
