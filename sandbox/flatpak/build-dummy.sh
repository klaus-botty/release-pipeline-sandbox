#!/usr/bin/env bash
# Builds a small dummy Flatpak app into a new unsigned repository, the way the
# release build does after flatpak-builder, but without a key and without
# static deltas:
#
#   flatpak build-update-repo --default-branch=stable --prune REPO
#
# Usage: build-dummy.sh VERSION WORK_DIR REPO_DIR
#
# Refs: app/org.example.SandboxApp/x86_64/stable, its .Locale and .Debug
# extensions, the runtime org.example.Platform/x86_64/1, appstream/x86_64,
# and appstream2/x86_64. VERSION changes the app, the locale, and the debug
# files; the runtime stays the same.
set -euo pipefail

[ $# -eq 3 ] || { echo "usage: build-dummy.sh VERSION WORK_DIR REPO_DIR" >&2; exit 1; }
v="$1" d="$2" repo="$3"
[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must be like 1.2.3: $v" >&2; exit 1; }
[ ! -e "$d" ] && [ ! -e "$repo" ] || { echo "WORK_DIR and REPO_DIR must not exist yet" >&2; exit 1; }

APP=org.example.SandboxApp
RT=org.example.Platform
ARCH=x86_64
BRANCH=stable

mkdir -p "$d/rt/usr/bin" "$d/app/files/bin" "$d/app/files/share/data" "$d/app/export" \
	"$d/loc/files/de" "$d/dbg/files/lib/debug"
printf '[Runtime]\nname=%s\nruntime=%s/%s/1\nsdk=%s/%s/1\n' $RT $RT $ARCH $RT $ARCH >"$d/rt/metadata"
echo runtime >"$d/rt/usr/bin/sh"

printf '[Application]\nname=%s\nruntime=%s/%s/1\nsdk=%s/%s/1\ncommand=sandbox-app\n\n[Extension %s.Locale]\ndirectory=share/runtime/locale\nautodelete=true\nlocale-subset=true\n\n[Extension %s.Debug]\ndirectory=lib/debug\nautodelete=true\nno-autodownload=true\n' \
	$APP $RT $ARCH $RT $ARCH $APP $APP >"$d/app/metadata"
printf '#!/bin/sh\necho sandbox app %s\n' "$v" >"$d/app/files/bin/sandbox-app"
chmod +x "$d/app/files/bin/sandbox-app"
# Files that stay the same between versions, and files that change: the
# static deltas between versions then have real content.
for i in $(seq 1 300); do head -c 4096 <(yes "stable-$i") >"$d/app/files/share/data/s$i"; done
for i in $(seq 1 20); do head -c 8192 <(yes "v$v-$i") >"$d/app/files/share/data/c$i"; done

printf '[Runtime]\nname=%s.Locale\n\n[ExtensionOf]\nref=app/%s/%s/%s\n' $APP $APP $ARCH $BRANCH >"$d/loc/metadata"
echo "locale $v" >"$d/loc/files/de/msg"
printf '[Runtime]\nname=%s.Debug\n\n[ExtensionOf]\nref=app/%s/%s/%s\n' $APP $APP $ARCH $BRANCH >"$d/dbg/metadata"
echo "debug $v" >"$d/dbg/files/lib/debug/sandbox-app.debug"

flatpak build-export --runtime --files=usr "$repo" "$d/rt" 1
flatpak build-export "$repo" "$d/app" $BRANCH
flatpak build-export --runtime --files=files "$repo" "$d/loc" $BRANCH
flatpak build-export --runtime --files=files "$repo" "$d/dbg" $BRANCH
flatpak build-update-repo --default-branch=$BRANCH --prune "$repo"
