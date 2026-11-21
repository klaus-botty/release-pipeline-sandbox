#!/usr/bin/env bash
# Flatpak repository signing. Source this file after lib.sh.
#
# Step 1 (CI) builds the Flatpak repository without a key and without static
# deltas. ci/flatpak-collect.sh packs the small files that need a signature
# into flatpak-to-sign.tar: summary, summary.idx, every commit object, and
# refs.txt (the refs of the repository with their commit ids).
# Step 2 (this file, on the machine of a maintainer) checks refs.txt against
# the expected ref names and signs exactly summary, summary.idx, and the commit
# objects that refs.txt names, with plain gpg. Step 3 (flatpak-finalize.sh)
# verifies the signatures and the refs, attaches the signatures to the
# repository, and generates the static deltas.
#
# refs.txt: one line per ref, "<ref name> <64 hex commit id>", one space,
# sorted by name (LC_ALL=C), no other lines. Two refs never share a commit:
# Flatpak binds every commit to its one ref.
#
# The functions work with bash 3.2, BSD and GNU userland, and need only gpg,
# tar, and a SHA-256 tool. They never handle a passphrase: gpg-agent does.
#
# Public functions:
#   flatpak_preflight FINGERPRINT
#   flatpak_expected_refs APP_ID ARCH BRANCH EXTRA_REFS_FILE|""
#   flatpak_sign TO_SIGN_TAR FINGERPRINT OUT_SIGNATURES_TAR EXPECTED_REFS_FILE
#   flatpak_check_unsigned_repo REPO_DIR        (CI: collect and finalize)
#   flatpak_repo_refs REPO_DIR                  (CI: the refs.txt lines)
#   flatpak_read_refs FILE                      (checks and prints a refs.txt)
#   flatpak_read_ref_list FILE                  (checks and prints ref names)
#   flatpak_compare_refs APPROVED ACTUAL ACTUAL_LABEL APPROVED_LABEL
#   flatpak_commit_path COMMIT_ID
#   flatpak_valid_ref NAME
#   flatpak_valid_sign_member NAME              (member name rule)

if ! command -v die >/dev/null 2>&1; then
	# shellcheck source-path=SCRIPTDIR source=lib.sh
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fi

# flatpak_valid_sign_member NAME: the only member names of flatpak-to-sign.tar.
flatpak_valid_sign_member() {
	case "$1" in
	summary | summary.idx | refs.txt) return 0 ;;
	esac
	[[ "$1" =~ ^objects/[0-9a-f]{2}/[0-9a-f]{62}\.commit$ ]]
}

# flatpak_valid_ref NAME: succeeds for app/ID/ARCH/BRANCH,
# runtime/ID/ARCH/BRANCH, appstream/ARCH, and appstream2/ARCH.
flatpak_valid_ref() {
	case "$1" in
	*..*) return 1 ;;
	esac
	[[ "$1" =~ ^(app|runtime)/[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_]+/[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] ||
		[[ "$1" =~ ^appstream2?/[A-Za-z0-9_]+$ ]]
}

# flatpak_commit_path COMMIT_ID: prints objects/<2 hex>/<62 hex>.commit.
flatpak_commit_path() {
	printf 'objects/%s/%s.commit\n' "${1:0:2}" "${1:2}"
}

# flatpak_read_ref_list FILE: prints the ref names of FILE, sorted. One name
# per line; white space, empty lines, and "#" comments are ignored. Fails on a
# name that is not a Flatpak ref and on a name that occurs twice.
flatpak_read_ref_list() {
	local file="$1" names name dup
	[ -f "$file" ] || {
		log "not a file: $file"
		return 1
	}
	names="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$file" | grep -v '^$' || true)"
	[ -n "$names" ] || return 0
	while IFS= read -r name; do
		flatpak_valid_ref "$name" || {
			log "$file: not a Flatpak ref name: $(printf '%q' "$name")"
			return 1
		}
	done <<EOF
$names
EOF
	dup="$(printf '%s\n' "$names" | LC_ALL=C sort | uniq -d)"
	[ -z "$dup" ] || {
		log "$file: ref listed more than once: $(printf '%s' "$dup" | tr '\n' ' ')"
		return 1
	}
	printf '%s\n' "$names" | LC_ALL=C sort
}

# flatpak_read_refs FILE: checks the refs.txt FILE and prints it. Fails unless
# every line is "<ref name> <64 hex commit id>", the names are sorted and
# unique, the file is not empty, and no commit id occurs twice.
flatpak_read_refs() {
	local file="$1" line content names dup
	[ -f "$file" ] && [ -s "$file" ] || {
		log "refs.txt is missing or empty: $file"
		return 1
	}
	content=""
	while IFS= read -r line || [ -n "$line" ]; do
		if ! [[ "$line" =~ ^([^ ]+)\ [0-9a-f]{64}$ ]] || ! flatpak_valid_ref "${line%% *}"; then
			log "$file: line is not \"<ref> <64 hex commit id>\": $(printf '%q' "$line")"
			return 1
		fi
		content="$content$line
"
	done <"$file"
	names="$(printf '%s' "$content" | cut -d' ' -f1)"
	[ "$names" = "$(printf '%s\n' "$names" | LC_ALL=C sort -u)" ] || {
		log "$file: the refs are not sorted (LC_ALL=C), or a ref occurs twice"
		return 1
	}
	dup="$(printf '%s' "$content" | cut -d' ' -f2 | LC_ALL=C sort | uniq -d)"
	[ -z "$dup" ] || {
		log "$file: two refs name the same commit $dup. Flatpak binds each commit to one ref."
		return 1
	}
	printf '%s' "$content"
}

# flatpak_compare_refs APPROVED ACTUAL ACTUAL_LABEL APPROVED_LABEL: fails, and
# lists every difference, unless the two files hold the same refs (first
# field) with the same commit ids (second field, if any).
flatpak_compare_refs() {
	local diff
	diff="$(awk -v what="$3" -v approved="$4" '
		FILENAME == ARGV[1] { want[$1] = $2; next }
		{ have[$1] = $2 }
		END {
			for (r in want) {
				if (!(r in have)) print r ": in " approved ", not in " what
				else if (want[r] != have[r]) print r ": " approved " has " want[r] ", " what " has " have[r]
			}
			for (r in have) if (!(r in want)) print r ": in " what (have[r] != "" ? " (" have[r] ")" : "") ", not in " approved
		}' "$1" "$2" | LC_ALL=C sort)"
	[ -n "$diff" ] || return 0
	log "$3 does not match $4:"
	printf '%s\n' "$diff" | sed 's/^/    /' >&2
	return 1
}

# flatpak_expected_refs APP_ID ARCH BRANCH EXTRA_REFS_FILE: prints the sorted
# ref names that a release must hold: app/APP_ID/ARCH/BRANCH,
# runtime/APP_ID.Debug/ARCH/BRANCH, appstream/ARCH, appstream2/ARCH, and the
# names in EXTRA_REFS_FILE (format of flatpak_read_ref_list; "" for none).
flatpak_expected_refs() {
	local app_id="${1:-}" arch="${2:-}" branch="${3:-}" extras="${4:-}" list more dup
	[ $# -eq 4 ] || die "usage: flatpak_expected_refs APP_ID ARCH BRANCH EXTRA_REFS_FILE|\"\""
	[[ "$app_id" =~ ^[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z_][A-Za-z0-9_-]*)+$ ]] || die "not a Flatpak application id: $app_id"
	[[ "$arch" =~ ^[A-Za-z0-9_]+$ ]] || die "not a Flatpak architecture: $arch"
	[[ "$branch" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || die "not a Flatpak branch name: $branch"
	list="app/$app_id/$arch/$branch
runtime/$app_id.Debug/$arch/$branch
appstream/$arch
appstream2/$arch"
	if [ -n "$extras" ]; then
		more="$(flatpak_read_ref_list "$extras")" || die "the extra ref list $extras is not valid"
		[ -z "$more" ] || list="$list
$more"
	fi
	dup="$(printf '%s\n' "$list" | LC_ALL=C sort | uniq -d)"
	[ -z "$dup" ] || die "the extra ref list $extras repeats a conventional ref: $dup"
	printf '%s\n' "$list" | LC_ALL=C sort
}

# flatpak_normalize_fingerprint FINGERPRINT: prints the fingerprint in upper
# case. Fails unless it is a full v4 (40 hex) or v5 (64 hex) fingerprint.
flatpak_normalize_fingerprint() {
	local fpr
	fpr="$(printf '%s' "$1" | tr -d ' ' | tr 'a-f' 'A-F')"
	if ! [[ "$fpr" =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]]; then
		log "not a full key fingerprint (40 or 64 hex digits): $1"
		return 1
	fi
	printf '%s\n' "$fpr"
}

# flatpak_preflight FINGERPRINT: fails unless the local keyring holds a usable
# secret key that can sign for the primary key FINGERPRINT. Lists keys only, so
# gpg never asks for a passphrase.
flatpak_preflight() {
	local fpr listing problem
	[ $# -eq 1 ] || die "usage: flatpak_preflight FINGERPRINT"
	need_tools gpg tar
	fpr="$(flatpak_normalize_fingerprint "$1")" || die "flatpak signing key: bad fingerprint"
	listing="$(gpg --batch --no-tty --with-colons --list-secret-keys -- "$fpr" 2>/dev/null </dev/null)" ||
		die "no secret key for the Flatpak signing key $fpr in your keyring"
	# Records: sec/ssb lines, each followed by its fpr line.
	#   field 2: validity (e = expired, r = revoked, d = disabled)
	#   field 12: capabilities; an upper case S means: the key can sign
	#   field 15: '#' means: the secret part is not on this machine
	problem="$(printf '%s\n' "$listing" | awk -F: -v want="$fpr" '
		$1 == "sec" || $1 == "ssb" { type = $1; validity = $2; caps = $12; serial = $15; next }
		$1 == "fpr" && type == "sec" {
			inkey = ($10 == want)
			if (inkey) { found = 1; keycaps = caps; keyvalid = validity }
		}
		$1 == "fpr" && type != "" {
			if (inkey && caps ~ /s/ && serial != "#" && validity !~ /[erd]/) usable = 1
			type = ""
		}
		END {
			if (!found) { print "no secret primary key with this fingerprint"; exit }
			if (keyvalid ~ /[erd]/) { print "the key is expired, revoked, or disabled"; exit }
			if (keycaps !~ /S/) { print "the key has no usable signing capability"; exit }
			if (!usable) { print "no secret signing (sub)key of this key is on this machine (only stubs)"; exit }
		}')"
	[ -z "$problem" ] || die "Flatpak signing key $fpr: $problem"
}

# _flatpak_unpack_to_sign TAR DIR: unpacks TAR into the empty directory DIR,
# and prints the sorted member names. Fails unless every member is a regular
# file with an allowed name, no name occurs twice, and the archive holds
# summary, summary.idx, refs.txt, and at least one commit.
_flatpak_unpack_to_sign() {
	local tar_file="$1" dir="$2" names verbose name duplicates count found commits=0
	names="$(LC_ALL=C tar -tf "$tar_file" 2>/dev/null)" || {
		log "cannot read $tar_file as a tar archive"
		return 1
	}
	[ -n "$names" ] || {
		log "$tar_file is empty"
		return 1
	}
	while IFS= read -r name; do
		if ! flatpak_valid_sign_member "$name"; then
			log "$tar_file: member is not allowed: $(printf '%q' "$name")"
			log "  allowed: summary, summary.idx, refs.txt, objects/<2 hex>/<62 hex>.commit"
			return 1
		fi
		case "$name" in
		objects/*) commits=$((commits + 1)) ;;
		esac
	done <<EOF
$names
EOF
	duplicates="$(printf '%s\n' "$names" | LC_ALL=C sort | uniq -d)"
	if [ -n "$duplicates" ]; then
		log "$tar_file: member occurs more than once: $duplicates"
		return 1
	fi
	for name in summary summary.idx refs.txt; do
		printf '%s\n' "$names" | grep -qxF -- "$name" || {
			log "$tar_file: $name is missing"
			return 1
		}
	done
	[ "$commits" -gt 0 ] || {
		log "$tar_file: holds no commit object"
		return 1
	}
	# The type of each member: the first character of a verbose listing is "-"
	# for a regular file, in GNU tar, bsdtar, and busybox tar.
	verbose="$(LC_ALL=C tar -tvf "$tar_file" 2>/dev/null)" || {
		log "cannot list $tar_file"
		return 1
	}
	count="$(printf '%s\n' "$names" | wc -l | tr -d ' ')"
	[ "$(printf '%s\n' "$verbose" | wc -l | tr -d ' ')" = "$count" ] || {
		log "$tar_file: the verbose listing does not match the member list"
		return 1
	}
	if printf '%s\n' "$verbose" | grep -v '^-' | grep -q .; then
		log "$tar_file: holds members that are not regular files (links, directories, or devices):"
		printf '%s\n' "$verbose" | grep -v '^-' | sed 's/^/    /' >&2
		return 1
	fi
	# The names are checked, so extraction stays inside DIR.
	(cd "$dir" && LC_ALL=C tar -xf "$tar_file") || {
		log "cannot unpack $tar_file"
		return 1
	}
	# Check the result once more: only the listed regular files, no links.
	found="$(cd "$dir" && find . ! -type d -print | wc -l | tr -d ' ')"
	[ "$found" = "$count" ] || {
		log "$tar_file: unpacking made $found files, but the archive lists $count"
		return 1
	}
	if [ -n "$(cd "$dir" && find . ! -type d ! -type f -print)" ] ||
		[ -n "$(cd "$dir" && find . -type f -links +1 -print)" ]; then
		log "$tar_file: unpacking made links"
		return 1
	fi
	while IFS= read -r name; do
		[ -f "$dir/$name" ] && [ ! -L "$dir/$name" ] || {
			log "$tar_file: $name is not a regular file after unpacking"
			return 1
		}
	done <<EOF
$names
EOF
	chmod -R u+rwX "$dir"
	printf '%s\n' "$names" | LC_ALL=C sort
}

# flatpak_sign TO_SIGN_TAR FINGERPRINT OUT_SIGNATURES_TAR EXPECTED_REFS_FILE:
# checks the refs.txt of TO_SIGN_TAR against EXPECTED_REFS_FILE (one ref name
# per line, see flatpak_expected_refs) and signs exactly summary, summary.idx,
# and the commit objects that refs.txt names, each with a binary detached
# signature by the key FINGERPRINT. Writes <member>.sig and a copy of refs.txt
# (the record of what was approved) into OUT_SIGNATURES_TAR.
# Refuses unless the ref names in refs.txt equal the expected names, every
# commit that refs.txt names is in the archive, no other commit object is in
# the archive, and every commit file name equals the SHA-256 of its content.
# The function runs in a subshell, so its temp directory and its trap stay
# local.
flatpak_sign() (
	set -euo pipefail
	[ $# -eq 4 ] || die "usage: flatpak_sign TO_SIGN_TAR FINGERPRINT OUT_SIGNATURES_TAR EXPECTED_REFS_FILE"
	to_sign="$1" out="$3" expected_file="$4"
	fpr="$(flatpak_normalize_fingerprint "$2")" || die "flatpak signing key: bad fingerprint"
	need_tools gpg tar
	[ -f "$to_sign" ] || die "not a file: $to_sign"
	[ -f "$expected_file" ] || die "not a file: $expected_file"
	[ ! -e "$out" ] && [ ! -L "$out" ] || die "$out exists already"
	case "$to_sign" in /*) ;; *) to_sign="$PWD/$to_sign" ;; esac
	case "$out" in /*) ;; *) out="$PWD/$out" ;; esac

	tmp="$(mktemp -d "${TMPDIR:-/tmp}/flatpak-sign.XXXXXX")" || die "cannot create a temp directory"
	trap 'rm -rf "$tmp"' EXIT
	mkdir "$tmp/files" "$tmp/sigs"

	flatpak_read_ref_list "$expected_file" >"$tmp/expected" ||
		die "refusing to sign: the expected ref list $expected_file is not valid"
	[ -s "$tmp/expected" ] || die "refusing to sign: the expected ref list $expected_file is empty"
	names="$(_flatpak_unpack_to_sign "$to_sign" "$tmp/files")" ||
		die "refusing to sign $to_sign"
	flatpak_read_refs "$tmp/files/refs.txt" >"$tmp/refs" ||
		die "refusing to sign $to_sign: its refs.txt is not valid"
	cut -d' ' -f1 "$tmp/refs" >"$tmp/ref-names"
	flatpak_compare_refs "$tmp/expected" "$tmp/ref-names" "refs.txt" "the expected ref list" ||
		die "refusing to sign $to_sign: the refs in its refs.txt differ from the expected refs in $expected_file"

	# The commit objects that refs.txt names, and no other.
	: >"$tmp/approved"
	while read -r ref commit; do
		path="$(flatpak_commit_path "$commit")"
		printf '%s\n' "$names" | grep -qxF -- "$path" ||
			die "refusing to sign $to_sign: refs.txt says $ref is the commit $commit, but the archive holds no commit object $path"
		printf '%s\n' "$path" >>"$tmp/approved"
	done <"$tmp/refs"
	LC_ALL=C sort -o "$tmp/approved" "$tmp/approved"
	printf '%s\n' "$names" | grep '^objects/' | LC_ALL=C sort >"$tmp/objects"
	orphans="$(LC_ALL=C comm -13 "$tmp/approved" "$tmp/objects")"
	[ -z "$orphans" ] ||
		die "refusing to sign $to_sign: it holds commit objects that no ref in refs.txt names: $(printf '%s' "$orphans" | tr '\n' ' ')"

	# Each commit object is named after the SHA-256 of its content.
	while IFS= read -r name; do
		want="${name#objects/}"
		want="${want%%/*}${want#*/}"
		want="${want%.commit}"
		got="$(sha256_of "$tmp/files/$name")"
		[ "$got" = "$want" ] ||
			die "refusing to sign $to_sign: the content of $name has the SHA-256 $got, not the hash in its name"
	done <"$tmp/approved"

	{
		printf '%s\n' summary summary.idx
		cat "$tmp/approved"
	} >"$tmp/sign"
	# --no-armor: ostree needs binary signatures, even if gpg.conf sets armor.
	while IFS= read -r name; do
		mkdir -p "$tmp/sigs/$(dirname "$name")"
		gpg --batch --yes --no-armor --local-user "$fpr" \
			--detach-sign --output "$tmp/sigs/$name.sig" "$tmp/files/$name" </dev/null ||
			die "gpg cannot sign $name with $fpr"
		# The signature must come from this key, also if gpg.conf says otherwise.
		status="$(gpg --batch --no-tty --status-fd 1 --verify "$tmp/sigs/$name.sig" "$tmp/files/$name" 2>/dev/null </dev/null)" ||
			die "the new signature of $name does not verify"
		primary="$(printf '%s\n' "$status" | awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print $NF }')"
		[ "$primary" = "$fpr" ] || die "the new signature of $name comes from $primary, not from $fpr"
	done <"$tmp/sign"
	cp "$tmp/refs" "$tmp/sigs/refs.txt"

	# ustar holds the short names, and it has no room for extended attributes.
	# COPYFILE_DISABLE stops macOS tar from adding ._ files. The archive
	# leaves this machine, so it records owner 0 and the time 1970-01-01
	# instead of the login name of the maintainer and the signing time.
	{
		sed 's/$/.sig/' "$tmp/sign"
		printf '%s\n' refs.txt
	} >"$tmp/list"
	tar_version="$(tar --version 2>/dev/null </dev/null | head -n 1)" || tar_version=""
	case "$tar_version" in
	*"GNU tar"*) owner_opts="--owner=0 --group=0 --numeric-owner" ;;
	*bsdtar*) owner_opts="--uid 0 --gid 0 --uname root --gname root" ;;
	*) die "cannot write $out: tar is neither GNU tar nor bsdtar ($tar_version)" ;;
	esac
	(cd "$tmp/sigs" && find . -type f -exec env TZ=UTC touch -t 197001010000 {} +) ||
		die "cannot set the time of the signature files"
	# shellcheck disable=SC2086 # owner_opts holds several options without spaces in them
	(cd "$tmp/sigs" && COPYFILE_DISABLE=1 LC_ALL=C tar --format=ustar $owner_opts -cf "$out.tmp" -T "$tmp/list") ||
		die "cannot write $out"
	mv "$out.tmp" "$out"
	log "    approved refs:"
	sed 's/^/      /' "$tmp/refs" >&2
	log "    signed summary, summary.idx, and $(grep -c . "$tmp/approved") commit objects with $fpr"
)

# flatpak_repo_refs REPO_DIR: prints the refs.txt lines of the repository:
# every file below refs/heads, with its commit id, sorted.
flatpak_repo_refs() {
	local repo="$1" refs ref commit
	[ -d "$repo/refs/heads" ] || {
		log "$repo has no refs/heads directory"
		return 1
	}
	refs="$(cd "$repo/refs/heads" && find . -type f -print | sed 's|^\./||' | LC_ALL=C sort)"
	[ -n "$refs" ] || {
		log "$repo has no refs"
		return 1
	}
	while IFS= read -r ref; do
		flatpak_valid_ref "$ref" || {
			log "$repo: not a Flatpak ref name: refs/heads/$(printf '%q' "$ref")"
			return 1
		}
		commit="$(cat "$repo/refs/heads/$ref")"
		[[ "$commit" =~ ^[0-9a-f]{64}$ ]] || {
			log "$repo: refs/heads/$ref holds no commit id"
			return 1
		}
		printf '%s %s\n' "$ref" "$commit"
	done <<EOF
$refs
EOF
}

# flatpak_check_unsigned_repo REPO_DIR: fails unless REPO_DIR is an unsigned
# Flatpak repository without static deltas, with summary, summary.idx, at
# least one commit, and refs only below refs/heads. Used by CI, so GNU find is
# fine, but the code stays simple.
flatpak_check_unsigned_repo() {
	local repo="$1" found
	[ -d "$repo" ] || die "not a directory: $repo"
	[ -f "$repo/config" ] && [ -d "$repo/objects" ] || die "$repo is not an OSTree repository (no config file or objects directory)"
	found="$(cd "$repo" && find . ! -type f ! -type d -print | awk 'NR <= 5')"
	[ -z "$found" ] || die "$repo holds entries that are not regular files or directories: $found"
	found="$(cd "$repo" && find . -name '*[!A-Za-z0-9._+-]*' -print | awk 'NR <= 5')"
	[ -z "$found" ] || die "$repo holds names with characters outside A-Z a-z 0-9 . _ + -: $found"
	found="$(cd "$repo" && for d in deltas delta-indexes; do [ ! -d "$d" ] || find "$d" ! -type d -print; done | awk 'NR <= 5')"
	[ -z "$found" ] ||
		die "$repo holds static deltas ($found ...). A delta superblock embeds the commit signature, so the deltas must be generated after the signatures are attached, in the finalize step. Run 'flatpak build-update-repo' without --generate-static-deltas."
	found="$(cd "$repo" && find objects -name '*.commitmeta' -print | awk 'NR <= 5')"
	[ -z "$found" ] ||
		die "$repo holds commit signatures or other detached commit metadata ($found ...). Step 1 must build without a key: no --gpg-sign for flatpak-builder or flatpak build-update-repo."
	found="$(cd "$repo" && find . -name '*.sig' -print | awk 'NR <= 5')"
	[ -z "$found" ] ||
		die "$repo holds summary signatures ($found). Step 1 must run 'flatpak build-update-repo' without --gpg-sign."
	[ -f "$repo/summary" ] && [ -f "$repo/summary.idx" ] ||
		die "$repo has no summary or no summary.idx. Run 'flatpak build-update-repo --default-branch=<branch> --prune' after the build."
	found="$(cd "$repo" && find objects -type f -name '*.commit' -print | awk 'NR == 1')"
	[ -n "$found" ] || die "$repo holds no commit object"
	found="$(cd "$repo" && { [ ! -d refs ] || find refs -type f ! -path 'refs/heads/*' -print; } | awk 'NR <= 5')"
	[ -z "$found" ] || die "$repo holds refs outside refs/heads (remotes or mirrors): $found"
}
