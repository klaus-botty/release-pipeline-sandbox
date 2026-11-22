#!/usr/bin/env python3
"""Helper of flatpak-finalize.sh. Run it with python3 -I.

Subcommands:
  extract repo TAR DEST        unpack the repository archive into the new
                               directory DEST (regular files and directories)
  extract signatures TAR DEST  unpack the signature archive into the new
                               directory DEST (only summary.sig,
                               summary.idx.sig, objects/xx/<62 hex>.commit.sig,
                               and refs.txt)
  attach REPO SIGDIR           attach the verified signatures to REPO
  summary-refs REPO            print "<ref> <commit>" for every ref in the
                               summary file, sorted
  index-refs REPO              print "<ref> <commit>" for every ref in the
                               current subsummaries that summary.idx names
                               (what flatpak clients read), sorted; checks the
                               SHA-256 of each subsummary against summary.idx
  check-commits REPO REFS APP_ID ARCH BRANCH
                               check the metadata of the commit of every ref
                               in the refs.txt file REFS (see check_commits)
  serve DIR PORT_FILE LOG      serve DIR on 127.0.0.1 on a free port, write
                               the port number into PORT_FILE, and append one
                               line "METHOD PATH STATUS" per request to LOG

Both extract modes refuse absolute names, "." and "..", empty name parts,
characters outside A-Z a-z 0-9 . _ + -, links, devices, and duplicates.

attach adds files only. It never changes a file that exists:
  - every commit gets its signature as detached metadata (.commitmeta),
    through libostree, so the format equals what "ostree gpg-sign" writes
  - summary.sig, summary.idx.sig, and summaries/<sha256 of summary.idx>.idx.sig
    get the variant a{sv} {"ostree.gpgsigs": aay [signature]}
"""

import hashlib
import os
import re
import sys
import tarfile

PART_RE = re.compile(r"^[A-Za-z0-9._+-]+$")
SIG_RE = re.compile(r"^((summary|summary\.idx|objects/[0-9a-f]{2}/[0-9a-f]{62}\.commit)\.sig|refs\.txt)$")
SUMMARY_TYPE = "(a(s(taya{sv}))a{sv})"
INDEX_TYPE = "(a{s(ayaaya{sv})}a{sv})"


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def check_name(tar_path, name):
    parts = name.split("/")
    if name.startswith("/") or any(p in ("", ".", "..") or not PART_RE.match(p) for p in parts):
        fail(f"{tar_path}: member name is not allowed: {name!r}")
    return parts


def extract(kind, tar_path, dest):
    if kind not in ("repo", "signatures"):
        fail(f"unknown archive kind: {kind}")
    os.mkdir(dest, 0o755)
    seen = set()
    dirs = {""}
    count = 0
    with tarfile.open(tar_path, mode="r:") as tar:
        for member in tar:
            # tarfile keeps a trailing slash of a directory name out of .name.
            name = member.name
            parts = check_name(tar_path, name)
            if name in seen:
                fail(f"{tar_path}: member occurs more than once: {name}")
            seen.add(name)
            if kind == "signatures" and not SIG_RE.match(name):
                fail(f"{tar_path}: member is not allowed: {name!r} "
                     "(allowed: summary.sig, summary.idx.sig, objects/<2 hex>/<62 hex>.commit.sig, refs.txt)")
            if member.isdir() and kind == "repo":
                kind_ok = True
            elif member.isfile():
                kind_ok = True
            else:
                kind_ok = False
            if not kind_ok:
                fail(f"{tar_path}: {name} is not a regular file"
                     f"{' or directory' if kind == 'repo' else ''} (links and devices are refused)")
            # Create the parent directories. A parent that is a file fails.
            parent = ""
            for part in parts[:-1]:
                parent = f"{parent}/{part}" if parent else part
                if parent not in dirs:
                    if os.path.lexists(os.path.join(dest, parent)):
                        fail(f"{tar_path}: {name} is below the file {parent}")
                    os.mkdir(os.path.join(dest, parent), 0o755)
                    dirs.add(parent)
            path = os.path.join(dest, name)
            if member.isdir():
                if name not in dirs:
                    if os.path.lexists(path):
                        fail(f"{tar_path}: directory {name} has the name of a file")
                    os.mkdir(path, 0o755)
                    dirs.add(name)
                continue
            if name in dirs:
                fail(f"{tar_path}: file {name} has the name of a directory")
            source = tar.extractfile(member)
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
            with os.fdopen(fd, "wb") as out:
                while True:
                    chunk = source.read(1 << 20)
                    if not chunk:
                        break
                    out.write(chunk)
            count += 1
    if count == 0:
        fail(f"{tar_path} holds no file")


def attach(repo_path, sigdir):
    Gio, GLib, OSTree = load_gi()
    repo = OSTree.Repo.new(Gio.File.new_for_path(repo_path))
    repo.open(None)

    def read(path):
        with open(path, "rb") as f:
            return f.read()

    def write_new(path, data):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
        with os.fdopen(fd, "wb") as out:
            out.write(data)

    def sig_variant(sig):
        value = GLib.Variant("a{sv}", {"ostree.gpgsigs": GLib.Variant("aay", [sig])})
        return value.get_normal_form().get_data_as_bytes().get_data()

    commits = 0
    objdir = os.path.join(sigdir, "objects")
    for prefix in sorted(os.listdir(objdir)):
        for name in sorted(os.listdir(os.path.join(objdir, prefix))):
            checksum = prefix + name[: -len(".commit.sig")]
            ok, metadata = repo.read_commit_detached_metadata(checksum, None)
            if metadata is not None:
                fail(f"commit {checksum} already has detached metadata")
            repo.append_gpg_signature(checksum, GLib.Bytes.new(read(os.path.join(objdir, prefix, name))), None)
            commits += 1

    for name in ("summary", "summary.idx"):
        data = sig_variant(read(os.path.join(sigdir, name + ".sig")))
        write_new(os.path.join(repo_path, name + ".sig"), data)
        if name == "summary.idx":
            digest = hashlib.sha256(read(os.path.join(repo_path, "summary.idx"))).hexdigest()
            os.makedirs(os.path.join(repo_path, "summaries"), exist_ok=True)
            write_new(os.path.join(repo_path, "summaries", digest + ".idx.sig"), data)
    print(f"attached {commits} commit signatures and the summary signatures", file=sys.stderr)


def load_gi():
    import gi

    gi.require_version("OSTree", "1.0")
    from gi.repository import Gio, GLib, OSTree

    return Gio, GLib, OSTree


def variant_from(GLib, type_string, data, what):
    value = GLib.Variant.new_from_bytes(GLib.VariantType(type_string), GLib.Bytes.new(data), False)
    if not value.is_normal_form():
        fail(f"{what} is not a variant in normal form")
    return value


def summary_ref_map(GLib, data, what):
    value = variant_from(GLib, SUMMARY_TYPE, data, what)
    refs, metadata = value.unpack()
    if "ostree.summary.collection-map" in metadata:
        fail(f"{what} holds collection refs (ostree.summary.collection-map); this pipeline checks only plain refs")
    result = {}
    for name, (_size, checksum, _meta) in refs:
        if name in result:
            fail(f"{what} lists the ref {name} twice")
        result[name] = bytes(checksum).hex()
    return result


def print_refs(refs):
    for name in sorted(refs):
        print(f"{name} {refs[name]}")


def summary_refs(repo_path):
    _, GLib, _ = load_gi()
    with open(os.path.join(repo_path, "summary"), "rb") as f:
        print_refs(summary_ref_map(GLib, f.read(), "summary"))


def index_refs(repo_path):
    import gzip

    _, GLib, _ = load_gi()
    with open(os.path.join(repo_path, "summary.idx"), "rb") as f:
        index, _meta = variant_from(GLib, INDEX_TYPE, f.read(), "summary.idx").unpack()
    if not index:
        fail("summary.idx names no subsummary")
    result = {}
    for name in sorted(index):
        digest = bytes(index[name][0]).hex()
        path = os.path.join(repo_path, "summaries", digest + ".gz")
        try:
            with open(path, "rb") as f:
                data = gzip.decompress(f.read())
        except OSError as e:
            fail(f"subsummary {name}: cannot read {path}: {e}")
        if hashlib.sha256(data).hexdigest() != digest:
            fail(f"subsummary {name}: the SHA-256 of {path} does not match summary.idx")
        for ref, commit in summary_ref_map(GLib, data, f"subsummary {name}").items():
            if result.get(ref, commit) != commit:
                fail(f"subsummaries disagree on the commit of {ref}")
            result[ref] = commit
    print_refs(result)


def check_commits(repo_path, refs_path, app_id, arch, branch):
    """For every "<ref> <commit>" line of refs_path, the commit metadata must:
      - bind the commit to exactly this ref (ostree.ref-binding = [ref]); a
        client that pulls the commit under another ref refuses it
      - bind no collection (ostree.collection-binding absent or empty)
      - for app/ and runtime/ refs: name the same ref in xa.ref, and carry an
        xa.metadata whose [Application] or [Runtime] name equals the id of
        the ref
    and the refs must hold app/APP_ID/ARCH/BRANCH."""
    Gio, GLib, OSTree = load_gi()
    repo = OSTree.Repo.new(Gio.File.new_for_path(repo_path))
    repo.open(None)
    app_ref = f"app/{app_id}/{arch}/{branch}"
    found_app = False
    with open(refs_path) as f:
        lines = f.read().splitlines()
    for line in lines:
        ref, commit = line.split(" ")
        try:
            _, commit_variant = repo.load_variant(OSTree.ObjectType.COMMIT, commit)
        except GLib.Error as e:
            fail(f"{ref}: cannot load the commit {commit}: {e.message}")
        metadata = commit_variant.get_child_value(0).unpack()
        binding = metadata.get("ostree.ref-binding")
        if binding != [ref]:
            fail(f"{ref}: the commit {commit} is bound to the refs {binding}, not to [{ref!r}]")
        if metadata.get("ostree.collection-binding", "") != "":
            fail(f"{ref}: the commit {commit} is bound to the collection {metadata['ostree.collection-binding']!r}")
        kind = ref.split("/")[0]
        if kind not in ("app", "runtime"):
            continue
        if metadata.get("xa.ref") != ref:
            fail(f"{ref}: the commit {commit} names the ref {metadata.get('xa.ref')!r} in xa.ref")
        ref_id, ref_arch, ref_branch = ref.split("/")[1:]
        keyfile = GLib.KeyFile()
        try:
            text = metadata.get("xa.metadata", "")
            keyfile.load_from_data(text, len(text.encode()), GLib.KeyFileFlags.NONE)
            group = "Application" if kind == "app" else "Runtime"
            name = keyfile.get_string(group, "name")
        except GLib.Error as e:
            fail(f"{ref}: the commit {commit} has no valid xa.metadata with a [{'Application' if kind == 'app' else 'Runtime'}] name: {e.message}")
        if name != ref_id:
            fail(f"{ref}: the commit {commit} holds the {kind} {name!r}, not {ref_id!r} (xa.metadata)")
        if kind == "app":
            if ref != app_ref:
                fail(f"{ref}: unexpected app ref; the release app ref is {app_ref} "
                     f"(app id {ref_id} vs {app_id}, arch {ref_arch} vs {arch}, branch {ref_branch} vs {branch})")
            found_app = True
    if not found_app:
        fail(f"the refs hold no {app_ref}")
    print(f"checked the commit metadata of {len(lines)} refs", file=sys.stderr)


def serve(directory, port_file, log_file):
    import functools
    import http.server
    import threading

    lock = threading.Lock()
    log = open(log_file, "a", buffering=1)

    class Logging(http.server.SimpleHTTPRequestHandler):
        def log_request(self, code="-", size="-"):
            with lock:
                log.write(f"{self.command} {self.path} {int(code)}\n")

        def log_message(self, *args):
            pass

    handler = functools.partial(Logging, directory=directory)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    with open(port_file + ".tmp", "w") as f:
        f.write(f"{server.server_address[1]}\n")
    os.rename(port_file + ".tmp", port_file)
    server.serve_forever()


def main(argv):
    if len(argv) == 5 and argv[1] == "extract":
        extract(argv[2], argv[3], argv[4])
    elif len(argv) == 4 and argv[1] == "attach":
        attach(argv[2], argv[3])
    elif len(argv) == 3 and argv[1] == "summary-refs":
        summary_refs(argv[2])
    elif len(argv) == 3 and argv[1] == "index-refs":
        index_refs(argv[2])
    elif len(argv) == 7 and argv[1] == "check-commits":
        check_commits(*argv[2:])
    elif len(argv) == 5 and argv[1] == "serve":
        serve(argv[2], argv[3], argv[4])
    else:
        fail("usage: flatpak-attach.py extract repo|signatures TAR DEST | attach REPO SIGDIR | summary-refs REPO"
             " | index-refs REPO | check-commits REPO REFS APP_ID ARCH BRANCH | serve DIR PORT_FILE LOG")


if __name__ == "__main__":
    main(sys.argv)
