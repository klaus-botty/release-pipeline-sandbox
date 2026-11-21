#!/usr/bin/env bash
# Step 3 of the release pipeline for the Flatpak repository (the future
# "finalize-release.sh flatpak"). Runs on ubuntu-24.04 with the apt packages
# flatpak ostree gir1.2-ostree-1.0 python3-gi gnupg.
#
# Usage: flatpak-finalize.sh
#     --repo-tar FILE        flatpak-repo.tar from step 1 (ci/flatpak-collect.sh)
#     --signatures-tar FILE  the signatures and the approved refs.txt from
#                            step 2 (flatpak_sign)
#     --pubkey FILE          armored public key file that holds the signing key
#     --fingerprint FPR      primary key fingerprint that must have signed
#     --app-id ID            application id, for example org.example.App
#     --arch ARCH            architecture of the app ref, for example x86_64
#     --branch BRANCH        Flatpak branch, for example stable
#     --expected-refs FILE   the ref names the release must hold, one per line
#                            (flatpak_expected_refs in flatpak.sh)
#     --bundle-name NAME     file name of the single-file bundle
#     --templates DIR        *.flatpakrepo and *.flatpakref templates, and the
#                            static pages (index.html, icon.png, ...)
#     --url URL              public URL of the repository (%Url%)
#     --homepage URL         project homepage (%Homepage%)
#     --out DIR              new directory: the content of the Pages branch
#   optional, passed to "flatpak build-bundle" (production passes neither):
#     --bundle-repo-url URL      --repo-url, plus --gpg-keys with the public key
#     --bundle-runtime-repo URL  --runtime-repo
#
# The steps, in this order:
#   1. unpack both archives safely
#   2. refs: the names in the approved refs.txt (from the signatures archive)
#      equal --expected-refs, which holds app/ID/ARCH/BRANCH; the refs of the
#      repository (names and commit ids) equal refs.txt; the repository holds
#      no other commit object
#   3. verify the signatures of summary, summary.idx, and every approved
#      commit with verify_detached from lib.sh, with a keyring and an
#      allowlist that hold only FPR: exactly one good binary signature whose
#      primary key is FPR (a signing subkey of FPR is fine); no extra and no
#      missing signature
#   4. every signed commit is bound to its ref (ostree.ref-binding), names
#      its ref in xa.ref, and holds the app or runtime of its ref; the app ref
#      is app/ID/ARCH/BRANCH; the refs in the signed summary and in the
#      subsummaries of the signed summary.idx equal refs.txt
#   5. record the SHA-256 of every file of the repository
#   6. attach the signatures, generate the static deltas, reindex, ostree fsck
#   7. self-check over local HTTP, each pull into its own new bare-user-only
#      repo with gpg-verify and gpg-verify-summary: one pull through the static
#      deltas only, one through the loose objects only. The HTTP access log
#      shows which path each pull used; the delta pull fails without a delta.
#      The pulled commits must equal refs.txt. flatpak lists the remote from
#      the signed summary.idx, with the same commits.
#   8. build the bundle and check its commit; fill %Url%, %Homepage%, and
#      %GPGKey% in the templates; copy the static pages; add .nojekyll
#   9. fail if a recorded file changed or disappeared
# --out then holds the same layout as the production Pages branch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source-path=SCRIPTDIR source=flatpak.sh
. "$SCRIPT_DIR/flatpak.sh"

usage() {
	die "usage: flatpak-finalize.sh --repo-tar FILE --signatures-tar FILE --pubkey FILE --fingerprint FPR --app-id ID --arch ARCH --branch BRANCH --expected-refs FILE --bundle-name NAME --templates DIR --url URL --homepage URL --out DIR [--bundle-repo-url URL] [--bundle-runtime-repo URL]"
}

repo_tar="" sig_tar="" pubkey="" fpr="" app_id="" arch="" branch="" expected_refs="" bundle_name="" templates="" url="" homepage="" out=""
bundle_repo_url="" bundle_runtime_repo=""
while [ $# -gt 0 ]; do
	[ $# -ge 2 ] || usage
	case "$1" in
	--repo-tar) repo_tar="$2" ;;
	--signatures-tar) sig_tar="$2" ;;
	--pubkey) pubkey="$2" ;;
	--fingerprint) fpr="$2" ;;
	--app-id) app_id="$2" ;;
	--arch) arch="$2" ;;
	--branch) branch="$2" ;;
	--expected-refs) expected_refs="$2" ;;
	--bundle-name) bundle_name="$2" ;;
	--templates) templates="$2" ;;
	--url) url="$2" ;;
	--homepage) homepage="$2" ;;
	--out) out="$2" ;;
	--bundle-repo-url) bundle_repo_url="$2" ;;
	--bundle-runtime-repo) bundle_runtime_repo="$2" ;;
	*) usage ;;
	esac
	shift 2
done
for value in "$repo_tar" "$sig_tar" "$pubkey" "$fpr" "$app_id" "$arch" "$branch" "$expected_refs" "$bundle_name" "$templates" "$url" "$homepage" "$out"; do
	[ -n "$value" ] || usage
done
fpr="$(flatpak_normalize_fingerprint "$fpr")" || die "--fingerprint is not valid"
[[ "$app_id" =~ ^[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z_][A-Za-z0-9_-]*)+$ ]] || die "--app-id is not a Flatpak application id: $app_id"
[[ "$arch" =~ ^[A-Za-z0-9_]+$ ]] || die "--arch is not a Flatpak architecture: $arch"
[[ "$branch" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || die "--branch is not a Flatpak branch name: $branch"
valid_asset_name "$bundle_name" || die "--bundle-name is not allowed: $bundle_name"
for value in "$url" "$homepage" "$bundle_repo_url" "$bundle_runtime_repo"; do
	case "$value" in
	*$'\n'* | *$'\r'*) die "a URL option holds a line break" ;;
	esac
done
[ -f "$repo_tar" ] || die "not a file: $repo_tar"
[ -f "$sig_tar" ] || die "not a file: $sig_tar"
[ -f "$pubkey" ] || die "not a file: $pubkey"
[ -f "$expected_refs" ] || die "not a file: $expected_refs"
[ -d "$templates" ] || die "not a directory: $templates"
[ ! -e "$out" ] && [ ! -L "$out" ] || die "--out must not exist yet: $out"
need_tools gpg ostree flatpak python3 base64 sed find sort comm awk

started=$SECONDS
work="$(mktemp -d)"
server_pid=""
cleanup() {
	if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
	rm -rf "$work"
}
trap cleanup EXIT
helper() { python3 -I "$SCRIPT_DIR/flatpak-attach.py" "$@"; }
site="$work/site"
app_ref="app/$app_id/$arch/$branch"

# ---------------------------------------------------------------------------
step "Unpacking the repository and the signatures"
helper extract repo "$repo_tar" "$site" || die "refusing $repo_tar"
helper extract signatures "$sig_tar" "$work/sigs" || die "refusing $sig_tar"
flatpak_check_unsigned_repo "$site"

# ---------------------------------------------------------------------------
step "Checking the refs against the approved refs.txt and --expected-refs"
[ -f "$work/sigs/refs.txt" ] ||
	die "$sig_tar holds no refs.txt, the record of the approved refs. Sign with the current flatpak_sign."
flatpak_read_refs "$work/sigs/refs.txt" >"$work/approved" ||
	die "the refs.txt in $sig_tar is not valid"
flatpak_read_ref_list "$expected_refs" >"$work/expected" || die "--expected-refs $expected_refs is not valid"
grep -qxF -- "$app_ref" "$work/expected" ||
	die "--expected-refs does not hold the app ref $app_ref. Check --app-id, --arch, --branch, and the list."
cut -d' ' -f1 "$work/approved" >"$work/approved-names"
flatpak_compare_refs "$work/expected" "$work/approved-names" "the approved refs.txt" "--expected-refs" ||
	die "the refs that the maintainer approved differ from --expected-refs"

ostree --repo="$site" refs >"$work/ref-names" || die "the unpacked repository is not a valid OSTree repository"
while IFS= read -r ref; do
	printf '%s %s\n' "$ref" "$(ostree --repo="$site" rev-parse "$ref")"
done <"$work/ref-names" | LC_ALL=C sort >"$work/repo-refs"
flatpak_compare_refs "$work/approved" "$work/repo-refs" "the repository" "the approved refs.txt" ||
	die "the refs of $repo_tar differ from the approved refs.txt in $sig_tar"

while read -r _ commit; do
	flatpak_commit_path "$commit"
done <"$work/approved" | LC_ALL=C sort >"$work/approved-commits"
(cd "$site" && find objects -type f -name '*.commit' -print) | LC_ALL=C sort >"$work/repo-commits"
extra="$(LC_ALL=C comm -13 "$work/approved-commits" "$work/repo-commits")"
[ -z "$extra" ] || die "the repository holds commit objects that no approved ref names: $(printf '%s' "$extra" | tr '\n' ' ')"
sed 's/^/    /' "$work/approved" >&2

# ---------------------------------------------------------------------------
step "Verifying the signatures with verify_detached and the key $fpr only"
mkdir -m 700 "$work/import"
gpg --homedir "$work/import" --batch --no-tty --quiet --import "$pubkey" 2>/dev/null ||
	die "cannot import $pubkey"
gpg --homedir "$work/import" --batch --no-tty --with-colons --list-keys 2>/dev/null |
	awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }' >"$work/primaries"
grep -qxF -- "$fpr" "$work/primaries" ||
	die "$pubkey holds no primary key $fpr. It holds: $(tr '\n' ' ' <"$work/primaries")"
gpg --homedir "$work/import" --batch --no-tty --export "$fpr" >"$work/key.gpg"
# The main verifier of lib.sh, with a key directory and an allowlist that
# hold this one key and nothing else.
mkdir "$work/signer-keys"
gpg --homedir "$work/import" --batch --no-tty --armor --export "$fpr" >"$work/signer-keys/flatpak.asc"
printf '%s\n' "$fpr" >"$work/allowed-signers"
# shellcheck disable=SC2034 # read by load_allowed_signers and make_verify_keyring
CFG_SIGNER_KEYS_DIR="$work/signer-keys" CFG_ALLOWED_SIGNERS="$work/allowed-signers"
load_allowed_signers
make_verify_keyring "$work/keyring"

{
	printf '%s\n' summary summary.idx
	cat "$work/approved-commits"
} | LC_ALL=C sort >"$work/expected-sigs"
(cd "$work/sigs" && find . -type f -name '*.sig' -print | sed 's|^\./||; s|\.sig$||' | LC_ALL=C sort) >"$work/signed"
missing="$(LC_ALL=C comm -13 "$work/signed" "$work/expected-sigs")"
extra="$(LC_ALL=C comm -23 "$work/signed" "$work/expected-sigs")"
[ -z "$missing" ] || die "signatures are missing for: $(printf '%s' "$missing" | tr '\n' ' ')"
[ -z "$extra" ] || die "signatures for files that are not approved: $(printf '%s' "$extra" | tr '\n' ' ')"

count=0
while IFS= read -r name; do
	verify_detached "$work/sigs/$name.sig" "$site/$name" ||
		die "$name.sig: not exactly one good binary signature by $fpr on $name. If $name changed after the signature, the repository is not what the maintainer signed."
	case "$name" in
	objects/*)
		hash="${name#objects/}"
		hash="${hash%%/*}${hash#*/}"
		[ "$(sha256_of "$site/$name")" = "${hash%.commit}" ] ||
			die "the content of $name does not match the hash in its name"
		;;
	esac
	count=$((count + 1))
done <"$work/expected-sigs"
log "    $count good signatures: summary, summary.idx, $((count - 2)) commits"

# ---------------------------------------------------------------------------
step "Checking the signed summary, summary.idx, and commits against the approved refs"
helper check-commits "$site" "$work/approved" "$app_id" "$arch" "$branch" ||
	die "the metadata of the signed commits does not match the approved refs"
helper summary-refs "$site" >"$work/summary-refs" || die "cannot read the refs of the summary"
flatpak_compare_refs "$work/approved" "$work/summary-refs" "the signed summary" "the approved refs.txt" ||
	die "the signed summary does not advertise the approved refs"
helper index-refs "$site" >"$work/index-refs" || die "cannot read the subsummaries of summary.idx"
flatpak_compare_refs "$work/approved" "$work/index-refs" "the subsummaries of the signed summary.idx" "the approved refs.txt" ||
	die "the signed summary.idx does not advertise the approved refs"
log "    summary and summary.idx advertise exactly the $(grep -c . "$work/approved") approved refs"

# ---------------------------------------------------------------------------
step "Recording the hashes of the repository files"
hash_tree() {
	(cd "$site" && find . -type f -print0 | xargs -0 -r sha256sum) | LC_ALL=C sort
}
hash_tree >"$work/before"
for name in summary summary.idx; do
	log "    $(grep -E "  \./$name\$" "$work/before")"
done
grep -E '\.commit$' "$work/before" | sed 's/^/    /' >&2

# ---------------------------------------------------------------------------
step "Attaching the signatures"
helper attach "$site" "$work/sigs" || die "cannot attach the signatures"

step "Generating static deltas (after the attach step: a superblock embeds the commit signature)"
delta_refs=""
while read -r ref commit; do
	case "$ref" in
	appstream/* | appstream2/*) continue ;;
	esac
	ostree --repo="$site" static-delta generate --empty --min-fallback-size=1 --to="$commit" >"$work/delta.log" 2>&1 || {
		sed 's/^/    /' "$work/delta.log" >&2
		die "cannot generate the static delta for $ref"
	}
	delta_refs="$delta_refs $ref"
done <"$work/approved"
[ -n "$delta_refs" ] || die "no ref for a static delta"
ostree --repo="$site" static-delta reindex || die "cannot reindex the static deltas"
log "    $(ostree --repo="$site" static-delta list | grep -c . || true) deltas for:$delta_refs"

step "Checking the repository with ostree fsck"
fsck_started=$SECONDS
ostree fsck --repo="$site" >"$work/fsck.log" 2>&1 || {
	sed 's/^/    /' "$work/fsck.log" >&2
	die "ostree fsck found errors in the repository"
}
log "    $(tail -n 1 "$work/fsck.log") ($((SECONDS - fsck_started)) s)"

# ---------------------------------------------------------------------------
step "Self-check: pulling over HTTP with signature checks, deltas and objects separately"
: >"$work/http.log"
helper serve "$site" "$work/port" "$work/http.log" &
server_pid=$!
i=0
while [ ! -s "$work/port" ]; do
	kill -0 "$server_pid" 2>/dev/null || die "the local HTTP server did not start"
	i=$((i + 1))
	[ "$i" -lt 100 ] || die "the local HTTP server did not report its port"
	sleep 0.1
done
repo_url="http://127.0.0.1:$(cat "$work/port")/"

# check_pull deltas|objects REFS...: pulls REFS into a new scratch repo, with
# only static deltas or only loose objects; compares the pulled commits with
# refs.txt; reads from the HTTP access log which path the pull used.
check_pull() {
	local name="$1" scratch="$work/check-$1" option ref start superblocks parts objects commitmeta others
	shift
	case "$name" in
	deltas) option=--require-static-deltas ;;
	objects) option=--disable-static-deltas ;;
	esac
	ostree --repo="$scratch" init --mode=bare-user-only
	ostree --repo="$scratch" remote add --set=gpg-verify=true --set=gpg-verify-summary=true \
		--gpg-import="$work/key.gpg" check "$repo_url" >/dev/null
	start="$(wc -l <"$work/http.log")"
	ostree --repo="$scratch" pull "$option" check "$@" >"$work/pull-$name.log" 2>&1 || {
		sed 's/^/    /' "$work/pull-$name.log" >&2
		die "self-check pull ($name) failed"
	}
	tail -n "+$((start + 1))" "$work/http.log" >"$work/http-$name.log"

	for ref in "$@"; do
		printf '%s %s\n' "$ref" "$(ostree --repo="$scratch" rev-parse "check:$ref")"
	done | LC_ALL=C sort >"$work/pulled-$name"
	printf '%s\n' "$@" >"$work/names-$name"
	awk 'FILENAME == ARGV[1] { want[$1] = 1; next } ($1 in want)' "$work/names-$name" "$work/approved" |
		LC_ALL=C sort >"$work/want-$name"
	flatpak_compare_refs "$work/want-$name" "$work/pulled-$name" "the $name pull" "the approved refs.txt" ||
		die "self-check pull ($name): the pulled commits differ from the approved commits"

	superblocks="$(grep -cE '^GET /deltas/[^ ]*/superblock 200$' "$work/http-$name.log" || true)"
	parts="$(grep -cE '^GET /deltas/[^ ]*/[0-9]+ 200$' "$work/http-$name.log" || true)"
	commitmeta="$(grep -cE '^GET /objects/[^ ]*\.commitmeta 200$' "$work/http-$name.log" || true)"
	objects="$(grep -cE '^GET /objects/[^ ]*\.(commit|dirtree|dirmeta|filez) 200$' "$work/http-$name.log" || true)"
	others="$(grep -cvE ' 200$' "$work/http-$name.log" || true)"
	log "    $name pull of $# refs: $superblocks delta superblocks, $parts delta parts, $objects loose objects, $commitmeta commitmeta, $others non-200 responses; ostree: $(grep . "$work/pull-$name.log" | tail -n 1)"
	case "$name" in
	deltas)
		[ "$superblocks" -ge "$#" ] ||
			die "self-check pull (deltas): fetched $superblocks delta superblocks for $# refs; the pull did not use the static deltas"
		;;
	objects)
		[ "$superblocks" = 0 ] && [ "$parts" = 0 ] && [ "$objects" -gt 0 ] ||
			die "self-check pull (objects): the pull did not use loose objects only"
		;;
	esac
	rm -rf "$scratch"
}
# shellcheck disable=SC2086 # the ref names have no white space
check_pull deltas $delta_refs
# shellcheck disable=SC2046
check_pull objects $(cut -d' ' -f1 "$work/approved")

# flatpak reads summary.idx, its signature, and the subsummaries, which ostree
# pull does not.
fp_home="$work/flatpak-home"
mkdir -p "$fp_home"
fp() {
	HOME="$fp_home" XDG_DATA_HOME="$fp_home/data" XDG_CACHE_HOME="$fp_home/cache" \
		XDG_CONFIG_HOME="$fp_home/config" FLATPAK_USER_DIR="$fp_home/flatpak" flatpak --user "$@"
}
fp remote-add --gpg-import="$work/key.gpg" check "$repo_url" ||
	die "flatpak cannot add the local remote"
fp remote-ls --all --arch="$arch" --columns=ref check >"$work/remote-ls" 2>"$work/remote-ls.err" || {
	sed 's/^/    /' "$work/remote-ls.err" >&2
	die "flatpak cannot read the signed summary of the repository"
}
# remote-ls shortens commit ids; remote-info prints them in full.
while IFS= read -r ref; do
	printf '%s %s\n' "$ref" "$(fp remote-info --show-commit check "$ref")" ||
		die "flatpak remote-info cannot read $ref"
done <"$work/remote-ls" | LC_ALL=C sort >"$work/flatpak-refs"
grep -E '^(app|runtime)/[^ ]*/'"$arch"'/' "$work/approved" >"$work/want-flatpak" || true
flatpak_compare_refs "$work/want-flatpak" "$work/flatpak-refs" "flatpak remote-ls" "the approved app and runtime refs" ||
	die "flatpak lists other refs or commits than the approved ones"
log "    flatpak lists the $(grep -c . "$work/flatpak-refs") approved app and runtime refs with the approved commits"
kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=""
rm -rf "$fp_home"

# ---------------------------------------------------------------------------
step "Building the bundle and the pages"
bundle_opts=()
if [ -n "$bundle_repo_url" ]; then
	bundle_opts+=("--repo-url=$bundle_repo_url" "--gpg-keys=$work/key.gpg")
fi
[ -z "$bundle_runtime_repo" ] || bundle_opts+=("--runtime-repo=$bundle_runtime_repo")
[ ! -e "$site/$bundle_name" ] || die "the repository already holds a file named $bundle_name"
flatpak build-bundle --arch="$arch" ${bundle_opts[@]+"${bundle_opts[@]}"} "$site" "$site/$bundle_name" "$app_id" "$branch" ||
	die "flatpak build-bundle failed"
ostree --repo="$work/bundle-check" init --mode=archive-z2
# flatpak 1.14 prints GLib-CRITICAL lines for a bundle without an origin remote.
flatpak build-import-bundle --no-update-summary "$work/bundle-check" "$site/$bundle_name" >"$work/import.log" 2>&1 || {
	sed 's/^/    /' "$work/import.log" >&2
	die "cannot import the new bundle"
}
bundle_commit="$(ostree --repo="$work/bundle-check" rev-parse "$app_ref")"
[ "$bundle_commit" = "$(awk -v r="$app_ref" '$1 == r { print $2 }' "$work/approved")" ] ||
	die "the bundle holds the commit $bundle_commit for $app_ref, not the approved commit"
ostree --repo="$work/bundle-check" show --print-detached-metadata-key=ostree.gpgsigs "$bundle_commit" >/dev/null 2>&1 ||
	die "the bundle does not carry the commit signature"
rm -rf "$work/bundle-check"
log "    $bundle_name holds the approved commit $bundle_commit with its signature"

gpg_key_b64="$(base64 -w0 <"$work/key.gpg")"
sed_escape() { printf '%s' "$1" | sed 's/[\\|&]/\\&/g'; }
found_template=0
for path in "$templates"/* "$templates"/.[!.]* "$templates"/..?*; do
	[ -e "$path" ] || [ -L "$path" ] || continue
	name="${path##*/}"
	[ ! -e "$site/$name" ] && [ ! -L "$site/$name" ] ||
		die "the template or page $name has the name of a file of the repository or the bundle"
	cp -RL "$path" "$site/$name" || die "cannot copy $path"
	case "$name" in
	*.flatpakrepo | *.flatpakref)
		[ -f "$site/$name" ] || die "$name is not a file"
		found_template=1
		sed -e "s|%Url%|$(sed_escape "$url")|g" \
			-e "s|%Homepage%|$(sed_escape "$homepage")|g" \
			-e "s|%GPGKey%|$gpg_key_b64|g" "$site/$name" >"$work/filled"
		cat "$work/filled" >"$site/$name"
		grep -q "^GPGKey=$gpg_key_b64\$" "$site/$name" || die "$name has no GPGKey=%GPGKey% line"
		case "$name" in
		*.flatpakref)
			ref_name="$(sed -n 's/^Name=//p' "$site/$name" | head -n 1)"
			ref_branch="$(sed -n 's/^Branch=//p' "$site/$name" | head -n 1)"
			[ "$ref_name" = "$app_id" ] || die "$name names the app $ref_name, not $app_id"
			[ -z "$ref_branch" ] || [ "$ref_branch" = "$branch" ] || die "$name names the branch $ref_branch, not $branch"
			;;
		esac
		;;
	esac
done
[ "$found_template" = 1 ] || die "$templates holds no .flatpakrepo or .flatpakref template"
[ ! -e "$site/.nojekyll" ] || die "the repository or the templates already hold .nojekyll"
: >"$site/.nojekyll"

# ---------------------------------------------------------------------------
step "Checking that no file of the repository changed"
hash_tree >"$work/after"
changed="$(LC_ALL=C comm -23 "$work/before" "$work/after")"
if [ -n "$changed" ]; then
	log "files that changed or disappeared after the signature check:"
	printf '%s\n' "$changed" | sed 's/^[0-9a-f]*  /    /' >&2
	die "the finalize steps changed signed or recorded files"
fi
log "    all $(grep -c . "$work/before") recorded files are unchanged; $(($(grep -c . "$work/after") - $(grep -c . "$work/before"))) files added"

mv "$site" "$out" || die "cannot move the result to $out"
log ""
log "Flatpak repository ready in $out ($((SECONDS - started)) s)."
