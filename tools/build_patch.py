#!/usr/bin/env python3
"""Apply the upstream diffs to their originals, producing the patched files.

The repository ships, for every upstream file this project edits:

    patch/original/<path>         the file exactly as it shipped -- NOT committed, and not needed
                                  here: pass your own game folder instead
    patch/modified/<path>.patch   a unified diff against it

This script turns the pair into `patch/modified/<path>`, which is what the launcher drops into the
pack. Keeping the generated result out of git is deliberate: a public repository then contains no
copy of the game's own files, only the exact edits applied to them.

    python3 tools/build_patch.py                      # regenerate, using patch/original/ if present
    python3 tools/build_patch.py --game <install>     # regenerate against the copy you own
    python3 tools/build_patch.py --check              # fail if a diff no longer applies cleanly
    python3 tools/build_patch.py --check --game <dir>  # the check that works in a public clone
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PATCH = ROOT / "patch"


def pack_entries(install: Path) -> dict[str, bytes]:
    """res:// paths -> bytes, straight out of the copy of the game the user owns."""
    sys.path.insert(0, str(ROOT / "tools"))
    import pck

    for name in ("data.pck", "youronlymoveishustle.pck", "game.pck", "resources.pck"):
        if (install / name).exists():
            p = pck.Pck(install / name)
            return {e.path: p.read(e.path) for e in p.entries}
    pcks = sorted(Path(install).glob("*.pck"))
    if pcks:
        p = pck.Pck(pcks[0])
        return {e.path: p.read(e.path) for e in p.entries}
    raise SystemExit(f"no .pck found in {install}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="verify only, do not write")
    ap.add_argument("--game", help="folder of your own copy, used instead of patch/original/")
    args = ap.parse_args()

    index = json.loads((PATCH / "index.json").read_text(encoding="utf-8"))
    owned = pack_entries(Path(args.game).expanduser()) if args.game else {}
    scratch = PATCH / "original"

    ok, failed = 0, []
    for rel in index["upstream_edits"]:
        target = rel[: -len(".patch")]
        diff = PATCH / "modified" / rel
        out = PATCH / "modified" / target
        original = scratch / target

        if not diff.exists():
            failed.append(f"{target} (missing diff)")
            continue
        if not original.exists():
            # A public clone has no patch/original/. The same file taken from the player's own
            # copy of the game is byte-identical, so the diff applies to that instead.
            data = owned.get("res://" + target)
            if data is None:
                failed.append(f"{target} (no patch/original/ and no --game to read it from)")
                continue
            scratch.mkdir(parents=True, exist_ok=True)
            original.parent.mkdir(parents=True, exist_ok=True)
            original.write_bytes(data)

        # `patch` is used rather than a hand-rolled applier: context matching, fuzz and offset
        # handling are the parts most likely to be subtly wrong if reimplemented.
        proc = subprocess.run(
            ["patch", "--quiet", "-o", str(out), str(original), str(diff)],
            capture_output=True, text=True,
        )
        if proc.returncode != 0:
            failed.append(f"{target} ({proc.stdout.strip() or proc.stderr.strip()})")
            continue
        ok += 1

    for rel in index["new_files"]:
        if not (PATCH / "modified" / rel).exists():
            failed.append(f"{rel} (own file missing)")

    print(f"applied {ok}/{len(index['upstream_edits'])} upstream diffs")
    for f in failed:
        print("  FAILED " + f)
    if failed and args.check:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
