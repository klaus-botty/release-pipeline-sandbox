#!/usr/bin/env bash
# Stand-in build: writes files of random bytes with the names of real
# release files. Usage: fake-build.sh NAME VERSION OUTDIR (NAME: linux|macos)
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 NAME VERSION OUTDIR" >&2
  exit 2
fi
name="$1"
V="$2"
out="$3"
mkdir -p "$out"

# write_random FILE MEGABYTES
write_random() {
  head -c "$(($2 * 1024 * 1024))" /dev/urandom >"$out/$1"
}

case "$name" in
  linux)
    write_random "sample_${V}_amd64.AppImage" 8
    write_random "sample_${V}_amd64.deb" 4
    write_random "sample_${V}_x64-setup.exe" 6
    write_random "tool_${V}_Linux_x86_64.tar" 2
    write_random "tool_${V}_Windows_x86_64.zip" 2
    write_random "helper_${V}_Linux_x86_64.tar" 1
    updater_file="sample_${V}_amd64.AppImage"
    ;;
  macos)
    write_random "sample_${V}_aarch64.dmg" 8
    write_random "sample_${V}_x64.dmg" 8
    write_random "sample_aarch64.app.tar.gz" 6
    write_random "sample_x64.app.tar.gz" 6
    write_random "tool_${V}_Darwin_aarch64.tar" 2
    write_random "tool_${V}_Darwin_x86_64.tar" 2
    updater_file="sample_aarch64.app.tar.gz"
    ;;
  *)
    echo "unknown build name: $name (expected linux or macos)" >&2
    exit 2
    ;;
esac

# A real build signs updater files with a throwaway key and drops those
# signatures. The maintainer signs them later with the real updater key.
echo "junk signature" >"$out/$updater_file.sig"
find "$out" -name '*.sig' -type f -delete

ls -l "$out"
