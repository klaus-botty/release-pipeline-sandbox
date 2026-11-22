#!/bin/bash
# Runs verify-macos.sh on the probe data: the positive case must pass, and
# every negative case must fail with the expected message.
# Usage: verify-probe.sh DATA_DIR
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
data="$1"
verify="$here/module/verify-macos.sh"
team=ZZTEST0001
req="anchor trusted and certificate leaf[subject.OU] = \"$team\""
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
failed=0

run_verify() { # DIR TEAM [ARG...]
	local d="$1" t="$2"
	shift 2
	/bin/bash "$verify" --dir "$d" --requirement "$req" --notarized false --team-id "$t" \
		--bundle-id org.example.sandboxapp --version 1.2.3 \
		--entitlements "$here/app/entitlements.plist" "$@"
}

echo "== positive case (requirement: $req)"
if run_verify "$data/signed" "$team" --unsigned-dir "$data/unsigned"; then
	echo "POSITIVE: pass"
	echo "- positive case: pass" >>"$summary"
else
	echo "POSITIVE: FAIL"
	echo "- positive case: FAIL" >>"$summary"
	failed=1
fi

negative() { # NAME PATTERN DIR TEAM
	local name="$1" pattern="$2" out rc
	echo
	echo "== negative case $name"
	out="$(run_verify "$3" "$4" 2>&1)"
	rc=$?
	printf '%s\n' "$out" | sed 's/^/    /'
	msg="$(printf '%s\n' "$out" | grep '^error: ' | tail -n 1)"
	if [ "$rc" = 0 ]; then
		echo "NEGATIVE $name: ACCEPTED (wrong)"
		failed=1
	elif printf '%s\n' "$msg" | grep -q -- "$pattern"; then
		echo "NEGATIVE $name: refused: $msg"
	else
		echo "NEGATIVE $name: refused, but not with '$pattern': $msg"
		failed=1
	fi
	printf -- '- %s: rc=%s: %s\n' "$name" "$rc" "$msg" >>"$summary"
}
negative wrong-team-id "is not for team .ZZWRONG999." "$data/signed" ZZWRONG999
negative other-team "requirement fails" "$data/neg/other-team" "$team"
negative unsigned-dmg "requirement fails" "$data/neg/unsigned-dmg" "$team"
negative separate-signing "different code directory hashes" "$data/neg/separate-signing" "$team"
negative separate-resign "hold different apps" "$data/neg/separate-resign" "$team"
negative wrong-bundle-id "signing identifier is" "$data/neg/wrong-bundle-id" "$team"
negative wrong-version "CFBundleShortVersionString is" "$data/neg/wrong-version" "$team"
negative other-entitlements "entitlements differ" "$data/neg/other-entitlements" "$team"
negative broken-seal "requirement fails" "$data/neg/broken-seal" "$team"
negative no-runtime "no hardened runtime flag" "$data/neg/no-runtime" "$team"
negative wrong-arch "but the asset name says" "$data/neg/wrong-arch" "$team"
exit "$failed"
