#!/usr/bin/env bash
# One-time setup on the machine of a maintainer: creates the encrypted secrets
# file that sign-release.sh reads.
#
# The file is a JSON object, encrypted to your release signing key with gpg.
# It holds TAURI_SIGNING_PRIVATE_KEY and TAURI_SIGNING_PRIVATE_KEY_PASSWORD.
# The script asks for the path of the updater private key file and for its
# password. It checks the key against the updater public key of the app before
# it saves anything. The secrets never reach the disk unencrypted.
#
# Usage: init-secrets.sh [--repo OWNER/NAME]
#
# Environment: RELEASE_SIGNING_KEY, RELEASE_SECRETS_FILE (see sign-release.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
	die "usage: init-secrets.sh [--repo OWNER/NAME]"
}

repo=""
while [ $# -gt 0 ]; do
	case "$1" in
	--repo)
		[ $# -ge 2 ] || usage
		repo="$2"
		shift 2
		;;
	*) usage ;;
	esac
done

need_tools gpg jq minisign base64
load_config
load_allowed_signers
repo="${repo:-$CFG_REPOSITORY}"
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "repository is not OWNER/NAME: $repo"

if [ "$(updater_target_count)" = 0 ]; then
	log "The configuration has no updater targets. There is nothing to store."
	exit 0
fi

secrets_file="$(secrets_file_path "$repo")"
if [ -e "$secrets_file" ] || [ -L "$secrets_file" ]; then
	die "$secrets_file exists already. Move it away first, if you want to make a new one."
fi

select_signing_key
log "signing key: $SIGNING_KEY"

printf 'Path of the Tauri updater private key file: ' >&2
IFS= read -r key_path || die "no path given"
case "$key_path" in
\~) key_path="$HOME" ;;
\~/*) key_path="$HOME/${key_path#??}" ;;
esac
[ -f "$key_path" ] || die "not a file: $key_path"
tauri_key="$(<"$key_path")" || die "cannot read $key_path"
[ -n "$tauri_key" ] || die "$key_path is empty"

printf 'Password of the updater private key (empty if it has none): ' >&2
tauri_key_password=""
if [ -t 0 ]; then
	IFS= read -rs tauri_key_password || true
	printf '\n' >&2
else
	IFS= read -r tauri_key_password || true
fi

# Check the key before it is saved: sign a test file with the same function
# that the signing script uses, and verify the signature with the updater
# public key of the app. The self-test uses a fixed version.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'updater key self-test\n' >"$work/selftest"
write_updater_pubkey "$work/updater.pub"
updater_sign "$tauri_key" "$tauri_key_password" "$work/selftest" 0.0.0 ||
	die "minisign cannot sign with this key and password"
selftest_comment="$(updater_sig_comment "$work/updater.pub" "$work/selftest.sig" "$work/selftest")" ||
	die "this is not the updater key of the app: its signature does not match the updater public key"
check_updater_comment selftest.sig "$selftest_comment" selftest 0.0.0

# Write the file. umask 077 keeps the file and new directories private.
# noclobber makes the shell refuse to replace a file that appeared meanwhile.
umask 077
secrets_dir="$(dirname "$secrets_file")"
# With umask 077, every directory that mkdir creates gets mode 700.
[ -d "$secrets_dir" ] || mkdir -p "$secrets_dir"
(set -o noclobber && : >"$secrets_file") 2>/dev/null ||
	die "cannot create $secrets_file. If it exists now, move it away first."
# From here on, the file is the empty file that this script just created.
if ! TAURI_SIGNING_PRIVATE_KEY="$tauri_key" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$tauri_key_password" \
	jq -n '{TAURI_SIGNING_PRIVATE_KEY: env.TAURI_SIGNING_PRIVATE_KEY, TAURI_SIGNING_PRIVATE_KEY_PASSWORD: env.TAURI_SIGNING_PRIVATE_KEY_PASSWORD}' |
	gpg --batch --quiet --trust-model always --encrypt --recipient "$SIGNING_KEY" >"$secrets_file"; then
	rm -f "$secrets_file"
	die "cannot encrypt the secrets to $SIGNING_KEY"
fi
tauri_key="" tauri_key_password=""

log ""
log "Saved the encrypted secrets: $secrets_file"
log "Next step, for each release: just sign-release <tag>"
