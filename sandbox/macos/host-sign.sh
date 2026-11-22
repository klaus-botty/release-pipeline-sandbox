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
# The certificate comes from /usr/bin/openssl (LibreSSL), not from rcodesign:
# on macOS, rcodesign 0.29.0 generate-self-signed-certificate always fails
# with "configuration file error ... problem key: sha256", because its
# --profile option (default apple-development) is also read as the global
# configuration profile. The certificate has the fields of a Developer ID
# Application certificate: team ID in subject.OU, code signing EKU, and the
# Developer ID extension 1.2.840.113635.100.6.1.13.
cat >"$wdir/keys/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = Developer ID Application: Sandbox Host Signer ($host_team)
OU = $host_team
O = Sandbox Host Signer
C = XX
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
1.2.840.113635.100.6.1.13 = critical,DER:05:00
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$wdir/keys/cert.cnf" \
	-keyout "$wdir/keys/host.key" -out "$wdir/keys/host.crt"
/usr/bin/openssl pkcs12 -export -inkey "$wdir/keys/host.key" -in "$wdir/keys/host.crt" \
	-out "$wdir/keys/host.p12" -passout "fd:3" 3<<<"$pw"
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
