#!/usr/bin/env python3
"""Refuse to let this repository become a copy of the game.

Run before every commit, and in CI if there is ever any:

    python3 tools/check_compliance.py            # flags anything that should not be here
    python3 tools/check_compliance.py --game <dir>   # also checks nothing is byte-identical to the game

Three rules, from LEGAL.md:

  1. No pack, no executable, no unpacked game tree, no `.import` caches of game files.
  2. No whole file that is byte-identical to an upstream file (diffs are fine; copies are not).
  3. Nothing under patch/original/ — diffs carry their own context and apply to the player's copy.

The only exceptions are the files in `localspot/`, which are this project's own edits of game art
and audio. They are declared, not accidental; see LEGAL.md for why they exist and what that means
for redistributing a fork.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOWED = {
    ".gitkeep",
}
BANNED_SUFFIX = {".pck", ".exe", ".so", ".dll", ".dylib", ".stex", ".md5", ".oggstr", ".mp3str", ".tpz"}
LOCAL_OK = "localspot"


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def files(root: Path):
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        rel = p.relative_to(root)
        if any(part in (".git", "build", "__pycache__") for part in rel.parts):
            continue
        yield p, rel.as_posix()


def tracked_files() -> list[str] | None:
    """Paths git would publish, or None when this is not a git checkout (nothing is public yet)."""
    try:
        proc = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"],
                              capture_output=True, text=True)
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    return [p for p in proc.stdout.split("\0") if p]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--game", help="folder of your own copy, to check for verbatim copies")
    args = ap.parse_args()

    problems: list[str] = []

    if (ROOT / "patch" / "original").exists():
        problems.append("patch/original/ exists — it must not be committed (see LEGAL.md)")

    index_path = ROOT / "patch" / "index.json"
    index = json.loads(index_path.read_text(encoding="utf-8")) if index_path.exists() else {}
    own = set(index.get("new_files", []))
    local = set(index.get("local_only", []))

    for path, rel in files(ROOT):
        if path.suffix.lower() in BANNED_SUFFIX and not rel.startswith(LOCAL_OK):
            if rel not in local and path.name != ".gitkeep":
                problems.append(f"{rel}: banned file type ({path.suffix})")
        if path.name in ALLOWED:
            continue

    # Every file under patch/modified/ must be either a diff, declared as ours, or the output of
    # applying a diff. That third kind is generated on disk by the launcher and by
    # tools/build_patch.py, and is git-ignored; it must never be *committed*, which is what the
    # git check below enforces.
    mod = ROOT / "patch" / "modified"
    if mod.is_dir():
        applied = {rel[:-len(".patch")] for rel in index.get("upstream_edits", [])}
        for path, rel in files(mod):
            inner = path.relative_to(mod).as_posix()
            if inner.endswith(".patch") or inner in own or inner in applied:
                continue
            problems.append(f"patch/modified/{inner}: not a diff and not declared in index.json new_files")

    # What actually matters is what git would publish. A generated file left on disk is harmless;
    # a generated file that is staged is a copy of the game, which is exactly what this guards.
    committed = tracked_files()
    if committed is not None:
        for rel in committed:
            inner = rel[len("patch/modified/"):] if rel.startswith("patch/modified/") else None
            if inner is not None and not inner.endswith(".patch") and inner not in own:
                problems.append(f"patch/modified/{inner}: generated output staged for commit "
                                "(git rm --cached it; see .gitignore)")
            if rel.startswith("patch/original/"):
                problems.append(f"{rel}: game file staged for commit")

    if args.game:
        base = Path(args.game).expanduser()
        pack = None
        for name in ("data.pck", "youronlymoveishustle.pck", "game.pck"):
            if (base / name).exists():
                pack = base / name
                break
        if pack is None:
            print(f"note: no .pck in {base}; skipping the byte-identical check")
        else:
            sys.path.insert(0, str(ROOT / "tools"))
            import pck as pckmod
            game = pckmod.Pck(pack)
            upstream = {hashlib.sha256(game.read(e.path)).hexdigest(): e.path for e in game.entries}
            for path, rel in files(ROOT):
                if rel.startswith(LOCAL_OK) or path.suffix in (".md", ".py", ".json", ".patch"):
                    continue
                if path.stat().st_size == 0:
                    continue
                if sha(path) in upstream:
                    problems.append(f"{rel}: byte-identical to {upstream[sha(path)]} in your game copy")

    if problems:
        print(f"FAIL: {len(problems)} problem(s)")
        for p in problems:
            print("  - " + p)
        return 1
    print("PASS: no game files, no verbatim copies, no patch/original/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
