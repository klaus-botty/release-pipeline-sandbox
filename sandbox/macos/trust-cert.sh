#!/bin/bash
# Test setup only: marks throwaway self-signed certificates as trusted for
# code signing on a CI macOS runner, so that "anchor trusted" requirements and
# codesign --verify accept them. Needs sudo without a password (GitHub-hosted
# runners have it). Never run this on a real machine.
# Usage: trust-cert.sh CERT.crt...
set -euo pipefail
for c in "$@"; do
	sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$c"
	echo "trusted for code signing: $(openssl x509 -in "$c" -noout -subject)"
done
