#!/usr/bin/env bash
# Creates or updates, on the machine of a maintainer, the encrypted secrets file
# that sign-release.sh reads.
#
# The file is one JSON object of string entries, encrypted to your release
# signing key with gpg:
#   TAURI_SIGNING_PRIVATE_KEY           the Tauri updater private key file (text)
#   TAURI_SIGNING_PRIVATE_KEY_PASSWORD  its password ("" if it has none)
#   APPLE_P12_BASE64                    the Developer ID Application .p12 file, base64
#   APPLE_P12_PASSWORD                  the password of the .p12 file
#   APPLE_API_KEY_JSON_BASE64           the JSON file that
#                                       `rcodesign encode-app-store-connect-api-key`
#                                       writes, base64
# The three APPLE_ entries are optional, but only as one group: the file holds
# all three or none of them.
#
# Usage: init-secrets.sh [--repo OWNER/NAME] [--updater] [--apple]
#                        [--apple-certificate] [--apple-api-key]
#
#   --updater            set the two TAURI_ entries
#   --apple              set the three APPLE_ entries
#   --apple-certificate  set APPLE_P12_BASE64 and APPLE_P12_PASSWORD
#   --apple-api-key      set APPLE_API_KEY_JSON_BASE64
#
# Without an option, the script asks what to set. If the secrets file does not
# exist, the script creates it. If it exists, the script decrypts it, sets the
# chosen entries, keeps all other entries, and replaces the file. The previous
# file stays next to it as <file>.backup-<UTC time>. The script never deletes a
# secrets file.
#
# The script checks every value before it unlocks anything: the updater key must
# sign a test file that the updater public key of the app accepts, rcodesign must
# open the .p12 file with its password, and the API key file must be the JSON
# that rcodesign writes. Secret values reach other programs only through pipes,
# never through an argument list or an environment variable, and never reach the
# disk unencrypted.
#
# Environment: RELEASE_SIGNING_KEY, RELEASE_SECRETS_FILE (see sign-release.sh).

# Tracing would print the secrets. Turn it off before anything else.
{ set +x; } 2>/dev/null
set -euo pipefail
# A core dump would write the secrets to the disk.
ulimit -c 0 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
	die "usage: init-secrets.sh [--repo OWNER/NAME] [--updater] [--apple] [--apple-certificate] [--apple-api-key]"
}

repo="" set_updater=0 set_apple_cert=0 set_apple_api=0 asked=0
while [ $# -gt 0 ]; do
	case "$1" in
	--repo)
		[ $# -ge 2 ] || usage
		repo="$2"
		shift
		;;
	--updater) set_updater=1 asked=1 ;;
	--apple) set_apple_cert=1 set_apple_api=1 asked=1 ;;
	--apple-certificate) set_apple_cert=1 asked=1 ;;
	--apple-api-key) set_apple_api=1 asked=1 ;;
	*) usage ;;
	esac
	shift
done

need_tools gpg jq base64 cmp ln mv
load_config
load_allowed_signers
repo="${repo:-$CFG_REPOSITORY}"
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "repository is not OWNER/NAME: $repo"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# ask PROMPT: reads one line into REPLY.
ask() {
	printf '%s' "$1" >&2
	REPLY=""
	IFS= read -r REPLY || [ -n "$REPLY" ] || die "no answer"
}

# ask_secret PROMPT: reads one line into REPLY. A terminal does not show it.
ask_secret() {
	printf '%s' "$1" >&2
	REPLY=""
	if [ -t 0 ]; then
		IFS= read -rs REPLY || true
		printf '\n' >&2
	else
		IFS= read -r REPLY || true
	fi
}

# ask_yes PROMPT: true if the answer is y or yes.
ask_yes() {
	ask "$1 [y/N] "
	case "$REPLY" in
	[yY] | [yY][eE][sS]) return 0 ;;
	*) return 1 ;;
	esac
}

# ask_path PROMPT: reads a path into REPLY and expands a leading "~".
ask_path() {
	ask "$1"
	case "$REPLY" in
	\~) REPLY="$HOME" ;;
	\~/*) REPLY="$HOME/${REPLY#??}" ;;
	esac
	[ -n "$REPLY" ] || die "no path given"
}

# mode_of PATH: prints the permission string of PATH, for example -rw-------.
mode_of() {
	local line
	line="$(ls -ld -- "$1")" || die "cannot read the permissions of $1"
	printf '%s\n' "${line%% *}"
}

# check_source_file PATH: PATH must be a regular file that you own and that no
# other user can change. Warns if other users can read it.
check_source_file() {
	local mode
	[ -f "$1" ] || die "not a file: $1"
	[ -O "$1" ] || die "$1 belongs to another user. Copy it to a file that you own."
	mode="$(mode_of "$1")"
	case "$mode" in
	?????w* | ????????w*) die "other users can change $1 ($mode). Run: chmod go-w '$1'" ;;
	esac
	case "$mode" in
	????r* | ???????r*) log "warning: other users can read $1 ($mode). Consider: chmod go-rwx '$1'" ;;
	esac
}

# check_private_dir DIR: DIR must be a directory that you own and that no other
# user can change. Otherwise another user could replace the secrets file.
check_private_dir() {
	local mode
	if [ ! -d "$1" ] || [ -L "$1" ]; then
		die "not a directory: $1"
	fi
	[ -O "$1" ] || die "the directory $1 belongs to another user. Use a directory that you own (RELEASE_SECRETS_FILE)."
	mode="$(mode_of "$1")"
	case "$mode" in
	?????w* | ????????w*) die "other users can change the directory $1 ($mode). Use a private directory (RELEASE_SECRETS_FILE)." ;;
	esac
}

# json_set NAME VALUE: sets the entry NAME of the JSON object in $json to the
# string VALUE. VALUE reaches jq through a pipe that only the shell writes.
json_set() {
	json="$(jq -c --arg name "$1" --rawfile value <(printf '%s' "$2") '. + {($name): $value}' < <(printf '%s' "$json"))" ||
		die "cannot set $1"
}

# ---------------------------------------------------------------------------
# What to set
# ---------------------------------------------------------------------------

secrets_file="$(secrets_file_path "$repo")"
secrets_dir="$(dirname "$secrets_file")"
[ ! -L "$secrets_file" ] || die "$secrets_file is a symbolic link. Point RELEASE_SECRETS_FILE at the real file."
if [ -e "$secrets_file" ]; then
	[ -f "$secrets_file" ] || die "$secrets_file is not a regular file"
	update=1
	log "The secrets file exists: $secrets_file"
	log "The script keeps its entries, except the ones that you set now, and keeps a backup."
else
	update=0
	log "The script creates a new secrets file: $secrets_file"
fi
[ ! -e "$secrets_dir" ] || check_private_dir "$secrets_dir"

if [ "$asked" = 0 ]; then
	if [ "$update" = 1 ]; then
		! ask_yes "Set the updater key (TAURI_SIGNING_PRIVATE_KEY and its password)?" || set_updater=1
	elif uses_updater; then
		set_updater=1
	fi
	if ask_yes "Set the Apple signing secrets (.p12 certificate, its password, App Store Connect API key)?"; then
		set_apple_cert=1 set_apple_api=1
	fi
fi
if [ "$update" = 0 ] && uses_updater && [ "$set_updater" = 0 ]; then
	die "a new secrets file needs the updater key, because the configuration has updater targets. Add --updater."
fi
if [ "$set_updater$set_apple_cert$set_apple_api" = 000 ]; then
	log "Nothing to change."
	exit 0
fi
if [ "$update" = 0 ] && [ "$set_apple_cert" != "$set_apple_api" ]; then
	die "a new secrets file holds all Apple entries or none. Use --apple."
fi

[ "$set_updater" = 0 ] || need_tools minisign
[ "$set_apple_cert" = 0 ] || need_tools rcodesign

select_signing_key
log "signing key: $SIGNING_KEY"

work="$(mktemp -d)"
tmp=""
trap 'rm -rf "$work"; [ -z "$tmp" ] || rm -f "$tmp"' EXIT

# ---------------------------------------------------------------------------
# Read and check the new values. Nothing is unlocked yet.
# ---------------------------------------------------------------------------

if [ "$set_updater" = 1 ]; then
	ask_path 'Path of the Tauri updater private key file: '
	key_path="$REPLY"
	check_source_file "$key_path"
	tauri_key="$(<"$key_path")" || die "cannot read $key_path"
	[ -n "$tauri_key" ] || die "$key_path is empty"
	ask_secret 'Password of the updater private key (empty if it has none): '
	tauri_key_password="$REPLY"

	# Sign a test file with the same function that the signing script uses, and
	# verify the signature with the updater public key of the app. The self-test
	# uses a fixed version.
	printf 'updater key self-test\n' >"$work/selftest"
	write_updater_pubkey "$work/updater.pub"
	updater_sign "$tauri_key" "$tauri_key_password" "$work/selftest" 0.0.0 ||
		die "minisign cannot sign with this key and password"
	selftest_comment="$(updater_sig_comment "$work/updater.pub" "$work/selftest.sig" "$work/selftest")" ||
		die "this is not the updater key of the app: its signature does not match the updater public key"
	check_updater_comment selftest.sig "$selftest_comment" selftest 0.0.0
	log "The updater key matches the updater public key of the app."
fi

if [ "$set_apple_cert" = 1 ]; then
	ask_path 'Path of the Developer ID Application certificate (.p12 file): '
	p12_path="$REPLY"
	check_source_file "$p12_path"
	apple_p12="$(base64 <"$p12_path" | tr -d '\n')" || die "cannot read $p12_path"
	[ -n "$apple_p12" ] || die "$p12_path is empty"
	ask_secret 'Password of the .p12 file: '
	apple_p12_password="$REPLY"
	# Open exactly the bytes that go into the file, the way apple.sh does.
	out="$(rcodesign analyze-certificate -C /dev/null \
		--p12-file <(printf '%s' "$apple_p12" | base64 --decode) \
		--p12-password-file <(printf '%s' "$apple_p12_password") 2>&1)" ||
		die "rcodesign cannot open $p12_path with this password: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')
(rcodesign reads only the older .p12 encryption. A file from 'openssl pkcs12 -export' needs the -legacy option.)"
	log "Apple certificate: $(printf '%s\n' "$out" | sed -n 's/^Subject CN: *//p' | head -n 1)"
fi

if [ "$set_apple_api" = 1 ]; then
	ask_path "Path of the App Store Connect API key JSON file (from 'rcodesign encode-app-store-connect-api-key'): "
	api_path="$REPLY"
	check_source_file "$api_path"
	apple_api_key="$(base64 <"$api_path" | tr -d '\n')" || die "cannot read $api_path"
	printf '%s' "$apple_api_key" | base64 --decode | jq -e '
		type == "object"
		and ([.issuer_id, .key_id, .private_key] | all(type == "string" and length > 0))
		and (.private_key | test("^[A-Za-z0-9+/=\\s]+$"))' >/dev/null 2>&1 ||
		die "$api_path is not the JSON that 'rcodesign encode-app-store-connect-api-key' writes (an object with the strings issuer_id, key_id, and private_key)"
	log "The App Store Connect API key file has the expected entries."
fi

# ---------------------------------------------------------------------------
# Combine with the previous file. Only now gpg may ask for the passphrase.
# ---------------------------------------------------------------------------

json='{}'
if [ "$update" = 1 ]; then
	# Decrypt a copy of the ciphertext. Before the script replaces the file, it
	# compares the file with this copy, so it never replaces a newer version.
	cp -- "$secrets_file" "$work/previous.gpg" || die "cannot read $secrets_file"
	json="$(gpg --quiet --decrypt <"$work/previous.gpg")" || die "cannot decrypt $secrets_file"
	printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1 ||
		die "$secrets_file does not hold a JSON object. The script changes nothing."
	json="$(jq -c . < <(printf '%s' "$json"))"
	previous_names="$(jq -r 'keys[]' < <(printf '%s' "$json"))"
fi

changed=""
set_entry() {
	json_set "$1" "$2"
	changed="$changed $1"
}
if [ "$set_updater" = 1 ]; then
	set_entry TAURI_SIGNING_PRIVATE_KEY "$tauri_key"
	set_entry TAURI_SIGNING_PRIVATE_KEY_PASSWORD "$tauri_key_password"
fi
if [ "$set_apple_cert" = 1 ]; then
	set_entry APPLE_P12_BASE64 "$apple_p12"
	set_entry APPLE_P12_PASSWORD "$apple_p12_password"
fi
[ "$set_apple_api" = 0 ] || set_entry APPLE_API_KEY_JSON_BASE64 "$apple_api_key"
tauri_key="" tauri_key_password="" apple_p12="" apple_p12_password="" apple_api_key=""

printf '%s' "$json" | jq -e '
	[has("APPLE_P12_BASE64"), has("APPLE_P12_PASSWORD"), has("APPLE_API_KEY_JSON_BASE64")]
	| all or (any | not)' >/dev/null ||
	die "the file would hold only part of the Apple entries (APPLE_P12_BASE64, APPLE_P12_PASSWORD, APPLE_API_KEY_JSON_BASE64). Set the missing ones too, for example with --apple. Nothing changed."

# ---------------------------------------------------------------------------
# Encrypt into a private temporary file next to the target, then install it.
# ---------------------------------------------------------------------------

umask 077
# With umask 077, every directory that mkdir creates gets mode 700.
[ -d "$secrets_dir" ] || mkdir -p "$secrets_dir"
check_private_dir "$secrets_dir"
secrets_base="${secrets_file##*/}"
tmp="$(mktemp "$secrets_dir/.$secrets_base.new.XXXXXX")" || die "cannot create a temporary file in $secrets_dir"
printf '%s' "$json" |
	gpg --batch --quiet --yes --trust-model always --encrypt --recipient "$SIGNING_KEY" --output "$tmp" ||
	die "cannot encrypt the secrets to $SIGNING_KEY"
json=""

if [ "$update" = 0 ]; then
	# ln fails if the target exists: the script never replaces a file that
	# appeared meanwhile.
	ln -- "$tmp" "$secrets_file" 2>/dev/null ||
		die "cannot create $secrets_file. If it exists now, run the script again to update it."
	rm -f -- "$tmp"
	tmp=""
	log ""
	log "Saved the encrypted secrets: $secrets_file"
	log "Entries:$changed"
else
	# Keep the previous file under a new name (a second link to the same file),
	# then rename the new file over the old name. rename is atomic.
	stamp="$(date -u +%Y%m%dT%H%M%SZ)"
	backup="$secrets_file.backup-$stamp"
	n=1
	until ln -- "$secrets_file" "$backup" 2>/dev/null; do
		[ -e "$secrets_file" ] || die "$secrets_file disappeared while the script ran. Nothing changed."
		[ -e "$backup" ] || [ -L "$backup" ] || die "cannot create the backup $backup (ln failed). Nothing changed."
		n=$((n + 1))
		backup="$secrets_file.backup-$stamp-$n"
	done
	cmp -s -- "$backup" "$work/previous.gpg" ||
		die "$secrets_file changed while the script ran. Nothing replaced. $backup is a copy of the current file. Run the script again."
	mv -f -- "$tmp" "$secrets_file" || die "cannot replace $secrets_file. The previous file is unchanged."
	tmp=""
	kept=""
	while IFS= read -r name; do
		case " $changed " in
		*" $name "*) ;;
		*) [ -z "$name" ] || kept="$kept $name" ;;
		esac
	done < <(printf '%s\n' "$previous_names")
	log ""
	log "Updated the encrypted secrets: $secrets_file"
	log "Set:$changed"
	log "Kept unchanged:${kept:- (none)}"
	log "The previous file is now $backup. The script does not delete it."
fi
log "Next step, for each release: just sign-release <tag>"
