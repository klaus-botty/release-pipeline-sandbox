#!/bin/bash
# macOS as the signing host: makes a throwaway certificate, signs the
# unsigned inputs with apple_process_all (hdiutil path, notarize false), and
# runs verify-macos.sh on the result.
# Usage: host-sign.sh UNSIGNED_DIR WORK_DIR
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
in_dir="$1" wdir="$2"
host_team=ZZHOST0003
mkdir -p "$wdir/keys" "$wdir/out"
echo "bash: $BASH_VERSION"

pw="hp-$(od -A n -t x1 -N 12 /dev/urandom | tr -d ' \n')"
env -u RCODESIGN_PROBE_UNKNOWN_KEY rcodesign generate-self-signed-certificate -C /dev/null --person-name "Sandbox Host Signer" \
	--profile developer-id-application --team-id "$host_team" --validity-days 2 \
	--p12-file "$wdir/keys/host.p12" --p12-password "$pw" --pem-filename "$wdir/keys/host" >/dev/null
/bin/bash "$here/trust-cert.sh" "$wdir/keys/host.crt"

# shellcheck source-path=SCRIPTDIR source=module/lib.sh
. "$here/module/lib.sh"
# shellcheck source-path=SCRIPTDIR source=module/apple.sh
. "$here/module/apple.sh"
# shellcheck disable=SC2034 # read by apple.sh
APPLE_P12_BASE64="$(base64 <"$wdir/keys/host.p12" | tr -d '\n')"
# shellcheck disable=SC2034 # read by apple.sh
APPLE_P12_PASSWORD="$pw"
rm -f "$wdir/keys/host.p12" "$wdir/keys/host.key"
unset pw

step "apple_preflight"
apple_preflight tools
apple_preflight secrets false
step "apple_process_all"
t0=$SECONDS
apple_process_all "$in_dir" "$here/app/entitlements.plist" false "$wdir/out"
echo "WALL apple_process_all: $((SECONDS - t0)) s"
ls -la "$wdir/out"
unset APPLE_P12_BASE64 APPLE_P12_PASSWORD

step "verify-macos.sh"
/bin/bash "$here/module/verify-macos.sh" --dir "$wdir/out" \
	--requirement "anchor trusted and certificate leaf[subject.OU] = \"$host_team\"" \
	--notarized false --team-id "$host_team" --bundle-id org.example.sandboxapp --version 1.2.3 \
	--entitlements "$here/app/entitlements.plist" --unsigned-dir "$in_dir"
