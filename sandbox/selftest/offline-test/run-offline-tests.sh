#!/usr/bin/env bash
# Offline tests for the release scripts: verify-release.sh, build-manifest.sh,
# init-secrets.sh, finalize-release.sh, sign-release.sh, and the local steps
# (apple.sh, flatpak.sh, the Homebrew generator). No network: a fake gh answers the
# GitHub calls, and a local bare repository stands in for the git remote. All
# keys are throwaway keys in a temp directory.
# The test repository is a git repository in the temp directory, because the
# signing script runs only from a clean git checkout.
#
# Usage: run-offline-tests.sh [SCRIPTS_DIR]
#   SCRIPTS_DIR defaults to the dev-scripts/release directory of the worktree.
# Set KEEP=1 to keep the temp directory. Set SHOW=1 to show the error output.
#
# Runs on Linux and on macOS (bash 3.2 and the BSD tools). A test that needs a
# tool or fixture that this host does not have is skipped, with the reason;
# the last line gives the totals. Fixture locations, for a host without the
# module test runs:
#   APPLE_TOOLS_PATH    "dir:dir:" with rcodesign (and xpwn on Linux)
#   APPLE_FIXTURE_DIR   testapp_aarch64.app.unsigned.tar and
#                       testapp_0.0.1_aarch64.unsigned.dmg
#   FLATPAK_FIXTURE_DIR flatpak-to-sign.tar and flatpak-repo.tar
#   TAURI_KEYS_DIR      tauri1.key(.pub) (password "test-password") and
#                       tauri2.key(.pub) (no password), instead of cargo-tauri

# Test code: ls on known names, A && B || C with pass/fail, a literal "~" input,
# shell code in single quotes for eval and awk.
# shellcheck disable=SC2012,SC2015,SC2016,SC2088,SC2154

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${1:-$HERE/../../../worktrees/release-split/dev-scripts/release}"
SCRIPTS="$(cd "$SCRIPTS" && pwd)"
# shellcheck source=/dev/null
[ ! -f "$HERE/../toolenv.sh" ] || . "$HERE/../toolenv.sh"
HOST_OS="$(uname -s)"
# sha256 [ARGS]: sha256sum, or shasum -a 256 where there is no sha256sum.
sha256() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
# mode_of PATH: the permission bits as octal digits (GNU and BSD stat).
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
# b64 [FILE]: base64 on one line.
b64() { if [ $# -gt 0 ]; then base64 <"$1"; else base64; fi | tr -d '\n'; }
# The Apple tools of the local-steps test (rcodesign, xpwn), resolved with the
# real HOME before the test replaces it. Set APPLE_TOOLS_PATH ("dir:dir:") to
# skip the lookup.
if [ -z "${APPLE_TOOLS_PATH+set}" ] && [ "$HOST_OS" = Linux ] && command -v nix >/dev/null 2>&1; then
	APPLE_TOOLS_PATH="$(timeout 300 nix shell nixpkgs#rcodesign nixpkgs#xpwn -c sh -c \
		'dirname "$(command -v rcodesign)"; dirname "$(command -v dmg)"' 2>/dev/null | tr '\n' ':')" || APPLE_TOOLS_PATH=""
fi

T="$(mktemp -d)"
export GNUPGHOME="$T/gnupg"
mkdir -m 700 "$GNUPGHOME"
export HOME="$T/home"
mkdir -p "$HOME"
unset XDG_CONFIG_HOME RELEASE_SIGNING_KEY RELEASE_SECRETS_FILE GITHUB_OUTPUT GITHUB_REF GITHUB_SHA RELEASE_CONFIG
export GIT_CEILING_DIRECTORIES="$T" GIT_CONFIG_NOSYSTEM=1
cleanup() {
	gpgconf --kill all >/dev/null 2>&1 || true
	if [ "${KEEP:-0}" = 1 ]; then
		echo "kept: $T"
	else
		rm -rf "$T"
	fi
}
trap cleanup EXIT

PASSED=0
FAILED=0
SKIPPED=0
FAILURES=""
SKIPS=""
pass() {
	PASSED=$((PASSED + 1))
	printf 'PASS  %s\n' "$1"
}
# skip NAME REASON: a test that cannot run on this host.
skip() {
	SKIPPED=$((SKIPPED + 1))
	SKIPS="$SKIPS$1 ($2)"$'\n'
	printf 'SKIP  %s (%s)\n' "$1" "$2"
}
fail() {
	FAILED=$((FAILED + 1))
	FAILURES="$FAILURES$1"$'\n'
	printf 'FAIL  %s\n' "$1"
	printf '%s\n' "$2" | sed 's/^/      | /'
}

# ---------------------------------------------------------------------------
# Fixture: repository root, keys, configuration
# ---------------------------------------------------------------------------
REPO="$T/repo"
mkdir -p "$REPO/dev-scripts/release" "$REPO/keys"
cp "$SCRIPTS"/*.sh "$REPO/dev-scripts/release/"

TAG="v1.2.3"
HEAD_SHA="abababababababababababababababababababab"
RUN_ID="987654321"
GH_REPO="example-owner/example-repo"
TAURI_PW="test-password"

# The GitHub repository, as git sees it: a bare repository that git reaches
# through url.<file>.insteadOf. COMMIT is the release commit, LATER_COMMIT a
# later commit on the same branch. The fake gh reads and writes the tags of
# this repository.
REMOTE="$T/remote.git"
git init -q --bare "$REMOTE"
git -C "$REMOTE" config uploadpack.allowAnySHA1InWant true
git init -q "$T/remote-src"
remote_commit() { # FILE MESSAGE
	printf '%s\n' "$2" >"$T/remote-src/$1"
	git -C "$T/remote-src" add -A
	git -C "$T/remote-src" -c user.name=dev -c user.email=dev@example.invalid -c commit.gpgsign=false commit -q -m "$2"
	git -C "$T/remote-src" rev-parse HEAD
}
COMMIT="$(remote_commit release "Release 1.2.3")"
LATER_COMMIT="$(remote_commit later "Later work")"
git -C "$T/remote-src" push -q "$REMOTE" HEAD:refs/heads/main
git config --global url."file://$REMOTE".insteadOf "https://github.com/$GH_REPO.git"
export FAKE_GH_REMOTE="$REMOTE"
remote_tag() { # TAG: the object that refs/tags/TAG names in the remote, or nothing
	git --git-dir="$REMOTE" rev-parse -q --verify "refs/tags/$1" 2>/dev/null || true
}

CFG="$REPO/dev-scripts/release/config.json"
cat >"$CFG" <<EOF
{
  "repository": "$GH_REPO",
  "build_workflow": "build.yml",
  "build_event": "workflow_dispatch",
  "finalize_workflow": "finalize.yml",
  "artifact_pattern": "release-*",
  "ci_artifact_pattern": "ci-*",
  "signer_keys_dir": "keys",
  "allowed_signers": "dev-scripts/release/allowed-signers.txt",
  "updater": {
    "pubkey_file": "tauri.conf.json",
    "pubkey_jq": ".plugins.updater.pubkey",
    "version_file": "tauri.conf.json",
    "version_jq": ".version"
  },
  "products": [
    {"name": "sample_{version}_amd64.AppImage", "origin": "build", "updater": ["linux-x86_64", "linux-x86_64-appimage"]},
    {"name": "sample_{version}_amd64.deb", "origin": "build", "updater": ["linux-x86_64-deb"]},
    {"name": "sample_{version}_x64-setup.exe", "origin": "build", "updater": ["windows-x86_64", "windows-x86_64-nsis"]},
    {"name": "tool_{version}_Linux_x86_64.tar", "origin": "build"},
    {"name": "sample_aarch64.app.unsigned.tar", "origin": "input"},
    {"name": "sample_{version}_aarch64.unsigned.dmg", "origin": "input"},
    {"name": "sample-repo.tar", "origin": "ci"},
    {"name": "sample_aarch64.app.tar.gz", "origin": "local", "updater": ["darwin-aarch64", "darwin-aarch64-app"]},
    {"name": "sample_{version}_aarch64.dmg", "origin": "local"}
  ]
}
EOF

echo "setting up throwaway keys ..."
genkey() { # NAME [gpg options before the command] -> prints fingerprint
	local name="$1"
	shift
	gpg --batch --quiet --pinentry-mode loopback --passphrase '' "$@" \
		--quick-gen-key "$name <$name@example.invalid>" default default "${EXPIRE:-0}" >/dev/null 2>&1
	gpg --batch --with-colons --list-keys "<$name@example.invalid>" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }'
}
FPR_A="$(genkey signer-a)"                                                    # allowed
FPR_B="$(genkey signer-b)"                                                    # in keys dir, not allowed
FPR_C="$(genkey signer-c)"                                                    # unknown
FPR_E="$(EXPIRE=1d genkey signer-e --faked-system-time 20200101T000000!)"     # allowed, expired
for k in A B E; do
	eval "fpr=\$FPR_$k"
	gpg --batch --armor --export "$fpr" >"$REPO/keys/signer-$k.asc"
done
cat >"$REPO/dev-scripts/release/allowed-signers.txt" <<EOF
# test allowlist
$FPR_A
$(printf '%s' "$FPR_E" | tr 'A-F' 'a-f')  # lower case on purpose
EOF

# Updater keys: KEY1 is the app key (with a password), KEY2 is another key.
if [ -n "${TAURI_KEYS_DIR:-}" ]; then
	cp "$TAURI_KEYS_DIR"/tauri1.key "$TAURI_KEYS_DIR"/tauri1.key.pub "$TAURI_KEYS_DIR"/tauri2.key "$TAURI_KEYS_DIR"/tauri2.key.pub "$T/"
else
	cargo-tauri signer generate --ci -p "$TAURI_PW" -w "$T/tauri1.key" </dev/null >/dev/null 2>&1
	cargo-tauri signer generate --ci -w "$T/tauri2.key" </dev/null >/dev/null 2>&1
fi
jq -n --arg pk "$(cat "$T/tauri1.key.pub")" '{version: "1.2.3", plugins: {updater: {pubkey: $pk}}}' >"$REPO/tauri.conf.json"

# The test repository is a clean git checkout.
git_commit() { # MESSAGE
	git -C "$REPO" add -A
	git -C "$REPO" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false commit -q -m "$1"
}
git -C "$REPO" init -q
git_commit "test repository"

# ---------------------------------------------------------------------------
# Release directory builder (independent of lib.sh). The product names come
# from the test configuration.
# ---------------------------------------------------------------------------
prod() { # ORIGIN [VERSION]: the product names with this origin
	jq -r --arg o "$1" --arg v "${2:-${TAG#v}}" '.products[] | select(.origin == $o) | .name | gsub("\\{version\\}"; $v)' "$CFG"
}
upd() { # [VERSION]: one line "name platform..." per updater product
	jq -r --arg v "${1:-${TAG#v}}" '.products[] | select(.updater) | [(.name | gsub("\\{version\\}"; $v))] + .updater | join(" ")' "$CFG"
}
AI=sample_1.2.3_amd64.AppImage
DMG=sample_1.2.3_aarch64.dmg
APPTGZ=sample_aarch64.app.tar.gz
INPUT_DMG=sample_1.2.3_aarch64.unsigned.dmg
INPUT_APP=sample_aarch64.app.unsigned.tar
CI_FILE=sample-repo.tar
BUILD_FILES="$(prod build | tr '\n' ' ')"
INPUT_FILES="$(prod input | tr '\n' ' ')"
WORKFLOW_REF="$GH_REPO/.github/workflows/build.yml@refs/heads/main"

write_info() { # DIR REPO TAG COMMIT RUN_ID [ATTEMPT]
	jq -n --arg r "$2" --arg t "$3" --arg c "$4" --argjson id "$5" --argjson a "${6:-1}" --arg w "$WORKFLOW_REF" \
		'{repository: $r, tag: $t, commit: $c, run_id: $id, run_attempt: $a, workflow_ref: $w}' >"$1/release-build-info.json"
}
# msign FILE [KEYFILE] [PASSWORD] [VERSION] [FILE_NAME_IN_COMMENT]: an updater
# signature made with minisign, in the format of the Tauri CLI with --app-version.
msign() {
	local f="$1" key pw="${3-$TAURI_PW}" v="${4-${TAG#v}}" n="${5-${1##*/}}"
	key="$(cat "${2:-$T/tauri1.key}")"
	rm -f "$f.sig" "$T/raw.minisig"
	printf '%s\n' "$pw" | minisign -S -s <(printf '%s' "$key" | base64 --decode) -m "$f" -x "$T/raw.minisig" \
		-t "$(printf 'timestamp:%s\tfile:%s\tversion:%s' 1700000000 "$n" "$v")" -c "signature from tauri secret key" >/dev/null 2>&1
	b64 "$T/raw.minisig" >"$f.sig"
}
# tauri_cli_sign FILE: an updater signature from the Tauri CLI 2.11.4, which
# writes no version field.
tauri_cli_sign() {
	rm -f "$1.sig"
	TAURI_SIGNING_PRIVATE_KEY="$(cat "$T/tauri1.key")" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$TAURI_PW" \
		cargo-tauri signer sign "$1" </dev/null >/dev/null 2>&1
}
updater_sigs() { # DIR [VERSION]
	local dir="$1" v="${2-${TAG#v}}" n rest
	while read -r n rest; do
		msign "$dir/$n" "" "$TAURI_PW" "$v"
	done < <(upd "$v")
}
write_latest() { # DIR [TAG]
	local dir="$1" tag="${2:-$TAG}" n rest p
	jq -n --arg v "${tag#v}" '{version: $v, notes: "", pub_date: "2026-01-01T00:00:00Z", platforms: {}}' >"$dir/latest.json"
	while read -r n rest; do
		for p in $rest; do
			jq --arg p "$p" --arg url "https://github.com/$GH_REPO/releases/download/$tag/$n" \
				--rawfile sig "$dir/$n.sig" '.platforms[$p] = {signature: $sig, url: $url}' "$dir/latest.json" >"$dir/latest.tmp"
			mv "$dir/latest.tmp" "$dir/latest.json"
		done
	done < <(upd "${tag#v}")
}
pgp_sign() { # FILE [KEY] [gpg options]
	local file="$1" key="${2:-$FPR_A}"
	shift 2 || shift $#
	gpg --batch --yes --local-user "$key" "$@" --armor --detach-sign --output "$file.asc" "$file" </dev/null 2>/dev/null
}
pgp_all() { # DIR
	local f
	for f in "$1"/*; do
		case "$f" in
		*.asc | *.sig | */SHA256SUMS) continue ;;
		esac
		pgp_sign "$f"
	done
}
remanifest() { # DIR [KEY] [gpg options]: new SHA256SUMS and SHA256SUMS.asc
	local dir="$1"
	shift
	rm -f "$dir/SHA256SUMS" "$dir/SHA256SUMS.asc"
	(cd "$dir" && LC_ALL=C ls | LC_ALL=C sort | while IFS= read -r n; do sha256 "$n"; done) >"$T/sums.tmp"
	mv "$T/sums.tmp" "$dir/SHA256SUMS"
	pgp_sign "$dir/SHA256SUMS" "$@"
}
resign() { # DIR: all PGP signatures and the manifest again
	rm -f "$1"/*.asc "$1/SHA256SUMS"
	pgp_all "$1"
	remanifest "$1"
}
# make_release DIR [TAG]: a complete, good release: the build and local
# products, the build info, the updater signatures, latest.json, the PGP
# signatures, and the signed manifest.
make_release() {
	local dir="$1" tag="${2:-$TAG}" n
	mkdir -p "$dir"
	for n in $(prod build "${tag#v}") $(prod local "${tag#v}"); do
		printf 'content of %s\n' "$n" >"$dir/$n"
	done
	write_info "$dir" "$GH_REPO" "$tag" "$COMMIT" "$RUN_ID"
	updater_sigs "$dir" "${tag#v}"
	write_latest "$dir" "$tag"
	resign "$dir"
}

GOOD="$T/good"
make_release "$GOOD"

N=0
variant() { # sets d to the path of a fresh copy of the good release
	N=$((N + 1))
	d="$T/case$N"
	cp -a "$GOOD" "$d"
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
OUT=""
RC=0
run() {
	RC=0
	OUT="$("$@" 2>&1 </dev/null)" || RC=$?
}
verify() { # DIR [extra args]
	local dir="$1"
	shift
	run "$REPO/dev-scripts/release/verify-release.sh" --dir "$dir" --repo "$GH_REPO" --tag "$TAG" \
		--commit "$COMMIT" --run-id "$RUN_ID" --repo-root "$REPO" "$@"
}
expect_ok() { # NAME
	if [ "$RC" = 0 ]; then pass "$1"; else fail "$1" "expected success, got rc=$RC:"$'\n'"$OUT"; fi
}
expect_err() { # NAME SUBSTRING...
	local name="$1" s
	shift
	if [ "$RC" = 0 ]; then
		fail "$name" "expected failure, got success:"$'\n'"$OUT"
		return
	fi
	for s in "$@"; do
		if ! printf '%s' "$OUT" | grep -qF -- "$s"; then
			fail "$name" "failed (rc=$RC), but the message lacks '$s':"$'\n'"$OUT"
			return
		fi
	done
	pass "$name"
	[ "${SHOW:-0}" = 0 ] || printf '%s\n' "$OUT" | sed 's/^/      > /'
}

echo
echo "== verify-release.sh"

verify "$GOOD"
expect_ok "good release passes"

variant
rm "$d/sample_1.2.3_amd64.deb.asc"
remanifest "$d"
verify "$d"
expect_err "missing .asc" "does not hold exactly the files" "missing: sample_1.2.3_amd64.deb.asc"

variant
pgp_sign "$d/sample_1.2.3_amd64.deb" "$FPR_B"
remanifest "$d"
verify "$d"
expect_err ".asc from a key in the keys dir but not allowed" "signed by $FPR_B, which is not an allowed signer"

variant
remanifest "$d" "$FPR_C"
verify "$d"
expect_err "SHA256SUMS.asc from an unknown key" "SHA256SUMS.asc: an unknown key signed it" "is not in the signer keys directory" "no single good signature in SHA256SUMS.asc" "SHA256SUMS has no good signature"

variant
printf 'x' >>"$d/tool_1.2.3_Linux_x86_64.tar"
verify "$d"
expect_err "file changed after signing" "hash mismatch for tool_1.2.3_Linux_x86_64.tar"

variant
printf 'extra\n' >"$d/extra.bin"
verify "$d"
expect_err "extra file" "files that the manifest does not list: extra.bin"

# C order puts "Z.bin" first; en_US.UTF-8 puts it last. The check must still
# report the extra file.
variant
printf 'extra\n' >"$d/Z.bin"
LC_ALL=en_US.UTF-8 verify "$d"
expect_err "extra file, user locale" "files that the manifest does not list: Z.bin"

variant
rm "$d/tool_1.2.3_Linux_x86_64.tar"
verify "$d"
expect_err "listed file missing" "files that the manifest lists but that are missing: tool_1.2.3_Linux_x86_64.tar"

variant
msign "$d/$AI" "$T/tauri2.key" ""
write_latest "$d"
resign "$d"
verify "$d"
expect_err "updater .sig from another minisign key" "$AI.sig: minisign rejects it" "the updater signature $AI.sig of $AI is not valid for the updater public key of the app"

variant
rm "$d/sample_1.2.3_amd64.deb.sig"
resign "$d"
verify "$d"
expect_err "missing updater .sig" "missing: sample_1.2.3_amd64.deb.sig"

variant
pgp_sign "$d/$DMG" "$FPR_E" --faked-system-time 20200101T120000!
remanifest "$d"
if gpg --batch --status-fd 1 --verify "$d/$DMG.asc" "$d/$DMG" 2>/dev/null | grep -q EXPKEYSIG; then
	verify "$d"
	expect_err "expired signer key" "no single good signature in $DMG.asc" "$DMG has no good signature"
else
	fail "expired signer key" "fixture problem: the test signature does not show EXPKEYSIG"
fi

variant
gpg --batch --yes --local-user "$FPR_A" --local-user "$FPR_B" --armor --detach-sign \
	--output "$d/$DMG.asc" "$d/$DMG" 2>/dev/null
remanifest "$d"
verify "$d"
expect_err ".asc with two signatures" "no single good signature in $DMG.asc"

variant
cat "$GOOD/tool_1.2.3_Linux_x86_64.tar.asc" "$GOOD/$DMG.asc" >"$d/$DMG.asc.new"
mv "$d/$DMG.asc.new" "$d/$DMG.asc"
remanifest "$d"
verify "$d"
expect_err ".asc with two concatenated armored signatures" "$DMG has no good signature"

for what in tag commit run_id repository; do
	variant
	case "$what" in
	tag) write_info "$d" "$GH_REPO" "v9.9.9" "$COMMIT" "$RUN_ID"; want="tag is v9.9.9" ;;
	commit) write_info "$d" "$GH_REPO" "$TAG" "fedcba9876543210fedcba9876543210fedcba98" "$RUN_ID"; want="commit is fedcba98" ;;
	run_id) write_info "$d" "$GH_REPO" "$TAG" "$COMMIT" 1; want="build run is 1" ;;
	repository) write_info "$d" "other/repo" "$TAG" "$COMMIT" "$RUN_ID"; want="repository is other/repo" ;;
	esac
	resign "$d"
	verify "$d"
	expect_err "build info with another $what" "release-build-info.json does not match this release: $want"
done

# Fix 10: the build info is exactly one object with every field and its type.
for what in empty whitespace two-objects array attempt-string run-id-float missing-field extra-field short-commit other-workflow; do
	variant
	info="$d/release-build-info.json"
	case "$what" in
	empty) : >"$info" ;;
	whitespace) printf '  \n\n' >"$info" ;;
	two-objects) cp "$info" "$T/i" && cat "$T/i" "$T/i" >"$info" ;;
	array) jq -c '[.]' "$info" >"$T/i" && mv "$T/i" "$info" ;;
	attempt-string) jq '.run_attempt = "1"' "$info" >"$T/i" && mv "$T/i" "$info" ;;
	run-id-float) jq ".run_id = $RUN_ID.5" "$info" >"$T/i" && mv "$T/i" "$info" ;;
	missing-field) jq 'del(.workflow_ref)' "$info" >"$T/i" && mv "$T/i" "$info" ;;
	extra-field) jq '.note = "x"' "$info" >"$T/i" && mv "$T/i" "$info" ;;
	short-commit) jq '.commit = "0123456"' "$info" >"$T/i" && mv "$T/i" "$info" ;;
	other-workflow) jq --arg w "$GH_REPO/.github/workflows/other.yml@refs/heads/main" '.workflow_ref = $w' "$info" >"$T/i" && mv "$T/i" "$info" ;;
	esac
	resign "$d"
	verify "$d"
	if [ "$what" = other-workflow ]; then
		expect_err "build info: $what" "release-build-info.json does not match this release: workflow is $GH_REPO/.github/workflows/other.yml"
	else
		expect_err "build info: $what" "release-build-info.json is not one JSON object with exactly the fields"
	fi
done

variant
jq --rawfile s "$d/sample_1.2.3_amd64.deb.sig" '.platforms["linux-x86_64"].signature = $s' "$d/latest.json" >"$d/l" && mv "$d/l" "$d/latest.json"
resign "$d"
verify "$d"
expect_err "latest.json with a wrong signature" "latest.json has a wrong entry for linux-x86_64"

variant
jq '.platforms["windows-x86_64"].url = "https://example.invalid/sample_1.2.3_x64-setup.exe"' "$d/latest.json" >"$d/l" && mv "$d/l" "$d/latest.json"
resign "$d"
verify "$d"
expect_err "latest.json with a wrong URL" "latest.json has a wrong entry for windows-x86_64"

variant
jq '.platforms["darwin-x86_64"] = .platforms["darwin-aarch64"]' "$d/latest.json" >"$d/l" && mv "$d/l" "$d/latest.json"
resign "$d"
verify "$d"
expect_err "latest.json with an extra platform" "latest.json does not list exactly the updater platforms"

variant
jq 'del(.platforms["darwin-aarch64-app"])' "$d/latest.json" >"$d/l" && mv "$d/l" "$d/latest.json"
resign "$d"
verify "$d"
expect_err "latest.json without a configured platform" "latest.json has a wrong entry for darwin-aarch64-app"

variant
jq '.version = "9.9.9"' "$d/latest.json" >"$d/l" && mv "$d/l" "$d/latest.json"
resign "$d"
verify "$d"
expect_err "latest.json with a wrong version" "latest.json has the wrong version: 9.9.9, but the release version is 1.2.3"

variant
cp "$d/SHA256SUMS" "$d/s"
printf '%s  ../x\n' "$(sha256 "$d/tool_1.2.3_Linux_x86_64.tar" | cut -d' ' -f1)" >>"$d/s"
mv "$d/s" "$d/SHA256SUMS"
pgp_sign "$d/SHA256SUMS"
verify "$d"
expect_err "manifest line with ../x" "line is not '<sha256>  <name>': "

variant
printf 'nothing\n' >"$T/nothing.bin"
pgp_sign "$T/nothing.bin"
mv "$T/nothing.bin.asc" "$d/nothing.bin.asc"
remanifest "$d"
verify "$d"
expect_err "orphan .asc" "not expected: nothing.bin.asc"

variant
cp "$d/sample_1.2.3_amd64.deb.sig" "$d/ghost_amd64.AppImage.sig"
remanifest "$d"
verify "$d"
expect_err "orphan .sig" "not expected: ghost_amd64.AppImage.sig"

variant
cp "$d/sample_1.2.3_amd64.deb.sig" "$d/tool_1.2.3_Linux_x86_64.tar.sig"
remanifest "$d"
verify "$d"
expect_err ".sig for a file that is not an updater file" "not expected: tool_1.2.3_Linux_x86_64.tar.sig"

variant
pgp_sign "$d/sample_1.2.3_amd64.deb.sig"
remanifest "$d"
verify "$d"
expect_err ".asc on a signature file" "not expected: sample_1.2.3_amd64.deb.sig.asc"

variant
rm "$d/SHA256SUMS.asc"
verify "$d"
expect_err "missing SHA256SUMS.asc" "SHA256SUMS has no good signature"

verify "$GOOD" --repo "bad repo"
expect_err "bad --repo argument" "repository is not OWNER/NAME"

# Fix 2: the release is exactly the configured product set.
variant
rm "$d/tool_1.2.3_Linux_x86_64.tar" "$d/tool_1.2.3_Linux_x86_64.tar.asc"
remanifest "$d"
verify "$d"
expect_err "products: a build product is missing" "missing: tool_1.2.3_Linux_x86_64.tar" "missing: tool_1.2.3_Linux_x86_64.tar.asc"

variant
rm "$d/$DMG" "$d/$DMG.asc"
remanifest "$d"
verify "$d"
expect_err "products: a local product is missing" "missing: $DMG"

variant
printf 'repo\n' >"$d/$CI_FILE"
pgp_sign "$d/$CI_FILE"
remanifest "$d"
verify "$d"
expect_err "products: a ci product in the release" "not expected: $CI_FILE (a product with origin ci, never released)"

variant
printf 'unsigned\n' >"$d/$INPUT_DMG"
pgp_sign "$d/$INPUT_DMG"
remanifest "$d"
verify "$d"
expect_err "products: an unsigned input file in the release" "$INPUT_DMG is an unsigned file. A release never holds one."

variant
printf 'x\n' >"$d/extra_1.2.3.zip"
pgp_sign "$d/extra_1.2.3.zip"
remanifest "$d"
verify "$d"
expect_err "products: an extra regular download" "not expected: extra_1.2.3.zip" "not expected: extra_1.2.3.zip.asc"

# Without any updater file, the verifier must still require them.
variant
while read -r n _; do rm -f "$d/$n" "$d/$n.sig" "$d/$n.asc"; done < <(upd)
rm -f "$d/latest.json" "$d/latest.json.asc"
remanifest "$d"
verify "$d"
expect_err "products: no updater file at all" "missing: $AI" "missing: $AI.sig" "missing: $APPTGZ.sig" "missing: latest.json"

variant
printf 'x\n' >"$d/trailing."
verify "$d"
expect_err "file name with a trailing period" "file name is not allowed: trailing."

# Updater signatures: each case signs with the right key, and makes the PGP
# signatures and the manifest again, so that only the trusted comment check
# can catch the problem.
variant
msign "$d/$AI" "" "$TAURI_PW" "9.9.9"
write_latest "$d"
resign "$d"
verify "$d"
expect_err ".sig with another version in the trusted comment" "$AI.sig: the trusted comment names the version 9.9.9, but the release version is 1.2.3"

variant
msign "$d/$AI" "" "$TAURI_PW" "1.2.3" "other_1.2.3_amd64.AppImage"
write_latest "$d"
resign "$d"
verify "$d"
expect_err ".sig whose trusted comment names another file" "$AI.sig: the trusted comment names the file other_1.2.3_amd64.AppImage, not $AI"

variant
if ! command -v cargo-tauri >/dev/null 2>&1; then
	skip ".sig without a version field (Tauri CLI 2.11.4)" "needs the Tauri CLI (cargo-tauri), which this host does not have"
else
tauri_cli_sign "$d/$AI"
write_latest "$d"
resign "$d"
if base64 --decode <"$d/$AI.sig" | grep -q '^trusted comment: timestamp:[0-9]*	file:'"$AI"'$'; then
	verify "$d"
	expect_err ".sig without a version field (Tauri CLI 2.11.4)" "$AI.sig: the trusted comment has no version field"
else
	fail ".sig without a version field (Tauri CLI 2.11.4)" "fixture problem: unexpected Tauri CLI signature: $(base64 --decode <"$d/$AI.sig")"
fi
fi

variant
base64 --decode <"$d/$AI.sig" | sed 's/	version:1\.2\.3$/	version:1.2.4/' >"$T/changed.minisig"
if grep -q 'version:1.2.4$' "$T/changed.minisig"; then
	b64 "$T/changed.minisig" >"$d/$AI.sig"
	write_latest "$d"
	resign "$d"
	verify "$d"
	expect_err ".sig whose trusted comment changed after signing" "$AI.sig: minisign rejects it for $AI" "Comment signature verification failed" "the updater signature $AI.sig of $AI is not valid"
else
	fail ".sig whose trusted comment changed after signing" "fixture problem: no version field to change"
fi

variant
printf 'not base64 at all!\n' >"$d/$AI.sig"
write_latest "$d"
resign "$d"
verify "$d"
expect_err ".sig that is not base64" "$AI.sig is not valid base64"

# Tags: the release version is the tag without one leading "v".
NOV="$T/tag-without-v"
cp -a "$GOOD" "$NOV"
write_info "$NOV" "$GH_REPO" "1.2.3" "$COMMIT" "$RUN_ID"
write_latest "$NOV" "1.2.3"
resign "$NOV"
verify "$NOV" --tag 1.2.3
expect_ok "tag without a leading v (1.2.3)"
verify "$GOOD" --tag v1.2.3
expect_ok "tag with a leading v (v1.2.3)"

for bad in v1.2 vv1.2.3 v1.2.3.4 v01.2.3 release-1.2.3; do
	verify "$GOOD" --tag "$bad"
	expect_err "tag that is not a semantic version: $bad" "tag $bad does not name a release version" "is not a semantic version"
done

# The product names take the version, so a pre-release has its own names.
PRE="$T/pre-release"
make_release "$PRE" "v1.2.3-rc.1+build.5"
verify "$PRE" --tag "v1.2.3-rc.1+build.5"
expect_ok "pre-release tag with build metadata"
verify "$GOOD" --tag "v1.2.4"
expect_err "release files named for another version" "missing: sample_1.2.4_amd64.AppImage" "not expected: $AI"

# ---------------------------------------------------------------------------
echo
echo "== configuration checks (fix 2, fix 15)"
# cfg_case NAME JQ_FILTER SUBSTRING...: verify-release.sh with a changed
# configuration must fail with the message.
cfg_case() {
	local name="$1" filter="$2"
	shift 2
	jq "$filter" "$CFG" >"$T/cfg-case.json"
	RELEASE_CONFIG="$T/cfg-case.json" verify "$GOOD"
	expect_err "config: $name" "$@"
}
cfg_case "duplicate product name" '.products += [.products[0]]' "sample_{version}_amd64.AppImage: the name occurs more than once"
cfg_case "updater platform of two products" '.products[1].updater += ["linux-x86_64"]' "the updater platform linux-x86_64 belongs to more than one product"
cfg_case "unknown origin" '.products[0].origin = "built"' "products[0].origin must be build, input, ci, or local"
cfg_case "old updater.targets" '.updater.targets = []' "updater.targets is no longer used"
cfg_case "unsigned released name" '.products[3].name = "tool.unsigned.tar"' "tool.unsigned.tar: a released file cannot have .unsigned. in its name"
cfg_case "trailing period" '.products[3].name = "tool_{version}."' "tool_{version}.: not a valid release file name"
cfg_case "reserved temp name" '.products[3].name = "SHA256SUMS.tmp"' "SHA256SUMS.tmp: the pipeline reserves this name"
cfg_case "reserved minisign temp name" '.products[3].name = "tool.tar.sig.minisig"' "tool.tar.sig.minisig: the pipeline reserves this name"
cfg_case "reserved latest.json" '.products[3].name = "latest.json"' "latest.json: the pipeline reserves this name"
cfg_case "other placeholder" '.products[3].name = "tool_{ver}.tar"' "tool_{ver}.tar: {version} is the only placeholder"
cfg_case "updater on an input product" '.products[4].updater = ["x"]' "products[4] has the origin input. It is never released"
cfg_case "updater is not a list" '.products[0].updater = "linux-x86_64"' "products[0].updater must be a nonempty list"
cfg_case "unknown product key" '.products[0].pattern = "*"' "products[0] has an unknown key: pattern"
cfg_case "missing ci_artifact_pattern" 'del(.ci_artifact_pattern)' "ci_artifact_pattern must be a nonempty string"
cfg_case "missing build_event" 'del(.build_event)' "build_event must be a nonempty string"
cfg_case "equal artifact patterns" '.ci_artifact_pattern = "release-*"' "artifact_pattern and ci_artifact_pattern must differ"
cfg_case "no products" '.products = []' "products must be a nonempty list"
cfg_case "updater keys missing" 'del(.updater.pubkey_jq)' "updater.pubkey_jq must be a nonempty string"

# ---------------------------------------------------------------------------
echo
echo "== build-manifest.sh"
bm() { # ARTIFACTS OUT
	run env GITHUB_REPOSITORY="$GH_REPO" GITHUB_SHA="$COMMIT" GITHUB_RUN_ID="$RUN_ID" GITHUB_RUN_ATTEMPT=2 \
		GITHUB_WORKFLOW_REF="$WORKFLOW_REF" \
		"$REPO/dev-scripts/release/build-manifest.sh" --artifacts "$1" --out "$2" --tag "$TAG"
}
# bm_artifacts DIR: the complete build output, in two release artifacts and
# one ci artifact.
bm_artifacts() {
	local n
	mkdir -p "$1/release-linux" "$1/release-other" "$1/ci-repo"
	for n in $BUILD_FILES; do printf 'build %s\n' "$n" >"$1/release-linux/$n"; done
	for n in $INPUT_FILES; do printf 'input %s\n' "$n" >"$1/release-other/$n"; done
	printf 'repo\n' >"$1/ci-repo/$CI_FILE"
}
A="$T/bm-good/artifacts"
bm_artifacts "$A"
bm "$A" "$T/bm-good/out"
if [ "$RC" != 0 ]; then
	fail "build manifest: good case" "rc=$RC:"$'\n'"$OUT"
else
	problems=""
	[ "$(LC_ALL=C ls "$T/bm-good/out" | tr '\n' ' ')" = "BUILD-SHA256SUMS release-build-info.json " ] || problems="$problems wrong output files;"
	jq -e --arg r "$GH_REPO" --arg t "$TAG" --arg c "$COMMIT" --argjson id "$RUN_ID" \
		'.repository == $r and .tag == $t and .commit == $c and .run_id == $id and .run_attempt == 2 and (.workflow_ref | endswith("@refs/heads/main"))' \
		"$T/bm-good/out/release-build-info.json" >/dev/null || problems="$problems wrong build info;"
	mkdir -p "$T/bm-good/check"
	cp "$A"/*/* "$T/bm-good/out/release-build-info.json" "$T/bm-good/check/"
	(cd "$T/bm-good/check" && sha256 -c "$T/bm-good/out/BUILD-SHA256SUMS") >/dev/null 2>&1 || problems="$problems hashes do not match;"
	[ "$(wc -l <"$T/bm-good/out/BUILD-SHA256SUMS" | tr -d ' ')" = 8 ] || problems="$problems manifest does not list 8 files (4 build, 2 input, 1 ci, info);"
	grep -q " $CI_FILE\$" "$T/bm-good/out/BUILD-SHA256SUMS" || problems="$problems ci product not listed;"
	[ -f "$A/release-linux/$AI" ] || problems="$problems the artifacts directory changed;"
	if [ -z "$problems" ]; then pass "build manifest: good case (build, input, and ci products)"; else fail "build manifest: good case" "$problems"$'\n'"$OUT"; fi
fi

bm "$A" "$T/bm-good/out"
expect_err "build manifest: refuses to replace output" "exists already"

bm_case() { # NAME SETUP_COMMAND SUBSTRING...: SETUP_COMMAND changes the artifacts in $A
	local name="$1" setup="$2"
	shift 2
	N=$((N + 1))
	A="$T/bm-$N/artifacts"
	bm_artifacts "$A"
	eval "$setup"
	bm "$A" "$T/bm-$N/out"
	expect_err "build manifest: $name" "$@"
}
bm_case ".sig in the build output" 'printf "sig\n" >"$A/release-linux/$AI.sig"' "$AI.sig" "throwaway updater signatures"
bm_case "duplicate name in two artifacts" 'cp "$A/release-linux/$AI" "$A/release-other/$AI"' "two artifacts contain a file named $AI"
bm_case "reserved name latest.json" 'printf "{}\n" >"$A/release-linux/latest.json"' "latest.json" "reserved"
bm_case "missing product" 'rm "$A/release-linux/sample_1.2.3_amd64.deb"' "missing: sample_1.2.3_amd64.deb"
bm_case "missing ci product" 'rm -r "$A/ci-repo"' "missing: $CI_FILE"
bm_case "extra file" 'printf "x\n" >"$A/release-linux/extra.bin"' "not expected: extra.bin"
bm_case "local product in the build" 'printf "x\n" >"$A/release-linux/$DMG"' "not expected: $DMG (a product with origin local: the signer makes it)"
bm_case "ci product in a release artifact" 'mv "$A/ci-repo/$CI_FILE" "$A/release-linux/" && rmdir "$A/ci-repo"' "a product with origin ci. It belongs in an artifact that matches ci-*"
bm_case "build product in a ci artifact" 'mv "$A/release-linux/$AI" "$A/ci-repo/"' "the artifacts that match ci-* hold $AI"
bm_case "artifact that matches no pattern" 'mkdir "$A/other" && printf "x\n" >"$A/other/x"' "the artifact other matches neither release-* nor ci-*"

# ---------------------------------------------------------------------------
echo
echo "== init-secrets.sh"
SECRETS="$HOME/cfg/release-signing/test.json.gpg"
init() { # INPUT [env assignments...]
	local input="$1"
	shift
	RC=0
	OUT="$(printf '%s' "$input" | env RELEASE_SECRETS_FILE="$SECRETS" "$@" \
		"$REPO/dev-scripts/release/init-secrets.sh" --repo "$GH_REPO" --updater 2>&1)" || RC=$?
}

init "$T/tauri1.key"$'\n'"$TAURI_PW"$'\n'
expect_err "init secrets: two allowed secret keys need RELEASE_SIGNING_KEY" "several of your secret keys are on the allowlist"

init "$T/tauri2.key"$'\n'$'\n' RELEASE_SIGNING_KEY="$FPR_A"
expect_err "init secrets: wrong updater key" "this is not the updater key of the app"
[ ! -e "$SECRETS" ] && pass "init secrets: wrong key writes no file" || fail "init secrets: wrong key writes no file" "$SECRETS exists"

init "$T/tauri1.key"$'\n'"wrong"$'\n' RELEASE_SIGNING_KEY="$FPR_A"
expect_err "init secrets: wrong password" "cannot sign with this key and password"

cp "$T/tauri1.key" "$HOME/updater.key"
init "~/updater.key"$'\n'"$TAURI_PW"$'\n' RELEASE_SIGNING_KEY="$FPR_A"
if [ "$RC" != 0 ]; then
	fail "init secrets: good case" "rc=$RC:"$'\n'"$OUT"
else
	problems=""
	json="$(gpg --batch --quiet --decrypt "$SECRETS" 2>/dev/null)" || problems="$problems cannot decrypt;"
	[ "$(printf '%s' "$json" | jq -r .TAURI_SIGNING_PRIVATE_KEY)" = "$(cat "$T/tauri1.key")" ] || problems="$problems wrong key;"
	[ "$(printf '%s' "$json" | jq -r .TAURI_SIGNING_PRIVATE_KEY_PASSWORD)" = "$TAURI_PW" ] || problems="$problems wrong password;"
	[ "$(mode_of "$SECRETS")" = 600 ] || problems="$problems file mode $(mode_of "$SECRETS");"
	[ "$(mode_of "$(dirname "$SECRETS")")" = 700 ] || problems="$problems dir mode;"
	printf '%s' "$OUT" | grep -qF "just sign-release <tag>" || problems="$problems no next step;"
	if [ -z "$problems" ]; then pass "init secrets: good case (~ path, password)"; else fail "init secrets: good case" "$problems"$'\n'"$OUT"; fi
fi

# init-secrets.sh updates an existing file and keeps the previous one.
before="$(sha256 <"$SECRETS")"
init "$T/tauri1.key"$'\n'"$TAURI_PW"$'\n' RELEASE_SIGNING_KEY="$FPR_A"
expect_ok "init secrets: existing file is updated"
backup="$(ls "$SECRETS".backup-* 2>/dev/null | head -n 1)"
[ -n "$backup" ] && [ "$before" = "$(sha256 <"$backup")" ] && pass "init secrets: existing file kept as a backup" ||
	fail "init secrets: existing file kept as a backup" "no backup with the previous content: $(ls "$(dirname "$SECRETS")")"

# Same check with an empty password key: generate an app config for key 2.
SECRETS="$HOME/cfg2/test.json.gpg"
cp "$REPO/tauri.conf.json" "$T/tauri.conf.json.saved"
jq -n --arg pk "$(cat "$T/tauri2.key.pub")" '{version: "1.2.3", plugins: {updater: {pubkey: $pk}}}' >"$REPO/tauri.conf.json"
init "$T/tauri2.key"$'\n' RELEASE_SIGNING_KEY="$FPR_A"
expect_ok "init secrets: key without password, empty answer"
cp "$T/tauri.conf.json.saved" "$REPO/tauri.conf.json"

jq '.products |= map(del(.updater))' "$CFG" >"$T/cfg-empty.json"
RC=0
OUT="$(printf '\n' | RELEASE_CONFIG="$T/cfg-empty.json" RELEASE_SECRETS_FILE="$HOME/none.gpg" "$REPO/dev-scripts/release/init-secrets.sh" 2>&1)" || RC=$?
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qF "Nothing to change." && [ ! -e "$HOME/none.gpg" ]; then
	pass "init secrets: no updater products"
else
	fail "init secrets: no updater products" "rc=$RC: $OUT"
fi

# ---------------------------------------------------------------------------
echo
echo "== finalize-release.sh (with a fake gh, no network)"
# The fake gh keeps one release in $GHS/release.json and its files in
# $GHS/assets. It answers only the calls that the scripts make. Like GitHub,
# the release object never holds the full asset list: the scripts must read
# the paginated assets endpoint, which the fake answers in two pages.
GHS="$T/ghstate"
mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
S="$FAKE_GH_STATE"
printf '%s\n' "$*" >>"$S/calls.log"
sha256() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
jqf="" method="GET" accept="" input="" flags="" fields=() args=()
opt_repo="" opt_name="" opt_dir="" opt_signer_workflow="" opt_source_digest="" opt_source_ref="" opt_format=""
cmd="$1"
shift
case "$cmd" in
release | run | auth | attestation | workflow)
	sub="$1"
	shift
	;;
esac
while [ $# -gt 0 ]; do
	case "$1" in
	--jq) jqf="$2"; shift 2 ;;
	-X) method="$2"; shift 2 ;;
	-H) case "$2" in Accept:*) accept="$2" ;; esac; shift 2 ;;
	-F | -f) fields+=("$2"); shift 2 ;;
	--input) input="$2"; shift 2 ;;
	--paginate | --clobber | --deny-self-hosted-runners) flags="$flags $1"; shift ;;
	--repo | --dir | --pattern | --name | --signer-workflow | --source-digest | --source-ref | --format | --ref)
		v="${1#--}"; printf -v "opt_${v//-/_}" '%s' "$2"; shift 2 ;;
	*) args+=("$1"); shift ;;
	esac
done
# The signing script runs several uploads at the same time. Every call holds
# the lock of the state while it runs. An upload first waits
# FAKE_GH_UPLOAD_DELAY seconds outside the lock (a slow network), and records
# its start and end in $S/upload-trace with the number of running uploads.
lock() { until mkdir "$S/lock.d" 2>/dev/null; do sleep 0.01; done; }
unlock() { rmdir "$S/lock.d"; }
upload_name=""
if [ "$cmd" = api ] && [ "$method" = POST ]; then
	case "${args[0]:-}" in
	https://uploads.github.com/*name=*)
		upload_name="${args[0]##*name=}"
		upload_name="${upload_name//%2B/+}"
		lock
		running=$(( $(cat "$S/uploads_running" 2>/dev/null || echo 0) + 1 ))
		echo "$running" >"$S/uploads_running"
		echo "start $upload_name $running" >>"$S/upload-trace"
		unlock
		sleep "${FAKE_GH_UPLOAD_DELAY:-0}"
		;;
	esac
fi
finish() {
	if [ -n "$upload_name" ]; then
		echo $(( $(cat "$S/uploads_running") - 1 )) >"$S/uploads_running"
		echo "end $upload_name" >>"$S/upload-trace"
	fi
	unlock
}
lock
trap finish EXIT
out() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
# The release object, as GitHub shows it: the embedded asset list is cut short.
release_view() { jq '.assets = []' "$S/release.json"; }
asset_obj() { # ID NAME
	local f="$S/assets/$2"
	if [ -f "$f" ]; then
		jq -n --argjson id "$1" --arg n "$2" --argjson size "$(wc -c <"$f")" --arg d "sha256:$(sha256 "$f" | cut -d' ' -f1)" \
			'{id: $id, name: $n, size: $size, digest: $d, state: "uploaded", url: "x"}'
	else
		jq -n --argjson id "$1" --arg n "$2" '{id: $id, name: $n, size: 0, digest: null, state: "uploaded"}'
	fi
}
all_assets() {
	jq -r '.assets[] | "\(.id) \(.name)"' "$S/release.json" | while read -r id n; do asset_obj "$id" "$n"; done | jq -s .
}
asset_name() { jq -r --argjson id "$1" '.assets[] | select(.id == $id) | .name' "$S/release.json"; }
set_release() { jq "$@" "$S/release.json" >"$S/r.tmp" && mv "$S/r.tmp" "$S/release.json"; }
case "$cmd" in
api)
	path="${args[0]}"
	case "$method $path" in
	"GET repos/"*"/releases?per_page=100") release_view | jq -c '[.]' | out ;;
	"GET repos/"*/releases/assets/*)
		id="${path##*/}"
		name="$(asset_name "$id")"
		[ -n "$name" ] || { echo "fake gh: HTTP 404" >&2; exit 1; }
		if [ "$accept" = "Accept: application/octet-stream" ]; then
			cat "$S/assets/$name"
		else
			asset_obj "$id" "$name" | out
		fi ;;
	"DELETE repos/"*/releases/assets/*)
		id="${path##*/}"
		name="$(asset_name "$id")"
		[ -n "$name" ] || { echo "fake gh: HTTP 404" >&2; exit 1; }
		rm -f "$S/assets/$name"
		set_release --argjson id "$id" '.assets |= map(select(.id != $id))' ;;
	"GET repos/"*/releases/*/assets\?*)
		count=$(( $(cat "$S/list_count" 2>/dev/null || echo 0) + 1 )); echo "$count" >"$S/list_count"
		if [ -s "$S/stray_on_list" ] && [ "$count" = "$(cat "$S/stray_on_list")" ]; then
			printf 'stray\n' >"$S/assets/late.bin"
			id=$(( $(cat "$S/next_id") + 1 )); echo "$id" >"$S/next_id"
			set_release --argjson id "$id" '.assets += [{id: $id, name: "late.bin"}]'
		fi
		# Two pages, like gh api --paginate prints them.
		a="$(all_assets)"
		jq -c '.[:2]' <<<"$a"
		jq -c '.[2:]' <<<"$a" ;;
	"GET repos/"*/releases/*) release_view | out ;;
	"PATCH repos/"*/releases/*)
		[ "${fields[0]}" = "draft=false" ] || exit 9
		set_release '.draft = false'
		[ ! -s "$S/tag_after_publish" ] || cp "$S/tag_after_publish" "$S/tag"
		if [ -s "$S/tamper_on_publish" ]; then
			printf 'tampered\n' >>"$S/assets/$(cat "$S/tamper_on_publish")"
		fi
		release_view | out ;;
	"POST https://uploads.github.com/repos/"*/releases/*/assets\?name=*)
		raw="${path##*name=}"
		case "$raw" in *+*) echo "fake gh: a raw + in the query string" >&2; exit 9 ;; esac
		name="${raw//%2B/+}"
		[ -n "$input" ] && [ -f "$input" ] || { echo "fake gh: upload without --input" >&2; exit 9; }
		if [ -s "$S/fail_upload_at" ] && grep -qxF -- "$name" "$S/fail_upload_at"; then
			echo "fake gh: connection reset during upload of $name" >&2
			exit 1
		fi
		[ "$(jq -r '.draft' "$S/release.json")" = true ] || echo "fake gh: note: upload to a published release" >&2
		if jq -e --arg n "$name" '.assets | any(.name == $n)' "$S/release.json" >/dev/null; then
			echo "fake gh: HTTP 422: already_exists: $name" >&2
			exit 1
		fi
		cp "$input" "$S/assets/$name"
		if [ -s "$S/corrupt_upload" ] && [ "$name" = "$(cat "$S/corrupt_upload")" ]; then
			# Same size, other bytes: only the digest shows it.
			printf 'X' | dd of="$S/assets/$name" bs=1 seek=0 conv=notrunc 2>/dev/null
		fi
		id=$(( $(cat "$S/next_id") + 1 )); echo "$id" >"$S/next_id"
		set_release --arg n "$name" --argjson id "$id" '.assets += [{id: $id, name: $n}]'
		if [ -e "$S/publish_after_upload" ]; then
			rm "$S/publish_after_upload"
			set_release '.draft = false'
		fi
		asset_obj "$id" "$name" | out ;;
	"GET repos/"*/actions/workflows/*/runs\?*)
		sha="${path#*head_sha=}"; sha="${sha%%&*}"
		for f in "$S"/runs/*/run.json; do [ -f "$f" ] && cat "$f"; done |
			jq -s --arg sha "$sha" '{workflow_runs: [.[] | select(.head_sha == $sha and .conclusion == "success")]}' | out ;;
	"GET repos/"*/actions/runs/*/artifacts\?*)
		id="${path#*/actions/runs/}"; id="${id%%/*}"
		[ -d "$S/runs/$id" ] || { echo "fake gh: HTTP 404" >&2; exit 1; }
		(cd "$S/runs/$id/artifacts" && ls) | jq -R . | jq -s '{artifacts: [.[] | {name: .}]}' | out ;;
	"GET repos/"*/actions/runs/*)
		id="${path##*/}"
		[ -f "$S/runs/$id/run.json" ] || { echo "fake gh: HTTP 404" >&2; exit 1; }
		cat "$S/runs/$id/run.json" | out ;;
	"GET repos/"*/contents/*)
		[ "$accept" = "Accept: application/vnd.github.raw+json" ] || exit 9
		file="${path#*/contents/}"; ref="${file#*\?ref=}"; file="${file%%\?*}"
		[ -f "$S/contents/$ref/$file" ] || { echo "fake gh: HTTP 404" >&2; exit 1; }
		cat "$S/contents/$ref/$file" ;;
	"GET repos/"*/compare/*) printf '{"status":"%s"}\n' "$(cat "$S/compare")" | out ;;
	"GET repos/"*/branches/*)
		# The finalize tests set $S/head. The signing tests name their checkout
		# in FAKE_GH_CHECKOUT: its HEAD is the head of the default branch,
		# unless $S/sign_head overrides it.
		if [ -s "$S/sign_head" ]; then head="$(cat "$S/sign_head")"
		elif [ -n "${FAKE_GH_CHECKOUT:-}" ]; then head="$(git -C "$FAKE_GH_CHECKOUT" rev-parse HEAD)"
		else head="$(cat "$S/head")"; fi
		jq -n --arg sha "$head" '{commit: {sha: $sha}}' | out ;;
	"GET repos/"*/commits/*)
		jq -n --arg sha "${path##*/}" '{sha: $sha, commit: {message: "Release 1.2.3\n\nThe release commit.", committer: {date: "2026-01-01T09:00:00Z"}}}' | out ;;
	"GET repos/"*/git/matching-refs/tags/*)
		t="${path##*/matching-refs/tags/}"
		n=$(( $(cat "$S/tagreads" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$S/tagreads"
		if [ -s "$S/move_tag_on_read" ]; then
			read -r at sha <"$S/move_tag_on_read"
			[ "$n" -lt "$at" ] || git --git-dir="$FAKE_GH_REMOTE" update-ref "refs/tags/$t" "$sha"
		fi
		if [ -s "$S/tag" ]; then
			# An override of the test: the tag points to this commit.
			jq -n --arg ref "refs/tags/$t" --arg sha "$(cat "$S/tag")" \
				'[{ref: $ref, object: {type: "commit", sha: $sha}}]' | out
		elif obj="$(git --git-dir="$FAKE_GH_REMOTE" rev-parse -q --verify "refs/tags/$t" 2>/dev/null)"; then
			jq -n --arg ref "refs/tags/$t" --arg sha "$obj" --arg type "$(git --git-dir="$FAKE_GH_REMOTE" cat-file -t "$obj")" \
				'[{ref: $ref, object: {type: $type, sha: $sha}}]' | out
		else
			echo '[]' | out
		fi ;;
	"GET repos/"*/git/tags/*)
		sha="${path##*/}"
		[ "$(git --git-dir="$FAKE_GH_REMOTE" cat-file -t "$sha" 2>/dev/null)" = tag ] || { echo "fake gh: HTTP 404" >&2; exit 1; }
		body="$(git --git-dir="$FAKE_GH_REMOTE" cat-file tag "$sha")"
		jq -n --arg sha "$sha" --arg o "$(sed -n 's/^object //p' <<<"$body" | head -n 1)" --arg t "$(sed -n 's/^type //p' <<<"$body" | head -n 1)" \
			'{sha: $sha, object: {type: $t, sha: $o}}' | out ;;
	"POST repos/"*/git/refs)
		ref="" sha=""
		for f in "${fields[@]}"; do
			case "$f" in ref=*) ref="${f#ref=}" ;; sha=*) sha="${f#sha=}" ;; esac
		done
		[ ! -e "$S/deny_api_tag" ] || { echo "fake gh: HTTP 403: denied by a ruleset" >&2; exit 1; }
		! git --git-dir="$FAKE_GH_REMOTE" rev-parse -q --verify "$ref" >/dev/null 2>&1 ||
			{ echo "fake gh: HTTP 422: Reference already exists" >&2; exit 1; }
		git --git-dir="$FAKE_GH_REMOTE" update-ref "$ref" "$sha" "" || { echo "fake gh: HTTP 422" >&2; exit 1; }
		jq -n --arg ref "$ref" --arg sha "$sha" '{ref: $ref, object: {type: "commit", sha: $sha}}' | out ;;
	"GET repos/"*) jq -n '{default_branch: "main", permissions: {push: true}}' | out ;;
	*) echo "fake gh: unknown api call: $method $path" >&2; exit 9 ;;
	esac ;;
run)
	[ "$sub" = download ] || exit 9
	id="${args[0]}"
	[ -n "$opt_name" ] && [ -n "$opt_dir" ] || { echo "fake gh: run download needs --name and --dir" >&2; exit 9; }
	[ -d "$S/runs/$id/artifacts/$opt_name" ] || { echo "fake gh: no artifact $opt_name in run $id" >&2; exit 1; }
	mkdir -p "$opt_dir"
	cp -R "$S/runs/$id/artifacts/$opt_name/." "$opt_dir/" ;;
release) echo "fake gh: the scripts upload by release id, not with gh release $sub" >&2; exit 9 ;;
auth) [ "$sub" = status ] || exit 9 ;;
attestation)
	[ "$sub" = verify ] || exit 9
	[ "$opt_format" = json ] && [[ "$flags" == *--deny-self-hosted-runners* ]] ||
		{ echo "fake gh: attestation verify needs --format json and --deny-self-hosted-runners" >&2; exit 9; }
	claims="$S/attest/$(sha256 "${args[0]}" | cut -d' ' -f1).json"
	[ -f "$claims" ] || { echo "fake gh: no attestation for ${args[0]}" >&2; exit 1; }
	# Like gh: only attestations that match every policy flag pass.
	jq -e --arg repo "$opt_repo" --arg wf "$opt_signer_workflow" --arg d "$opt_source_digest" --arg ref "$opt_source_ref" \
		'.repo == $repo and .signerWorkflow == $wf and .sourceRepositoryDigest == $d and .sourceRepositoryRef == $ref' "$claims" >/dev/null ||
		{ echo "fake gh: verification failed: the attestation does not match the policy" >&2; exit 1; }
	jq '[{verificationResult: {signature: {certificate: .}}}]' "$claims" ;;
workflow) [ "$sub" = run ] || exit 9 ;;
*) echo "fake gh: unknown command $cmd" >&2; exit 9 ;;
esac
FAKE
chmod +x "$T/bin/gh"

RUNDIR="$GHS/runs/$RUN_ID"
OTHER_RUN=111222333
# add_run ID TAG CREATED_AT: a successful build run of COMMIT. The artifact
# release-files holds the build and input products, ci-repo the ci product,
# and release-build-manifest the build info and the build manifest.
add_run() {
	local id="$1" tag="$2" created="$3" dir="$GHS/runs/$1" n
	mkdir -p "$dir/artifacts/release-files" "$dir/artifacts/ci-repo" "$dir/artifacts/release-build-manifest"
	for n in $BUILD_FILES; do
		cp "$GOOD/$n" "$dir/artifacts/release-files/$n"
	done
	for n in $INPUT_FILES; do
		printf 'unsigned %s\n' "$n" >"$dir/artifacts/release-files/$n"
	done
	printf 'repository\n' >"$dir/artifacts/ci-repo/$CI_FILE"
	jq -n --arg c "$COMMIT" --arg r "$GH_REPO" --argjson id "$id" --arg at "$created" \
		'{id: $id, created_at: $at, repository: {full_name: $r}, head_repository: {full_name: $r}, path: ".github/workflows/build.yml@refs/heads/main", head_sha: $c, head_branch: "main", event: "workflow_dispatch", run_attempt: 1, status: "completed", conclusion: "success"}' >"$dir/run.json"
	set_run_info "$id" "$tag" "$COMMIT"
}
# set_run_info ID TAG COMMIT [ATTEMPT]: new build info and build manifest of a
# run, and the attestation of the build manifest.
set_run_info() {
	local dir="$GHS/runs/$1/artifacts" sha
	write_info "$dir/release-build-manifest" "$GH_REPO" "$2" "$3" "$1" "${4:-1}"
	(cd "$dir/release-files" && sha256 -- *
	 cd ../ci-repo && sha256 -- *
	 cd ../release-build-manifest && sha256 -- release-build-info.json) | LC_ALL=C sort -k2 >"$T/bm.tmp"
	mv "$T/bm.tmp" "$dir/release-build-manifest/BUILD-SHA256SUMS"
	sha="$(sha256 "$dir/release-build-manifest/BUILD-SHA256SUMS" | cut -d' ' -f1)"
	mkdir -p "$GHS/attest"
	jq -n --arg r "$GH_REPO" --arg c "$3" --arg run "https://github.com/$GH_REPO/actions/runs/$1/attempts/${4:-1}" \
		'{repo: $r, signerWorkflow: "\($r)/.github/workflows/build.yml", buildTrigger: "workflow_dispatch", runInvocationURI: $run, sourceRepositoryDigest: $c, sourceRepositoryRef: "refs/heads/main", runnerEnvironment: "github-hosted"}' \
		>"$GHS/attest/$sha.json"
	ATTEST="$GHS/attest/$sha.json"
}
# app_config [VERSION] [PUBKEY_FILE]: the app configuration at COMMIT, as the API serves it.
app_config() {
	mkdir -p "$GHS/contents/$COMMIT"
	jq -n --arg v "${1:-${TAG#v}}" --arg pk "$(cat "${2:-$T/tauri1.key.pub}")" '{version: $v, plugins: {updater: {pubkey: $pk}}}' \
		>"$GHS/contents/$COMMIT/tauri.conf.json"
}
app_version() { app_config "$1"; }
# empty_state: a draft without files (as step 1 leaves it), and the build run.
empty_state() {
	rm -rf "$GHS"
	mkdir -p "$GHS/assets" "$GHS/runs"
	jq -n --arg t "$TAG" --arg c "$COMMIT" '{id: 4242, tag_name: $t, draft: true, target_commitish: $c, html_url: "x", body: "notes", assets: []}' >"$GHS/release.json"
	echo 0 >"$GHS/next_id"
	add_run "$RUN_ID" "$TAG" "2026-01-01T10:00:00Z"
	app_config
	echo identical >"$GHS/compare"
	echo "$HEAD_SHA" >"$GHS/head"
	: >"$GHS/tag"
	: >"$GHS/calls.log"
	# No tag and no hook in the remote.
	git --git-dir="$REMOTE" for-each-ref --format='%(refname)' refs/tags | while IFS= read -r r; do
		git --git-dir="$REMOTE" update-ref -d "$r"
	done
	rm -f "$REMOTE/hooks/pre-receive"
}
put_asset() { # FILE: put a file on the fake draft, as an upload would
	local n="${1##*/}" id
	cp "$1" "$GHS/assets/$n"
	id=$(( $(cat "$GHS/next_id") + 1 )); echo "$id" >"$GHS/next_id"
	jq --arg n "$n" --argjson id "$id" '.assets += [{id: $id, name: $n}]' "$GHS/release.json" >"$GHS/r" && mv "$GHS/r" "$GHS/release.json"
}
# fake_state: a draft that holds what the signing script uploads, and a build
# run that holds the build files.
fake_state() {
	local f n
	empty_state
	git --git-dir="$REMOTE" update-ref "refs/tags/$TAG" "$COMMIT"
	for f in "$GOOD"/*; do
		n="${f##*/}"
		case " $BUILD_FILES release-build-info.json " in
		*" $n "*) ;;
		*) put_asset "$f" ;;
		esac
	done
}
fin() {
	run env PATH="$T/bin:$PATH" FAKE_GH_STATE="$GHS" GH_TOKEN=fake-token GITHUB_SHA="${FIN_SHA-$HEAD_SHA}" \
		"$REPO/dev-scripts/release/finalize-release.sh" "$@"
}
stage() { fin stage --tag "$TAG" --run-id "$RUN_ID" --repo "$GH_REPO" --repo-root "$REPO" "$@"; }
publish() { fin publish --tag "$TAG" --run-id "$RUN_ID" --repo "$GH_REPO" --manifest-sha256 "${1:-$GOOD_SHA}" --repo-root "$REPO"; }
GOOD_SHA="$(sha256 "$GOOD/SHA256SUMS" | cut -d' ' -f1)"
uploads() { grep -c '^api -X POST .*https://uploads.github.com/' "$GHS/calls.log" || true; }

fake_state
GITHUB_OUTPUT="$T/gh-output" stage
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qx "manifest_sha256=$GOOD_SHA" && grep -qx "manifest_sha256=$GOOD_SHA" "$T/gh-output" &&
	[ "$(ls "$GHS/assets" | wc -l | tr -d ' ')" = "$(ls "$GOOD" | wc -l | tr -d ' ')" ] && diff -r "$GOOD" "$GHS/assets" >/dev/null &&
	[ "$(uploads)" = 5 ]; then
	pass "stage: good case uploads the build files and prints the manifest hash"
else
	fail "stage: good case" "rc=$RC:"$'\n'"$OUT"
fi

: >"$GHS/calls.log"
stage
if [ "$RC" = 0 ] && [ "$(uploads)" = 0 ]; then pass "stage: second run uploads nothing"; else fail "stage: second run" "rc=$RC: $OUT"; fi

# Fix 5: stage --out leaves the verified set; check-set checks it offline.
stage --out "$T/staged"
if [ "$RC" = 0 ] && diff -r "$GOOD" "$T/staged" >/dev/null; then
	pass "stage --out: leaves the complete verified set"
else
	fail "stage --out" "rc=$RC: $OUT"
fi
mkdir -p "$T/not-empty" && touch "$T/not-empty/x"
stage --out "$T/not-empty"
expect_err "stage --out: refuses a directory that is not empty" "$T/not-empty exists and is not an empty directory"

cset() { # DIR [args]
	local dir="$1"
	shift
	run env -u GH_TOKEN PATH="$T/nobin:$PATH" "$REPO/dev-scripts/release/finalize-release.sh" check-set --dir "$dir" --repo-root "$REPO" "$@"
}
mkdir -p "$T/nobin"
printf '#!/bin/sh\necho "gh must not run" >&2\nexit 9\n' >"$T/nobin/gh"
chmod +x "$T/nobin/gh"
cset "$T/staged" --manifest-sha256 "$GOOD_SHA"
expect_ok "check-set: exact set, no token, no network"
cp -a "$T/staged" "$T/cs1"
rm "$T/cs1/$AI" "$T/cs1/tool_1.2.3_Linux_x86_64.tar"
cset "$T/cs1" --manifest-sha256 "$GOOD_SHA"
expect_err "check-set: missing files fail without --subset" "files that the manifest lists but that are missing: $AI tool_1.2.3_Linux_x86_64.tar"
cset "$T/cs1" --manifest-sha256 "$GOOD_SHA" --subset
expect_ok "check-set --subset: absent files are fine"
printf 'x' >>"$T/cs1/sample_1.2.3_amd64.deb"
cset "$T/cs1" --manifest-sha256 "$GOOD_SHA" --subset
expect_err "check-set --subset: a changed file fails" "hash mismatch for sample_1.2.3_amd64.deb"
cp -a "$T/staged" "$T/cs2"
printf 'x\n' >"$T/cs2/extra.bin"
cset "$T/cs2" --manifest-sha256 "$GOOD_SHA" --subset
expect_err "check-set --subset: an unlisted file fails" "files that the manifest does not list: extra.bin"
cset "$T/staged" --manifest-sha256 "$(printf '%064d' 0)"
expect_err "check-set: wrong pinned hash" "SHA256SUMS in $T/staged has the sha256 $GOOD_SHA, not the pinned"
cp -a "$T/staged" "$T/cs3"
pgp_sign "$T/cs3/SHA256SUMS" "$FPR_B"
cset "$T/cs3" --manifest-sha256 "$GOOD_SHA" --subset
expect_err "check-set: manifest signature from a key that is not allowed" "SHA256SUMS has no good signature"
cp -a "$T/staged" "$T/cs4"
rm "$T/cs4/SHA256SUMS.asc"
cset "$T/cs4" --manifest-sha256 "$GOOD_SHA" --subset
expect_err "check-set --subset: SHA256SUMS.asc is still required" "signature file is missing: SHA256SUMS.asc"
fin check-set --dir "$T/staged" --manifest-sha256 "$GOOD_SHA" --tag "$TAG"
expect_err "check-set: refuses options of other commands" "check-set does not take --tag"

D="$T/fetch1"
fin fetch --tag "$TAG" --repo "$GH_REPO" --manifest-sha256 "$GOOD_SHA" --dir "$D"
if [ "$RC" = 0 ] && diff -r -x SHA256SUMS.asc "$GHS/assets" "$D" >/dev/null 2>&1 &&
	[ "$(ls "$D" | wc -l | tr -d ' ')" = "$(($(wc -l <"$GOOD/SHA256SUMS") + 1))" ] && [ ! -e "$D/SHA256SUMS.asc" ]; then
	# SHA256SUMS plus every listed file: SHA256SUMS.asc is the only file not fetched
	pass "fetch: all files"
else
	fail "fetch: all files" "rc=$RC: $OUT"
fi
fin fetch --tag "$TAG" --repo "$GH_REPO" --manifest-sha256 "$GOOD_SHA" --dir "$T/fetch2" sample_1.2.3_amd64.deb latest.json
[ "$RC" = 0 ] && [ "$(LC_ALL=C ls "$T/fetch2" | tr '\n' ' ')" = "SHA256SUMS latest.json sample_1.2.3_amd64.deb " ] &&
	pass "fetch: named files" || fail "fetch: named files" "rc=$RC: $OUT $(ls "$T/fetch2")"
fin fetch --tag "$TAG" --repo "$GH_REPO" --manifest-sha256 "$(printf '%064d' 0)" --dir "$T/fetch3"
expect_err "fetch: wrong manifest hash" "SHA256SUMS of release $TAG has the sha256"
fin fetch --tag "$TAG" --repo "$GH_REPO" --manifest-sha256 "$GOOD_SHA" --dir "$T/fetch4" SHA256SUMS.asc
expect_err "fetch: name not in the manifest" "SHA256SUMS does not list SHA256SUMS.asc"
printf 'x' >>"$GHS/assets/sample_1.2.3_amd64.deb"
fin fetch --tag "$TAG" --repo "$GH_REPO" --manifest-sha256 "$GOOD_SHA" --dir "$T/fetch5" sample_1.2.3_amd64.deb
expect_err "fetch: changed file" "hash mismatch for sample_1.2.3_amd64.deb"
publish
expect_err "publish: file changed after stage" "hash mismatch for sample_1.2.3_amd64.deb"
cp "$GOOD/sample_1.2.3_amd64.deb" "$GHS/assets/sample_1.2.3_amd64.deb"

publish "$(printf '%064d' 0)"
expect_err "publish: wrong manifest hash" "SHA256SUMS changed after the stage step"
echo "fedcba9876543210fedcba9876543210fedcba98" >"$GHS/tag"
publish
expect_err "publish: tag exists at another commit" "git tag $TAG points to fedcba98" "not to the release commit $COMMIT" \
	"If release $TAG was published already, its tag can never move" "make the next attempt with a new version number" \
	"Before publication, a maintainer can delete the tag (git push <remote> --delete refs/tags/$TAG)"
: >"$GHS/tag"
GITHUB_REF=refs/heads/feature publish
expect_err "publish: wrong workflow branch" "Start it from the branch main"
# Fix 3: the finalize commit must be the current head of the default branch.
FIN_SHA="cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd" publish
expect_err "publish: finalize commit is not the head of the default branch" "uses the scripts, signer keys, and allowlist of commit cdcdcdcd" "but the head of the default branch main is $HEAD_SHA now"
FIN_SHA="" publish
expect_err "publish: GITHUB_SHA missing" "GITHUB_SHA is not set"
put_asset "$T/nothing.bin"
publish
expect_err "publish: extra asset on the draft" "files that the manifest does not list: nothing.bin"
[ "$(jq -r .draft "$GHS/release.json")" = true ] && pass "publish: extra asset keeps the draft" || fail "publish: extra asset keeps the draft" "published"
jq '.assets |= map(select(.name != "nothing.bin"))' "$GHS/release.json" >"$GHS/r" && mv "$GHS/r" "$GHS/release.json"
GITHUB_REF=refs/heads/main publish
if [ "$RC" = 0 ] && [ "$(jq -r .draft "$GHS/release.json")" = false ] && grep -q '^api -X PATCH repos/.*/releases/4242 -F draft=false' "$GHS/calls.log" &&
	[ "$(grep -c '^api --paginate repos/.*/releases/4242/assets' "$GHS/calls.log")" -ge 3 ]; then
	pass "publish: good case (asset list read before and after the flip)"
else
	fail "publish: good case" "rc=$RC: $OUT"
fi
publish
expect_err "publish: already published" "is not a draft"
fin fetch --tag "$TAG" --repo "$GH_REPO" --manifest-sha256 "$GOOD_SHA" --dir "$T/fetch6" tool_1.2.3_Linux_x86_64.tar
expect_ok "fetch: published release"

fake_state
echo "fedcba9876543210fedcba9876543210fedcba98" >"$GHS/tag_after_publish"
stage
publish
expect_err "publish: tag moved during publish" "NEEDS A HUMAN"

# Fix 4: an asset that arrives after the check, right before the flip. The
# asset list is read the first time by find_release, the second time right
# before the flip.
fake_state
stage
rm -f "$GHS/list_count"
echo 2 >"$GHS/stray_on_list"
publish
expect_err "publish: asset added after the check" "the files of the draft release $TAG changed after the check. Nothing is published" "late.bin"
[ "$(jq -r .draft "$GHS/release.json")" = true ] && pass "publish: late asset keeps the draft" || fail "publish: late asset keeps the draft" "published"

# Fix 4: an asset that changes during the flip of the draft flag.
fake_state
stage
echo "sample_1.2.3_amd64.deb" >"$GHS/tamper_on_publish"
publish
expect_err "publish: asset changed during the publish call" "RELEASE $TAG NEEDS A HUMAN NOW: after the publish call, its files differ from the verified files" \
	"sample_1.2.3_amd64.deb" "nobody can make it a draft again, or change, add, or" "1. Do not publish to any other channel" \
	"gh api -X DELETE repos/$GH_REPO/releases/4242" "with a new version number" "make the next attempt with a new version number"
! grep -q 'draft=true' <<<"$OUT" && pass "publish: the recovery text suggests no draft=true" ||
	fail "publish: the recovery text suggests no draft=true" "$OUT"

fake_state
FIN_SHA="cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd" stage
expect_err "stage: finalize commit is not the head of the default branch" "but the head of the default branch main is $HEAD_SHA now"

fake_state
GITHUB_REF=refs/heads/feature stage
expect_err "stage: wrong workflow branch" "this workflow runs on refs/heads/feature. Start it from the branch main."

fake_state
jq '.assets = []' "$GHS/release.json" >"$GHS/r" && mv "$GHS/r" "$GHS/release.json"
stage
expect_err "stage: empty draft" "has no files. The signing script has to run first"

fake_state
printf 'x\n' >"$T/stray.bin"
put_asset "$T/stray.bin"
stage
expect_err "stage: extra file on the draft" "extra file on the draft release: stray.bin"

fake_state
rm "$RUNDIR/artifacts/release-files/tool_1.2.3_Linux_x86_64.tar"
stage
expect_err "stage: file in neither place" "tool_1.2.3_Linux_x86_64.tar is in SHA256SUMS, but neither on the draft release nor in the build run. The signing script has to run again."

fake_state
printf 'x' >>"$RUNDIR/artifacts/release-files/sample_1.2.3_x64-setup.exe"
stage
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -qF "hash mismatch for sample_1.2.3_x64-setup.exe" && [ "$(uploads)" = 0 ]; then
	pass "stage: changed build file, nothing uploaded"
else
	fail "stage: changed build file" "rc=$RC: $OUT"
fi

fake_state
gpg --batch --yes --local-user "$FPR_C" --armor --detach-sign --output "$GHS/assets/SHA256SUMS.asc" "$GHS/assets/SHA256SUMS" 2>/dev/null
stage
expect_err "stage: manifest signed by an unknown key" "SHA256SUMS has no good signature"

fake_state
jq '.draft = false' "$GHS/release.json" >"$GHS/r" && mv "$GHS/r" "$GHS/release.json"
stage
expect_err "stage: published release" "is not a draft"

fake_state
jq '.head_sha = "fedcba9876543210fedcba9876543210fedcba98"' "$RUNDIR/run.json" >"$GHS/r" && mv "$GHS/r" "$RUNDIR/run.json"
stage
expect_err "stage: build run of another commit" "workflow run $RUN_ID is not the build of this release"

fake_state
jq '.event = "push"' "$RUNDIR/run.json" >"$GHS/r" && mv "$GHS/r" "$RUNDIR/run.json"
stage
expect_err "stage: build run started by another event" "the event push started it, not workflow_dispatch"

fake_state
echo diverged >"$GHS/compare"
stage
expect_err "stage: commit not on the branch" "is not on the branch main"

fake_state
jq '.target_commitish = "main"' "$GHS/release.json" >"$GHS/r" && mv "$GHS/r" "$GHS/release.json"
stage
expect_err "stage: draft targets a branch name" "The build workflow must set a full commit SHA"

fake_state
jq '.assets[0].name = "../evil"' "$GHS/release.json" >"$GHS/r" && mv "$GHS/r" "$GHS/release.json"
stage
expect_err "stage: asset with a bad name" "name that is not allowed: ../evil"

fake_state
echo "tool_1.2.3_Linux_x86_64.tar" >"$GHS/corrupt_upload"
stage
expect_err "stage: upload whose digest GitHub reports differently" "GitHub reports the digest"

fin stage --tag "bad tag" --run-id "$RUN_ID" --repo "$GH_REPO"
expect_err "stage: bad tag argument" "tag is not valid"
fin stage --tag "$TAG" --run-id "12a" --repo "$GH_REPO"
expect_err "stage: bad run id argument" "build run id is not a number"
fin fetch --tag "$TAG" --repo "$GH_REPO" --manifest-sha256 "$GOOD_SHA" --dir "$T/f7" "../x"
expect_err "fetch: bad name argument" "file name is not allowed: ../x"
RC=0
OUT="$(env -u GH_TOKEN PATH="$T/bin:$PATH" "$REPO/dev-scripts/release/finalize-release.sh" stage --tag "$TAG" --run-id 1 --repo "$GH_REPO" 2>&1)" || RC=$?
expect_err "finalize: GH_TOKEN missing" "GH_TOKEN is not set"

fake_state
app_version 1.2.4
stage
expect_err "stage: app version at the commit differs from the tag" "the app version in tauri.conf.json at commit $COMMIT is 1.2.4, but the release version is 1.2.3"

# Fix 9: the updater public key at the release commit.
fake_state
app_config "" "$T/tauri2.key.pub"
stage
expect_err "stage: updater key at the release commit differs" "the updater public key in tauri.conf.json at the release commit $COMMIT differs from the key in this checkout"

fake_state
stage
expect_ok "stage before a publish with another app version"
app_version 1.2.4
publish
expect_err "publish: app version at the commit differs from the tag" "the app version in tauri.conf.json at commit $COMMIT is 1.2.4, but the release version is 1.2.3"
[ "$(jq -r .draft "$GHS/release.json")" = true ] && pass "publish: app version mismatch keeps the draft" || fail "publish: app version mismatch keeps the draft" "published"

fake_state
printf 'x' >>"$GHS/assets/latest.json"
stage
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -qF "hash mismatch for latest.json on the draft release: the file does not match SHA256SUMS. The signing script has to run again." &&
	! grep -qE '^run download|/artifacts\?' "$GHS/calls.log"; then
	pass "stage: changed draft file fails before the build download"
else
	fail "stage: changed draft file fails before the build download" "rc=$RC: $OUT"$'\n'"calls: $(grep -E 'run download|artifacts' "$GHS/calls.log" || true)"
fi

fake_state
set_run_info "$RUN_ID" "v9.9.9" "$COMMIT"
stage
expect_err "stage: build output of another tag" "release-build-info.json does not match this release: tag is v9.9.9, not $TAG" "does not belong to release $TAG"

fake_state
jq '.assets |= map(select(.name != "SHA256SUMS"))' "$GHS/release.json" >"$GHS/r" && mv "$GHS/r" "$GHS/release.json"
stage
expect_err "stage: draft without SHA256SUMS" "the draft release has no SHA256SUMS. The signing script has to run again."

# ---------------------------------------------------------------------------
echo
echo "== sign-release.sh (with the fake gh, no network)"
# The secrets file of the init-secrets good case holds updater key 1.
SIGN_SECRETS="$HOME/cfg/release-signing/test.json.gpg"
signr() { # ARGS...
	run env PATH="$T/bin:$PATH" FAKE_GH_STATE="$GHS" FAKE_GH_CHECKOUT="$REPO" RELEASE_SIGNING_KEY="$FPR_A" RELEASE_SECRETS_FILE="$SIGN_SECRETS" \
		"$REPO/dev-scripts/release/sign-release.sh" "$@"
}
# expect_preflight_err NAME SUBSTRING...: fails before the passphrase prompt.
expect_preflight_err() {
	if printf '%s' "$OUT" | grep -qF "Unlocking your keys"; then
		fail "$1" "the script reached the passphrase step:"$'\n'"$OUT"
		return
	fi
	expect_err "$@"
}
in_draft() { jq -e --arg n "$1" '[.assets[].name] | index($n) != null' "$GHS/release.json" >/dev/null; }

# Fix 2: without local steps, the local products are missing, and the script
# stops before it signs anything.
empty_state
signr "$TAG" --no-dispatch
expect_err "sign: missing local products stop the script before signing" \
	"the release directory after the local steps does not hold exactly the files" "missing: $APPTGZ" "missing: $DMG"
[ "$(uploads)" = 0 ] && ! grep -q 'Making the' <<<"$OUT" && pass "sign: missing local products: nothing signed, nothing uploaded" ||
	fail "sign: missing local products: nothing signed, nothing uploaded" "$OUT"

# The local steps of the test: they "sign" the input products. A real local
# step goes to the same place. The test commits the change, so the checkout
# stays clean.
LOCAL_STEPS='v="$RELEASE_VERSION"
{ cat "$inputs/sample_${v}_aarch64.unsigned.dmg"; printf "signed\\n"; } >"$assets/sample_${v}_aarch64.dmg"
{ cat "$inputs/sample_aarch64.app.unsigned.tar"; printf "signed\\n"; } >"$assets/sample_aarch64.app.tar.gz"'
# The text goes through the environment: BSD awk refuses a newline in -v.
steps="$LOCAL_STEPS" awk '$0 == "# (end of the local steps)" { print ENVIRON["steps"] } { print }' \
	"$REPO/dev-scripts/release/sign-release.sh" >"$T/sign.tmp"
if grep -q 'sample_aarch64.app.tar.gz' "$T/sign.tmp"; then
	cat "$T/sign.tmp" >"$REPO/dev-scripts/release/sign-release.sh"
	git_commit "test local steps"
else
	fail "sign: fixture" "no marker line '# (end of the local steps)' in sign-release.sh"
fi
CHECKOUT="$(git -C "$REPO" rev-parse HEAD)"

empty_state
signr "$TAG" --no-dispatch
if [ "$RC" != 0 ]; then
	fail "sign: good case" "rc=$RC:"$'\n'"$OUT"
else
	problems=""
	for n in SHA256SUMS SHA256SUMS.asc latest.json latest.json.asc $AI.sig $AI.asc release-build-info.json.asc $DMG $DMG.asc $APPTGZ $APPTGZ.sig $APPTGZ.asc; do
		in_draft "$n" || problems="$problems $n missing on the draft;"
	done
	for n in $BUILD_FILES release-build-info.json $INPUT_FILES $CI_FILE; do
		! in_draft "$n" || problems="$problems build, input, or ci file $n uploaded;"
	done
	sig="$GHS/assets/$AI.sig"
	[ "$(wc -l <"$sig" | tr -d ' ')" = 0 ] || problems="$problems .sig has a newline;"
	base64 --decode <"$sig" >"$T/signed.minisig"
	[ "$(sed -n 1p "$T/signed.minisig")" = "untrusted comment: signature from tauri secret key" ] || problems="$problems wrong untrusted comment;"
	sed -n 2p "$T/signed.minisig" | grep -q '^RU' || problems="$problems not an Ed signature;"
	[ "$(base64 --decode <<<"$(sed -n 2p "$T/signed.minisig")" | head -c 2)" = ED ] || problems="$problems not prehashed (ED);"
	sed -n 3p "$T/signed.minisig" | grep -qE "^trusted comment: timestamp:[0-9]+	file:$AI	version:1\.2\.3$" || problems="$problems wrong trusted comment: $(sed -n 3p "$T/signed.minisig");"
	[ "$(wc -l <"$T/signed.minisig" | tr -d ' ')" = 4 ] || problems="$problems not 4 lines;"
	minisign -V -q -p <(base64 --decode <"$T/tauri1.key.pub") -x "$T/signed.minisig" -m "$GOOD/$AI" || problems="$problems minisign -V fails;"
	[ "$(jq -r .version "$GHS/assets/latest.json")" = 1.2.3 ] || problems="$problems latest.json version;"
	[ "$(jq -r '.platforms["linux-x86_64"].signature' "$GHS/assets/latest.json")" = "$(cat "$sig")" ] || problems="$problems latest.json signature;"
	[ "$(jq -r '.platforms | keys | length' "$GHS/assets/latest.json")" = 7 ] || problems="$problems latest.json does not have 7 platforms;"
	[ "$(uploads)" = "$(jq '.assets | length' "$GHS/release.json")" ] || problems="$problems not one upload per draft file;"
	grep '^api -X POST' "$GHS/calls.log" | tail -2 | head -1 | grep -qE 'name=SHA256SUMS$' || problems="$problems second to last upload is not SHA256SUMS;"
	grep '^api -X POST' "$GHS/calls.log" | tail -1 | grep -qE 'name=SHA256SUMS\.asc$' || problems="$problems last upload is not SHA256SUMS.asc;"
	grep -q '^api -X POST .*https://uploads.github.com/repos/'"$GH_REPO"'/releases/4242/assets' "$GHS/calls.log" || problems="$problems upload not by release id;"
	[ "$(grep -c "^run download $RUN_ID .*--name release-build-manifest" "$GHS/calls.log")" = 2 ] || problems="$problems manifest artifact not downloaded twice (hint and build);"
	grep -q "^run download $RUN_ID .*--name release-files" "$GHS/calls.log" || problems="$problems release-files not downloaded;"
	! grep -q "^run download .*--name ci-" "$GHS/calls.log" || problems="$problems a ci artifact was downloaded;"
	grep -q "^attestation verify .*--source-ref refs/heads/main" "$GHS/calls.log" || problems="$problems attestation without --source-ref;"
	# Fix 8 and fix 14: the log names the signing checkout and the release commit.
	grep -qF "signing scripts: commit $CHECKOUT of $REPO (clean, head of main)" <<<"$OUT" || problems="$problems no checkout commit in the log;"
	grep -qF "commit:      $COMMIT (on main)" <<<"$OUT" || problems="$problems no release commit in the log;"
	grep -qF "subject:   Release 1.2.3" <<<"$OUT" || problems="$problems no commit subject in the log;"
	grep -qF "date:      2026-01-01T09:00:00Z" <<<"$OUT" || problems="$problems no commit date in the log;"
	grep -qF "build run $RUN_ID (attempt 1), and its attestation all name commit $COMMIT" <<<"$OUT" || problems="$problems no commit binding in the log;"
	if [ -z "$problems" ]; then pass "sign: good case (local products, manifest last, version in the trusted comment)"; else fail "sign: good case" "$problems"$'\n'"$OUT"; fi
fi
SIGNED_SHA="$(sha256 "$GHS/assets/SHA256SUMS" | cut -d' ' -f1)"
stage
expect_ok "sign, then stage"
publish "$SIGNED_SHA"
expect_ok "sign, stage, then publish"

# Fix 13: a second run after success replaces the earlier approval, keeps the
# files with the same bytes, and the result passes finalize.
empty_state
signr "$TAG" --no-dispatch
stage
signr "$TAG" --no-dispatch
if [ "$RC" = 0 ] && grep -qF "on the draft already, same bytes: $DMG" <<<"$OUT" &&
	grep -qF "REPLACING AN EARLIER APPROVAL: the draft holds an earlier SHA256SUMS" <<<"$OUT" &&
	grep -qF "REPLACING AN EARLIER APPROVAL: the draft holds other bytes for $DMG.asc" <<<"$OUT"; then
	pass "sign: second run keeps same bytes and says that it replaces the earlier approval"
else
	fail "sign: second run" "rc=$RC: $OUT"
fi
stage
expect_ok "stage after the second signing run (draft also held the build files)"

# Fix 13: a build file on the draft that differs from the build (an earlier
# stage of another build) must not block the release.
empty_state
put_asset "$GOOD/tool_1.2.3_Linux_x86_64.tar"
printf 'other build\n' >"$RUNDIR/artifacts/release-files/tool_1.2.3_Linux_x86_64.tar"
set_run_info "$RUN_ID" "$TAG" "$COMMIT"
signr "$TAG" --no-dispatch
if [ "$RC" = 0 ] && grep -qF "tool_1.2.3_Linux_x86_64.tar is unchanged build output: the finalize workflow adds it again" <<<"$OUT" &&
	! in_draft tool_1.2.3_Linux_x86_64.tar; then
	pass "sign: stale build file on the draft is removed"
else
	fail "sign: stale build file on the draft" "rc=$RC: $OUT"
fi
stage
expect_ok "stage after the stale build file"

empty_state
touch "$GHS/publish_after_upload"
signr "$TAG" --no-dispatch
expect_err "sign: release published during the upload" "it is not a draft any more (it was published)"
# The uploads run 4 at a time: the ones that checked the draft before the
# publication finish; no upload starts after it.
[ "$(uploads)" -ge 1 ] && [ "$(uploads)" -le 4 ] && [ "$(grep -c '^start ' "$GHS/upload-trace")" = "$(uploads)" ] &&
	pass "sign: published release: no upload starts after the run sees it (at most the 4 running ones finish)" ||
	fail "sign: published release: no upload starts after the run sees it" "$(uploads) uploads"

empty_state
printf 'stray\n' >"$T/stray.bin"
put_asset "$T/stray.bin"
signr "$TAG" --no-dispatch
expect_err "sign: unknown file on the draft" "the draft release holds files that are not part of this release: stray.bin"
[ "$(uploads)" = 0 ] && pass "sign: unknown file on the draft: nothing uploaded" || fail "sign: unknown file on the draft: nothing uploaded" "$(uploads) uploads"

empty_state
echo "latest.json" >"$GHS/corrupt_upload"
signr "$TAG" --no-dispatch
expect_err "sign: upload whose digest GitHub reports differently" "the upload of latest.json is not right: GitHub reports the digest"

empty_state
add_run "$OTHER_RUN" "v1.2.4" "2026-01-02T10:00:00Z"
signr "$TAG" --no-dispatch
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qF "build run:   https://github.com/$GH_REPO/actions/runs/$RUN_ID" &&
	grep -q "^run download $OTHER_RUN .*--name release-build-manifest" "$GHS/calls.log" &&
	! grep -q "^run download $OTHER_RUN .*--name release-files" "$GHS/calls.log"; then
	pass "sign: two runs on one commit, the newer one of another tag: picks the run of the tag"
else
	fail "sign: two runs on one commit" "rc=$RC:"$'\n'"$OUT"
fi

empty_state
rm -rf "$RUNDIR"
add_run "$OTHER_RUN" "v1.2.4" "2026-01-02T10:00:00Z"
add_run 444555666 "v1.2.2" "2026-01-01T09:00:00Z"
signr "$TAG" --no-dispatch
expect_preflight_err "sign: no run of the tag lists the tags found" "no successful run of build.yml for commit $COMMIT built tag $TAG" "run $OTHER_RUN: tag v1.2.4" "run 444555666: tag v1.2.2"

empty_state
add_run "$OTHER_RUN" "v1.2.4" "2026-01-02T10:00:00Z"
signr "$TAG" --no-dispatch --run-id "$OTHER_RUN"
expect_preflight_err "sign: wrong --run-id fails in the preflight" "build run $OTHER_RUN built tag v1.2.4, not tag $TAG"

empty_state
app_version 1.2.4
signr "$TAG" --no-dispatch
expect_preflight_err "sign: app version at the commit differs from the tag" "the app version in tauri.conf.json at commit $COMMIT is 1.2.4, but the release version is 1.2.3"

empty_state
app_config "" "$T/tauri2.key.pub"
signr "$TAG" --no-dispatch
expect_preflight_err "sign: updater key at the release commit differs" "the updater public key in tauri.conf.json at the release commit $COMMIT differs from the key in this checkout"

empty_state
signr v1.2 --no-dispatch
expect_preflight_err "sign: tag that is not a semantic version" "tag v1.2 does not name a release version"

empty_state
set_run_info "$RUN_ID" "$TAG" "fedcba9876543210fedcba9876543210fedcba98"
signr "$TAG" --no-dispatch
expect_err "sign: build info of the download does not match" "release-build-info.json does not match this release: commit is fedcba9876543210fedcba9876543210fedcba98, not $COMMIT" "Pass --run-id with the build run of $TAG"

# Fix 9: the attestation is bound to the event, the ref, and the run attempt.
empty_state
jq '.buildTrigger = "push"' "$ATTEST" >"$T/a" && mv "$T/a" "$ATTEST"
signr "$TAG" --no-dispatch
expect_err "sign: attestation from another event" "the attestation of BUILD-SHA256SUMS does not match the build run $RUN_ID, attempt 1: an attestation comes from the event push, not workflow_dispatch"

empty_state
jq --arg u "https://github.com/$GH_REPO/actions/runs/$RUN_ID/attempts/2" '.runInvocationURI = $u' "$ATTEST" >"$T/a" && mv "$T/a" "$ATTEST"
signr "$TAG" --no-dispatch
expect_err "sign: attestation from another run attempt" "an attestation comes from the run https://github.com/$GH_REPO/actions/runs/$RUN_ID/attempts/2"

empty_state
jq '.sourceRepositoryRef = "refs/heads/feature"' "$ATTEST" >"$T/a" && mv "$T/a" "$ATTEST"
signr "$TAG" --no-dispatch
expect_err "sign: attestation of a build on another ref" "BUILD-SHA256SUMS has no valid attestation from build.yml at commit $COMMIT on refs/heads/main"

empty_state
jq '.sourceRepositoryDigest = "fedcba9876543210fedcba9876543210fedcba98"' "$ATTEST" >"$T/a" && mv "$T/a" "$ATTEST"
signr "$TAG" --no-dispatch
expect_err "sign: attestation of another commit" "BUILD-SHA256SUMS has no valid attestation from build.yml at commit $COMMIT"

empty_state
jq '.run_attempt = 2' "$RUNDIR/run.json" >"$T/a" && mv "$T/a" "$RUNDIR/run.json"
signr "$TAG" --no-dispatch
expect_err "sign: build info of an older run attempt" "release-build-info.json comes from attempt 1 of build run $RUN_ID, but the latest attempt of the run is 2"

# Fix 2: the downloaded set and the build manifest are exact.
empty_state
cp "$RUNDIR/artifacts/ci-repo/$CI_FILE" "$RUNDIR/artifacts/release-files/"
rm -r "$RUNDIR/artifacts/ci-repo"
set_run_info "$RUN_ID" "$TAG" "$COMMIT"
signr "$TAG" --no-dispatch
expect_err "sign: ci product in the downloaded artifacts" "not expected: $CI_FILE (a product with origin ci belongs in an artifact that matches ci-*)"

empty_state
rm "$RUNDIR/artifacts/release-files/$INPUT_APP"
set_run_info "$RUN_ID" "$TAG" "$COMMIT"
signr "$TAG" --no-dispatch
expect_err "sign: build manifest without an input product" "BUILD-SHA256SUMS of build run $RUN_ID does not hold exactly the files" "missing: $INPUT_APP"

empty_state
rm "$RUNDIR/artifacts/release-files/$INPUT_APP"
signr "$TAG" --no-dispatch
expect_err "sign: input product missing in the download" "the artifacts of build run $RUN_ID that match release-* does not hold exactly the files" "missing: $INPUT_APP"

# Parallel uploads: several at a time, at most UPLOAD_JOBS (4); SHA256SUMS
# and SHA256SUMS.asc go last, each alone. A slow fake network (0.5 s per
# upload) makes the overlap visible.
empty_state
rm -f "$GHS/upload-trace"
export FAKE_GH_UPLOAD_DELAY=0.5
up_started=$SECONDS
signr "$TAG" --no-dispatch
up_seconds=$((SECONDS - up_started))
unset FAKE_GH_UPLOAD_DELAY
if [ "$RC" = 0 ] && [ -s "$GHS/upload-trace" ]; then
	problems=""
	max="$(awk '$1 == "start" && $3 > m { m = $3 } END { print m + 0 }' "$GHS/upload-trace")"
	n="$(grep -c '^start ' "$GHS/upload-trace")"
	[ "$max" -ge 2 ] && [ "$max" -le 4 ] || problems="$problems at most $max uploads ran at the same time (expected 2 to 4);"
	# Every other upload ended before SHA256SUMS started; SHA256SUMS ended
	# before SHA256SUMS.asc started; each ran alone.
	tail -n 4 "$GHS/upload-trace" | tr '\n' ' ' | grep -qx 'start SHA256SUMS 1 end SHA256SUMS start SHA256SUMS.asc 1 end SHA256SUMS.asc ' ||
		problems="$problems the manifest uploads are not last and alone: $(tail -n 4 "$GHS/upload-trace" | tr '\n' ' ');"
	[ "$(grep -c '^end ' "$GHS/upload-trace")" = "$n" ] || problems="$problems an upload did not end;"
	[ "$(grep -c '^    uploaded: ' <<<"$OUT")" = "$n" ] || problems="$problems the log does not name each upload;"
	grep -qF "uploaded $n files, 0 were on the draft already" <<<"$OUT" || problems="$problems wrong upload count in the log;"
	if [ -z "$problems" ]; then
		pass "sign: uploads run in parallel (at most $max at a time), the manifest and its signature go last, each alone"
	else
		fail "sign: parallel uploads" "$problems"$'\n'"$(cat "$GHS/upload-trace")"
	fi
	printf '      %s uploads with 0.5 s of fake network each: %s s for the whole run, phase %s\n' "$n" "$up_seconds" \
		"$(grep -oE '\(upload: [0-9]+ s\)' <<<"$OUT")"
else
	fail "sign: parallel uploads" "rc=$RC: $OUT"
fi
stage
expect_ok "stage after the parallel uploads"

# Two uploads fail at the same time: the run waits for the running uploads,
# names both files, and uploads no manifest.
empty_state
printf '%s\n' "$DMG" "$DMG.asc" >"$GHS/fail_upload_at"
signr "$TAG" --no-dispatch
if [ "$RC" != 0 ] && grep -qF "error: upload of $DMG $DMG.asc failed. The draft has no new SHA256SUMS" <<<"$OUT" &&
	grep -qF "fake gh: connection reset during upload of $DMG.asc" <<<"$OUT" && ! in_draft SHA256SUMS && ! in_draft SHA256SUMS.asc &&
	[ "$(cat "$GHS/uploads_running")" = 0 ] && [ ! -d "$GHS/lock.d" ]; then
	pass "sign: two failed uploads: the error names both files, the running uploads end, no manifest"
else
	fail "sign: two failed uploads" "rc=$RC: $OUT"$'\n'"draft: $(jq -c '[.assets[].name]' "$GHS/release.json")"
fi
rm "$GHS/fail_upload_at"
signr "$TAG" --no-dispatch
[ "$RC" = 0 ] && grep -qF "REPLACING AN EARLIER APPROVAL: the draft holds other bytes for $AI.sig" <<<"$OUT" &&
	in_draft "$DMG" && in_draft "$DMG.asc" && in_draft SHA256SUMS.asc &&
	pass "sign: a second run after the failed uploads replaces the files that arrived and completes the draft" ||
	fail "sign: second run after failed uploads" "rc=$RC: $OUT"
stage
expect_ok "stage after the second run that followed the failed uploads"

empty_state
echo "sample_1.2.3_amd64.deb.asc" >"$GHS/fail_upload_at"
signr "$TAG" --no-dispatch
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -qF "upload of sample_1.2.3_amd64.deb.asc failed. The draft has no new SHA256SUMS. Run this script again" &&
	in_draft "$AI.sig" && ! in_draft SHA256SUMS && ! in_draft SHA256SUMS.asc; then
	pass "sign: interrupted first upload leaves no manifest on the draft"
else
	fail "sign: interrupted first upload" "rc=$RC: $OUT"$'\n'"draft: $(jq -c '[.assets[].name]' "$GHS/release.json")"
fi
stage
expect_err "stage after an interrupted upload: no tag yet" "git tag $TAG does not exist" "The finalize workflow never creates a tag"
git --git-dir="$REMOTE" update-ref "refs/tags/$TAG" "$COMMIT"
stage
expect_err "stage after an interrupted upload" "the draft release has no SHA256SUMS. The signing script has to run again."
rm "$GHS/fail_upload_at"
signr "$TAG" --no-dispatch
if [ "$RC" = 0 ] && grep -qF "REPLACING AN EARLIER APPROVAL: the draft holds other bytes for $AI.sig" <<<"$OUT"; then
	pass "sign: run again after an interrupted upload"
else
	fail "sign: run again after an interrupted upload" "rc=$RC: $OUT"
fi
stage
expect_ok "stage after the second signing run"

# Fix 8: the signing script runs only from a clean git checkout.
empty_state
printf '# local change\n' >>"$REPO/dev-scripts/release/lib.sh"
signr "$TAG" --no-dispatch
expect_preflight_err "sign: changed script in the checkout" "has changed, untracked, or ignored files" "dev-scripts/release/lib.sh"
git -C "$REPO" checkout -q -- dev-scripts/release/lib.sh

printf 'x\n' >"$REPO/dev-scripts/release/extra.sh"
signr "$TAG" --no-dispatch
expect_preflight_err "sign: untracked file in the scripts directory" "has changed, untracked, or ignored files" "?? dev-scripts/release/extra.sh"
rm "$REPO/dev-scripts/release/extra.sh"

printf 'x\n' >>"$REPO/keys/signer-A.asc"
signr "$TAG" --no-dispatch
expect_preflight_err "sign: changed signer key file" "has changed, untracked, or ignored files" "keys/signer-A.asc"
git -C "$REPO" checkout -q -- keys/signer-A.asc

printf 'x\n' >"$REPO/keys/extra.asc"
signr "$TAG" --no-dispatch
expect_preflight_err "sign: untracked signer key file" "?? keys/extra.asc"
rm "$REPO/keys/extra.asc"

NOGIT="$T/nogit"
mkdir -p "$NOGIT"
(cd "$REPO" && tar --exclude=.git -cf - .) | tar -xf - -C "$NOGIT"
run env PATH="$T/bin:$PATH" FAKE_GH_STATE="$GHS" RELEASE_SIGNING_KEY="$FPR_A" RELEASE_SECRETS_FILE="$SIGN_SECRETS" \
	"$NOGIT/dev-scripts/release/sign-release.sh" "$TAG" --no-dispatch
expect_preflight_err "sign: scripts outside a git checkout" "$NOGIT is not a git checkout"

run env PATH="$T/bin:$PATH" FAKE_GH_STATE="$GHS" RELEASE_SIGNING_KEY="$FPR_A" RELEASE_SECRETS_FILE="$SIGN_SECRETS" RELEASE_CONFIG="$CFG" \
	"$REPO/dev-scripts/release/sign-release.sh" "$TAG" --no-dispatch
expect_preflight_err "sign: RELEASE_CONFIG is refused" "RELEASE_CONFIG is set"

# The checkout must be the head of the default branch, as the API reports it.
empty_state
printf '%s\n' "$LATER_COMMIT" >"$GHS/sign_head"
signr "$TAG" --no-dispatch
expect_preflight_err "sign: checkout is not the head of the default branch" \
	"this checkout ($REPO) is at commit $CHECKOUT, but the head of the default branch main of $GH_REPO is $LATER_COMMIT now" \
	"Update the checkout" "git checkout --detach $LATER_COMMIT"
[ "$(uploads)" = 0 ] && ! grep -q "Downloading the build output" <<<"$OUT" &&
	pass "sign: outdated checkout: nothing downloaded, nothing uploaded" || fail "sign: outdated checkout: nothing downloaded, nothing uploaded" "$OUT"
grep -q "^api repos/$GH_REPO/branches/main --jq .commit.sha" "$GHS/calls.log" &&
	pass "sign: the head comes from the API" || fail "sign: the head comes from the API" "$(cat "$GHS/calls.log")"
empty_state

[ -z "$(git -C "$REPO" status --porcelain --untracked-files=all --ignored=matching)" ] &&
	pass "sign: the test checkout is clean again" || fail "sign: the test checkout is clean again" "$(git -C "$REPO" status --short)"
signr "$TAG" --no-dispatch
expect_ok "sign: clean checkout after the checks"

# ---------------------------------------------------------------------------
echo
echo "== git tag: the signing script makes it, the finalize step never does"
tag_type() { git --git-dir="$REMOTE" cat-file -t "refs/tags/$1" 2>/dev/null || true; }
tag_peeled() { git --git-dir="$REMOTE" rev-parse -q --verify "refs/tags/$1^{commit}" 2>/dev/null || true; }

empty_state
branch_before="$(git -C "$REPO" symbolic-ref HEAD)"
head_before="$(git -C "$REPO" rev-parse HEAD)"
signr "$TAG" --no-dispatch
if [ "$RC" != 0 ]; then
	fail "tag: signed annotated tag" "rc=$RC:"$'\n'"$OUT"
else
	problems=""
	[ "$(tag_type "$TAG")" = tag ] || problems="$problems not an annotated tag ($(tag_type "$TAG"));"
	[ "$(tag_peeled "$TAG")" = "$COMMIT" ] || problems="$problems does not point to the release commit;"
	git --git-dir="$REMOTE" tag -v "$TAG" >"$T/tag-v.log" 2>&1 || problems="$problems git tag -v fails: $(cat "$T/tag-v.log");"
	grep -q "Good signature from \"signer-a <signer-a@example.invalid>\"" "$T/tag-v.log" || problems="$problems git tag -v names no good signature of signer-a;"
	body="$(git --git-dir="$REMOTE" cat-file tag "refs/tags/$TAG")"
	grep -q "^tagger signer-a <signer-a@example.invalid> [0-9]* +0000$" <<<"$body" || problems="$problems tagger is not the identity of the key;"
	grep -qx "SHA256SUMS: $(sha256 "$GHS/assets/SHA256SUMS" | cut -d' ' -f1)" <<<"$body" || problems="$problems the tag message does not name the signed manifest;"
	grep -qF "pushed the signed tag object" <<<"$OUT" || problems="$problems no push line;"
	! grep -qF "FALLBACK" <<<"$OUT" || problems="$problems fell back;"
	grep -qE '\(git tag: [0-9]+ s\)' <<<"$OUT" || problems="$problems no time of the tag phase;"
	[ "$(git -C "$REPO" symbolic-ref HEAD)" = "$branch_before" ] || problems="$problems the checked-out branch changed;"
	[ "$(git -C "$REPO" rev-parse HEAD)" = "$head_before" ] || problems="$problems HEAD changed;"
	[ -z "$(git -C "$REPO" tag -l)" ] || problems="$problems a local tag ref appeared;"
	[ -z "$(git -C "$REPO" status --porcelain --untracked-files=all --ignored=matching)" ] || problems="$problems the work tree changed;"
	grep -n 'Making the git tag' <<<"$OUT" | cut -d: -f1 >"$T/l1"
	grep -n 'Uploading to the draft release' <<<"$OUT" | cut -d: -f1 >"$T/l2"
	[ "$(cat "$T/l2")" -lt "$(cat "$T/l1")" ] || problems="$problems the tag came before the upload;"
	if [ -z "$problems" ]; then pass "tag: signed annotated tag, verifiable with git tag -v, checkout unchanged"; else fail "tag: signed annotated tag" "$problems"$'\n'"$OUT"; fi
	TAG_TIMING="$(grep -E 'fetched the release commit|pushed the signed tag|\(git tag:' <<<"$OUT" | tr '\n' ' ')"
	printf '      timing: %s\n' "$TAG_TIMING"
fi
stage
expect_ok "tag: stage accepts the signed tag"
publish "$(sha256 "$GHS/assets/SHA256SUMS" | cut -d' ' -f1)"
expect_ok "tag: publish accepts the signed tag"

tag_obj="$(remote_tag "$TAG")"
jq '.draft = true' "$GHS/release.json" >"$GHS/r" && mv "$GHS/r" "$GHS/release.json"
signr "$TAG" --no-dispatch
if [ "$RC" = 0 ] && grep -qF "git tag:     $TAG exists already on the release commit" <<<"$OUT" &&
	grep -qF "$TAG exists already and points to $COMMIT" <<<"$OUT" && [ "$(remote_tag "$TAG")" = "$tag_obj" ]; then
	pass "tag: second run keeps the existing tag"
else
	fail "tag: second run keeps the existing tag" "rc=$RC: $OUT"
fi

empty_state
git --git-dir="$REMOTE" -c user.name=maint -c user.email=maint@example.invalid tag -a -m "by hand" "$TAG" "$COMMIT"
tag_obj="$(remote_tag "$TAG")"
signr "$TAG" --no-dispatch
[ "$RC" = 0 ] && [ "$(remote_tag "$TAG")" = "$tag_obj" ] && grep -qF "exists already on the release commit" <<<"$OUT" &&
	pass "tag: an annotated tag on the release commit is accepted (peeled)" ||
	fail "tag: an annotated tag on the release commit is accepted" "rc=$RC: $OUT"

empty_state
git --git-dir="$REMOTE" update-ref "refs/tags/$TAG" "$LATER_COMMIT"
signr "$TAG" --no-dispatch
expect_preflight_err "tag: a tag on another commit is refused before signing" \
	"git tag $TAG exists and points to $LATER_COMMIT, not to the release commit $COMMIT" \
	"make the next attempt with a new version number" "a maintainer can delete the tag (git push <remote> --delete refs/tags/$TAG)"
[ "$(uploads)" = 0 ] && ! grep -q 'Making the PGP' <<<"$OUT" && pass "tag: refused tag: nothing signed, nothing uploaded" ||
	fail "tag: refused tag: nothing signed, nothing uploaded" "$OUT"

empty_state
git --git-dir="$REMOTE" -c user.name=maint -c user.email=maint@example.invalid tag -a -m "elsewhere" "$TAG" "$LATER_COMMIT"
signr "$TAG" --no-dispatch
expect_preflight_err "tag: an annotated tag on another commit is refused (peeled)" "git tag $TAG exists and points to $LATER_COMMIT"

# Fallback 1: a shallow checkout without the release commit.
SHALLOW="$T/shallow"
git clone -q --depth 1 "file://$REPO" "$SHALLOW"
if [ "$(git -C "$SHALLOW" rev-parse --is-shallow-repository)" = true ] && ! git -C "$SHALLOW" cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
	empty_state
	run env PATH="$T/bin:$PATH" FAKE_GH_STATE="$GHS" FAKE_GH_CHECKOUT="$SHALLOW" RELEASE_SIGNING_KEY="$FPR_A" RELEASE_SECRETS_FILE="$SIGN_SECRETS" \
		"$SHALLOW/dev-scripts/release/sign-release.sh" "$TAG" --no-dispatch
	if [ "$RC" = 0 ] && grep -qF "a plain tag $TAG through the API after the upload, because this checkout is shallow" <<<"$OUT" &&
		grep -qF "FALLBACK: a plain tag through the API, because this checkout is shallow" <<<"$OUT" &&
		[ "$(tag_type "$TAG")" = commit ] && [ "$(tag_peeled "$TAG")" = "$COMMIT" ] &&
		grep -q "^api -X POST repos/$GH_REPO/git/refs -f ref=refs/tags/$TAG -f sha=$COMMIT" "$GHS/calls.log" &&
		! git -C "$SHALLOW" cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
		pass "tag: fallback to a plain API tag in a shallow checkout (no fetch)"
	else
		fail "tag: fallback in a shallow checkout" "rc=$RC: $OUT"
	fi
	stage
	expect_ok "tag: stage accepts the plain tag"
else
	fail "tag: fallback in a shallow checkout" "fixture problem: the clone is not shallow, or it holds the release commit"
fi

# Fallback 2: gpg-agent forgot the key, so a signed tag would need a prompt.
mkdir -p "$T/gpgwrap"
cat >"$T/gpgwrap/gpg" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
	case "\$a" in *tag.payload) echo "gpg: signing failed: No pinentry" >&2; exit 2 ;; esac
done
exec "$(command -v gpg)" "\$@"
EOF
chmod +x "$T/gpgwrap/gpg"
empty_state
run env PATH="$T/gpgwrap:$T/bin:$PATH" FAKE_GH_STATE="$GHS" FAKE_GH_CHECKOUT="$REPO" RELEASE_SIGNING_KEY="$FPR_A" RELEASE_SECRETS_FILE="$SIGN_SECRETS" \
	"$REPO/dev-scripts/release/sign-release.sh" "$TAG" --no-dispatch
[ "$RC" = 0 ] && grep -qF "FALLBACK: a plain tag through the API, because gpg-agent no longer holds the unlocked release key, and a signed tag would need a second passphrase prompt" <<<"$OUT" &&
	[ "$(tag_type "$TAG")" = commit ] && [ "$(tag_peeled "$TAG")" = "$COMMIT" ] &&
	pass "tag: fallback to a plain API tag when the key would need a second prompt" ||
	fail "tag: fallback when the key would need a second prompt" "rc=$RC: $OUT"

# Fallback 3: the push of the signed tag fails.
empty_state
printf '#!/bin/sh\necho "push denied" >&2\nexit 1\n' >"$REMOTE/hooks/pre-receive"
chmod +x "$REMOTE/hooks/pre-receive"
signr "$TAG" --no-dispatch
[ "$RC" = 0 ] && grep -qF "FALLBACK: a plain tag through the API, because git push of the signed tag failed" <<<"$OUT" &&
	[ "$(tag_type "$TAG")" = commit ] && pass "tag: fallback to a plain API tag when the push fails" ||
	fail "tag: fallback when the push fails" "rc=$RC: $OUT"

empty_state
printf '#!/bin/sh\nexit 1\n' >"$REMOTE/hooks/pre-receive"
chmod +x "$REMOTE/hooks/pre-receive"
touch "$GHS/deny_api_tag"
signr "$TAG" --no-dispatch
expect_err "tag: push and API both refused" "cannot create the git tag $TAG. The draft holds the signed files. Run this script again"
[ -z "$(remote_tag "$TAG")" ] && pass "tag: push and API both refused: no tag" || fail "tag: push and API both refused: no tag" "$(remote_tag "$TAG")"

# The finalize step never creates a tag.
fake_state
git --git-dir="$REMOTE" update-ref -d "refs/tags/$TAG"
stage
expect_err "stage: no tag" "git tag $TAG does not exist" "The finalize workflow never creates a tag"
fake_state
stage
git --git-dir="$REMOTE" update-ref -d "refs/tags/$TAG"
publish
expect_err "publish: no tag" "git tag $TAG does not exist" "The finalize workflow never creates a tag"
[ "$(jq -r .draft "$GHS/release.json")" = true ] && [ -z "$(remote_tag "$TAG")" ] &&
	pass "publish: no tag: still a draft, and still no tag" || fail "publish: no tag: still a draft, and still no tag" "$OUT"
fake_state
stage
git --git-dir="$REMOTE" update-ref "refs/tags/$TAG" "$LATER_COMMIT"
publish
expect_err "publish: tag on another commit" "git tag $TAG points to $LATER_COMMIT, not to the release commit $COMMIT" "make the next attempt with a new version number"
[ "$(jq -r .draft "$GHS/release.json")" = true ] && pass "publish: tag on another commit: still a draft" || fail "publish: tag on another commit: still a draft" "published"
# The tag moves after the first check: the check right before the flip sees it.
fake_state
stage
rm -f "$GHS/tagreads"
cat >"$GHS/move_tag_on_read" <<EOF
2 $LATER_COMMIT
EOF
publish
expect_err "publish: tag moved between the checks, refused right before the flip" "git tag $TAG points to $LATER_COMMIT"
[ "$(jq -r .draft "$GHS/release.json")" = true ] && pass "publish: tag moved before the flip: still a draft" || fail "publish: tag moved before the flip: still a draft" "published"

# ---------------------------------------------------------------------------
echo
echo "== local steps: Apple, Flatpak, Homebrew (real modules)"
# Real modules: apple.sh with rcodesign and xpwn (dmg, hfsplus) and a
# throwaway self-signed certificate (no Apple network: notarization runs
# through a stub of "rcodesign notary-submit", the rest is the real
# rcodesign); flatpak.sh with gpg on the dummy repository of the Flatpak module
# test; a stand-in Homebrew generator (the real generator of the worktree runs
# on its own below). The finalize flatpak command runs the real
# flatpak-finalize.sh in the ubuntu image of the Flatpak module test (flatpak
# and ostree), with jq from the host. verify-macos.sh needs macOS: on Linux the
# test checks the arguments that it gets (stand-in), and that the real script
# accepts them up to its macOS check.
SW="$(cd "$HERE/.." && pwd)"
if [ -n "${APPLE_FIXTURE_DIR:-}" ]; then
	APPLE_IN="$APPLE_FIXTURE_DIR"
else
	APPLE_IN="$(ls -d "$SW"/apple-module/run.*/in 2>/dev/null | while read -r d; do [ -f "$d/testapp_aarch64.app.unsigned.tar" ] && echo "$d"; done | tail -n 1)"
fi
FP_CI="${FLATPAK_FIXTURE_DIR:-$SW/flatpak-module/work/ci1}"
P="$T/prepo"
PCFG="$P/dev-scripts/release/config.json"
FP_IMAGE="flatpak-module-ubuntu:24.04"

platform_ready=1
# apple.sh rebuilds the DMG with xpwn (dmg, hfsplus) on Linux, with hdiutil
# on macOS.
apple_tools="rcodesign hdiutil ditto"
[ "$HOST_OS" = Darwin ] || apple_tools="rcodesign dmg hfsplus"
for need in $apple_tools; do
	PATH="$APPLE_TOOLS_PATH$PATH" command -v "$need" >/dev/null 2>&1 || { platform_ready=0; echo "missing tool for the Apple steps: $need"; }
done
[ -n "$APPLE_IN" ] || { platform_ready=0; echo "missing fixture: $SW/apple-module/run.*/in/testapp_aarch64.app.unsigned.tar"; }
[ -f "$FP_CI/flatpak-to-sign.tar" ] && [ -f "$FP_CI/flatpak-repo.tar" ] || { platform_ready=0; echo "missing fixture: $FP_CI"; }

if [ "$platform_ready" = 0 ]; then
	fail "local steps" "the tools or fixtures of the real modules are missing (see above)"
else
# The name of the app in the fixture (the top directory of the archive).
APP_DIR_NAME="$(tar -tf "$APPLE_IN/testapp_aarch64.app.unsigned.tar" | head -n 1 | cut -d/ -f1)"
mkdir -p "$P/dev-scripts/release" "$P/keys" "$P/pages" "$P/src-tauri" "$P/brew" "$P/icons"
cp "$SCRIPTS"/*.sh "$SCRIPTS"/*.py "$P/dev-scripts/release/"
cp "$REPO"/keys/*.asc "$P/keys/"
cp "$REPO/dev-scripts/release/allowed-signers.txt" "$P/dev-scripts/release/"
cp "$REPO/tauri.conf.json" "$P/"
cat >"$P/src-tauri/Entitlements.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
</dict>
</plist>
EOF
cat >"$P/brew/testapp.rb.template" <<'EOF'
cask "testapp" do
  version "VERSION_PLACEHOLDER"

  on_arm do
    sha256 "AARCH64_SHA256_PLACEHOLDER"
    url "https://github.com/example-owner/example-repo/releases/download/TAG_PLACEHOLDER/testapp_#{version}_aarch64.dmg"
  end
end
EOF
# The stand-in Homebrew generator: the interface of
# dev-scripts/homebrew/generate-formula.sh (TAG AARCH64_DMG X64_DMG OUTPUT),
# with the template next to it. It records its arguments.
cat >"$P/brew/generate-formula.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$@" >"$T/brew-args"
[ \$# -eq 4 ] && [ ! -e "\$4" ]
a="\$(shasum -a 256 "\$2" 2>/dev/null || sha256sum "\$2")"
a="\${a%% *}"
sed -e "s|VERSION_PLACEHOLDER|\${1#v}|g" -e "s|TAG_PLACEHOLDER|\$1|g" -e "s|AARCH64_SHA256_PLACEHOLDER|\$a|g" \
	"\$(dirname "\${BASH_SOURCE[0]}")/testapp.rb.template" >"\$4"
EOF
printf '<html>test</html>\n' >"$P/pages/index.html"
printf 'not really a png\n' >"$P/icons/icon.png"
printf '# test readme\n' >"$P/README.md"
printf '[Flatpak Repo]\nUrl=%%Url%%\nHomepage=%%Homepage%%\nGPGKey=%%GPGKey%%\nTitle=test\n' >"$P/pages/test.flatpakrepo"
printf '[Flatpak Ref]\nName=org.test.Hello\nBranch=stable\nUrl=%%Url%%\nHomepage=%%Homepage%%\nGPGKey=%%GPGKey%%\nIsRuntime=false\n' >"$P/pages/org.test.Hello.flatpakref"
jq --arg fpr "$FPR_A" '{repository, build_workflow, build_event, finalize_workflow, artifact_pattern, ci_artifact_pattern, signer_keys_dir, allowed_signers, updater,
	apple: {entitlements_file: "src-tauri/Entitlements.plist", notarize: false, requirement: "anchor apple generic", team_id: "ZZTEST0001", bundle_id: "org.test.app"},
	flatpak: {app_id: "org.test.Hello", arch: "x86_64", branch: "stable",
		extra_refs: ["runtime/org.test.Hello.Locale/x86_64/stable", "runtime/org.test.Platform/x86_64/1"],
		fingerprint: $fpr, bundle_name: "org.test.Hello.flatpak",
		pages: ["pages/index.html", "pages/test.flatpakrepo", "pages/org.test.Hello.flatpakref", "icons/icon.png", "README.md"],
		url: "https://example-owner.github.io/example-repo", homepage: "https://github.com/example-owner/example-repo",
		to_sign: "flatpak-to-sign.tar", repo_tar: "flatpak-repo.tar", signatures: "flatpak-signatures.tar"},
	homebrew: {generator: "brew/generate-formula.sh", output: "testapp.rb", dmg: {aarch64: "testapp_{version}_aarch64.dmg", x64: "testapp_{version}_aarch64.dmg"}},
	products: [
		{name: "tool_{version}_Linux_x86_64.tar", origin: "build"},
		{name: "testapp_aarch64.app.unsigned.tar", origin: "input"},
		{name: "testapp_{version}_aarch64.unsigned.dmg", origin: "input"},
		{name: "flatpak-to-sign.tar", origin: "input"},
		{name: "flatpak-repo.tar", origin: "ci"},
		{name: "testapp_aarch64.app.tar.gz", origin: "local", updater: ["darwin-aarch64"]},
		{name: "testapp_{version}_aarch64.dmg", origin: "local"},
		{name: "flatpak-signatures.tar", origin: "local"},
		{name: "testapp.rb", origin: "local"}]}' "$CFG" >"$PCFG"
git -C "$P" init -q
git -C "$P" add -A
git -C "$P" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false commit -q -m "platform test repository"
PCFG_GOOD="$T/pcfg-good.json"
cp "$PCFG" "$PCFG_GOOD"
# pcfg FILTER: commits a changed configuration (the signer needs a clean checkout).
pcfg() {
	jq "$1" "$PCFG_GOOD" >"$PCFG"
	git -C "$P" diff --quiet ||
		git -C "$P" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false commit -q -am "test configuration"
}

# The Apple secrets: a throwaway certificate and a fake App Store Connect key.
mkdir -m 700 "$T/p12"
p12_pw="tp-$(od -A n -t x1 -N 8 /dev/urandom | tr -d ' \n')"
PATH="$APPLE_TOOLS_PATH$PATH" rcodesign generate-self-signed-certificate -C /dev/null --person-name "Throwaway Test Signer" \
	--profile developer-id-application --team-id ZZTEST0001 --p12-file "$T/p12/t.p12" --p12-password "$p12_pw" >/dev/null 2>&1
api_b64="$(printf '{"issuer_id":"00000000-0000-0000-0000-000000000000","key_id":"TESTKEY001","private_key":"-----BEGIN PRIVATE KEY-----\\nFAKE\\n-----END PRIVATE KEY-----\\n"}' | b64)"
PSECRETS="$HOME/p-secrets.json.gpg"
PSECRETS_NOAPPLE="$HOME/p-secrets-noapple.json.gpg"
jq -n --rawfile k "$T/tauri1.key" --arg pw "$TAURI_PW" --arg p12 "$(b64 "$T/p12/t.p12")" --arg p12pw "$p12_pw" --arg api "$api_b64" \
	'{TAURI_SIGNING_PRIVATE_KEY: ($k | rtrimstr("\n")), TAURI_SIGNING_PRIVATE_KEY_PASSWORD: $pw, APPLE_P12_BASE64: $p12, APPLE_P12_PASSWORD: $p12pw, APPLE_API_KEY_JSON_BASE64: $api}' |
	gpg --batch --yes --trust-model always -r "$FPR_A" --encrypt -o "$PSECRETS"
jq -n --rawfile k "$T/tauri1.key" --arg pw "$TAURI_PW" '{TAURI_SIGNING_PRIVATE_KEY: ($k | rtrimstr("\n")), TAURI_SIGNING_PRIVATE_KEY_PASSWORD: $pw}' |
	gpg --batch --yes --trust-model always -r "$FPR_A" --encrypt -o "$PSECRETS_NOAPPLE"

# init-secrets.sh: a new file with the updater key, then an update that adds
# the Apple group (the throwaway certificate and an API key file).
ISEC="$HOME/init-apple/secrets.json.gpg"
printf '{"issuer_id":"00000000-0000-0000-0000-000000000000","key_id":"TESTKEY001","private_key":"RkFLRSBLRVk="}\n' >"$T/p12/api.json"
chmod 600 "$T/p12/api.json" "$T/p12/t.p12"
isec() { # INPUT OPTION
	RC=0
	OUT="$(printf '%s' "$1" | env PATH="$APPLE_TOOLS_PATH$PATH" RELEASE_SECRETS_FILE="$ISEC" RELEASE_SIGNING_KEY="$FPR_A" \
		"$P/dev-scripts/release/init-secrets.sh" --repo "$GH_REPO" "$2" 2>&1)" || RC=$?
}
isec "$T/tauri1.key"$'\n'"$TAURI_PW"$'\n' --updater
expect_ok "init secrets: new file with the updater key (platform checkout)"
isec "$T/p12/t.p12"$'\n'"$p12_pw"$'\n'"$T/p12/api.json"$'\n' --apple
json="$(gpg --batch --quiet --decrypt "$ISEC" 2>/dev/null)" || json="{}"
if [ "$RC" = 0 ] && grep -qF "Apple certificate: Developer ID Application: Throwaway Test Signer (ZZTEST0001)" <<<"$OUT" &&
	grep -qF "Set: APPLE_P12_BASE64 APPLE_P12_PASSWORD APPLE_API_KEY_JSON_BASE64" <<<"$OUT" &&
	grep -qF "Kept unchanged: TAURI_SIGNING_PRIVATE_KEY TAURI_SIGNING_PRIVATE_KEY_PASSWORD" <<<"$OUT" &&
	[ "$(printf '%s' "$json" | jq -r .APPLE_P12_BASE64)" = "$(b64 "$T/p12/t.p12")" ] &&
	[ "$(printf '%s' "$json" | jq -r .APPLE_P12_PASSWORD)" = "$p12_pw" ] &&
	[ "$(printf '%s' "$json" | jq -r .APPLE_API_KEY_JSON_BASE64 | base64 --decode)" = "$(cat "$T/p12/api.json")" ] &&
	[ "$(printf '%s' "$json" | jq -r .TAURI_SIGNING_PRIVATE_KEY)" = "$(cat "$T/tauri1.key")" ] &&
	[ "$(ls "$ISEC".backup-* 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && [ "$(mode_of "$ISEC")" = 600 ]; then
	pass "init secrets: an update adds the Apple group, keeps the updater key, and keeps a backup"
else
	fail "init secrets: update with the Apple group" "rc=$RC: $OUT"
fi
json=""
rm -rf "$T/p12"

# A stub for "rcodesign notary-submit" only; every other call goes to rcodesign.
mkdir -p "$T/notary-stub"
cat >"$T/notary-stub/rcodesign" <<EOF
#!/usr/bin/env bash
if [ "\$1" = notary-submit ]; then
	printf '%s\n' "\$*" >>"$T/notary.log"
	echo "stub: notarized and stapled" >&2
	exit 0
fi
exec "$(PATH="$APPLE_TOOLS_PATH$PATH" command -v rcodesign)" "\$@"
EOF
chmod +x "$T/notary-stub/rcodesign"

# platform_state: a draft without files, and a build run with the platform products.
platform_state() {
	local dir="$GHS/runs/$RUN_ID/artifacts"
	empty_state
	rm -rf "$GHS/runs/$RUN_ID/artifacts"
	mkdir -p "$dir/release-files" "$dir/ci-repo" "$dir/release-build-manifest"
	printf 'build tool\n' >"$dir/release-files/tool_1.2.3_Linux_x86_64.tar"
	cp "$APPLE_IN/testapp_aarch64.app.unsigned.tar" "$dir/release-files/"
	cp "$APPLE_IN/testapp_0.0.1_aarch64.unsigned.dmg" "$dir/release-files/testapp_1.2.3_aarch64.unsigned.dmg"
	cp "$FP_CI/flatpak-to-sign.tar" "$dir/release-files/"
	cp "$FP_CI/flatpak-repo.tar" "$dir/ci-repo/"
	set_run_info "$RUN_ID" "$TAG" "$COMMIT"
	mkdir -p "$GHS/contents/$COMMIT/src-tauri"
	cp "$P/src-tauri/Entitlements.plist" "$GHS/contents/$COMMIT/src-tauri/"
}
psign() { # [SECRETS_FILE] [extra PATH]
	run env PATH="${2:-}$APPLE_TOOLS_PATH$T/bin:$PATH" FAKE_GH_STATE="$GHS" FAKE_GH_CHECKOUT="$P" RELEASE_SIGNING_KEY="$FPR_A" \
		RELEASE_SECRETS_FILE="${1:-$PSECRETS}" APPLE_TIMESTAMP_URL=none \
		"$P/dev-scripts/release/sign-release.sh" "$TAG" --no-dispatch
}
pfin() { run env PATH="$T/bin:$PATH" FAKE_GH_STATE="$GHS" GH_TOKEN=fake-token GITHUB_SHA="$HEAD_SHA" "$P/dev-scripts/release/finalize-release.sh" "$@"; }

platform_state
psign
PDMG=testapp_1.2.3_aarch64.dmg PAPP=testapp_aarch64.app.tar.gz
if [ "$RC" != 0 ]; then
	fail "local steps: good case" "rc=$RC:"$'\n'"$OUT"
else
	problems=""
	for n in $PAPP $PAPP.sig $PAPP.asc $PDMG $PDMG.asc flatpak-signatures.tar flatpak-signatures.tar.asc testapp.rb testapp.rb.asc latest.json SHA256SUMS SHA256SUMS.asc; do
		in_draft "$n" || problems="$problems $n missing on the draft;"
	done
	for n in testapp_aarch64.app.unsigned.tar testapp_1.2.3_aarch64.unsigned.dmg flatpak-to-sign.tar flatpak-repo.tar; do
		! in_draft "$n" || problems="$problems input or ci file $n uploaded;"
	done
	for n in testapp.rb flatpak-signatures.tar $PDMG $PAPP; do
		grep -q "  $n\$" "$GHS/assets/SHA256SUMS" || problems="$problems SHA256SUMS does not list $n;"
	done
	# The order of the steps, and the time of each phase.
	order="$(grep -nE '^==> (Apple|Flatpak|Homebrew|Making the updater)' <<<"$OUT" | cut -d' ' -f2 | tr '\n' ' ')"
	[ "$order" = "Apple: Flatpak: Homebrew: Making " ] || problems="$problems step order: $order;"
	for ph in Apple Flatpak Homebrew "updater signatures" "PGP signatures" "git tag" upload; do
		grep -qE "\\($ph: [0-9]+ s\\)" <<<"$OUT" || problems="$problems no time for the phase $ph;"
	done
	! grep -q "notarizing" <<<"$OUT" && [ ! -e "$T/notary.log" ] || problems="$problems notarized with notarize=false;"
	# Apple: signed by the throwaway certificate.
	info="$(PATH="$APPLE_TOOLS_PATH$PATH" rcodesign print-signature-info "$GHS/assets/$PDMG" 2>&1)" || true
	grep -q "Throwaway Test Signer" <<<"$info" || problems="$problems the DMG is not signed by the test certificate;"
	tar -tzf "$GHS/assets/$PAPP" | grep -qxF "$APP_DIR_NAME/Contents/_CodeSignature/CodeResources" || problems="$problems the app has no bundle seal;"
	# Flatpak: the approved refs and signatures by the configured key.
	mkdir -p "$T/pfsig" "$T/pfin"
	tar -xf "$GHS/assets/flatpak-signatures.tar" -C "$T/pfsig"
	tar -xf "$FP_CI/flatpak-to-sign.tar" -C "$T/pfin"
	cmp -s "$T/pfsig/refs.txt" "$T/pfin/refs.txt" || problems="$problems the approved refs.txt differs;"
	[ "$(gpg --batch --status-fd 1 --verify "$T/pfsig/summary.sig" "$T/pfin/summary" 2>/dev/null | awk '$2 == "VALIDSIG" { print $NF }')" = "$FPR_A" ] ||
		problems="$problems summary.sig is not a signature by $FPR_A;"
	[ "$(find "$T/pfsig/objects" -name '*.commit.sig' | wc -l | tr -d ' ')" = 6 ] || problems="$problems not 6 commit signatures;"
	if [ -z "$problems" ]; then pass "local steps: Apple, Flatpak, and Homebrew products, signed and uploaded, in order, with phase times"; else fail "local steps: good case" "$problems"$'\n'"$OUT"; fi
	printf '      phases: %s\n' "$(grep -oE '\((preflight|unlock|download|provenance check|Apple|Flatpak|Homebrew|updater signatures|PGP signatures|self-check|upload|git tag): [0-9]+ s\)' <<<"$OUT" | tr '\n' ' ')"
fi

expected_rb="$(sed -e "s|VERSION_PLACEHOLDER|1.2.3|g" -e "s|TAG_PLACEHOLDER|$TAG|g" \
	-e "s|AARCH64_SHA256_PLACEHOLDER|$(sha256 "$GHS/assets/$PDMG" | cut -d' ' -f1)|g" "$P/brew/testapp.rb.template")"
[ "$RC" = 0 ] && [ "$(cat "$GHS/assets/testapp.rb")" = "$expected_rb" ] &&
	grep -qF "url \"https://github.com/example-owner/example-repo/releases/download/$TAG/testapp_#{version}_aarch64.dmg\"" "$GHS/assets/testapp.rb" &&
	[ "$(sed -n 1p "$T/brew-args")" = "$TAG" ] && [ "$(sed -n 2p "$T/brew-args" | sed 's|.*/||')" = "$PDMG" ] &&
	[ "$(sed -n 3p "$T/brew-args" | sed 's|.*/||')" = "$PDMG" ] && [ "$(sed -n 4p "$T/brew-args" | sed 's|.*/||')" = testapp.rb ] &&
	! grep -q 'contents/brew' "$GHS/calls.log" &&
	pass "homebrew: the generator of the checkout gets TAG AARCH64_DMG X64_DMG OUTPUT; the formula holds the version, the tag, and the SHA-256 of the signed DMG" ||
	fail "homebrew: formula content" "$(cat "$GHS/assets/testapp.rb" 2>&1)"

pfin stage --tag "$TAG" --run-id "$RUN_ID" --repo "$GH_REPO" --repo-root "$P" --out "$T/p-staged"
expect_ok "local steps: stage verifies the signed release"
PSHA="$(sha256 "$GHS/assets/SHA256SUMS" | cut -d' ' -f1)"

# The real generator of the worktree (dev-scripts/homebrew/generate-formula.sh,
# owned by the workflow engineer), with the real configuration. Its template
# writes the tag into the download URL (TAG_PLACEHOLDER). For a tag without
# "v", the formula must name the same URLs and hashes as the formula of the
# production job, which filled the template of origin/master (5.0.4: URL with
# #{version}) with sed.
GEN="$SCRIPTS/../homebrew/generate-formula.sh"
REAL_CFG="$SCRIPTS/config.json"
[ "$(jq -r .homebrew.generator "$REAL_CFG")" = dev-scripts/homebrew/generate-formula.sh ] && [ -f "$SCRIPTS/../../$(jq -r .homebrew.generator "$REAL_CFG")" ] &&
	[ "$(jq -c '.homebrew.dmg' "$REAL_CFG")" = '{"aarch64":"sampleapp_{version}_aarch64.dmg","x64":"sampleapp_{version}_x64.dmg"}' ] &&
	[ "$(jq -r .homebrew.output "$REAL_CFG")" = sampleapp.rb ] &&
	pass "homebrew: the real configuration names the generator of the repository, the two DMG products, and sampleapp.rb" ||
	fail "homebrew: real configuration" "$(jq -c .homebrew "$REAL_CFG")"
PROD_TMPL="$T/sampleapp.rb.prod"
cat >"$PROD_TMPL" <<'EOF'
cask "sampleapp" do
  version "VERSION_PLACEHOLDER"

  on_arm do
    sha256 "AARCH64_SHA256_PLACEHOLDER"
    url "https://github.com/example-owner/example-repo/releases/download/#{version}/sampleapp_#{version}_aarch64.dmg"
  end

  on_intel do
    sha256 "X64_SHA256_PLACEHOLDER"
    url "https://github.com/example-owner/example-repo/releases/download/#{version}/sampleapp_#{version}_x64.dmg"
  end

  name "Sampleapp"
  desc "Sample application"
  homepage "https://github.com/example-owner/example-repo"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true

  app "sampleapp.app"
end
EOF
B="$T/brew-real"
mkdir -p "$B"
printf 'arm dmg\n' >"$B/sampleapp_5.0.4_aarch64.dmg"
printf 'intel dmg\n' >"$B/sampleapp_5.0.4_x64.dmg"
a="$(sha256 "$B/sampleapp_5.0.4_aarch64.dmg" | cut -d' ' -f1)"
x="$(sha256 "$B/sampleapp_5.0.4_x64.dmg" | cut -d' ' -f1)"
sed -e "s/VERSION_PLACEHOLDER/5.0.4/g" -e "s/AARCH64_SHA256_PLACEHOLDER/$a/g" -e "s/X64_SHA256_PLACEHOLDER/$x/g" "$PROD_TMPL" >"$B/production.rb"
sed -e "s/VERSION_PLACEHOLDER/5.0.4/g" -e "s/TAG_PLACEHOLDER/5.0.4/g" -e "s/AARCH64_SHA256_PLACEHOLDER/$a/g" -e "s/X64_SHA256_PLACEHOLDER/$x/g" \
	"$SCRIPTS/../homebrew/sampleapp.rb.template" >"$B/expected.rb"
run bash "$GEN" 5.0.4 "$B/sampleapp_5.0.4_aarch64.dmg" "$B/sampleapp_5.0.4_x64.dmg" "$B/sampleapp.rb"
[ "$RC" = 0 ] && cmp -s "$B/expected.rb" "$B/sampleapp.rb" &&
	cmp -s "$B/production.rb" <(sed 's|/releases/download/5\.0\.4/|/releases/download/#{version}/|' "$B/sampleapp.rb") &&
	pass "homebrew: the real generator fills its template for tag 5.0.4; the formula differs from the production one only in the literal tag in the URL" ||
	fail "homebrew: real generator, tag 5.0.4" "rc=$RC: $OUT $(diff "$B/expected.rb" "$B/sampleapp.rb" 2>&1) $(diff "$B/production.rb" "$B/sampleapp.rb" 2>&1)"
run bash "$GEN" v5.0.4 "$B/sampleapp_5.0.4_aarch64.dmg" "$B/sampleapp_5.0.4_x64.dmg" "$B/sampleapp-v.rb"
[ "$RC" = 0 ] && grep -qx '  version "5.0.4"' "$B/sampleapp-v.rb" &&
	grep -qF 'releases/download/v5.0.4/sampleapp_#{version}_aarch64.dmg' "$B/sampleapp-v.rb" &&
	pass "homebrew: the real generator takes a tag with a leading v (version without it, URL with the tag)" ||
	fail "homebrew: real generator, tag v5.0.4" "rc=$RC: $OUT $(cat "$B/sampleapp-v.rb" 2>&1)"
run bash "$GEN" 5.0.4 "$B/sampleapp_5.0.4_aarch64.dmg" "$B/sampleapp_5.0.4_x64.dmg" "$B/sampleapp.rb"
expect_err "homebrew: the real generator refuses an existing output" "exists already"
# bash 3.2 with busybox (the image of the Flatpak module test): the bash of
# macOS, with a userland that is not GNU. On macOS: /bin/bash itself.
if [ "$HOST_OS" = Darwin ]; then
	RC=0
	OUT="$( { /bin/bash --version | head -n 1; /bin/bash "$GEN" 5.0.4 "$B/sampleapp_5.0.4_aarch64.dmg" "$B/sampleapp_5.0.4_x64.dmg" "$B/sampleapp-b32.rb"; } 2>&1)" || RC=$?
	[ "$RC" = 0 ] && grep -q 'version 3\.2' <<<"$OUT" && cmp -s "$B/expected.rb" "$B/sampleapp-b32.rb" &&
		pass "homebrew: the real generator runs under /bin/bash 3.2 of macOS and gives the same bytes" ||
		fail "homebrew: real generator under bash 3.2" "rc=$RC: $OUT"
elif docker image inspect flatpak-module-bash32:1 >/dev/null 2>&1; then
	RC=0
	OUT="$(docker run --rm --network none --user "$(id -u):$(id -g)" -v "$(cd "$SCRIPTS/../homebrew" && pwd):/gen:ro" -v "$B:/b" \
		flatpak-module-bash32:1 bash -c 'bash --version | head -n 1; bash /gen/generate-formula.sh 5.0.4 /b/sampleapp_5.0.4_aarch64.dmg /b/sampleapp_5.0.4_x64.dmg /b/sampleapp-b32.rb' 2>&1)" || RC=$?
	[ "$RC" = 0 ] && grep -q 'version 3\.2' <<<"$OUT" && cmp -s "$B/expected.rb" "$B/sampleapp-b32.rb" &&
		pass "homebrew: the real generator runs under bash 3.2 with busybox and gives the same bytes" ||
		fail "homebrew: real generator under bash 3.2" "rc=$RC: $OUT"
else
	fail "homebrew: real generator under bash 3.2" "docker image flatpak-module-bash32:1 not found (built by flatpak-module/test-flatpak.sh)"
fi

# The generator directory belongs to the clean checkout.
platform_state
printf 'x\n' >"$P/brew/stray.txt"
psign
expect_preflight_err "homebrew: an untracked file next to the generator stops the signer" "has changed, untracked, or ignored files" "?? brew/stray.txt"
rm "$P/brew/stray.txt"

# Notarization follows apple.notarize in the committed configuration only.
pcfg '.apple.notarize = true'
platform_state
psign "" "$T/notary-stub:"
if [ "$RC" = 0 ] && grep -qF "notarize=true (from config.json)" <<<"$OUT" && grep -q "notarizing" <<<"$OUT" &&
	[ "$(grep -c '^notary-submit .*--wait --staple' "$T/notary.log" 2>/dev/null)" = 1 ]; then
	pass "local steps: apple.notarize=true in config.json notarizes (stub notary)"
else
	fail "local steps: notarize=true" "rc=$RC: $OUT"
fi
run env "$P/dev-scripts/release/sign-release.sh" "$TAG" --notarize
expect_err "local steps: no command line switch for notarization" "usage: sign-release.sh TAG"

# Missing Apple secrets: stop right after the decryption, before the download.
platform_state
psign "$PSECRETS_NOAPPLE"
expect_err "local steps: Apple secrets missing" "holds no Apple signing secrets (APPLE_P12_BASE64, APPLE_P12_PASSWORD, APPLE_API_KEY_JSON_BASE64)" \
	"config.json has an apple section" "Add them with: just release-signing-setup"
! grep -q "Downloading the build output" <<<"$OUT" && [ "$(uploads)" = 0 ] &&
	pass "local steps: Apple secrets missing: stops before the download" || fail "local steps: Apple secrets missing: stops before the download" "$OUT"
pcfg '.'

# The certificate of another team: the signer stops right after the
# decryption, before any signature (step 3 would refuse the release).
pcfg '.apple.team_id = "ZZOTHER001"'
platform_state
psign
expect_err "local steps: Apple certificate of another team" \
	"the Apple certificate in the secrets belongs to team ZZTEST0001, but apple.team_id in config.json is ZZOTHER001"
! grep -qE "release signing self-test|Downloading the build output|Making the PGP signatures|signing .*\.app" <<<"$OUT" &&
	[ "$(uploads)" = 0 ] && [ -z "$(remote_tag "$TAG")" ] &&
	pass "local steps: another team: stops before any signature, download, upload, or tag" ||
	fail "local steps: another team: stops before any signature" "$OUT"
pcfg '.'

# A wrong Flatpak key.
jq --arg f "$FPR_B" '.flatpak.fingerprint = $f' "$PCFG_GOOD" >"$PCFG"
git -C "$P" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false commit -q -am "test configuration"
platform_state
psign
expect_preflight_err "flatpak: a key that is not on the allowlist" "flatpak.fingerprint $FPR_B is not on the allowlist"
FPR_F="$(genkey signer-f)"
gpg --batch --armor --export "$FPR_F" >"$P/keys/signer-F.asc"
printf '%s\n' "$FPR_F" >>"$P/dev-scripts/release/allowed-signers.txt"
gpg --batch --yes --delete-secret-keys "$FPR_F" >/dev/null 2>&1
jq --arg f "$FPR_F" '.flatpak.fingerprint = $f' "$PCFG_GOOD" >"$PCFG"
git -C "$P" add -A
git -C "$P" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false commit -q -m "test: flatpak key without a secret key"
platform_state
psign
expect_preflight_err "flatpak: an allowed key without a local secret key" "no secret key for the Flatpak signing key $FPR_F"
git -C "$P" rm -q "keys/signer-F.asc"
sed "/^$FPR_F\$/d" "$P/dev-scripts/release/allowed-signers.txt" >"$T/allowed.tmp"
mv "$T/allowed.tmp" "$P/dev-scripts/release/allowed-signers.txt"
cp "$PCFG_GOOD" "$PCFG"
git -C "$P" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false commit -q -am "test: back to the good configuration"
pcfg '.flatpak.extra_refs = ["runtime/org.test.Hello.Locale/x86_64/stable"]'
platform_state
psign
expect_err "flatpak: refs differ from the configuration" "runtime/org.test.Platform/x86_64/1: in refs.txt, not in the expected ref list" "Flatpak signing failed"
[ "$(uploads)" = 0 ] && pass "flatpak: refs differ: nothing uploaded" || fail "flatpak: refs differ: nothing uploaded" "$(uploads) uploads"
pcfg '.'

# Configuration checks of the new sections.
pcfg_case() { # NAME FILTER SUBSTRING...
	local name="$1" filter="$2"
	shift 2
	jq "$filter" "$PCFG_GOOD" >"$T/pcfg-case.json"
	run env RELEASE_CONFIG="$T/pcfg-case.json" "$P/dev-scripts/release/verify-release.sh" --dir "$T/p-staged" --repo "$GH_REPO" \
		--tag "$TAG" --commit "$COMMIT" --run-id "$RUN_ID" --repo-root "$P"
	expect_err "config: $name" "$@"
}
run env "$P/dev-scripts/release/verify-release.sh" --dir "$T/p-staged" --repo "$GH_REPO" --tag "$TAG" --commit "$COMMIT" --run-id "$RUN_ID" --repo-root "$P"
expect_ok "config: the platform configuration and its release pass verify-release.sh"
pcfg_case "apple without the local app archive" '.products |= map(select(.name != "testapp_aarch64.app.tar.gz"))' \
	"apple: the input product testapp_aarch64.app.unsigned.tar needs the local product testapp_aarch64.app.tar.gz"
pcfg_case "apple notarize as a string" '.apple.notarize = "yes"' "apple.notarize must be true or false"
pcfg_case "apple unknown key" '.apple.notary = true' "apple has an unknown key: notary"
pcfg_case "apple entitlements path with .." '.apple.entitlements_file = "../x.plist"' "apple.entitlements_file must be a plain relative path"
pcfg_case "apple team id" '.apple.team_id = "abc"' "apple.team_id must be a team identifier"
pcfg_case "flatpak to_sign not an input" '.flatpak.to_sign = "flatpak-repo.tar"' "flatpak.to_sign is flatpak-repo.tar, which is not a product with the origin input"
pcfg_case "flatpak signatures not local" '.flatpak.signatures = "x.tar"' "flatpak.signatures is x.tar, which is not a product with the origin local"
pcfg_case "flatpak repo_tar not ci" '.flatpak.repo_tar = "flatpak-to-sign.tar"' "flatpak.repo_tar is flatpak-to-sign.tar, which is not a product with the origin ci"
pcfg_case "flatpak conventional extra ref" '.flatpak.extra_refs += ["appstream/x86_64"]' "flatpak.extra_refs lists appstream/x86_64, which every release holds already"
pcfg_case "flatpak bad extra ref" '.flatpak.extra_refs = ["app/../x"]' "flatpak.extra_refs: not a Flatpak ref name: app/../x"
pcfg_case "flatpak short fingerprint" '.flatpak.fingerprint = "AAAA1111"' "flatpak.fingerprint must be a full key fingerprint"
pcfg_case "flatpak missing key" 'del(.flatpak.branch)' "flatpak.branch is missing"
pcfg_case "flatpak url" '.flatpak.url = "http://x y"' "flatpak.url must be an https URL"
pcfg_case "homebrew output not local" '.homebrew.output = "tool_{version}_Linux_x86_64.tar"' "homebrew.output is tool_{version}_Linux_x86_64.tar, which is not a product with the origin local"
pcfg_case "homebrew dmg not a product" '.homebrew.dmg.x64 = "testapp_x64.dmg"' "homebrew.dmg.x64 is testapp_x64.dmg, which is not a product"
pcfg_case "homebrew empty dmg" '.homebrew.dmg = {}' "homebrew.dmg must be an object with exactly the keys aarch64 and x64"
pcfg_case "homebrew dmg without x64" 'del(.homebrew.dmg.x64)' "homebrew.dmg must be an object with exactly the keys aarch64 and x64"
pcfg_case "homebrew old template_file" '.homebrew.template_file = "brew/testapp.rb.template" | del(.homebrew.generator)' \
	"homebrew.template_file is no longer used" "homebrew.generator is missing"
pcfg_case "homebrew generator path with .." '.homebrew.generator = "../gen.sh"' "homebrew.generator must be a plain relative path"
pcfg_case "flatpak old templates_dir" '.flatpak.templates_dir = "pages" | del(.flatpak.pages)' \
	"flatpak.templates_dir is no longer used. List every file of the Pages site" "flatpak.pages is missing"
pcfg_case "flatpak pages: two files with one name" '.flatpak.pages += ["other/index.html"]' "flatpak.pages lists more than one file named index.html"
pcfg_case "flatpak pages without a template" '.flatpak.pages = ["pages/index.html"]' "flatpak.pages holds no .flatpakrepo or .flatpakref template"
pcfg_case "flatpak pages: empty list" '.flatpak.pages = []' "flatpak.pages must be a nonempty list of plain relative paths"
pcfg_case "flatpak pages: path with .." '.flatpak.pages += ["../x.png"]' "flatpak.pages must be a nonempty list of plain relative paths"

# finalize-release.sh verify-macos: check-set --subset, the build info, then
# verify-macos.sh. Stand-in: a copy of the scripts whose verify-macos.sh and
# flatpak-finalize.sh print their arguments.
VM="$T/vm-scripts"
cp -a "$P/dev-scripts/release" "$VM"
cat >"$VM/verify-macos.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$T/vm-args"
while [ \$# -gt 0 ]; do [ "\$1" = --entitlements ] && cp "\$2" "$T/vm-ent"; shift; done
EOF
cat >"$VM/flatpak-finalize.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$T/fp-args"
while [ \$# -gt 0 ]; do
	case "\$1" in
	--expected-refs) cp "\$2" "$T/fp-expected" ;;
	--pubkey) cp "\$2" "$T/fp-pubkey" ;;
	--templates) (cd "\$2" && LC_ALL=C ls -A) | tr '\n' ' ' >"$T/fp-pages"; cmp -s "\$2/icon.png" "$P/icons/icon.png" || echo "icon.png differs" >"$T/fp-pages" ;;
	esac
	shift
done
EOF
chmod +x "$VM/verify-macos.sh" "$VM/flatpak-finalize.sh"
vmfin() { run env PATH="$T/bin:$PATH" FAKE_GH_STATE="$GHS" GH_TOKEN=fake-token "$VM/finalize-release.sh" "$@"; }
args_have() { grep -qxF -- "$1" "$2"; }

# The finalize workflow calls: verify-macos --tag TAG --dir DIR --repo-root DIR
# (no manifest hash, no GH_TOKEN in that step).
vmfin verify-macos --tag "$TAG" --dir "$T/p-staged" --repo-root "$P"
if [ "$RC" = 0 ] && args_have --requirement "$T/vm-args" && args_have "anchor apple generic" "$T/vm-args" &&
	args_have false "$T/vm-args" && args_have ZZTEST0001 "$T/vm-args" && args_have org.test.app "$T/vm-args" &&
	args_have 1.2.3 "$T/vm-args" && args_have "$T/p-staged" "$T/vm-args" && cmp -s "$T/vm-ent" "$P/src-tauri/Entitlements.plist" &&
	! args_have --unsigned-dir "$T/vm-args" && grep -q "^api -H Accept: application/vnd.github.raw+json repos/$GH_REPO/contents/src-tauri/Entitlements.plist?ref=$COMMIT" "$GHS/calls.log" &&
	grep -qF "SHA256SUMS in $T/p-staged has the sha256 $PSHA (no pinned hash given)" <<<"$OUT"; then
	pass "verify-macos: without --manifest-sha256, runs verify-macos.sh with the configured values and the entitlements of the release commit"
else
	fail "verify-macos: good case" "rc=$RC: $OUT $(cat "$T/vm-args" 2>&1)"
fi
mkdir -p "$T/unsigned"
vmfin verify-macos --tag "$TAG" --dir "$T/p-staged" --manifest-sha256 "$PSHA" --unsigned-dir "$T/unsigned" --repo-root "$P"
[ "$RC" = 0 ] && args_have --unsigned-dir "$T/vm-args" && args_have "$T/unsigned" "$T/vm-args" &&
	pass "verify-macos: with --manifest-sha256, passes --unsigned-dir on" || fail "verify-macos: --unsigned-dir" "rc=$RC: $OUT"
vmfin verify-macos --tag v9.9.9 --dir "$T/p-staged" --repo-root "$P"
expect_err "verify-macos: --tag differs from the verified build info" "--tag is v9.9.9, but the verified release-build-info.json names the tag $TAG"
vmfin verify-macos --dir "$T/p-staged" --manifest-sha256 "$PSHA" --repo-root "$P"
expect_err "verify-macos: --tag is required" "usage: finalize-release.sh"
cp -a "$T/p-staged" "$T/vm-sub"
rm "$T/vm-sub/$PDMG" "$T/vm-sub/tool_1.2.3_Linux_x86_64.tar"
vmfin verify-macos --tag "$TAG" --dir "$T/vm-sub" --repo-root "$P"
expect_err "verify-macos: a missing DMG fails (other files may be absent)" "lacks files that this check needs: $PDMG"
cp "$T/p-staged/$PDMG" "$T/vm-sub/"
printf 'x' >>"$T/vm-sub/$PAPP"
vmfin verify-macos --tag "$TAG" --dir "$T/vm-sub" --repo-root "$P"
expect_err "verify-macos: without a pin, a changed app archive still fails the hash check" "hash mismatch for $PAPP"
cp -a "$T/p-staged" "$T/vm-sig"
pgp_sign "$T/vm-sig/SHA256SUMS" "$FPR_B"
vmfin verify-macos --tag "$TAG" --dir "$T/vm-sig" --repo-root "$P"
expect_err "verify-macos: without a pin, SHA256SUMS still needs a good signature from an allowed signer" "SHA256SUMS has no good signature from an allowed signer"
cp -a "$T/p-staged" "$T/vm-extra"
printf 'x\n' >"$T/vm-extra/extra.bin"
vmfin verify-macos --tag "$TAG" --dir "$T/vm-extra" --repo-root "$P"
expect_err "verify-macos: without a pin, an unlisted file fails" "files that the manifest does not list: extra.bin"
vmfin verify-macos --tag "$TAG" --dir "$T/p-staged" --manifest-sha256 "$(printf '%064d' 0)" --repo-root "$P"
expect_err "verify-macos: wrong pinned manifest hash" "not the pinned"
# Without GH_TOKEN: the entitlements file comes from raw.githubusercontent.com.
mkdir -p "$T/curlbin"
cat >"$T/curlbin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$T/curl.log"
for url in "\$@"; do :; done
case "\$url" in
https://raw.githubusercontent.com/$GH_REPO/*)
	rest="\${url#https://raw.githubusercontent.com/$GH_REPO/}"
	f="$GHS/contents/\${rest%%/*}/\${rest#*/}"
	[ -f "\$f" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
	cat "\$f" ;;
*) echo "curl: unexpected URL \$url" >&2; exit 9 ;;
esac
EOF
chmod +x "$T/curlbin/curl"
rm -f "$T/curl.log" "$T/vm-ent"
: >"$GHS/calls.log"
RC=0
OUT="$(env -u GH_TOKEN PATH="$T/curlbin:$T/nobin:$PATH" "$VM/finalize-release.sh" verify-macos --tag "$TAG" --dir "$T/p-staged" --repo-root "$P" 2>&1)" || RC=$?
[ "$RC" = 0 ] && cmp -s "$T/vm-ent" "$P/src-tauri/Entitlements.plist" &&
	grep -qF "https://raw.githubusercontent.com/$GH_REPO/$COMMIT/src-tauri/Entitlements.plist" "$T/curl.log" &&
	grep -qF -- "--proto =https" "$T/curl.log" && [ ! -s "$GHS/calls.log" ] &&
	pass "verify-macos: without GH_TOKEN, reads the entitlements of the release commit from raw.githubusercontent.com (no gh call)" ||
	fail "verify-macos: without GH_TOKEN" "rc=$RC: $OUT $(cat "$T/curl.log" 2>&1)"
rm -rf "$GHS/contents/$COMMIT/src-tauri"
RC=0
OUT="$(env -u GH_TOKEN PATH="$T/curlbin:$T/nobin:$PATH" "$VM/finalize-release.sh" verify-macos --tag "$TAG" --dir "$T/p-staged" --repo-root "$P" 2>&1)" || RC=$?
expect_err "verify-macos: without GH_TOKEN, a missing file fails" "cannot read src-tauri/Entitlements.plist at commit $COMMIT from https://raw.githubusercontent.com/$GH_REPO"
mkdir -p "$GHS/contents/$COMMIT/src-tauri"
cp "$P/src-tauri/Entitlements.plist" "$GHS/contents/$COMMIT/src-tauri/"
pfin verify-macos --tag "$TAG" --dir "$T/p-staged" --repo-root "$P"
if [ "$HOST_OS" = Darwin ]; then
	# On macOS the real script runs its checks. The throwaway certificate is
	# not an Apple certificate, so the requirement check must refuse it.
	expect_err "verify-macos: on macOS the real verify-macos.sh runs up to the requirement check, which refuses the throwaway certificate" \
		"codesign --verify --deep --strict with the requirement fails"
else
	expect_err "verify-macos: the real verify-macos.sh accepts the arguments and stops at its macOS check" "verify-macos.sh runs on macOS only"
fi

# finalize-release.sh flatpak.
vmfin flatpak --tag "$TAG" --dir "$T/p-staged" --manifest-sha256 "$PSHA" --repo-tar "$FP_CI/flatpak-repo.tar" --out "$T/fp-out" --repo-root "$P"
fp_key_fpr="$(gpg --batch --with-colons --import-options show-only --import "$T/fp-pubkey" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')" || fp_key_fpr=""
if [ "$RC" = 0 ] && args_have "$FPR_A" "$T/fp-args" && args_have org.test.Hello "$T/fp-args" && args_have x86_64 "$T/fp-args" &&
	args_have stable "$T/fp-args" && args_have org.test.Hello.flatpak "$T/fp-args" &&
	[ "$(cat "$T/fp-pages")" = "README.md icon.png index.html org.test.Hello.flatpakref test.flatpakrepo " ] &&
	args_have "https://example-owner.github.io/example-repo" "$T/fp-args" && args_have "$T/p-staged/flatpak-signatures.tar" "$T/fp-args" &&
	args_have "$T/fp-out" "$T/fp-args" && [ "$fp_key_fpr" = "$FPR_A" ] &&
	diff <(LC_ALL=C sort "$T/fp-expected") <(tar -xOf "$FP_CI/flatpak-to-sign.tar" refs.txt | cut -d' ' -f1 | LC_ALL=C sort) >/dev/null; then
	pass "flatpak: runs flatpak-finalize.sh with the configured values, the committed key, the expected refs, and the files of flatpak.pages"
else
	fail "flatpak: arguments" "rc=$RC: $OUT $(cat "$T/fp-args" "$T/fp-pages" 2>&1)"
fi
cp -a "$T/p-staged" "$T/fp-sub"
rm "$T/fp-sub/flatpak-signatures.tar"
vmfin flatpak --dir "$T/fp-sub" --manifest-sha256 "$PSHA" --repo-tar "$FP_CI/flatpak-repo.tar" --out "$T/fp-out2" --repo-root "$P"
expect_err "flatpak: the signatures archive is missing" "lacks files that this check needs: flatpak-signatures.tar"
vmfin flatpak --dir "$T/p-staged" --manifest-sha256 "$PSHA" --repo-tar "$FP_CI/flatpak-repo.tar" --repo-root "$P"
expect_err "flatpak: --out is required" "usage:"
vmfin flatpak --tag v9.9.9 --dir "$T/p-staged" --manifest-sha256 "$PSHA" --repo-tar "$FP_CI/flatpak-repo.tar" --out "$T/fp-out3" --repo-root "$P"
expect_err "flatpak: --tag differs from the verified build info" "--tag is v9.9.9, but the verified release-build-info.json names the tag $TAG"
mv "$P/icons/icon.png" "$T/icon.moved"
vmfin flatpak --tag "$TAG" --dir "$T/p-staged" --manifest-sha256 "$PSHA" --repo-tar "$FP_CI/flatpak-repo.tar" --out "$T/fp-out4" --repo-root "$P"
expect_err "flatpak: a missing file of flatpak.pages fails" "flatpak.pages lists icons/icon.png, which is not a regular file in $P"
mv "$T/icon.moved" "$P/icons/icon.png"
# The real configuration: every file of flatpak.pages exists in the worktree,
# and the Pages site gets what the production job copied.
missing=""
for f in $(jq -r '.flatpak.pages[]' "$REAL_CFG"); do
	[ -f "$SCRIPTS/../../$f" ] || missing="$missing $f"
done
[ -z "$missing" ] && [ "$(jq -r '.flatpak.pages | map(split("/") | last) | sort | .[]' "$REAL_CFG")" = \
	"$(printf '%s\n' README.md sampleapp.flatpakrepo icon.png index.html org.example.SampleApp.flatpakref | LC_ALL=C sort)" ] &&
	pass "flatpak: the real flatpak.pages lists index.html, both templates, icon.png, and README.md, and each file exists" ||
	fail "flatpak: real flatpak.pages" "missing:$missing $(jq -c .flatpak.pages "$REAL_CFG")"

if [ "$HOST_OS" != Linux ]; then
	skip "flatpak: real flatpak-finalize.sh" "needs flatpak and ostree in the Docker image $FP_IMAGE, Linux only"
elif docker image inspect "$FP_IMAGE" >/dev/null 2>&1; then
	jq_dir="$(dirname "$(readlink -f "$(command -v jq)")")"
	RC=0
	OUT="$(docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/tmp -e PATH="$jq_dir:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
		-v /nix/store:/nix/store:ro -v "$T:$T" -v "$FP_CI:$FP_CI:ro" "$FP_IMAGE" \
		"$P/dev-scripts/release/finalize-release.sh" flatpak --tag "$TAG" --dir "$T/p-staged" --manifest-sha256 "$PSHA" \
		--repo-tar "$FP_CI/flatpak-repo.tar" --out "$T/site" --repo-root "$P" 2>&1)" || RC=$?
	if [ "$RC" = 0 ] && [ -f "$T/site/summary.sig" ] && [ -f "$T/site/org.test.Hello.flatpak" ] && [ -f "$T/site/.nojekyll" ] &&
		grep -qx "Url=https://example-owner.github.io/example-repo" "$T/site/org.test.Hello.flatpakref" &&
		grep -qx "GPGKey=$(gpg --batch --export "$FPR_A" | b64)" "$T/site/test.flatpakrepo" && [ -f "$T/site/index.html" ] &&
		cmp -s "$T/site/icon.png" "$P/icons/icon.png" && cmp -s "$T/site/README.md" "$P/README.md"; then
		pass "flatpak: the real flatpak-finalize.sh builds the signed repository (ubuntu 24.04, flatpak, ostree)"
	else
		fail "flatpak: real flatpak-finalize.sh" "rc=$RC: $OUT"
	fi
else
	fail "flatpak: real flatpak-finalize.sh" "docker image $FP_IMAGE not found (built by flatpak-module/test-flatpak.sh)"
fi
fi
# ---------------------------------------------------------------------------
echo
[ -z "$SKIPS" ] || printf 'skipped tests:\n%s' "$SKIPS"
echo "passed: $PASSED  failed: $FAILED  skipped: $SKIPPED"
[ "$FAILED" = 0 ] || {
	printf 'failed tests:\n%s' "$FAILURES"
	exit 1
}
