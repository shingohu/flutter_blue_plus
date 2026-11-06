#!/usr/bin/env python3
"""Release helper for the federated flutter_blue_plus monorepo.

The app-facing package and its sibling platform packages resolve from ONE git
ref (see "Consuming the federated monorepo from Git" in the README). A release
therefore must, in this exact order:

    1. replace every `ref: <old>` in packages/*/pubspec.yaml + the README example
    2. commit that change
    3. create an annotated tag pointing at that commit (self-reference)
    4. push the branch and the tag

Skipping step 1 makes downstream consumers pull the PREVIOUS tag's platform
packages, so the release silently contains none of the fixes.

Usage (run from anywhere inside the repo):

    python3 scripts/release.py 2.0.3                      # dry-run, no writes
    python3 scripts/release.py 2.0.3 --apply             # step 1-3, local only
    python3 scripts/release.py 2.0.3 --apply --push      # also push
    python3 scripts/release.py 2.0.3 --apply --push --ssh

`--push` implies `--apply`. `--ssh` uses a per-command URL rewrite
(https://github.com/ -> git@github.com:) and never changes git config; use it
when HTTPS credentials are unavailable. No third-party dependencies.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

REF_LINE = re.compile(r"^([ \t]*ref:[ \t]*)(\S+)([ \t]*)$", re.MULTILINE)
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
SSH_REWRITE = ["-c", "url.git@github.com:.insteadOf=https://github.com/"]


def run(argv, *, check=True, capture=True):
    return subprocess.run(argv, check=check, text=True, capture_output=capture)


def git(*args, check=True):
    return run(["git", *args], check=check).stdout.strip()


def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def find_ref_files(root: Path):
    pubspecs = sorted((root / "packages").glob("*/pubspec.yaml"))
    readme = root / "packages/flutter_blue_plus/README.md"
    return pubspecs + ([readme] if readme.exists() else [])


def collect_refs(root: Path):
    """Return (files_with_refs, current_ref, total_occurrences)."""
    found = {}
    for path in find_ref_files(root):
        values = [m.group(2) for m in REF_LINE.finditer(path.read_text())]
        if values:
            found[path] = values
    if not found:
        fail("no `ref:` lines found - is this the federated monorepo root?")

    distinct = {value for values in found.values() for value in values}
    if len(distinct) != 1:
        detail = "\n".join(
            f"  {p.relative_to(root)}: {', '.join(sorted(set(v)))}"
            for p, v in found.items()
        )
        fail("git refs are not uniform; fix them before releasing:\n" + detail)
    return found, distinct.pop(), sum(len(v) for v in found.values())


def preflight(args, root: Path, version: str):
    if not VERSION_RE.match(version):
        fail(f"version must look like x.y.z, got {version!r}")

    branch = git("branch", "--show-current")
    if branch != args.branch:
        fail(f"expected branch {args.branch!r}, currently on {branch!r}")

    dirty = git("status", "--porcelain", "--untracked-files=no")
    if dirty:
        fail("tracked files have local changes; commit or stash first:\n" + dirty)

    if run(["git", "rev-parse", "-q", "--verify", f"refs/tags/{version}"],
           check=False).returncode == 0:
        fail(f"tag {version} already exists locally")

    remote_ref = f"{args.remote}/{args.branch}"
    has_remote = run(["git", "rev-parse", "-q", "--verify", remote_ref],
                     check=False).returncode == 0
    if has_remote:
        counts = git("rev-list", "--left-right", "--count", f"{remote_ref}...HEAD")
        behind, ahead = counts.split()
        if behind != "0" or ahead != "0":
            fail(f"{args.branch} is not in sync with {remote_ref} "
                 f"(behind {behind}, ahead {ahead}); fetch/merge or push first")
    return branch, has_remote


def main():
    parser = argparse.ArgumentParser(
        description="Sync federated git refs, tag, and optionally push a release.")
    parser.add_argument("version", help="new git tag, e.g. 2.0.3")
    parser.add_argument("--apply", action="store_true",
                        help="write files, commit, and create the annotated tag")
    parser.add_argument("--push", action="store_true",
                        help="also push the branch and tag (implies --apply)")
    parser.add_argument("--ssh", action="store_true",
                        help="use a per-command SSH URL rewrite for git operations")
    parser.add_argument("--branch", default="master", help="release branch (default: master)")
    parser.add_argument("--remote", default="origin", help="git remote (default: origin)")
    parser.add_argument("--tag-message", default=None, help="annotated tag message")
    args = parser.parse_args()
    if args.push:
        args.apply = True
    version = args.version
    prefix = SSH_REWRITE if args.ssh else []

    root = Path(git("rev-parse", "--show-toplevel"))
    # All later git calls use paths relative to the repo root, so make that the
    # cwd even when this script is launched from a subdirectory.
    os.chdir(root)
    branch, has_remote = preflight(args, root, version)
    ref_files, old_ref, total = collect_refs(root)
    if old_ref == version:
        fail(f"all refs already point at {version}; nothing to release")

    commit_msg = (
        f"chore(release): {version} - sync federated git refs\n\n"
        f"Point all {total} internal git dependency refs at tag {version} so the "
        f"whole federated set resolves from one source revision.\n\n"
        f"Generated by scripts/release.py. pubspec version fields are unchanged: "
        f"the x.y.z git tag line is separate from pub.dev package versions."
    )
    tag_msg = args.tag_message or f"Release {version}"

    print(f"Repository : {root}")
    print(f"Branch     : {branch}" + ("" if has_remote else " (no remote tracking ref)"))
    print(f"Ref change : {old_ref} -> {version}  ({total} occurrences, {len(ref_files)} files)")
    for path, values in ref_files.items():
        print(f"  {path.relative_to(root)}: {len(values)}")
    print(f"Commit     : chore(release): {version} - sync federated git refs")
    print(f"Tag        : annotated {version} -> release commit")
    print(f"Push       : {'yes' if args.push else 'no'}"
          + (" (via SSH rewrite)" if args.push and args.ssh else ""))

    if not args.apply:
        print("\nDry run: nothing was changed. Re-run with --apply (and --push when ready).")
        return

    # 1. replace
    for path, values in ref_files.items():
        text = path.read_text()
        updated, count = REF_LINE.subn(
            lambda m: m.group(1) + version + m.group(3) if m.group(2) == old_ref
            else m.group(0),
            text,
        )
        if count != len(values):
            fail(f"replacement count mismatch in {path}: {count} != {len(values)}")
        path.write_text(updated)

    # 2. verify the tree before committing
    _, new_ref, new_total = collect_refs(root)
    if new_ref != version or new_total != total:
        fail(f"post-replacement check failed: ref={new_ref}, count={new_total}")
    changed = git("diff", "--name-only")
    if not changed:
        fail("no files changed after replacement")
    diff_check = run(["git", "diff", "--check"], check=False)
    if diff_check.returncode != 0:
        fail("git diff --check failed:\n" + diff_check.stdout + diff_check.stderr)

    # 3. commit + annotated tag pointing at THAT commit (self-reference)
    run(["git", "add", *[str(p.relative_to(root)) for p in ref_files]])
    run(["git", "commit", "-m", commit_msg], capture=False)
    commit = git("rev-parse", "HEAD")
    run(["git", "tag", "-a", version, "-m", tag_msg])
    print(f"\nCreated commit {commit[:8]} and annotated tag {version}.")
    print("Undo (before pushing): git tag -d " + version + " && git reset --soft HEAD~1")

    # 4. push + verify remote refs agree
    if args.push:
        run(["git", *prefix, "push", args.remote, args.branch,
             f"refs/tags/{version}:refs/tags/{version}"], capture=False)
        head_line = git(*prefix, "ls-remote", "--heads", args.remote, args.branch)
        remote_head = head_line.split()[0] if head_line else ""
        tag_lines = git(*prefix, "ls-remote", "--tags", args.remote,
                        f"refs/tags/{version}").splitlines()
        peeled = [line.split()[0] for line in tag_lines if line.endswith("^{}")]
        remote_tag = peeled[0] if peeled else (tag_lines[0].split()[0] if tag_lines else "")
        if remote_head and remote_tag and remote_head == remote_tag:
            print(f"Verified: {args.remote}/{args.branch} and tag {version} "
                  f"both point at {remote_head[:8]}.")
        else:
            fail(f"remote verification failed: branch={remote_head}, tag={remote_tag}")


if __name__ == "__main__":
    main()
