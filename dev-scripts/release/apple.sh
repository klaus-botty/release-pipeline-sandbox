#!/usr/bin/env bash
# Apple code signing for step 2 of the release pipeline. Source this file
# after lib.sh.
#
# CI builds, per architecture, an unsigned app and an unsigned DMG:
#   <base>.app.unsigned.tar   the .app directory at the top level
#   <base>.unsigned.dmg       the DMG template, with the unsigned app inside
# The functions here sign the app with rcodesign, notarize and staple it if
# asked, and write:
#   <base>.app.tar.gz         the updater archive, with the signed app
#   <base>.dmg                the DMG, rebuilt around the signed app, signed
#
# Public functions:
#   apple_preflight tools
#   apple_preflight secrets <notarize: true|false> <team_id>
#   apple_process_arch <unsigned_app_tar> <unsigned_dmg> <entitlements_plist> <notarize> <out_dir>
#   apple_process_all <in_dir> <entitlements_plist> <notarize> <out_dir>
#   apple_tar_app <parent_dir> <app_name> <out_file> <gz|none>
#
# Secrets: the caller holds them in shell variables. Never export them. They
# reach rcodesign through process substitution only, so they never reach an
# argument list, the environment of a child, or a file on disk. A pipe can
# be read once, without seeking. rcodesign 0.29.0 (apple-codesign crate)
# reads each file once, from start to end, per call:
#   --p12-file           std::fs::read          src/cli/certificate_source.rs:385
#   --p12-password-file  std::fs::read_to_string src/cli/mod.rs:102 (first line)
#   --api-key-file       std::fs::read          app-store-connect 0.7.0 src/api_key.rs:84,
#                        via src/notarization.rs:168, once per notary-submit (src/cli/mod.rs:853)
# `sign` resolves the certificate once (src/cli/mod.rs:1529), and so does
# `analyze-certificate` (src/cli/mod.rs:320). Check this again when rcodesign
# changes.
#   APPLE_P12_BASE64            the Developer ID Application certificate and key (.p12, base64)
#   APPLE_P12_PASSWORD          the password of the .p12 file
#   APPLE_API_KEY_JSON_BASE64   only for notarization: the JSON file that
#                               `rcodesign encode-app-store-connect-api-key` writes, base64
#
# Optional:
#   APPLE_TIMESTAMP_URL         passed to `rcodesign sign --timestamp-url`.
#                               Default: the default of rcodesign (the Apple
#                               timestamp server). Notarization needs it.
#
# Hosts: Linux (rcodesign, dmg and hfsplus from xpwn, and bwrap, which runs
# xpwn in a sandbox) and macOS (rcodesign and hdiutil). The code works with
# bash 3.2, with BSD and GNU userland, and with GNU tar and bsdtar.
#
# Untrusted input: the CI build may be compromised, so the unsigned app
# archive and the unsigned DMG are untrusted on this machine, which holds
# the signing keys. See "Archives and app trees" and "Sandbox for xpwn".

# Other scripts use the variables that this file sets.
# shellcheck disable=SC2034

declare -F die >/dev/null 2>&1 || {
	printf 'error: source lib.sh before apple.sh\n' >&2
	return 1
}

APPLE_UNSIGNED_APP_SUFFIX=".app.unsigned.tar"
APPLE_UNSIGNED_DMG_SUFFIX=".unsigned.dmg"
APPLE_APP_SUFFIX=".app.tar.gz"
APPLE_DMG_SUFFIX=".dmg"

_APPLE_TAB="$(printf '\t')"
_APPLE_TAG=""

# _apple_note MESSAGE: a progress line, with the tag of the architecture.
_apple_note() { log "${_APPLE_TAG:+$_APPLE_TAG }$*"; }
_APPLE_NL='
'

# ---------------------------------------------------------------------------
# Secrets. Each function writes one secret to stdout, for a process
# substitution. printf is a shell builtin, so no argument list holds a secret.
# ---------------------------------------------------------------------------

_apple_p12() { printf '%s' "$APPLE_P12_BASE64" | base64 --decode; }
_apple_p12_password() { printf '%s' "$APPLE_P12_PASSWORD"; }
_apple_api_key() { printf '%s' "$APPLE_API_KEY_JSON_BASE64" | base64 --decode; }

# ---------------------------------------------------------------------------
# rcodesign
# ---------------------------------------------------------------------------

# _apple_rcodesign ARG...: runs rcodesign without the environment variables
# that start with RCODESIGN_. rcodesign reads each of them as a configuration
# setting (RCODESIGN_<KEY>), even with "-C /dev/null", so an unrelated
# variable can change or break the signing: RCODESIGN_SHA256 in a CI job made
# every call fail with "problem key: sha256". Every rcodesign call goes
# through this function.
_apple_rcodesign() {
	local v drop=()
	for v in $(compgen -e); do
		case "$v" in
		RCODESIGN_*) drop+=(-u "$v") ;;
		esac
	done
	env ${drop[@]+"${drop[@]}"} rcodesign "$@"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

_apple_host() {
	case "$(uname -s)" in
	Darwin) printf 'macos\n' ;;
	Linux) printf 'linux\n' ;;
	*) die "Apple signing runs on Linux or macOS only, not on $(uname -s)" ;;
	esac
}

# apple_preflight tools: checks the tools for this host. Needs no secret, so
# the caller can run it before the passphrase prompt.
# apple_preflight secrets NOTARIZE TEAM_ID: checks that the secret variables
# are set, that rcodesign can open the certificate with the password, and that
# the certificate belongs to TEAM_ID (its subject.OU, the team that step 3
# requires). With NOTARIZE=true, it also checks the App Store Connect API key.
apple_preflight() {
	local what="${1:-}" host out w
	case "$what" in
	tools)
		host="$(_apple_host)" || exit 1
		need_tools rcodesign tar gzip od base64 find sort awk jq cmp diff
		if [ "$host" = macos ]; then
			need_tools hdiutil ditto
		else
			need_tools dmg hfsplus bwrap env
			w="$(mktemp -d "${TMPDIR:-/tmp}/apple-preflight.XXXXXX")" || die "cannot create a temp directory"
			if ! { w="$(cd -P "$w" && pwd -P)" && mkdir "$w/jail" && _apple_jail_check "$w"; }; then
				rm -rf "$w"
				die "the sandbox for the DMG tools does not work on this host"
			fi
			out="$(_apple_jail "$w" dmg 2>&1 || true)"
			rm -rf "$w"
			case "$out" in
			*build*extract* | *extract*build*) ;;
			*) die "the dmg command is not the dmg tool of xpwn (install xpwn): $out" ;;
			esac
		fi
		;;
	secrets)
		_apple_check_notarize_arg "${2:-}"
		[[ "${3:-}" =~ ^[A-Z0-9]{10}$ ]] || die "apple_preflight secrets: the expected team ID is not 10 capital letters or digits: '${3:-}'"
		[ -n "${APPLE_P12_BASE64:-}" ] || die "APPLE_P12_BASE64 is not set"
		[ -n "${APPLE_P12_PASSWORD+set}" ] || die "APPLE_P12_PASSWORD is not set"
		out="$(_apple_rcodesign analyze-certificate -C /dev/null --p12-file <(_apple_p12) \
			--p12-password-file <(_apple_p12_password) 2>&1)" ||
			die "rcodesign cannot open the certificate in APPLE_P12_BASE64 with APPLE_P12_PASSWORD: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
		log "    Apple certificate: $(printf '%s\n' "$out" | sed -n 's/^Subject CN: *//p' | head -n 1)"
		out="$(_apple_team_id)" || die "cannot read the team ID of the certificate in APPLE_P12_BASE64"
		log "    Apple team ID (subject.OU of the certificate): $out"
		[ "$out" = "$3" ] ||
			die "the Apple certificate in the secrets belongs to team $out, but apple.team_id in config.json is $3. Step 3 accepts only signatures of team $3. Use the certificate of team $3 (just release-signing-setup)."
		if [ "$2" = true ]; then
			[ -n "${APPLE_API_KEY_JSON_BASE64:-}" ] || die "APPLE_API_KEY_JSON_BASE64 is not set (needed for notarization)"
			_apple_api_key | jq -e '(.issuer_id | strings) and (.key_id | strings) and (.private_key | strings)' >/dev/null 2>&1 ||
				die "APPLE_API_KEY_JSON_BASE64 is not the base64 of the JSON that 'rcodesign encode-app-store-connect-api-key' writes"
		fi
		;;
	*) die "usage: apple_preflight tools | apple_preflight secrets <true|false> <team_id>" ;;
	esac
}

# _apple_team_id: prints the team ID of the signing certificate (its
# subject.OU, which rcodesign reports as "Team ID"). The certificate comes
# first in the output of analyze-certificate.
_apple_team_id() {
	local out team
	out="$(_apple_rcodesign analyze-certificate -C /dev/null --p12-file <(_apple_p12) \
		--p12-password-file <(_apple_p12_password) 2>&1)" || {
		log "rcodesign cannot open the certificate: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
		return 1
	}
	team="$(printf '%s\n' "$out" | sed -n 's/^Team ID: *//p' | head -n 1)"
	[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || {
		log "the certificate has no team ID of 10 letters and digits in subject.OU: '$team'"
		return 1
	}
	printf '%s\n' "$team"
}

_apple_check_notarize_arg() {
	case "$1" in
	true | false) ;;
	*) die "notarize must be true or false, not '$1'" ;;
	esac
}

# ---------------------------------------------------------------------------
# File trees
# ---------------------------------------------------------------------------

# _apple_perm PATH: prints the permission bits of PATH as 4 octal digits.
_apple_perm() {
	local p
	p="$(stat -c %a "$1" 2>/dev/null)" || p="$(stat -f %Mp%Lp "$1")" || return 1
	printf '%04o\n' "$((8#$p))"
}

# _apple_is_macho FILE: true if FILE starts with a Mach-O or fat Mach-O magic.
# 0xcafebabe is also the magic of Java class files. Like file(1), a value
# below 45 in the next 4 bytes means a fat Mach-O (an architecture count),
# and a higher value means a Java class (a class file version).
_apple_is_macho() {
	local bytes magic
	[ -f "$1" ] && [ ! -L "$1" ] || return 1
	bytes="$(od -A n -t x1 -N 8 "$1" 2>/dev/null | tr -d ' \n')"
	magic="${bytes:0:8}"
	case "$magic" in
	feedface | feedfacf | cefaedfe | cffaedfe) return 0 ;;
	cafebabe | bebafeca)
		[ "${#bytes}" = 16 ] || return 1
		if [ "$magic" = cafebabe ]; then
			[ "$((16#${bytes:8:8}))" -lt 45 ]
		else
			[ "$((16#${bytes:14:2}${bytes:12:2}${bytes:10:2}${bytes:8:2}))" -lt 45 ]
		fi
		;;
	*) return 1 ;;
	esac
}

# _apple_check_names PARENT APP [ascii]: fails if a name in the tree has a tab
# or a newline. With "ascii", it also fails on names that are not printable
# ASCII: the HFS+ tools of xpwn convert names byte by byte.
_apple_check_names() {
	local parent="$1" app="$2" mode="${3:-}" bad
	bad="$(cd "$parent" && find "$app" \( -name "*$_APPLE_NL*" -o -name "*$_APPLE_TAB*" \) -print)" || return 1
	[ -z "$bad" ] || {
		log "$app holds a name with a tab or a newline"
		return 1
	}
	if [ "$mode" = ascii ]; then
		bad="$(cd "$parent" && find "$app" -print | LC_ALL=C grep '[^ -~]' || true)"
		[ -z "$bad" ] || {
			log "$app holds names that are not printable ASCII. The HFS+ tools of xpwn cannot write them: $(printf '%s' "$bad" | tr '\n' ' ')"
			return 1
		}
	fi
}

# _apple_tree_manifest PARENT APP: prints one line per entry of PARENT/APP:
#   path<TAB>kind<TAB>perm<TAB>size<TAB>value
# kind is d, f, or l. value is the SHA-256 of a file, the target of a link,
# or "-". perm and size are "-" and 0 for links. The lines are sorted.
_apple_tree_manifest() {
	local parent="$1" app="$2" list p f kind perm size value
	list="$(cd "$parent" && find "$app" -print)" || return 1
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		f="$parent/$p"
		if [ -L "$f" ]; then
			kind=l perm=- size=0
			value="$(readlink "$f")" || return 1
		elif [ -d "$f" ]; then
			kind=d size=0 value=-
			perm="$(_apple_perm "$f")" || return 1
		elif [ -f "$f" ]; then
			kind=f
			perm="$(_apple_perm "$f")" || return 1
			size="$(wc -c <"$f" | tr -d ' ')"
			value="$(sha256_of "$f")"
		else
			log "$p is not a file, a directory, or a symbolic link"
			return 1
		fi
		printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$kind" "$perm" "$size" "$value"
	done <<EOF
$list
EOF
}

# _apple_manifest PARENT APP OUT: writes the sorted manifest of PARENT/APP.
_apple_manifest() {
	_apple_tree_manifest "$1" "$2" >"$3.unsorted" || return 1
	LC_ALL=C sort "$3.unsorted" >"$3" || return 1
	rm -f "$3.unsorted"
}

# _apple_same_manifest A B WHAT: fails, and shows the difference, unless the
# manifests A and B are equal.
_apple_same_manifest() {
	local d
	d="$(diff "$1" "$2" 2>&1)" && return 0
	log "$3. Difference (< first, > second; path, kind, mode, size, SHA-256 or link target):"
	log "$d"
	return 1
}

# ---------------------------------------------------------------------------
# Archives and app trees
#
# An app archive from CI is untrusted input on a machine that holds signing
# keys. The rules for an app tree, checked on the member list of an archive
# before extraction and on the tree after extraction:
#   - exactly one top-level entry, a directory named *.app, listed as a member
#   - no absolute name, no empty, "." or ".." component, no AppleDouble "._"
#   - only directories, regular files, and symbolic links: no hard link, no
#     device, no FIFO, no socket
#   - no duplicate member, and no member below a symbolic link or a file
#   - a symbolic link has a relative target that stays inside the app, also
#     when the path passes through other links in the tree
#   - every directory of the tree is a member of its own
#   - names and link targets that the tar listing escapes are refused: those
#     with a backslash, a control character, or a byte that is not ASCII. The
#     listing cannot show them without ambiguity. Names that contain " -> " or
#     " link to " are refused for the same reason.
# ---------------------------------------------------------------------------

# _apple_check_members LABEL: reads member lines KIND<TAB>NAME<TAB>TARGET on
# stdin and prints the name of the app directory. KIND is d (directory), f
# (regular file), l (symbolic link), h (hard link), c (device), p (FIFO), s
# (socket), or ?X (other, X from the listing). TARGET is the target of a
# symbolic link. On a broken rule, it logs the reason and fails.
_apple_check_members() {
	local label="$1" out
	# MAXSYMLINKS of macOS, where the app runs, bounds the links on one path.
	out="$(awk -F '\t' -v maxlinks=32 '
		function fail(msg) { if (err == "") err = msg }
		function parent(p) { sub(/\/[^\/]*$/, "", p); return p }
		# escapes(L): why the target of link L leaves the app, or "".
		function escapes(link,   path, rest, comp, p, t, hops) {
			path = parent(link)
			rest = target[link]
			hops = 0
			while (rest != "") {
				p = index(rest, "/")
				if (p) { comp = substr(rest, 1, p - 1); rest = substr(rest, p + 1) }
				else { comp = rest; rest = "" }
				if (comp == "" || comp == ".") continue
				if (comp == "..") {
					if (index(path, "/") == 0) return "its target leaves the app"
					path = parent(path)
					continue
				}
				path = path "/" comp
				# An inner component that is a link: follow it, as the kernel does.
				if (rest != "" && (path in kind) && kind[path] == "l") {
					if (++hops > maxlinks) return "its target has too many levels of links"
					t = target[path]
					if (substr(t, 1, 1) == "/") return "its target passes through a link with an absolute target"
					path = parent(path)
					rest = t "/" rest
				}
			}
			return ""
		}
		{
			n++
			k = $1; name = $2; tgt = $3
			if (NF < 2 || name == "") { fail("an empty member name"); next }
			if (substr(name, length(name)) == "/") name = substr(name, 1, length(name) - 1)
			if (substr(name, 1, 1) == "/") fail("absolute name: " name)
			if (index(name, "\\") || index(tgt, "\\")) fail("a name or link target with a backslash, a control character, or a byte that is not ASCII: " name)
			if (index(name, " -> ") || index(name, " link to ")) fail("a name that the tar listing cannot show without ambiguity: " name)
			c = split(name, comps, "/")
			for (i = 1; i <= c; i++) {
				if (comps[i] == "") fail("empty component in " name)
				else if (comps[i] == "." || comps[i] == "..") fail("\"" comps[i] "\" component in " name)
				else if (substr(comps[i], 1, 2) == "._") fail("AppleDouble entry: " name)
			}
			if (app == "") app = comps[1]
			else if (comps[1] != app) fail("more than one top-level entry: " app " and " comps[1])
			if (name in kind) fail("duplicate member: " name)
			if (k == "h") fail("hard link: " name)
			else if (k == "c") fail("device: " name)
			else if (k == "p") fail("FIFO: " name)
			else if (k == "s") fail("socket: " name)
			else if (k != "d" && k != "f" && k != "l") fail("unsupported entry type " k ": " name)
			kind[name] = k
			target[name] = tgt
			order[n] = name
		}
		END {
			if (n == 0) fail("no member")
			if (err == "" && app !~ /.\.app$/) fail("the top-level entry is not named *.app: " app)
			if (err == "" && kind[app] != "d") fail("the top-level entry " app " is not a directory member")
			for (j = 1; j <= n && err == ""; j++) {
				name = order[j]
				for (p = parent(name); index(name, "/") && p != ""; p = parent(p)) {
					if ((p in kind) && kind[p] != "d") fail(name " is below " p ", which is not a directory")
					if (index(p, "/") == 0) break
				}
				if (kind[name] != "l") continue
				if (target[name] == "") fail("symbolic link without a target: " name)
				else if (substr(target[name], 1, 1) == "/") fail("symbolic link with an absolute target: " name " -> " target[name])
				else if ((why = escapes(name)) != "") fail("symbolic link " name " -> " target[name] ": " why)
			}
			if (err != "") { print err; exit 1 }
			print app
		}')" || {
		log "$label: $out"
		return 1
	}
	printf '%s\n' "$out"
}

# _apple_tar_members ARCHIVE: prints the member lines of ARCHIVE for
# _apple_check_members, from the plain and the verbose listing. Both GNU tar
# and bsdtar print the same type letters and "NAME -> TARGET" for links. A
# line that does not fit is an error.
_apple_tar_members() {
	local archive="$1" names verbose quiet=()
	# GNU tar: -P only quiets the "Removing leading" notes. A listing shows
	# the stored names either way. Extraction never uses -P.
	! tar --version 2>/dev/null | grep -q 'GNU tar' || quiet=(-P)
	names="$(LC_ALL=C tar ${quiet[@]+"${quiet[@]}"} -tf "$archive")" || {
		log "cannot list $archive"
		return 1
	}
	[ -n "$names" ] || {
		log "$archive has no member"
		return 1
	}
	verbose="$(LC_ALL=C tar ${quiet[@]+"${quiet[@]}"} -tvf "$archive")" || {
		log "cannot list $archive"
		return 1
	}
	awk -v archive="$archive" '
		function bad(msg) { print archive ": " msg > "/dev/stderr"; failed = 1; exit 1 }
		NR == FNR { name[FNR] = $0; n = FNR; next }
		{
			m++
			if (m > n) bad("the two listings differ in length")
			line = $0; nm = name[m]; c = substr(line, 1, 1); tgt = ""
			if (c == "l") {
				p = index(line, " " nm " -> ")
				if (p == 0) bad("cannot read the listing line: " line)
				tgt = substr(line, p + length(nm) + 5)
			} else if (c != "h" && substr(line, length(line) - length(nm)) != " " nm) {
				bad("cannot read the listing line: " line)
			}
			if (c == "-") k = "f"
			else if (c == "d" || c == "l" || c == "h" || c == "c" || c == "p" || c == "s") k = c
			else if (c == "b") k = "c"
			else k = "?" c
			print k "\t" nm "\t" tgt
		}
		END { if (!failed && m != n) bad("the two listings differ in length") }
	' <(printf '%s\n' "$names") <(printf '%s\n' "$verbose")
}

# _apple_tree_members PARENT APP: prints the member lines of the tree
# PARENT/APP for _apple_check_members. A regular file with more than one
# link is reported as a hard link.
_apple_tree_members() {
	local parent="$1" app="$2" list hard p f k t
	list="$(cd "$parent" && LC_ALL=C find "$app" -print)" || return 1
	hard="$(cd "$parent" && LC_ALL=C find "$app" -type f -links +1 -print)" || return 1
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		f="$parent/$p" t=""
		if [ -L "$f" ]; then
			k=l
			t="$(readlink "$f")" || return 1
		elif [ -d "$f" ]; then
			k=d
		elif [ -f "$f" ]; then
			k=f
			case "$_APPLE_NL$hard$_APPLE_NL" in
			*"$_APPLE_NL$p$_APPLE_NL"*) k=h ;;
			esac
		elif [ -p "$f" ]; then
			k=p
		elif [ -c "$f" ] || [ -b "$f" ]; then
			k=c
		elif [ -S "$f" ]; then
			k=s
		else
			k='?'
		fi
		printf '%s\t%s\t%s\n' "$k" "$p" "$t"
	done <<EOF
$list
EOF
}

# _apple_check_tree PARENT APP LABEL: fails unless the tree PARENT/APP keeps
# the rules above.
_apple_check_tree() {
	local members
	members="$(_apple_tree_members "$1" "$2")" || {
		log "$3: cannot list $1/$2"
		return 1
	}
	printf '%s\n' "$members" | _apple_check_members "$3" >/dev/null
}

# _apple_unpack_app ARCHIVE DIR: checks the member list of the untrusted
# ARCHIVE (tar, optionally gzip), extracts it into the new directory DIR,
# checks the extracted tree again and compares it with the member list, and
# prints the name of the app directory.
_apple_unpack_app() {
	local archive="$1" dir="$2" members app tree want got
	members="$(_apple_tar_members "$archive")" || return 1
	app="$(printf '%s\n' "$members" | _apple_check_members "$archive")" || return 1
	mkdir "$dir" || return 1
	tar -xpf "$archive" -C "$dir" || {
		log "cannot extract $archive"
		return 1
	}
	got="$(cd "$dir" && LC_ALL=C find . -mindepth 1 -maxdepth 1 -print)" || return 1
	[ "$got" = "./$app" ] || {
		log "$archive: the extraction made other top-level entries than $app: $(printf '%s' "$got" | tr '\n' ' ')"
		return 1
	}
	tree="$(_apple_tree_members "$dir" "$app")" || return 1
	printf '%s\n' "$tree" | _apple_check_members "$archive (extracted)" >/dev/null || return 1
	want="$(printf '%s\n' "$members" | awk -F '\t' -v OFS='\t' '{ sub(/\/$/, "", $2); print }' | LC_ALL=C sort)"
	got="$(printf '%s\n' "$tree" | LC_ALL=C sort)"
	[ "$want" = "$got" ] || {
		log "$archive: the extracted tree differs from the member list (< list, > tree):"
		log "$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") || true)"
		return 1
	}
	printf '%s\n' "$app"
}

# apple_tar_app PARENT APP OUT COMPRESSION: writes PARENT/APP as a tar file:
# APP at the top level, no "./" prefix, no AppleDouble or extended attribute
# entries, numeric owner and group 0, modes as on disk, entries in sorted
# order (a directory comes before its content). COMPRESSION is gz or none.
# The tree must keep the rules for an app tree, so that _apple_unpack_app
# accepts the result.
apple_tar_app() {
	local parent="$1" app="$2" out="$3" compression="$4" list names want got
	case "$compression" in
	gz | none) ;;
	*) die "apple_tar_app: compression must be gz or none" ;;
	esac
	[ -d "$parent/$app" ] && [ ! -L "$parent/$app" ] || die "not a directory: $parent/$app"
	[ ! -e "$out" ] && [ ! -L "$out" ] || die "$out exists already"
	_apple_check_names "$parent" "$app" || die "cannot pack $app"
	_apple_check_tree "$parent" "$app" "$parent/$app" || die "cannot pack $app: it breaks the rules for an app tree"
	case "$out" in
	/*) list="$out.list" ;;
	*) list="$PWD/$out.list" ;;
	esac
	(cd "$parent" && find "$app" -print) | LC_ALL=C sort >"$list" || die "cannot list $parent/$app"
	if tar --version 2>/dev/null | grep -q 'GNU tar'; then
		tar --format=gnu --numeric-owner --owner=0 --group=0 --no-recursion \
			-C "$parent" -T "$list" -cf - >"$out.tar" || die "tar cannot pack $app"
	else
		COPYFILE_DISABLE=1 tar --format=gnutar --numeric-owner --uid 0 --gid 0 \
			--no-mac-metadata --no-xattrs --no-acls --no-fflags --no-recursion \
			-C "$parent" -T "$list" -cf - >"$out.tar" || die "tar cannot pack $app"
	fi
	# The archive must list exactly the entries of the tree, in this order.
	want="$(cat "$list")"
	names="$(tar -tf "$out.tar")" || die "cannot list the new archive of $app"
	got="$(printf '%s\n' "$names" | sed 's#/$##')"
	[ "$got" = "$want" ] || die "the new archive of $app does not hold exactly the entries of the app"
	rm -f "$list"
	if [ "$compression" = gz ]; then
		gzip -n <"$out.tar" >"$out" || die "gzip failed for $out"
		rm -f "$out.tar"
	else
		mv "$out.tar" "$out"
	fi
}

# ---------------------------------------------------------------------------
# Code signing
# ---------------------------------------------------------------------------

_apple_timestamp_args() {
	[ -z "${APPLE_TIMESTAMP_URL:-}" ] || printf '%s\n' "--timestamp-url" "$APPLE_TIMESTAMP_URL"
}

# _apple_sign PATH [ARG...]: signs PATH in place with the certificate.
_apple_sign() {
	local path="$1" ts=() line
	shift
	while IFS= read -r line; do
		[ -n "$line" ] && ts+=("$line")
	done < <(_apple_timestamp_args)
	_apple_rcodesign sign -C /dev/null --p12-file <(_apple_p12) --p12-password-file <(_apple_p12_password) \
		${ts[@]+"${ts[@]}"} "$@" "$path"
}

# _apple_machos PARENT APP: prints the bundle-relative paths of the Mach-O
# files in PARENT/APP.
_apple_machos() {
	local parent="$1" app="$2" list p
	list="$(cd "$parent/$app" && find . -type f -print | LC_ALL=C sort)" || return 1
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		p="${p#./}"
		! _apple_is_macho "$parent/$app/$p" || printf '%s\n' "$p"
	done <<EOF
$list
EOF
}

# _apple_sign_app PARENT APP ENTITLEMENTS TEAM: signs the bundle with the
# hardened runtime on every Mach-O file and the entitlements on the main
# executable. Without a path scope, rcodesign sets the runtime flag on the
# main executable only, so every other Mach-O file gets a scoped flag.
# rcodesign writes the team ID into the signature by itself only for a
# certificate that Apple issued, so TEAM (from _apple_team_id) is given.
_apple_sign_app() {
	local parent="$1" app="$2" entitlements="$3" team="$4" machos m args=() info flags
	machos="$(_apple_machos "$parent" "$app")" || return 1
	[ -n "$machos" ] || {
		log "$app holds no Mach-O file"
		return 1
	}
	while IFS= read -r m; do
		case "$m" in
		*:*)
			log "$app/$m: rcodesign cannot scope a setting to a path with a colon"
			return 1
			;;
		esac
		args+=(--code-signature-flags "$m:runtime")
	done <<EOF
$machos
EOF
	_apple_sign "$parent/$app" --team-name "$team" --code-signature-flags runtime "${args[@]}" \
		--entitlements-xml-file "$entitlements" || return 1
	# Check the result: every Mach-O (every slice of a fat file) has a
	# signature with the runtime flag.
	while IFS= read -r m; do
		info="$(_apple_rcodesign print-signature-info -C /dev/null "$parent/$app/$m" 2>&1)" || {
			log "rcodesign cannot read the signature of $app/$m: $info"
			return 1
		}
		flags="$(printf '%s\n' "$info" | grep -E '^ *flags: CodeSignatureFlags\(' || true)"
		[ -n "$flags" ] || {
			log "$app/$m has no code directory after signing"
			return 1
		}
		if printf '%s\n' "$flags" | grep -v -q 'RUNTIME'; then
			log "$app/$m has no hardened runtime flag after signing: $(printf '%s' "$flags" | tr '\n' ' ')"
			return 1
		fi
	done <<EOF
$machos
EOF
}

# ---------------------------------------------------------------------------
# Sandbox for xpwn on Linux
#
# dmg and hfsplus from xpwn are old C code, and they parse the DMG from CI,
# which a compromised build can craft. Every call that touches that image
# runs in a bubblewrap sandbox: no network, a read-only root, an empty tmpfs
# over the home directories, /tmp, /var/tmp, /run/user, HOME, GNUPGHOME, the
# directories of gpg-agent, TMPDIR, XDG_RUNTIME_DIR, XDG_CONFIG_HOME, and the
# directory of RELEASE_SECRETS_FILE, an own /dev and /proc (no access to
# the environment of other processes), an empty environment, and write
# access to WORK/jail only. WORK/signed (the signed app) is read-only. The
# signing secrets are only in shell variables of the caller, never on disk.
# When the sandboxed process exits, every process in it ends (own PID
# namespace).
# ---------------------------------------------------------------------------

# _apple_jail WORK COMMAND [ARG...]: runs COMMAND in the sandbox.
_apple_jail() {
	local work="$1" bin bwrap p real hide=() args=() ro=()
	shift
	bin="$(type -P "$1")" || {
		log "$1: command not found"
		return 1
	}
	shift
	bwrap="$(type -P bwrap)" || {
		log "bwrap: command not found"
		return 1
	}
	[ -d "$work/jail" ] && [ ! -L "$work/jail" ] || {
		log "internal error: no directory $work/jail"
		return 1
	}
	hide=(/home /root /tmp /var/tmp /run/user "${HOME:-}" "${GNUPGHOME:-}" "${TMPDIR:-}" "${XDG_RUNTIME_DIR:-}"
		"${XDG_CONFIG_HOME:-}")
	# The directory of the encrypted secrets file (see secrets_file_path).
	case "${RELEASE_SECRETS_FILE:-}" in
	*/*) hide+=("${RELEASE_SECRETS_FILE%/*}") ;;
	esac
	if type -P gpgconf >/dev/null 2>&1; then
		hide+=("$(gpgconf --list-dirs homedir 2>/dev/null || true)" "$(gpgconf --list-dirs socketdir 2>/dev/null || true)")
	fi
	args=(--unshare-all --die-with-parent --new-session --ro-bind / / --dev /dev --proc /proc)
	for p in "${hide[@]}"; do
		[ -n "$p" ] && [ -d "$p" ] || continue
		# A directory that this user cannot enter (/root) is hidden as it is.
		real="$(cd -P "$p" 2>/dev/null && pwd -P)" || real="$p"
		[ "$real" != / ] || continue
		args+=(--tmpfs "$real")
		ro+=(--remount-ro "$real")
	done
	args+=(--bind "$work/jail" "$work/jail")
	[ ! -d "$work/signed" ] || args+=(--ro-bind "$work/signed" "$work/signed")
	# The empty tmpfs mounts become read-only too, after bwrap has made the
	# mount points of the binds in them.
	args+=(${ro[@]+"${ro[@]}"} --chdir "$work/jail")
	env -i PATH=/usr/bin:/bin LC_ALL=C "$bwrap" "${args[@]}" -- "$bin" "$@"
}

# _apple_jail_check WORK: fails unless the sandbox works on this host.
_apple_jail_check() {
	local out
	out="$(_apple_jail "$1" true 2>&1)" || {
		log "bwrap cannot create the sandbox for xpwn: $out"
		log "bwrap needs unprivileged user namespaces (kernel.unprivileged_userns_clone=1; on Ubuntu 24.04 and later an AppArmor profile that allows them for bwrap), or a setuid bwrap."
		return 1
	}
}

# _apple_jail_plain DIR: fails unless DIR, written in the sandbox, holds only
# directories and regular files with one link each. The shell reads these
# files later, and must not follow a link or block on a FIFO.
_apple_jail_plain() {
	local bad
	bad="$(find "$1" \( \( ! -type f ! -type d \) -o \( -type f -links +1 \) \) -print 2>&1)" || {
		log "cannot list $1: $bad"
		return 1
	}
	[ -z "$bad" ] || {
		log "the sandbox left entries that are not plain files or directories: $(printf '%s' "$bad" | tr '\n' ' ')"
		return 1
	}
}

# ---------------------------------------------------------------------------
# DMG rebuild on Linux, with dmg and hfsplus from xpwn, in the sandbox
#
# hfsplus returns 0 after many errors, so every result is checked by a
# comparison of the image with the signed tree at the end.
# ---------------------------------------------------------------------------

# _apple_be IMAGE OFFSET COUNT: prints the big-endian number at OFFSET.
_apple_be() {
	od -A n -t u1 -j "$2" -N "$3" "$1" | awk '{ for (i = 1; i <= NF; i++) { n = n * 256 + $i } } END { printf "%.0f\n", n }'
}

# The HFS+ volume header is at byte 1024. Offsets of its fields:
_APPLE_HFS_SIG=1024          # "H+"
_APPLE_HFS_BLOCK_SIZE=1064   # u32
_APPLE_HFS_TOTAL_BLOCKS=1068 # u32
_APPLE_HFS_FREE_BLOCKS=1072  # u32
_APPLE_HFS_ALLOC_SIZE=1136   # u64: logical size of the allocation file
_APPLE_HFS_EXT_CLUMP=1224    # u32: clump size of the extents overflow file
_APPLE_HFS_CAT_CLUMP=1304    # u32: clump size of the catalog file
_APPLE_HFS_ATTR_CLUMP=1384   # u32: clump size of the attributes file

# _apple_hfs IMAGE ARG...: runs hfsplus in the sandbox, and shows its output
# on failure. IMAGE is WORK/jail/volume.img.
_apple_hfs() {
	local img="$1" jail out
	jail="${img%/*}"
	[ "${jail##*/}" = jail ] || {
		log "internal error: the image $img is not in a jail directory"
		return 1
	}
	# The root directory holds names with NUL characters (the HFS+ private
	# directories), which a shell variable cannot hold.
	out="$(_apple_jail "${jail%/*}" hfsplus "$@" 2>&1 | tr -d '\000')" || {
		log "hfsplus ${*:2} failed: $out"
		return 1
	}
	[ -f "$img" ] && [ ! -L "$img" ] || {
		log "after hfsplus ${*:2}, $img is not a regular file"
		return 1
	}
	if printf '%s\n' "$out" | grep -E -q '^(No such file or directory|Not a file|Not a folder|Not enough|Cannot |error|WARNING)'; then
		log "hfsplus ${*:2}: $out"
		return 1
	fi
	printf '%s\n' "$out"
}

# _apple_hfs_manifest IMAGE APP XDIR: prints the manifest of /APP in the HFS+
# IMAGE, in the format of _apple_tree_manifest. Modes come from the catalog,
# the content from a copy that hfsplus extracts into the new directory XDIR,
# next to IMAGE in the jail directory. Names from the image are untrusted:
# ".", "..", and names with "/" are refused, so a path never leaves XDIR.
_apple_hfs_manifest() {
	local img="$1" app="$2" xdir="$3" re out queue dir line mode name kind perm path rel size value found=""
	re='^([0-7]{6}) +[0-9]+ +[0-9]+ +[0-9]+ (.{17})(.*)$'
	mkdir "$xdir" || return 1
	_apple_hfs "$img" extractall "/$app" "$xdir" >/dev/null || return 1
	_apple_jail_plain "$xdir" || return 1
	out="$(_apple_hfs "$img" ls /)" || return 1
	while IFS= read -r line; do
		if [[ "$line" =~ $re ]] && [ "${BASH_REMATCH[3]}" = "$app" ]; then
			mode="${BASH_REMATCH[1]}"
			[ "$((8#$mode >> 12))" = 4 ] || {
				log "/$app in the DMG is not a directory"
				return 1
			}
			printf '%s\td\t%04o\t0\t-\n' "$app" "$((8#$mode & 07777))"
			found=1
		fi
	done <<EOF
$out
EOF
	[ -n "$found" ] || {
		log "the DMG has no /$app"
		return 1
	}
	queue="$app"
	while [ -n "$queue" ]; do
		dir="${queue%%"$_APPLE_NL"*}"
		case "$queue" in
		*"$_APPLE_NL"*) queue="${queue#*"$_APPLE_NL"}" ;;
		*) queue="" ;;
		esac
		out="$(_apple_hfs "$img" ls "/$dir")" || return 1
		# The first line names the directory. The last line gives the sizes.
		out="$(printf '%s\n' "$out" | sed '1d' | grep -v '^Total filesystem size: ' || true)"
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			[[ "$line" =~ $re ]] || {
				log "cannot read this line of 'hfsplus ls /$dir': $line"
				return 1
			}
			mode="${BASH_REMATCH[1]}"
			name="${BASH_REMATCH[3]}"
			case "$name" in
			"" | . | .. | */*)
				log "/$dir in the DMG holds an entry with an unsafe name: '$name'"
				return 1
				;;
			esac
			path="$dir/$name"
			rel="${path#"$app"/}"
			perm="$(printf '%04o' "$((8#$mode & 07777))")"
			case "$((8#$mode >> 12))" in
			4)
				kind=d size=0 value=-
				queue="$queue${queue:+$_APPLE_NL}$path"
				;;
			8)
				kind=f
				size="$(wc -c <"$xdir/$rel" | tr -d ' ')" || return 1
				value="$(sha256_of "$xdir/$rel")"
				;;
			10)
				# extractall writes the target of a link as a file.
				kind=l perm=- size=0
				value="$(cat "$xdir/$rel")" || return 1
				;;
			*)
				log "/$path in the DMG has an unsupported file type (mode $mode)"
				return 1
				;;
			esac
			printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$kind" "$perm" "$size" "$value"
		done <<EOF
$out
EOF
	done
}

# _apple_hfs_space IMAGE NEED_BYTES: grows the volume in IMAGE if it has fewer
# than NEED_BYTES free, and checks the result.
_apple_hfs_space() {
	local img="$1" need="$2" bs total free need_blocks missing new_total map_bytes alloc_bytes extra prev out
	bs="$(_apple_be "$img" "$_APPLE_HFS_BLOCK_SIZE" 4)"
	total="$(_apple_be "$img" "$_APPLE_HFS_TOTAL_BLOCKS" 4)"
	free="$(_apple_be "$img" "$_APPLE_HFS_FREE_BLOCKS" 4)"
	need_blocks=$(((need + bs - 1) / bs))
	_apple_note "DMG volume: $((free * bs)) bytes free, $((need_blocks * bs)) bytes needed"
	[ "$free" -lt "$need_blocks" ] || return 0
	# Growing can enlarge the allocation bitmap, and the bitmap takes blocks
	# from the free space. Repeat until the numbers are stable.
	alloc_bytes="$(_apple_be "$img" "$_APPLE_HFS_ALLOC_SIZE" 8)"
	extra=0 prev=-1
	while [ "$extra" != "$prev" ]; do
		prev="$extra"
		missing=$((need_blocks - free + extra))
		new_total=$((total + missing))
		map_bytes=$(((new_total + 7) / 8))
		extra=0
		[ "$map_bytes" -le "$alloc_bytes" ] || extra=$(((map_bytes - alloc_bytes + bs - 1) / bs))
	done
	_apple_note "growing the DMG volume from $((total * bs)) to $((new_total * bs)) bytes"
	out="$(_apple_hfs "$img" grow "$((new_total * bs))")" || return 1
	total="$(_apple_be "$img" "$_APPLE_HFS_TOTAL_BLOCKS" 4)"
	free="$(_apple_be "$img" "$_APPLE_HFS_FREE_BLOCKS" 4)"
	[ "$total" = "$new_total" ] && [ "$free" -ge "$need_blocks" ] || {
		log "the DMG volume did not grow as expected (hfsplus said: $out): $total blocks, $free free, $need_blocks needed"
		return 1
	}
}

# _apple_dmg_linux DMG_IN WORK APP OUT_DMG: rebuilds DMG_IN with the signed
# app. WORK (a path without symbolic links) holds the trees unsigned/APP and
# signed/APP. The image gets the difference between the two trees, so the
# rest of the DMG stays as it is. Every dmg and hfsplus call runs in the
# sandbox, which can write to WORK/jail only.
_apple_dmg_linux() {
	local dmg_in="$1" work="$2" app="$3" out_dmg="$4" jail="$2/jail" img="$2/jail/volume.img" sig actions bs clumps line op a b c
	_apple_check_names "$work/signed" "$app" ascii || return 1
	_apple_check_names "$work/unsigned" "$app" ascii || return 1
	mkdir "$jail" || return 1
	cp "$dmg_in" "$jail/in.dmg" || return 1
	_apple_jail "$work" dmg extract "$jail/in.dmg" "$img" >"$work/dmg-extract.log" 2>&1 || {
		log "dmg extract failed for $dmg_in: $(tail -n 5 "$work/dmg-extract.log")"
		return 1
	}
	rm -f "$jail/in.dmg"
	_apple_jail_plain "$jail" || return 1
	[ -f "$img" ] || {
		log "dmg extract wrote no image for $dmg_in"
		return 1
	}
	sig="$(od -A n -t x1 -j "$_APPLE_HFS_SIG" -N 2 "$img" 2>/dev/null | tr -d ' \n')"
	[ "$sig" = 482b ] || {
		log "$dmg_in does not hold an HFS+ volume (signature '$sig', expected 482b). The Linux path needs HFS+."
		return 1
	}

	# The app in the DMG must be the unsigned app of the archive.
	_apple_manifest "$work/unsigned" "$app" "$work/unsigned.manifest" || return 1
	_apple_manifest "$work/signed" "$app" "$work/signed.manifest" || return 1
	_apple_hfs_manifest "$img" "$app" "$jail/dmg-before" >"$work/dmg-before.unsorted" || return 1
	LC_ALL=C sort "$work/dmg-before.unsorted" >"$work/dmg-before.manifest"
	_apple_same_manifest "$work/unsigned.manifest" "$work/dmg-before.manifest" \
		"the app in $dmg_in differs from the app in the unsigned app archive (first: archive, second: DMG)" || return 1
	rm -rf "$jail/dmg-before"

	# Actions, one per line: rm KIND PATH, mkdir PATH, add PATH, link PATH
	# TARGET, chmod PERM PATH. The last line is: space BLOCKS. A changed file
	# is written in place: hfsplus extends its extents, and the old content
	# leaves no stale blocks in the image.
	bs="$(_apple_be "$img" "$_APPLE_HFS_BLOCK_SIZE" 4)"
	actions="$(awk -F '\t' -v bs="$bs" '
		function blocks(n) { return int((n + bs - 1) / bs) }
		NR == FNR { ukind[$1] = $2; uperm[$1] = $3; usize[$1] = $4; uvalue[$1] = $5; next }
		{
			seen[$1] = 1
			if ($1 in ukind && ukind[$1] != $2) {
				print "rm\t" ukind[$1] "\t" $1
				delete ukind[$1]
			}
			if (!($1 in ukind)) {
				if ($2 == "d") print "mkdir\t" $1
				else if ($2 == "f") { print "add\t" $1; need += blocks($4) }
				else { print "link\t" $1 "\t" $5; need += 1 }
				if ($2 != "l") print "chmod\t" $3 "\t" $1
				next
			}
			if ($2 == "f" && uvalue[$1] != $5) {
				print "add\t" $1
				if (blocks($4) > blocks(usize[$1])) need += blocks($4) - blocks(usize[$1])
			}
			if ($2 == "l" && uvalue[$1] != $5) { print "rm\tl\t" $1; print "link\t" $1 "\t" $5 }
			if ($2 != "l" && uperm[$1] != $3) print "chmod\t" $3 "\t" $1
		}
		END {
			for (p in ukind) if (!(p in seen)) print "rm\t" ukind[p] "\t" p
			print "space\t" need + 0
		}' "$work/unsigned.manifest" "$work/signed.manifest")" || return 1

	# Free space: the new data, plus one clump for each B-tree file that a new
	# catalog entry can make grow.
	clumps=$(($(_apple_be "$img" "$_APPLE_HFS_CAT_CLUMP" 4) + $(_apple_be "$img" "$_APPLE_HFS_EXT_CLUMP" 4) + $(_apple_be "$img" "$_APPLE_HFS_ATTR_CLUMP" 4)))
	line="$(printf '%s\n' "$actions" | awk -F '\t' '$1 == "space" { print $2 }')"
	_apple_hfs_space "$img" "$((line * bs + clumps))" || return 1

	# Order: removals (children before parents), new directories (parents
	# first), files and links, then modes.
	{
		printf '%s\n' "$actions" | awk -F '\t' '$1 == "rm"' | LC_ALL=C sort -t "$_APPLE_TAB" -k3,3r
		printf '%s\n' "$actions" | awk -F '\t' '$1 == "mkdir"' | LC_ALL=C sort -t "$_APPLE_TAB" -k2,2
		printf '%s\n' "$actions" | awk -F '\t' '$1 == "add" || $1 == "link"'
		printf '%s\n' "$actions" | awk -F '\t' '$1 == "chmod"'
	} >"$work/actions"
	_apple_note "DMG changes: $(awk -F '\t' '{ n[$1]++ } END { for (k in n) printf "%s=%d ", k, n[k] }' "$work/actions")"
	while IFS="$_APPLE_TAB" read -r op a b c; do
		case "$op" in
		rm) _apple_hfs "$img" rm "/$b" >/dev/null || return 1 ;;
		mkdir) _apple_hfs "$img" mkdir "/$a" >/dev/null || return 1 ;;
		add) _apple_hfs "$img" add "$work/signed/$a" "/$a" >/dev/null || return 1 ;;
		link) _apple_hfs "$img" symlink "/$a" "$b" >/dev/null || return 1 ;;
		chmod) _apple_hfs "$img" chmod "$a" "/$b" >/dev/null || return 1 ;;
		*)
			log "internal error: unknown action $op"
			return 1
			;;
		esac
	done <"$work/actions"

	# The app in the image must now be the signed app.
	_apple_hfs_manifest "$img" "$app" "$jail/dmg-after" >"$work/dmg-after.unsorted" || return 1
	LC_ALL=C sort "$work/dmg-after.unsorted" >"$work/dmg-after.manifest"
	_apple_same_manifest "$work/signed.manifest" "$work/dmg-after.manifest" \
		"after the rebuild, the app in the DMG differs from the signed app (first: signed, second: DMG)" || return 1
	rm -rf "$jail/dmg-after"

	_apple_jail "$work" dmg build "$img" "$jail/out.dmg" >"$work/dmg-build.log" 2>&1 || {
		log "dmg build failed: $(tail -n 5 "$work/dmg-build.log")"
		return 1
	}
	rm -f "$img"
	_apple_jail_plain "$jail" || return 1
	[ -f "$jail/out.dmg" ] || {
		log "dmg build wrote no image"
		return 1
	}
	mv "$jail/out.dmg" "$out_dmg"
}

# ---------------------------------------------------------------------------
# DMG rebuild on macOS, with hdiutil. Tested on GitHub macOS 15 runners.
#
# No sandbox here: hdiutil and the kernel handle the image natively. Mounting
# the DMG from CI carries the same exposure as opening any downloaded DMG on
# this Mac.
# ---------------------------------------------------------------------------

_APPLE_ATTACHED=""

_apple_detach() {
	[ -n "$_APPLE_ATTACHED" ] || return 0
	hdiutil detach "$_APPLE_ATTACHED" -quiet || hdiutil detach "$_APPLE_ATTACHED" -force -quiet || {
		log "cannot detach $_APPLE_ATTACHED"
		return 1
	}
	_APPLE_ATTACHED=""
}

# _apple_dmg_macos DMG_IN WORK APP OUT_DMG: replaces APP in a read-write copy
# of DMG_IN with WORK/signed/APP, and converts the result to UDZO.
_apple_dmg_macos() {
	local dmg_in="$1" work="$2" app="$3" out_dmg="$4" rw="$2/rw.dmg" mnt="$2/mnt" sectors app_kb
	hdiutil convert "$dmg_in" -quiet -format UDRW -o "$rw" || return 1
	sectors="$(hdiutil resize -limits "$rw" | awk 'NF >= 3 { print $2; exit }')"
	[[ "$sectors" =~ ^[0-9]+$ ]] || {
		log "cannot read the size of $rw"
		return 1
	}
	# Room for a full second copy of the app: the old copy is deleted first,
	# so this is more than enough.
	app_kb="$(du -sk "$work/signed/$app" | awk '{ print $1 }')"
	hdiutil resize -quiet -sectors "$((sectors + app_kb * 2))" "$rw" || return 1
	mkdir "$mnt" || return 1
	hdiutil attach "$rw" -readwrite -nobrowse -noautoopen -noverify -mountpoint "$mnt" -quiet || return 1
	_APPLE_ATTACHED="$mnt"
	[ -d "$mnt/$app" ] && [ ! -L "$mnt/$app" ] || {
		log "the DMG has no /$app"
		return 1
	}
	rm -rf "${mnt:?}/$app" || return 1
	ditto --norsrc --noextattr --noqtn --noacl "$work/signed/$app" "$mnt/$app" || return 1
	_apple_detach || return 1
	hdiutil convert "$rw" -quiet -format UDZO -imagekey zlib-level=9 -o "$out_dmg" || return 1
	rm -f "$rw"
}

# ---------------------------------------------------------------------------
# One architecture
# ---------------------------------------------------------------------------

# apple_process_arch UNSIGNED_APP_TAR UNSIGNED_DMG ENTITLEMENTS NOTARIZE OUT_DIR
# The body runs in a subshell: its own traps, and die ends only this call.
apple_process_arch() (
	set -euo pipefail
	[ $# -eq 5 ] || die "usage: apple_process_arch <unsigned_app_tar> <unsigned_dmg> <entitlements_plist> <true|false> <out_dir>"
	app_tar="$1" dmg_in="$2" entitlements="$3" notarize="$4" out_dir="$5"
	_apple_check_notarize_arg "$notarize"
	app_file="${app_tar##*/}" dmg_file="${dmg_in##*/}"
	case "$app_file" in
	?*"$APPLE_UNSIGNED_APP_SUFFIX") ;;
	*) die "$app_file does not end with $APPLE_UNSIGNED_APP_SUFFIX" ;;
	esac
	case "$dmg_file" in
	?*"$APPLE_UNSIGNED_DMG_SUFFIX") ;;
	*) die "$dmg_file does not end with $APPLE_UNSIGNED_DMG_SUFFIX" ;;
	esac
	app_out="$out_dir/${app_file%"$APPLE_UNSIGNED_APP_SUFFIX"}$APPLE_APP_SUFFIX"
	dmg_out="$out_dir/${dmg_file%"$APPLE_UNSIGNED_DMG_SUFFIX"}$APPLE_DMG_SUFFIX"
	[ -f "$app_tar" ] || die "not a file: $app_tar"
	[ -f "$dmg_in" ] || die "not a file: $dmg_in"
	[ -f "$entitlements" ] || die "entitlements file not found: $entitlements"
	[ -d "$out_dir" ] || die "not a directory: $out_dir"
	for f in "$app_out" "$dmg_out"; do
		[ ! -e "$f" ] && [ ! -L "$f" ] || die "$f exists already"
	done
	host="$(_apple_host)" || exit 1
	_APPLE_TAG="[${app_file%"$APPLE_UNSIGNED_APP_SUFFIX"}]"
	tag="$_APPLE_TAG"
	started=$SECONDS

	work="$(mktemp -d "${TMPDIR:-/tmp}/apple-sign.XXXXXX")" || die "cannot create a temp directory"
	trap '_apple_detach || true; rm -rf "$work"' EXIT
	# The sandbox binds paths as they are, so WORK must have no link in it.
	work="$(cd -P "$work" && pwd -P)" || die "cannot resolve the temp directory"

	_apple_note "checking and extracting ${app_tar##*/}"
	app="$(_apple_unpack_app "$app_tar" "$work/unsigned")" || die "$tag the unsigned app archive is not usable"
	app2="$(_apple_unpack_app "$app_tar" "$work/signed")" || die "$tag the unsigned app archive is not usable"
	[ "$app" = "$app2" ] || die "$tag ${app_tar##*/} changed while it was read"

	team="$(_apple_team_id)" || die "$tag cannot read the team ID of the certificate"
	_apple_note "signing $app (team $team)"
	_apple_sign_app "$work/signed" "$app" "$entitlements" "$team" || die "$tag cannot sign $app"

	if [ "$notarize" = true ]; then
		_apple_note "notarizing $app (submit, wait, staple)"
		_apple_rcodesign notary-submit -C /dev/null --api-key-file <(_apple_api_key) --wait --staple "$work/signed/$app" ||
			die "$tag notarization of $app failed"
	fi

	_apple_note "packing the updater archive"
	apple_tar_app "$work/signed" "$app" "$work/app.tar.gz" gz

	_apple_note "rebuilding the DMG on $host"
	if [ "$host" = macos ]; then
		_apple_dmg_macos "$dmg_in" "$work" "$app" "$work/out.dmg" || die "$tag cannot rebuild the DMG"
	else
		_apple_dmg_linux "$dmg_in" "$work" "$app" "$work/out.dmg" || die "$tag cannot rebuild the DMG"
	fi
	# Decision: the DMG is signed, but not notarized, as in production today.
	# The app inside it is notarized and stapled (with notarize=true), so
	# Gatekeeper checks the app when it first runs. No DMG notarization here.
	# rcodesign takes the identifier of a DMG from the name of the file that
	# it signs (here "out"), so it is given: the final name without ".dmg".
	_apple_note "signing the DMG"
	_apple_sign "$work/out.dmg" --binary-identifier "${dmg_file%"$APPLE_UNSIGNED_DMG_SUFFIX"}" ||
		die "$tag cannot sign the DMG"

	mv "$work/app.tar.gz" "$app_out" || die "cannot write $app_out"
	mv "$work/out.dmg" "$dmg_out" || die "cannot write $dmg_out"
	_apple_note "done in $((SECONDS - started)) s: ${app_out##*/}, ${dmg_out##*/}"
)

# ---------------------------------------------------------------------------
# All architectures
# ---------------------------------------------------------------------------

# _apple_arch_key BASE: the part after the last "_", for example aarch64 in
# app_1.0.0_aarch64. It pairs an app archive with its DMG.
_apple_arch_key() {
	printf '%s\n' "${1##*_}"
}

# apple_process_all IN_DIR ENTITLEMENTS NOTARIZE OUT_DIR: finds the pairs
# <base>.app.unsigned.tar and <base2>.unsigned.dmg in IN_DIR, paired by the
# part of the base after the last "_" (the architecture), and runs
# apple_process_arch for each pair in parallel. Each pair has its own log,
# which is printed on failure.
apple_process_all() {
	local in_dir="$1" entitlements="$2" notarize="$3" out_dir="$4"
	local f name key apps="" dmgs="" pairs="" dmg logs jobs="" pid failed="" started=$SECONDS count
	[ $# -eq 4 ] || die "usage: apple_process_all <in_dir> <entitlements_plist> <true|false> <out_dir>"
	_apple_check_notarize_arg "$notarize"
	[ -d "$in_dir" ] || die "not a directory: $in_dir"
	[ -d "$out_dir" ] || die "not a directory: $out_dir"
	for f in "$in_dir"/*"$APPLE_UNSIGNED_APP_SUFFIX"; do
		[ -f "$f" ] || continue
		name="${f##*/}"
		apps="$apps$(_apple_arch_key "${name%"$APPLE_UNSIGNED_APP_SUFFIX"}") $name$_APPLE_NL"
	done
	for f in "$in_dir"/*"$APPLE_UNSIGNED_DMG_SUFFIX"; do
		[ -f "$f" ] || continue
		name="${f##*/}"
		dmgs="$dmgs$(_apple_arch_key "${name%"$APPLE_UNSIGNED_DMG_SUFFIX"}") $name$_APPLE_NL"
	done
	[ -n "$apps" ] || die "no *$APPLE_UNSIGNED_APP_SUFFIX file in $in_dir"
	f="$(printf '%s' "$apps" | cut -d' ' -f1 | LC_ALL=C sort | uniq -d)"
	[ -z "$f" ] || die "more than one unsigned app archive for: $f"
	f="$(printf '%s' "$dmgs" | cut -d' ' -f1 | LC_ALL=C sort | uniq -d)"
	[ -z "$f" ] || die "more than one unsigned DMG for: $f"
	while IFS=' ' read -r key name; do
		[ -n "$key" ] || continue
		dmg="$(printf '%s' "$dmgs" | awk -v k="$key" '$1 == k { print $2 }')"
		[ -n "$dmg" ] || die "no unsigned DMG for $name (architecture $key)"
		pairs="$pairs$key $name $dmg$_APPLE_NL"
	done <<EOF
$apps
EOF
	while IFS=' ' read -r key name; do
		[ -n "$key" ] || continue
		printf '%s' "$apps" | awk -v k="$key" '$1 == k { found = 1 } END { exit !found }' ||
			die "no unsigned app archive for $name (architecture $key)"
	done <<EOF
$dmgs
EOF
	count="$(printf '%s' "$pairs" | grep -c .)"
	logs="$(mktemp -d "${TMPDIR:-/tmp}/apple-logs.XXXXXX")" || die "cannot create a temp directory"
	log "    Apple signing: $count architectures in parallel"
	while IFS=' ' read -r key name dmg; do
		[ -n "$key" ] || continue
		apple_process_arch "$in_dir/$name" "$in_dir/$dmg" "$entitlements" "$notarize" "$out_dir" \
			</dev/null >"$logs/$key.log" 2>&1 &
		jobs="$jobs$! $key $name$_APPLE_NL"
	done <<EOF
$pairs
EOF
	while IFS=' ' read -r pid key name; do
		[ -n "$pid" ] || continue
		if wait "$pid"; then
			# The progress lines only; the full log has the output of rcodesign.
			awk -v p="[${name%"$APPLE_UNSIGNED_APP_SUFFIX"}] " 'index($0, p) == 1' "$logs/$key.log" >&2
		else
			failed="$failed $key"
			log ""
			log "---- log of $key ----"
			cat "$logs/$key.log" >&2
			log "---- end of the log of $key ----"
		fi
	done <<EOF
$jobs
EOF
	rm -rf "$logs"
	[ -z "$failed" ] || die "Apple signing failed for:$failed"
	log "    Apple signing done in $((SECONDS - started)) s"
}
