#!/bin/bash
# Runs the offline tests of the release scripts on a macOS runner, with
# /bin/bash (3.2) and the BSD tools of macOS. Only these tools come from
# elsewhere: gpg and minisign (Homebrew), rcodesign (the pinned release
# binary), and jq (the one of the runner). They get links in one directory;
# PATH holds that directory and the system directories only, so no GNU tool
# and no newer bash from Homebrew can take part.
#
# The Apple fixture (an unsigned app archive and DMG) is built here with
# sandbox/macos/build.sh and ci/macos-collect.sh. The Flatpak fixture and the
# throwaway updater keys are files in fixtures/.
#
# Usage: run-macos.sh WORK_DIR
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$1"
mkdir -p "$work"
work="$(cd "$work" && pwd)"
repo="$here/repo"
rel="$repo/dev-scripts/release"

echo "== host"
sw_vers
uname -m

echo "== tools"
tools="$work/tools"
mkdir -p "$tools"
for t in gpg gpg-agent gpgconf gpg-connect-agent minisign rcodesign jq; do
	p="$(command -v "$t")" || { echo "missing tool: $t" >&2; exit 1; }
	ln -sf "$p" "$tools/$t"
	echo "$t: $p"
done
export PATH="$tools:/usr/bin:/bin:/usr/sbin:/sbin"
echo "bash: $(command -v bash) ($(bash --version | head -n 1))"
case "$(bash --version | head -n 1)" in
*"version 3.2"*) ;;
*) echo "bash on PATH is not 3.2" >&2; exit 1 ;;
esac
for t in sed awk tar find sort grep stat base64 date mktemp cmp diff od cut tr wc head tail xargs; do
	printf '%s: %s\n' "$t" "$(command -v "$t")"
done
command -v sha256sum >/dev/null 2>&1 && echo "sha256sum: $(command -v sha256sum)" || echo "sha256sum: none (shasum is used)"
gpg --version | head -n 1
minisign -v 2>&1 | head -n 1 || true
rcodesign --version
jq --version

echo "== /bin/bash -n on every script"
n=0
for f in "$rel"/*.sh "$rel"/ci/*.sh "$repo"/dev-scripts/homebrew/*.sh "$here"/offline-test/*.sh "$here"/*.sh; do
	/bin/bash -n "$f"
	n=$((n + 1))
done
echo "syntax ok: $n files"

echo "== Apple fixture: unsigned app and DMG (build.sh, then ci/macos-collect.sh)"
build="$work/build"
fixture="$work/apple-fixture"
rm -rf "$build" "$fixture"
# build.sh needs python3, sips, clang, and SetFile: all in the system
# directories.
/bin/bash "$here/../macos/build.sh" aarch64 "$build" 0.0.1 >"$work/build.log" 2>&1 ||
	{ cat "$work/build.log"; exit 1; }
tail -n 3 "$work/build.log"
/bin/bash "$rel/ci/macos-collect.sh" --app "$build/sandboxapp.app" --dmg "$build/sandboxapp_0.0.1_aarch64.dmg" \
	--app-base testapp_aarch64 --dmg-base testapp_0.0.1_aarch64 --out "$fixture"
ls -l "$fixture"

echo "== offline tests"
export APPLE_TOOLS_PATH="" APPLE_FIXTURE_DIR="$fixture"
export FLATPAK_FIXTURE_DIR="$here/fixtures/flatpak" TAURI_KEYS_DIR="$here/fixtures/tauri"
/bin/bash "$here/offline-test/run-offline-tests.sh" "$rel"
