#!/usr/bin/env python3
"""FULL PROJECT launcher.

Run it with no arguments and you get a window:

    python3 launcher.py            # opens the launcher window
    pythonw launcher.py            # same, without a console window on Windows

Point the window at the copy of the game you own and press **Build and run**. It unpacks your
copy, applies this project's patches, adds this project's own art and music, repacks, and starts
the result. Nothing is ever written into the folder your copy of the game lives in — a patched
copy is built under ``build/`` and run from there, so a bad patch cannot break the copy you own.

The terminal interface is still here, for scripts and for machines with no display:

    python3 launcher.py --cli                # same launcher, keyboard only
    python3 launcher.py --verify             # check the patch set against your copy
    python3 launcher.py --dry-run            # say what would happen, write nothing
    python3 launcher.py --unpack-only        # unpack your copy to build/unpacked and stop
    python3 launcher.py --no-apply           # repack and run without the patches
    python3 launcher.py --game <folder>      # point at a specific install

Any of those action flags implies ``--cli``. A bare ``--game <folder>`` opens the window with that
folder already filled in.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import queue
import re
import shutil
import subprocess
import sys
import textwrap
import threading
from pathlib import Path

try:  # a Python built without tkinter still gets the terminal launcher
    import tkinter as tk
    from tkinter import filedialog, messagebox, ttk
    from tkinter import font as tkfont

    HAVE_TK = True
except Exception:  # pragma: no cover - depends on the Python build
    HAVE_TK = False

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "tools"))

import pck  # noqa: E402

PATCH = HERE / "patch"
LOCAL = HERE / "localspot"
MANAGED = HERE / "build"
LOG_NAME = "launcher.log"
PATH_CACHE = Path.home() / ".cache" / "full-project"

CANDIDATES = {
    "Windows": [
        r"C:\Program Files (x86)\Steam\steamapps\common\YourOnlyMoveIsHUSTLE",
        r"C:\Program Files\Steam\steamapps\common\YourOnlyMoveIsHUSTLE",
        "~/AppData/Roaming/YourOnlyMoveIsHUSTLE",
    ],
    "Linux": [
        "~/.local/share/Steam/steamapps/common/YourOnlyMoveIsHUSTLE",
        "~/.steam/steam/steamapps/common/YourOnlyMoveIsHUSTLE",
        "~/.steam/root/steamapps/common/YourOnlyMoveIsHUSTLE",
        "~/Steam/steamapps/common/YourOnlyMoveIsHUSTLE",
        "~/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/YourOnlyMoveIsHUSTLE",
    ],
    "Darwin": [
        "~/Library/Application Support/Steam/steamapps/common/YourOnlyMoveIsHUSTLE",
    ],
}
# The game installs under a name or two, but a player may also have moved it, so the folder name
# is only used to *rank* candidates, never to reject one.
GAME_DIR_NAMES = ("youronlymoveishustle", "your only move is hustle", "yomi hustle", "hustle")
EXE_NAMES = {
    "Windows": ["YourOnlyMoveIsHUSTLE.exe", "Your Only Move Is HUSTLE.exe", "hustle.exe"],
    "Darwin": ["YourOnlyMoveIsHUSTLE.app/Contents/MacOS/YourOnlyMoveIsHUSTLE", "YourOnlyMoveIsHUSTLE"],
    "Linux": ["YourOnlyMoveIsHUSTLE", "youronlymoveishustle", "hustle"],
}
# What Godot writes next to the executable when the pack is loose. The Windows and Linux builds
# do not agree on capitalisation, which is why this is matched case-insensitively.
PACK_NAMES = ("data.pck", "youronlymoveishustle.pck", "game.pck", "resources.pck")


# ---------------------------------------------------------------- logging

class LauncherError(Exception):
    """Something the user can fix: no game found, a patch that will not apply, and so on."""


_sink = None
_sink_lock = threading.Lock()


def set_sink(fn) -> None:
    """Route log lines somewhere other than stdout (the window uses this)."""
    global _sink
    _sink = fn


def log(msg: str) -> None:
    with _sink_lock:
        sink = _sink
        if sink is None:
            print(msg, flush=True)
        try:
            MANAGED.mkdir(parents=True, exist_ok=True)
            with (MANAGED / LOG_NAME).open("a", encoding="utf-8") as f:
                f.write(msg + "\n")
        except OSError:
            pass  # a read-only checkout still gets the messages on screen
    if sink is not None:
        sink(msg)


def die(msg: str):
    log("ERROR: " + msg)
    raise LauncherError(msg)


# ---------------------------------------------------------------- finding the game

def is_source_project(p: Path) -> bool:
    """A decompiled source tree: it has project.godot, and Godot can open it directly."""
    try:
        return p.is_dir() and (p / "project.godot").is_file()
    except OSError:
        return False


def looks_like_install(p: Path) -> bool:
    """A folder counts if it has a launcher we can run and a pack we can read, or is a source tree."""
    try:
        if is_source_project(p):
            return True
        if not p.is_dir():
            return False
        has_exe = any((p / n).exists() for n in EXE_NAMES.get(platform.system(), []))
        wanted = {name.lower() for name in PACK_NAMES}
        has_pack = any(q.is_file() and q.name.lower() in wanted for q in p.iterdir())
        return has_exe or has_pack
    except (OSError, PermissionError):
        return False


def steam_roots() -> list[Path]:
    """Every Steam library root on this machine, from Steam's own library list where possible."""
    home = Path.home()
    system = platform.system()
    roots: list[Path] = []
    if system == "Windows":
        for base in (os.environ.get("ProgramFiles(x86)"), os.environ.get("ProgramFiles")):
            if base:
                roots.append(Path(base) / "Steam")
        appdata = os.environ.get("LOCALAPPDATA")
        if appdata:
            roots.append(Path(appdata) / "Steam")
    elif system == "Darwin":
        roots.append(home / "Library/Application Support/Steam")
    else:
        roots += [home / ".local/share/Steam", home / ".steam/steam", home / ".steam/root",
                  home / "Steam", home / ".var/app/com.valvesoftware.Steam/.local/share/Steam"]

    libraries: list[Path] = []
    for root in roots:
        vdf = root / "steamapps" / "libraryfolders.vdf"
        libraries.append(root)
        try:
            text = vdf.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        # Just enough VDF: every "path" entry is a library root. Handles the old
        # "1" "D:\\Games" form and the newer "path" "D:\\Games" one.
        for line in text.splitlines():
            parts = line.strip().split('"')
            if len(parts) >= 4 and parts[1].lower() in ("path", "1", "2", "3", "4", "5", "6", "7"):
                candidate = Path(parts[3])
                if candidate not in libraries:
                    libraries.append(candidate)
    return [p for p in libraries if p.is_dir()]


# Folders worth walking past: caches, package trees and Steam's own scratch space are huge and
# never contain the game.
FIND_PRUNE = [
    ".cache", ".git", "node_modules", "__pycache__", ".venv", "venv", "site-packages",
    ".npm", ".cargo", ".rustup", "Trash", "compatdata", "shadercache", "downloading",
    ".gradle", ".m2", ".vscode", ".mozilla", ".thunderbird", "proc", "sys",
]
FIND_DIR_NAMES = ["youronlymoveishustle*", "your only move is hustle*", "yomihustle*", "yomi*hustle*"]


def _run_find(args: list[str], timeout: float) -> list[str]:
    try:
        proc = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return []
    if proc.returncode not in (0, 1):      # 1 = "some dirs unreadable", still useful output
        return []
    return [line for line in proc.stdout.splitlines() if line.strip()]


def find_with_find_command(timeout: float = 30.0) -> list[Path]:
    """Look for the game with the system `find`, the way the user asked for.

    Runs two searches from the home directory: folders named like the game, and the pack itself
    (`YourOnlyMoveIsHUSTLE.pck` / `data.pck` in a folder named after the game). Heavy directories
    are pruned so this stays quick on a real machine. Returns the folders that look like an install.
    """
    if platform.system() == "Windows" or shutil.which("find") is None:
        return []
    home = str(Path.home())
    prune: list[str] = []
    for name in FIND_PRUNE:
        if prune:
            prune.append("-o")
        prune += ["-name", name]
    pruned_expr = ["(", *prune, ")", "-prune", "-o"]

    name_tests: list[str] = []
    for pat in FIND_DIR_NAMES:
        if name_tests:
            name_tests.append("-o")
        name_tests += ["-iname", pat]

    searches = [
        ["find", home, "-maxdepth", "9", *pruned_expr, "-type", "d", "(", *name_tests, ")",
         "-print"],
        ["find", home, "-maxdepth", "9", *pruned_expr, "-type", "f",
         "(", "-iname", "youronlymoveishustle.pck", "-o", "-iname", "youronlymoveishustle.x86_64",
         "-o", "-iname", "youronlymoveishustle.exe", ")", "-print"],
    ]
    hits: list[Path] = []
    per_search = max(timeout / len(searches), 5.0)
    for args in searches:
        for line in _run_find(args, per_search):
            path = Path(line)
            # A pack or an executable means the folder around it is the install.
            candidate = path.parent if path.suffix.lower() in (".pck", ".exe") or "." in path.name else path
            if candidate not in hits:
                hits.append(candidate)
    return [p for p in hits if looks_like_install(p)]


def detect_installs(max_depth: int = 4) -> list[Path]:
    """Every copy of the game we can find, best first. Never raises."""
    found: list[Path] = []
    seen: set[Path] = set()

    def add(p: Path) -> None:
        try:
            key = p.resolve()
        except OSError:
            key = p
        if key in seen or not looks_like_install(p):
            return
        seen.add(key)
        found.append(p)

    # 1. the system `find` over the home directory: catches copies that were moved anywhere
    for p in find_with_find_command():
        add(p)

    # 2. the usual places, plus every Steam library Steam itself knows about
    for root in steam_roots() + [Path(g).expanduser() for g in CANDIDATES.get(platform.system(), [])]:
        add(root / "steamapps" / "common" / "YourOnlyMoveIsHUSTLE")
        add(root)
        try:
            for entry in (root / "steamapps" / "common").iterdir():
                if entry.name.lower().replace("_", "").replace(" ", "") in (
                        "youronlymoveishustle", "youronlymoveishustle", "yomihustle"):
                    add(entry)
        except OSError:
            continue

    # 3. anything that looks like the game in the places people actually keep it
    skip = {"node_modules", "__pycache__", "AppData", "Library", "$RECYCLE.BIN", "System Volume Information"}
    for home_dir in (Path.home() / "Desktop", Path.home() / "Documents", Path.home() / "Downloads",
                     Path.home() / "Games", Path.home()):
        if not home_dir.is_dir():
            continue
        try:
            for dirpath, dirnames, _ in os.walk(home_dir):
                depth = len(Path(dirpath).relative_to(home_dir).parts)
                dirnames[:] = [d for d in dirnames
                               if d not in skip and not d.startswith(".") and d.lower() != "steamapps"]
                if depth >= max_depth:
                    dirnames[:] = []
                if Path(dirpath).name.lower().replace(" ", "").replace("_", "") in (
                        "youronlymoveishustle", "yomihustle"):
                    add(Path(dirpath))
        except OSError:
            continue

    # 4. folders that hold the game but are named something else, e.g. an extracted copy
    for extra in (Path.home() / "Desktop", Path.home() / "Downloads", Path.cwd()):
        try:
            for entry in extra.iterdir():
                if entry.is_dir():
                    add(entry)
        except OSError:
            continue

    def rank(p: Path) -> tuple:
        name = p.name.lower().replace(" ", "").replace("_", "")
        return (0 if name in ("youronlymoveishustle", "yomihustle") else 1,
                0 if "steamapps" in p.as_posix() else 1,
                len(p.as_posix()))

    return sorted(found, key=rank)


def detect_install() -> Path | None:
    """Best guess at where the game is, or None. Never raises."""
    installs = detect_installs()
    return installs[0] if installs else None


def ask_for_folder(found: list[Path]) -> Path | None:
    """Let the player type, drag or paste the folder, when nothing was found or it is ambiguous."""
    if not sys.stdin or not sys.stdin.isatty():
        return None
    print()
    if found:
        print("which copy should I use?")
        for i, p in enumerate(found, 1):
            print(f"  {i}. {p}")
        prompt = "number, or the folder itself: "
    else:
        prompt = "paste the game folder (it holds YourOnlyMoveIsHUSTLE.exe / .x86_64 and the .pck): "
    while True:
        try:
            answer = input(prompt).strip().strip('"').strip("'")
        except (EOFError, KeyboardInterrupt):
            print()
            return None
        if not answer:
            return None
        if answer.isdigit() and found and 1 <= int(answer) <= len(found):
            return found[int(answer) - 1]
        # accept a drag-and-drop path, which the desktop sometimes quotes or escapes
        candidate = Path(answer.replace("\\ ", " ")).expanduser()
        if candidate.is_file():
            candidate = candidate.parent
        if looks_like_install(candidate):
            return candidate
        print(f"  {candidate} does not contain the game. Try the folder itself, not the .pck.")


def find_install(explicit: str | None, interactive: bool = True) -> Path:
    if explicit:
        p = Path(explicit).expanduser()
        if not p.is_dir():
            die(f"--game {p} is not a directory")
        if not looks_like_install(p):
            die(f"{p} does not contain the game: no "
                f"{EXE_NAMES.get(platform.system(), ['executable'])[0]}, no .pck, and no "
                "project.godot.")
        return p
    found_all = detect_installs()
    if len(found_all) == 1:
        return found_all[0]
    if interactive:
        chosen = ask_for_folder(found_all)
        if chosen is not None:
            return chosen
    if found_all:
        return found_all[0]
    tried = ", ".join(str(p) for p in steam_roots()) or "no Steam folders"
    die("could not find your copy of the game. Pass --game <folder>: the folder that holds "
        f"the game's executable and its .pck. (Looked in {tried}, plus your home folders.)")


def launcher_candidates(install: Path) -> list[Path]:
    """Executables in this folder, best first, excluding Windows binaries when not on Windows.

    A folder that ships both builds has `YourOnlyMoveIsHUSTLE.exe` and `YourOnlyMoveIsHUSTLE.x86_64`
    side by side; picking the .exe on Linux produces a build that cannot start at all.
    """
    system = platform.system()
    names = EXE_NAMES.get(system, [])
    ordered: list[Path] = []
    for name in names:
        p = install / name
        if p.exists():
            ordered.append(p)
    try:
        entries = sorted(install.iterdir())
    except OSError:
        entries = []
    for p in entries:
        if not p.is_file() or p in ordered:
            continue
        suffix = p.suffix.lower()
        if suffix == ".exe" and system != "Windows":
            continue                      # a Windows build, useless here
        if suffix in (".dll", ".so", ".dylib", ".pck", ".txt", ".cmd", ".bat", ".sh",
                      ".md", ".zip", ".dll", ".pdb"):
            continue
        if system == "Windows" and p.suffix.lower() not in (".exe", ""):
            continue
        try:
            if system != "Windows" and not os.access(p, os.X_OK):
                continue
        except OSError:
            continue
        ordered.append(p)
    return ordered


def find_executable(install: Path) -> Path:
    for p in launcher_candidates(install):
        if p.suffix.lower() in (".exe", "") or platform.system() == "Darwin":
            return p
    cands = launcher_candidates(install)
    if cands:
        return cands[0]
    # Nothing runnable: say whether that is because of permissions, which is the common cause.
    blocked = []
    try:
        for q in sorted(install.iterdir()):
            if q.is_file() and q.suffix.lower() in ("", ".x86_64", ".exe"):
                if platform.system() != "Windows" and not os.access(q, os.X_OK):
                    blocked.append(q.name)
    except OSError:
        pass
    if blocked:
        die(f"{install} has {', '.join(blocked)} but it is not executable. "
            f"Fix it with:  chmod +x \"{install / blocked[0]}\"")
    die(f"no program to run found in {install} — expected the game's executable next to its .pck")


def find_pack(install: Path, exe: Path) -> Path:
    """The loose pack next to the executable, matched however it is capitalised."""
    lowered = {n.lower(): n for n in PACK_NAMES}
    try:
        for p in sorted(install.iterdir()):
            if p.is_file() and p.name.lower() in lowered and embedded_offset(p) is None:
                return p
    except OSError:
        pass
    try:
        pcks = sorted(p for p in install.iterdir() if p.suffix.lower() == ".pck")
    except OSError:
        pcks = []
    if len(pcks) == 1:
        return pcks[0]
    if pcks:
        # Several: prefer one named after the executable, else the biggest.
        stem = exe.stem.lower()
        for p in pcks:
            if p.stem.lower() == stem:
                return p
        return max(pcks, key=lambda q: q.stat().st_size)
    if embedded_offset(exe) is not None:
        return exe
    die(f"no .pck in {install} and no pack embedded in the executable")


def embedded_offset(exe: Path) -> int | None:
    """Offset of a pack appended to an executable, or None if there isn't one."""
    size = exe.stat().st_size
    if size < 96:
        return None
    with exe.open("rb") as f:
        f.seek(size - 4)
        if f.read(4) == pck.MAGIC:
            f.seek(size - 12)
            import struct
            (pack_size,) = struct.unpack("<Q", f.read(8))
            start = size - 12 - pack_size
            return start if start >= 0 else None
        f.seek(0)
        head = f.read(1 << 20)
    idx = head.find(pck.MAGIC)
    return idx if idx > 0 else None


# ---------------------------------------------------------------- the patch set

def load_index() -> dict:
    index = PATCH / "index.json"
    if not index.exists():
        die(f"missing {index}; this checkout is incomplete")
    return json.loads(index.read_text(encoding="utf-8"))


def build_one(target: str, fallback: bytes | None = None) -> bool:
    """Produce patch/modified/<target> from patch/original/<target> and its diff.

    `fallback` is the same file taken out of the user's own copy of the game. A public clone has
    no patch/original/ (shipping the game's files is exactly what this repository avoids), so the
    diff is applied to the user's copy instead: same bytes, no redistribution.
    """
    original = PATCH / "original" / target
    diff = PATCH / "modified" / (target + ".patch")
    out = PATCH / "modified" / target
    if not diff.exists():
        return False

    scratch = MANAGED / "originals" / target
    if original.exists():
        source = original
    elif fallback is not None:
        scratch.parent.mkdir(parents=True, exist_ok=True)
        scratch.write_bytes(fallback)
        source = scratch
    else:
        return False

    # The diffs are written with a/ and b/ labels. Against a file of our own naming we tell
    # patch which file to edit and take the result from -o, which needs no path stripping.
    try:
        proc = subprocess.run(
            ["patch", "--quiet", "-o", str(out), str(source), str(diff)],
            capture_output=True, text=True,
        )
    except OSError:
        die("the `patch` command is not available. Install GNU patch (or use Windows' Git "
            "for Windows shell, which ships it) and try again.")
    if proc.returncode != 0:
        log(f"          patch failed for {target}: {(proc.stdout or proc.stderr).strip()}")
        return False
    return True


def explain_skips(skipped: list[str], names: list[str]) -> None:
    """One clear diagnosis instead of the same sentence twenty-seven times."""
    missing = [s.split(" (")[0] for s in skipped if "(not in this pack)" in s]
    failed = [s.split(" (")[0] for s in skipped if "(diff did not apply)" in s]
    total = len(skipped)
    if missing and len(missing) == total:
        log(f"          none of the {total} files this patch edits exist in your copy.")
        log("          your copy is a different build from the one these patches were made "
            "against, so there is nothing to patch.")
        log("          what is in it: " + describe_pack_names(names))
        log("          the patches expect: project.godot, ui/UILayer.gd, main.gd, game.gd, ...")
        log("          nothing was patched; the build contains only this project's own added files.")
        return
    if failed:
        log(f"          {len(failed)} of {total} diffs would not apply — your files are a "
            "different version from the ones the patches were made against.")
        for name in failed[:8]:
            log("            " + name)
        if len(failed) > 8:
            log(f"            ... and {len(failed) - 8} more")
    for name in missing:
        log("          skipped " + name + " (not in your copy)")


def describe_pack_names(names: list[str]) -> str:
    """What a mismatched pack does contain, so the player can recognise their own build."""
    files = [n for n in names if not n.endswith("/")]
    top: dict[str, int] = {}
    for n in files:
        stem = n[6:] if n.startswith("res://") else n
        head = stem.split("/")[0]
        top[head] = top.get(head, 0) + 1
    biggest = sorted(top.items(), key=lambda kv: -kv[1])[:6]
    kind = []
    for name in ("project.godot", "res://project.godot", "resources.pck", "data.pck"):
        if name in names:
            kind.append(name.replace("res://", ""))
    has_gd = sum(1 for n in files if n.endswith(".gd") or n.endswith(".gd.remap"))
    bits = [f"{n} files" for n in ([f"{len(files)}"] if files else [])]
    out = f"{len(files)} entries"
    if kind:
        out += ", including " + ", ".join(kind)
    out += f"; {has_gd} scripts"
    if has_gd and not any(n.endswith(".gd") for n in files):
        out += " (all renamed to .gd.remap — this is an exported/release build, not a dev build)"
    out += "; top folders: " + ", ".join(f"{k or '.'}{v}" for k, v in biggest)
    return out


def inspect_pack(p: "pck.Pck") -> dict:
    """Say what kind of build this pack is. This decides whether patching is possible at all."""
    names = [e.path for e in p.entries]
    short = [n[6:] if n.startswith("res://") else n for n in names]
    scripts = [n for n in short if n.endswith(".gd")]
    compiled = [n for n in short if n.endswith((".gdc", ".gd.remap"))]
    binary = [n for n in short if n.endswith(("project.binary", "engine.cfg", "project.cfg"))]
    has_text_project = "project.godot" in short
    has_addons = any(n.startswith("addons/") for n in short)
    return {
        "files": len(short),
        "scripts": len(scripts),
        "compiled": len(compiled),
        "has_project_godot": has_text_project,
        "has_project_binary": bool(binary),
        "has_addons": has_addons,
        "exported": (not has_text_project) or (binary and not has_text_project) or
                    (compiled and not scripts),
    }


def describe_build(info: dict) -> str:
    if info["exported"]:
        bits = []
        if info["has_project_binary"]:
            bits.append("a compiled project.binary instead of project.godot")
        elif not info["has_project_godot"]:
            bits.append("no project.godot")
        if info["compiled"]:
            bits.append(f"{info['compiled']} compiled script(s)")
        if info["has_addons"]:
            bits.append("an addons/ folder")
        return "an exported release build (" + ", ".join(bits) + ")"
    return f"a readable source build ({info['scripts']} .gd scripts, project.godot present)"


def patchable(p: "pck.Pck") -> tuple[bool, str]:
    """Can these patches be applied to this pack at all?"""
    info = inspect_pack(p)
    if not info["has_project_godot"]:
        return False, (f"{describe_build(info)}. The diffs need the source files of a decompiled "
                       f"build, and this pack holds compiled scripts and a binary project file "
                       f"instead — so it gets recovered to source first, then patched.")
    if info["compiled"] and not info["scripts"]:
        return False, f"{describe_build(info)}; the scripts are compiled."
    return True, describe_build(info)


def apply_patches(entries: list[tuple[str, bytes]], allow_local: bool) -> tuple[list[tuple[str, bytes]], dict]:
    """Overwrite upstream files with their patched versions, and add this project's own files."""
    index = load_index()
    by_name = dict(entries)
    report = {"patched": [], "added": [], "skipped": []}

    for rel in index["upstream_edits"]:
        target = rel[:-len(".patch")]                       # "ui/UILayer.gd.patch" -> "ui/UILayer.gd"
        patched = PATCH / "modified" / target
        if not patched.exists():
            # A fresh clone has the diffs but not their output: build it now rather than
            # skipping, so cloning and running is enough.
            if not build_one(target, by_name.get("res://" + target)):
                report["skipped"].append(target + " (diff did not apply)")
                continue
        key = "res://" + target
        if key not in by_name:
            report["skipped"].append(target + " (not in this pack)")
            continue
        by_name[key] = patched.read_bytes()
        report["patched"].append(target)

    for rel in index["new_files"]:
        by_name["res://" + rel] = (PATCH / "modified" / rel).read_bytes()
        report["added"].append(rel)

    if allow_local:
        for rel in index.get("local_only", []):
            src = LOCAL / rel
            if not src.exists():
                continue
            by_name["res://" + rel] = src.read_bytes()
            report.setdefault("local", []).append(rel)
            # Godot draws images through the imported .stex in .import/, not the .png itself.
            # A patched picture without its patched cache is a patched picture nobody sees.
            stem = Path(rel)
            for cache in (LOCAL / ".import").glob(stem.stem + ".*"):
                if cache.suffix in (".stex", ".md5"):
                    by_name["res://.import/" + cache.name] = cache.read_bytes()
                    report.setdefault("local_cache", []).append(cache.name)
    return list(by_name.items()), report


def check_originals(entries: list[tuple[str, bytes]]) -> list[str]:
    """Every patch is generated against a specific upstream file. Report any that don't match."""
    index = load_index()
    by_name = dict(entries)
    mismatched = []
    for rel in index["original_copies"]:
        reference = PATCH / "original" / rel
        if not reference.exists():
            # A public clone has no originals; --verify then only checks presence, not exact version.
            continue
        want = reference.read_bytes()
        got = by_name.get("res://" + rel)
        if got is None:
            mismatched.append(rel + " (missing from your copy)")
        elif hashlib.sha256(got).digest() != hashlib.sha256(want).digest():
            mismatched.append(rel + " (different version)")
    return mismatched


# ---------------------------------------------------------------- the pipeline

def _open_embedded(exe: Path) -> Path:
    offset = embedded_offset(exe)
    if offset is None:
        die("could not find the embedded pack inside the executable")
    source = MANAGED / "embedded.pck"
    source.write_bytes(exe.read_bytes()[offset:])
    return source


def probe_folder(folder: str) -> dict:
    """Cheap, read-only look at a folder: is the game here, and can it be patched?"""
    try:
        install = Path(folder).expanduser()
        if not install.is_dir() or not looks_like_install(install):
            return {"ok": False, "why": "no game in this folder"}
        if is_source_project(install):
            scripts = sum(1 for _ in install.rglob("*.gd"))
            return {"ok": True, "can_patch": True, "source": True,
                    "exe": "project.godot", "pack": f"{scripts} .gd scripts",
                    "files": sum(1 for p in install.rglob('*') if p.is_file())}
        exe = find_executable(install)
        pack_path = find_pack(install, exe)
        source = pack_path
        if pack_path == exe:
            offset = embedded_offset(exe)
            if offset is None:
                return {"ok": False, "why": "no pack found"}
            tmp = MANAGED / "probe.pck"
            MANAGED.mkdir(parents=True, exist_ok=True)
            tmp.write_bytes(exe.read_bytes()[offset:])
            source = tmp
        p = pck.Pck(source)
        info = inspect_pack(p)
        can, why = patchable(p)
        # not patchable, but a genuine compiled project: recoverable with GDRE, then patchable
        recoverable = not can and info.get("compiled", 0) > 0
        return {"ok": True, "can_patch": can, "recoverable": recoverable, "why": why,
                "exe": exe.name, "pack": pack_path.name, "files": info["files"],
                "version": ".".join(map(str, p.version))}
    except (LauncherError, pck.PckError, OSError) as exc:
        return {"ok": False, "why": str(exc)}


def copy_install(install: Path, out_dir: Path, pack_path: Path, staged: Path, exe: Path) -> None:
    """Copy the player's install into build/game and drop the repacked pack in.

    Two things this must survive: the install being on another drive (a cross-device copy can fail
    halfway) and a folder we cannot fully read. So the copy is made into a scratch folder first and
    only moved into place once the executable and the pack are both really there — a half-written
    build/game is what produced "No such file or directory" when the launcher tried to start it.
    """
    partial = out_dir.with_name(out_dir.name + ".partial")
    if partial.exists():
        shutil.rmtree(partial, ignore_errors=True)
    log(f"copying:  {install.name}/ into build/game (this is the slow part)")

    problems: list[str] = []

    def ignore(directory: str, names: list[str]) -> set[str]:
        return set()

    def on_error(err: OSError) -> None:
        problems.append(f"{getattr(err, 'filename', '?')}: {err.strerror or err}")

    try:
        shutil.copytree(install, partial, symlinks=True, ignore_dangling_symlinks=True,
                        ignore=ignore, copy_function=shutil.copy2)
    except shutil.Error as err:
        # copytree collects per-file trouble here rather than stopping; keep going, the pack and
        # the executable are all that have to survive.
        for _src, _dst, why in err.args[0]:
            problems.append(str(why))
    except OSError as err:
        problems.append(str(err))

    if problems:
        log(f"warning:  {len(problems)} file(s) could not be copied:")
        for line in problems[:5]:
            log("            " + line)
        if len(problems) > 5:
            log(f"            ... and {len(problems) - 5} more")

    # The pack is written from memory, so it cannot be lost to a partial copy.
    try:
        (partial / pack_path.name).write_bytes(staged.read_bytes())
    except OSError as err:
        shutil.rmtree(partial, ignore_errors=True)
        die(f"could not write the repacked {pack_path.name} into {out_dir}: {err}. "
            "Is the disk full?")

    for needed in (exe.name, pack_path.name):
        if not (partial / needed).is_file():
            shutil.rmtree(partial, ignore_errors=True)
            die(f"the copy is missing {needed} — your install could not be copied in full. "
                "Try a folder on the same drive as your game, or run the game from your own "
                "folder with --game.")

    try:
        os.replace(partial, out_dir) if not out_dir.exists() else (
            shutil.rmtree(out_dir, ignore_errors=True) or os.replace(partial, out_dir))
    except OSError:
        # Different filesystem: fall back to moving what we can.
        shutil.rmtree(out_dir, ignore_errors=True)
        shutil.move(str(partial), str(out_dir))


SOURCE_BUILD_DIR = "game-src"


# ---------------------------------------------------------------- decompile and recompile

GDRE_VERSION = "v2.7.4"
GDRE_URL = ("https://github.com/GDRETools/gdsdecomp/releases/download/"
            f"{GDRE_VERSION}/GDRE_tools-{GDRE_VERSION}-linux.zip")
GDRE_MARKER = "gdre_tools.x86_64"


def _download(url: str, dest: Path, what: str = "the decompiler") -> None:
    import urllib.request
    log(f"downloading {url}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": "FULL-PROJECT-launcher"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r, part.open("wb") as f:
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
    except Exception as exc:                                # noqa: BLE001
        part.unlink(missing_ok=True)
        die(f"could not download {what}: {exc}")
    os.replace(part, dest)


EXPORT_TEMPLATES_URL = (
    "https://github.com/godotengine/godot/releases/download/3.5.1-stable/"
    "Godot_v3.5.1-stable_export_templates.tpz")
GAME_NAME = "YourOnlyMoveIsRECOMPILED"


def app_dir() -> Path:
    """Where an installed copy lives."""
    return Path.home() / ".local" / "share" / GAME_NAME


def desktop_dir() -> Path:
    """The user's desktop, honouring a localised one."""
    home = Path.home()
    for name in ("Desktop", "Escritorio", "Bureau", "Schreibtisch", "桌面", "デスクトップ"):
        d = home / name
        if d.is_dir():
            return d
    return home / "Desktop"


def export_templates_dir() -> Path:
    return Path.home() / ".local" / "share" / "godot" / "templates" / "3.5.1.stable"


GODOT_VERSION = "3.5.1-stable"
# the _headless build has no renderer and cannot run a game, so fetch the X11 one
GODOT_BIN = f"Godot_v{GODOT_VERSION}_x11.64"
GODOT_ZIP = f"Godot_v{GODOT_VERSION}_x11.64.zip"
GODOT_URL = (f"https://github.com/godotengine/godot/releases/download/"
             f"3.5.1-stable/{GODOT_ZIP}")


def godot_cache() -> Path:
    return PATH_CACHE / "godot-3.5.1"


def find_cached_godot() -> Path | None:
    """A Godot 3.5.1 binary we downloaded earlier, if there is one."""
    cache = godot_cache()
    for name in (GODOT_BIN, "godot"):
        c = cache / name
        if c.is_file() and os.access(c, os.X_OK):
            return c
    return None


def ensure_godot(explicit: str | None = None) -> Path | None:
    """Return a Godot 3.5.1 binary, downloading one if needed.

    A recovered project needs a real editor binary to run; the game's own exported executable
    cannot load a project directory. Most players will not have Godot installed, so fetch it the
    same way the decompiler is fetched, and cache it next to it.
    """
    if explicit:
        p = Path(explicit).expanduser()
        if p.is_file():
            return p
        die(f"--godot {p} is not a file")
    cached = find_cached_godot()
    if cached is not None:
        return cached
    found = find_godot()
    if found is not None:
        return found
    cache = godot_cache()
    binary = cache / GODOT_BIN
    zip_path = cache / GODOT_ZIP
    log("")
    log("no Godot 3.5 engine was found, so one is being downloaded to run the build")
    log("(about 25 MB, once; it is cached and reused after this)")
    if not zip_path.is_file():
        _download(GODOT_URL, zip_path, what="the Godot engine")
    import zipfile
    log("unpacking " + zip_path.name)
    try:
        with zipfile.ZipFile(zip_path) as z:
            for member in z.namelist():
                if member.endswith(("_x11.64", "_x11.32")):
                    target = cache / Path(member).name
                    with z.open(member) as srcf, target.open("wb") as dstf:
                        shutil.copyfileobj(srcf, dstf)
                    target.chmod(0o755)
    except (zipfile.BadZipFile, OSError) as exc:
        die(f"could not unpack the Godot download: {exc}")
    if binary.is_file():
        binary.chmod(0o755)
        return binary
    for cand in cache.iterdir():
        if cand.is_file() and cand.name.startswith("Godot_v"):
            cand.chmod(0o755)
            return cand
    die("downloaded Godot but could not find the binary inside the archive.")


def find_gdre(explicit: str | None = None) -> Path | None:
    """The decompiler binary: given, already downloaded, or None."""
    if explicit:
        p = Path(explicit).expanduser()
        if not p.is_file():
            die(f"--gdre {p} is not a file")
        return p
    for folder in (HERE, HERE / "tools", Path.cwd()):
        for name in (GDRE_MARKER, "gdre_tools"):
            q = folder / name
            if q.is_file():
                return q
        try:
            for q in folder.rglob("gdre_tools*"):
                if q.is_file() and os.access(q, os.X_OK):
                    return q
        except OSError:
            pass
    return None


def ensure_gdre(explicit: str | None) -> Path:
    found = find_gdre(explicit)
    if found:
        return found
    cache = PATH_CACHE / GDRE_VERSION
    binary = cache / GDRE_MARKER
    if not binary.is_file():
        archive = cache / "gdre.zip"
        _download(GDRE_URL, archive)
        import zipfile
        log(f"unpacking {archive.name}")
        with zipfile.ZipFile(archive) as z:
            z.extractall(cache)
        os.chmod(binary, 0o755)
    if not binary.is_file():
        die(f"the decompiler was downloaded but {GDRE_MARKER} is not in {cache}")
    return binary


def build_from_pack(pack_path: Path, *, apply: bool = True, local: bool = True,
                    launch: bool = True, godot: str | None = None,
                    gdre: str | None = None, install: Path | None = None,
                    export: bool = False, target: str | None = None,
                    install_flag: bool = False, shortcut: bool = False) -> int:
    """Decompile a compiled release, patch the recovered project, and run it.

    This is the route for a store install: the pack has no source in it, so it is recovered to a
    source tree first (into build/, never into your own folder), and the same 27 diffs are then
    applied to that recovered tree.
    """
    gdre_bin = ensure_gdre(gdre)
    recovered = MANAGED / "recovered"
    if recovered.exists():
        shutil.rmtree(recovered)
    log(f"decompiling {pack_path.name} with GDRE Tools {GDRE_VERSION}")
    log("")
    log("  This will look stuck. It is not. Leave it alone for at least 10 minutes —")
    log("  on a full Steam install it decompiles 500-odd scripts and 5,000-odd files, and")
    log("  nothing is printed while that happens. Closing the window now loses the work.")
    log("")
    proc = subprocess.run([str(gdre_bin), "--headless", f"--recover={pack_path}",
                           f"--output={recovered}"], capture_output=True, text=True)
    if proc.returncode != 0 or not (recovered / "project.godot").exists():
        tail = "\n".join((proc.stdout or "").splitlines()[-8:])
        die("recovery failed — no project.godot came out of the pack.\n" + tail)

    # A recovery contains the PNG sources and the .import sidecars but not the compiled
    # .stex textures those sidecars point at, so the engine cannot load a single image until
    # they are rebuilt. Copy them out of the pack being replaced when it has them: they are
    # derived data for images whose bytes we have not touched.
    src_import = pack_path.parent / ".import"
    if src_import.is_dir():
        stex = list(src_import.glob("*.stex"))
        if stex:
            log(f"copying:  {len(stex)} imported texture cache file(s) from the install")
            shutil.copytree(src_import, recovered / ".import", dirs_exist_ok=True)

    # `--recover` extracts .gdc files but does not always turn them back into .gd, so do that
    # pass explicitly. Without it the diffs have nothing to land on.
    compiled = sorted(recovered.rglob("*.gdc"))
    if compiled:
        log(f"decompiling {len(compiled)} script(s) to source")
        # GDRE writes every result flat into one output folder, and this project has 31 repeated
        # basenames (each character has its own AirDash.gd, ...), so a flat write would collide
        # and lose scripts. Run one call per source folder into a matching folder: same count of
        # processes as a per-file loop but each covers a whole folder at once.
        by_dir = {}
        for gdc in compiled:
            by_dir.setdefault(gdc.parent, []).append(gdc)
        scratch = MANAGED / "dec"
        if scratch.exists():
            shutil.rmtree(scratch)
        fixed = 0
        for folder in sorted(by_dir):
            out_dir = scratch / folder.relative_to(recovered)
            out_dir.mkdir(parents=True, exist_ok=True)
            subprocess.run([str(gdre_bin), "--headless", f"--decompile={folder}/*.gdc",
                            "--bytecode=3.5.0", f"--output={out_dir}"],
                           capture_output=True, text=True)
            for made in out_dir.glob("*.gd"):
                # NB: this must not be called `target` — that name belongs to the --target
                # platform argument of this function, and reusing it here passed a Path into
                # the exporter, which then asked it for .lower().
                dest_gd = folder / made.name
                if not dest_gd.exists() or dest_gd.stat().st_size == 0:
                    shutil.move(str(made), str(dest_gd))
                    fixed += 1
        shutil.rmtree(scratch, ignore_errors=True)
        log(f"decompiled: {fixed} script(s)")

        # Now that the source exists, the bytecode must go. A release carries Foo.gdc plus a
        # Foo.gd.remap that redirects the engine to that bytecode; if they are left behind the
        # engine keeps loading the .gdc and every decompiled .gd is ignored — including the
        # patched ones — and scenes fail with "referenced nonexistent resource".
        dropped = 0
        for gdc in compiled:
            gd = gdc.with_suffix(".gd")
            if not (gd.is_file() and gd.stat().st_size > 0):
                continue
            for p_ in (gdc, Path(str(gd) + ".remap")):
                if p_.is_file():
                    p_.unlink()
                    dropped += 1
        if dropped:
            log(f"removed:  {dropped} compiled script file(s) superseded by source")

        missing = [g for g in compiled if not g.with_suffix(".gd").is_file()]
        if missing:
            log(f"warning:  {len(missing)} script(s) did not decompile:")
            for g in missing[:8]:
                log("          " + str(g.relative_to(recovered)))

    scripts = sum(1 for _ in recovered.rglob("*.gd"))
    scenes = sum(1 for _ in recovered.rglob("*.tscn"))
    log(f"recovered: {scripts} scripts, {scenes} scenes, project.godot present")
    if scripts == 0:
        die("recovery produced no source scripts, so the patches cannot be applied.")

    # The recovered tree is a source project from here on: same code path as a folder you own.
    return build_from_source(recovered, apply=apply, local=local, launch=launch, godot=godot,
                             owner=install, label="recovered", export=export,
                             platform_target=target, install=install_flag,
                             shortcut=shortcut, gdre=gdre)


def ensure_export_templates(gdre_bin: Path | None = None) -> Path:
    """Return the folder holding this engine's export templates, downloading them if needed.

    Godot ships templates as a 576 MB .tpz in the same release as the engine. Both the Linux and
    the Windows 64-bit binaries are inside, which is what lets one machine build for either.
    """
    dest = export_templates_dir()
    wanted = ("linux_x11_64_release",)
    if dest.is_dir() and all((dest / n).is_file() for n in wanted):
        return dest
    dest.mkdir(parents=True, exist_ok=True)

    zip_path = PATH_CACHE / "godot-3.5.1" / "templates.tpz"
    if not (zip_path.is_file() and zip_path.stat().st_size > 500_000_000):
        log("")
        log("export templates are not installed, so they are being downloaded now")
        log("  one file, about 575 MB, saved once and reused for every later build")
        log("  this is the long part: give it at least 10 minutes on a slow connection")
        log("")
        _download(EXPORT_TEMPLATES_URL, zip_path, what="the Godot export templates")
    import zipfile
    log("installing export templates")
    try:
        with zipfile.ZipFile(zip_path) as z:
            for member in z.namelist():
                if not member.startswith("templates/"):
                    continue
                name = member.split("/", 1)[1]
                if not name:
                    continue
                with z.open(member) as srcf, (dest / name).open("wb") as dstf:
                    shutil.copyfileobj(srcf, dstf)
    except (zipfile.BadZipFile, OSError) as exc:
        die(f"could not install the export templates: {exc}")
    return dest


def make_project_binary(project: Path, gdre_bin: Path, work: Path) -> Path:
    """project.godot -> project.binary using GDRE, so the binary format is exactly right."""
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run([str(gdre_bin), "--headless", f"--txt-to-bin={project / 'project.godot'}",
                           f"--output={work}"], capture_output=True, text=True)
    made = work / "project.binary"
    if not made.is_file():
        tail = "\n".join((proc.stdout or "").splitlines()[-6:])
        die("could not turn project.godot into project.binary.\n" + tail)
    return made


def collect_pack_entries(project: Path, binary: Path) -> list:
    """Everything a shipped build carries: resources, the import cache, and the config binary."""
    entries = []
    skip = {"project.godot", "project.binary", "export_presets.cfg", "export_credentials.cfg"}
    for file in sorted(project.rglob("*")):
        if not file.is_file():
            continue
        rel = file.relative_to(project).as_posix()
        if rel.startswith(".import/") or rel in skip:
            continue
        entries.append(("res://" + rel, file.read_bytes()))
    cache = project / ".import"
    if cache.is_dir():
        for file in sorted(cache.iterdir()):
            if file.is_file():
                entries.append(("res://.import/" + file.name, file.read_bytes()))
    entries.append(("res://project.binary", binary.read_bytes()))
    return entries


def build_game(project: Path, out_dir: Path, target: str, binary: Path) -> tuple[Path, Path]:
    """Write <name>.pck plus the platform template as <name>.<ext>."""
    template_name, suffix = ("linux_x11_64_release", "x86_64")
    templates = export_templates_dir()
    template = templates / template_name
    if not template.is_file():
        die(f"the {target} export template is missing from {templates}")

    out_dir.mkdir(parents=True, exist_ok=True)
    entries = collect_pack_entries(project, binary)
    pack_path = out_dir / (GAME_NAME + ".pck")
    pck.write_pck(pack_path, entries)

    exe_path = out_dir / f"{GAME_NAME}.{suffix}"
    shutil.copyfile(template, exe_path)
    exe_path.chmod(0o755)
    return exe_path, pack_path


def install_game(exe: Path, pack_path: Path, project: Path) -> Path:
    """Copy a built game into the per-user application folder and leave it runnable."""
    dest = app_dir()
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(exe, dest / exe.name)
    (dest / exe.name).chmod(0o755)
    shutil.copyfile(pack_path, dest / pack_path.name)
    # GDNative libraries are loaded from beside the executable, not from inside the pack
    lib = project / "lib"
    if lib.is_dir():
        shutil.copytree(lib, dest / "lib", dirs_exist_ok=True)

    # The desktop icon starts the small launcher, so that launcher has to live somewhere permanent
    # rather than in whatever folder this build happened to run from. Copy it and the builder it
    # drives into the application folder next to the game.
    for name in ("YOMI-Launcher.py", "launcher.py", "icon.png"):
        source = HERE / name
        if source.is_file():
            shutil.copyfile(source, dest / name)
    install_icon(dest)
    if (HERE / "tools").is_dir():
        shutil.copytree(HERE / "tools", dest / "tools", dirs_exist_ok=True)
    if (HERE / "patch").is_dir():
        shutil.copytree(HERE / "patch", dest / "patch", dirs_exist_ok=True)
    if (HERE / "localspot").is_dir():
        shutil.copytree(HERE / "localspot", dest / "localspot", dirs_exist_ok=True)

    (dest / "uninstall.json").write_text(json.dumps(
        {"name": GAME_NAME, "installed": str(dest)}, indent=2))
    return dest


def launcher_app() -> Path | None:
    """The small launcher to put on the desktop: the installed copy first, then one beside us."""
    for folder in (app_dir(), HERE):
        for name in ("YOMI-Launcher.py", "YOMI-Launcher.pyw"):
            candidate = folder / name
            if candidate.is_file():
                return candidate
    return None


def install_icon(app_folder: Path) -> None:
    """Keep the icon beside the app and in the icon theme, at the sizes desktops look for."""
    source = HERE / "icon.png"
    if not source.is_file():
        source = app_folder / "icon.png"
    if not source.is_file():
        return
    shutil.copyfile(source, app_folder / "icon.png")
    try:
        from PIL import Image            # optional: only used to make the smaller sizes
    except ImportError:
        return
    theme = Path.home() / ".local" / "share" / "icons" / "hicolor"
    for size in (16, 32, 48, 64, 128, 256):
        try:
            target = theme / f"{size}x{size}" / "apps"
            target.mkdir(parents=True, exist_ok=True)
            with Image.open(source) as img:
                img.resize((size, size), Image.LANCZOS).save(target / f"{GAME_NAME}.png")
        except OSError:
            continue


def make_desktop_shortcut(target_exe: Path, label: str = GAME_NAME) -> Path | None:
    """Put the launcher icon on the desktop as a .desktop entry."""
    desktop = desktop_dir()
    try:
        desktop.mkdir(parents=True, exist_ok=True)
    except OSError:
        return None

    # The icon opens the launcher (Launch / Update / Uninstall), not the game directly.
    app = launcher_app()
    if app is not None:
        # `python3` from PATH, not sys.executable: a build may run under a virtualenv whose
        # interpreter disappears, and the desktop entry has to keep working afterwards.
        command = f'python3 "{app}"'
        workdir = str(app.parent)
        icon = GAME_NAME                   # resolves through the hicolor theme
    else:
        command = f'"{target_exe}"'
        workdir = str(target_exe.parent)
        icon = GAME_NAME

    entry = desktop / f"{label}.desktop"
    entry.write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        f"Name={label}\n"
        "Comment=Your Only Move Is HUSTLE, offline, controller-first\n"
        f"Exec={command}\n"
        f"Path={workdir}\n"
        f"Icon={icon}\n"
        "Terminal=false\n"
        "Categories=Game;\n"
        "StartupWMClass=Your Only Move Is RECOMPILED\n", encoding="utf-8")
    entry.chmod(0o755)

    # GNOME will not show a .desktop file it has not been told to trust.
    try:
        subprocess.run(["gio", "set", str(entry), "metadata::trusted", "true"],
                       capture_output=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        pass
    return entry


def uninstall_game(keep_saves: bool = True) -> int:
    """Remove the installed copy and the desktop shortcut."""
    dest = app_dir()
    removed = []
    if dest.exists():
        shutil.rmtree(dest)
        removed.append(str(dest))
    for candidate in (desktop_dir() / f"{GAME_NAME}.desktop",):
        if candidate.is_file():
            candidate.unlink()
            removed.append(str(candidate))
    if removed:
        log("removed:")
        for item in removed:
            log("  " + item)
    else:
        log("nothing was installed, so there was nothing to remove")
    if keep_saves:
        log("")
        log("your saves and replays were left alone.")
    return 0


def initialize_imports(project: Path, godot_exe: Path | None) -> bool:
    """Run the engine over the project once so it imports every texture and resource.

    This is what "opening the project in the editor at least once" means in Godot 3.x: without it
    `res://Main.tscn` cannot be loaded, even though every file is present, because the scenes refer
    to `res://.import/*.stex` files that do not exist yet.

    The editor must be left running until it has finished: `--editor --quit` aborts the scan
    thread immediately, so almost nothing gets imported. It is started normally, polled until the
    cache satisfies every `.import` sidecar, and then closed.
    """
    if godot_exe is None:
        return False

    wanted, have = _import_state(project)
    if wanted and wanted <= have:
        return False                                    # every texture is already imported
    if platform.system() == "Linux" and not os.environ.get("DISPLAY"):
        log("warning:  no display available, so the project cannot be imported automatically")
        log("          run the launcher on your desktop, or open the project in Godot once")
        return False

    log("")
    log("importing the project (the engine builds every texture)")
    log(f"  {len(wanted)} texture(s) to build. This is the slow step: several minutes, and")
    log("  it prints nothing while it works. It is not stuck - give it at least 10 minutes.")
    log("")
    try:
        proc = subprocess.Popen([str(godot_exe), "--editor", "--path", str(project)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                cwd=str(project))
    except OSError as exc:
        log(f"warning:  could not start the import pass: {exc}")
        return False

    import time
    deadline = time.time() + 1800
    last = -1
    while time.time() < deadline:
        time.sleep(5)
        if proc.poll() is not None:
            break                                       # the editor closed itself
        wanted, have = _import_state(project)
        if wanted and wanted <= have:
            break
        if len(have) != last:
            last = len(have)
            log(f"          imported {len(have)} / {len(wanted)}")
    try:
        proc.terminate()
        proc.wait(timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        try:
            proc.kill()
        except OSError:
            pass
    wanted, have = _import_state(project)
    if wanted and not (wanted <= have):
        log(f"warning:  only {len(have)} of {len(wanted)} textures were imported")
        return False
    return True


def _import_state(project: Path) -> tuple[set, set]:
    """Which textures the project asks for, and which are actually cached."""
    wanted: set = set()
    for sidecar in project.rglob("*.import"):
        if not sidecar.is_file():                       # `.import` is also a directory name
            continue
        try:
            text = sidecar.read_text(errors="ignore")
        except OSError:
            continue
        m = re.search(r'res://\.import/([^"\n]+\.stex)', text)
        if m:
            wanted.add(m.group(1))
    cache = project / ".import"
    have = {q.name for q in cache.glob("*.stex")} if cache.is_dir() else set()
    return wanted, have


def build_from_source(src: Path, *, apply: bool = True, local: bool = True,
                      launch: bool = True, godot: str | None = None,
                      owner: Path | None = None, label: str = "source",
                      export: bool = False, platform_target: str | None = None,
                      install: bool = False, shortcut: bool = False,
                      gdre: str | None = None) -> int:
    """Patch a decompiled project folder and run it with Godot's own binary.

    This is the route for a player who has the source tree but not a game executable: the folder
    is copied to build/game-src, the 27 diffs are applied to the copies, the 6 own files and the
    local art are added, and Godot is started with --path on the result.

    `owner` is the game install being replaced, if there was one. Its executable is an exported
    Godot game, which is a Godot 3.5 engine with the pack attached: it runs a project directory
    perfectly well, so a player who owns the game already has the engine and needs no download.
    """
    out = MANAGED / SOURCE_BUILD_DIR
    in_place = label == "recovered" and src.parent == MANAGED
    if in_place:
        # the recovered tree is already ours: patch it where it is instead of copying it again
        out = src
        log(f"recovered: {src}")
    else:
        if out.exists():
            shutil.rmtree(out)
        log(f"source:   {src}")
    if not in_place:
        log(f"copying:  source tree into build/{SOURCE_BUILD_DIR}")

    def on_error(err: OSError) -> None:
        log(f"warning:  could not copy {getattr(err, 'filename', '?')}: {err.strerror or err}")

    if not in_place:
        try:
            shutil.copytree(src, out, symlinks=True, ignore_dangling_symlinks=True,
                            copy_function=shutil.copy2)
        except shutil.Error as err:
            for _src, _dst, why in err.args[0]:
                log("warning:  " + str(why))

    index = load_index()
    patched, added, skipped = [], [], []
    if apply:
        for rel in index["upstream_edits"]:
            target = rel[:-len(".patch")]
            diff = PATCH / "modified" / rel
            dst = out / target
            if not dst.is_file():
                skipped.append(target + " (not in the source tree)")
                continue
            try:
                proc = subprocess.run(["patch", "--quiet", "-o", str(dst) + ".new", str(dst), str(diff)],
                                      capture_output=True, text=True)
            except OSError:
                die("the `patch` command is not available. Install GNU patch and try again.")
            if proc.returncode != 0:
                # `project.godot` is rebuilt from a compiled binary, so its comments, blank
                # lines and key order are the decompiler's, not the original's, and the diff
                # cannot land on it even though the settings are the same. We ship the whole
                # patched file, so use that: same result, no hunk matching.
                whole = PATCH / "modified" / target
                if whole.is_file() and whole.suffix in (".godot", ".cfg"):
                    shutil.copyfile(whole, dst)
                    for leftover in (Path(str(dst) + ".new"), Path(str(dst) + ".rej")):
                        leftover.unlink(missing_ok=True)
                    patched.append(target + " (whole file)")
                    continue
                skipped.append(target + " (diff did not apply)")
                continue
            os.replace(str(dst) + ".new", dst)
            patched.append(target)
        for rel in index["new_files"]:
            data = (PATCH / "modified" / rel).read_bytes()
            (out / rel).parent.mkdir(parents=True, exist_ok=True)
            (out / rel).write_bytes(data)
            added.append(rel)
        if local:
            for rel in index.get("local_only", []):
                srcf = LOCAL / rel
                if not srcf.exists():
                    continue
                (out / rel).parent.mkdir(parents=True, exist_ok=True)
                (out / rel).write_bytes(srcf.read_bytes())
                stem = Path(rel).stem
                for cache in (LOCAL / ".import").glob(stem + ".*"):
                    if cache.suffix in (".stex", ".md5"):
                        (out / ".import").mkdir(parents=True, exist_ok=True)
                        (out / ".import" / cache.name).write_bytes(cache.read_bytes())

    log(f"patched:  {len(patched)} upstream files, {len(added)} added")
    if skipped and not patched:
        die("not one diff applied to that source tree; it is a different version. Nothing was built.")
    if skipped:
        log(f"WARNING:  {len(skipped)} file(s) skipped — this build is PARTIAL.")
        for s in skipped[:8]:
            log("          " + s)

    # A recovered tree has the PNGs and the .import sidecars but not the compiled .stex textures
    # those sidecars name, so the engine can find no image and no scene until it has imported the
    # project once. This is the slowest step of the whole build — minutes, not seconds — and it
    # prints nothing while it works. It belongs here, before the "just build it" exit, because a
    # build without it cannot be run at all.
    godot_exe = ensure_godot(godot)
    if initialize_imports(out, godot_exe):
        log("imported: textures and resources are cached, so the game can load them")

    if export or install:
        return export_build(out, target=platform_target, install=install, shortcut=shortcut,
                            launch=launch, gdre=gdre, godot=godot)

    if not launch:
        log(f"built:    {out}")
        return 0
    if godot_exe is None:
        log(f"built:    {out}")
        log("")
        log("The patched project was built, but there is no Godot 3.5 engine to run it with.")
        log("Any of these fixes it:")
        log("  · pass --godot <path to a Godot 3.5 binary>")
        log("  · put a Godot 3.5 binary next to launcher.py")
        log("The engine is a free download: https://godotengine.org/download/3.x/")
        die("nothing left to do; the build itself is finished.")
    log(f"running:  {godot_exe} --path {out}")
    subprocess.Popen([str(godot_exe), "--path", str(out)], cwd=str(out))
    return 0


def detect_target(explicit: str | None = None) -> str:
    """This launcher builds Linux games only.

    Windows was supported for a while, but it could never be tested here, so rather than ship a
    path that was only ever believed to work it is gone. The code that names a platform is kept so
    `--target` still says something sensible if anyone passes it.
    """
    if explicit and explicit.lower() in ("win", "win64", "windows"):
        die("this launcher builds Linux games only; Windows is not supported.")
    if platform.system() != "Linux":
        die("this launcher runs on Linux only.")
    return "linux"


def export_build(project: Path, *, target: str | None = None, install: bool = False,
                 shortcut: bool = False, launch: bool = True,
                 gdre: str | None = None, godot: str | None = None) -> int:
    """Turn the patched project into a real game: template + pack, optionally installed."""
    target = detect_target(target)          # always "linux"; windows is refused
    log("")
    log(f"exporting: a {target} build")

    # The pack carries image references that point into the .import cache. Packing a project that
    # was never imported produces a game that starts and then fails on every texture, so make sure
    # the cache is complete before anything is packed.
    engine = ensure_godot(godot)
    if initialize_imports(project, engine):
        log("imported: textures rebuilt, so the packed game can load them")

    templates = ensure_export_templates()
    log(f"templates: {templates}")

    gdre_bin = ensure_gdre(gdre)
    binary = make_project_binary(project, gdre_bin, MANAGED / "bin")

    dist = MANAGED / "dist"
    if dist.exists():
        shutil.rmtree(dist)
    exe, pack_path = build_game(project, dist, target, binary)
    log(f"packed:   {pack_path.name}, {pack_path.stat().st_size:,} bytes")
    log(f"exe:      {exe.name}, {exe.stat().st_size:,} bytes")

    if not install and not shortcut:
        log(f"built:    {dist}")
        log("")
        log("That folder is a finished game: run the executable, keep it anywhere.")
        log("Add --install to copy it into place and --shortcut for a desktop icon.")
        return 0

    where = install_game(exe, pack_path, project)
    log(f"installed: {where}")
    if shortcut:
        made = make_desktop_shortcut(where / exe.name)
        if made:
            log(f"shortcut:  {made}")
        else:
            log("shortcut:  could not be created on this desktop")
    if launch:
        log(f"running:   {where / exe.name}")
        subprocess.Popen([str(where / exe.name)], cwd=str(where))
    return 0


def find_godot(explicit: str | None = None, owner: "Path | None" = None) -> Path | None:
    """A Godot 3.5 editor binary: the one given, one next to the launcher, or one on PATH.

    `owner` is accepted so callers can say where the game is, but it is not used as a fallback:
    see the note below.
    """
    if explicit:
        p = Path(explicit).expanduser()
        if p.is_file():
            return p
        die(f"--godot {p} is not a file")
    # Note: the game's own exported binary is deliberately NOT used as the engine. An exported
    # Godot game has its pack attached and refuses to load a project directory ("no main scene
    # defined in the project"), even for a project that a real editor binary runs fine.
    names = ["Godot_v3.5.1-stable_x11.64", "Godot_v3.5.1-stable_x11.32",
             "Godot_v3.5.1-stable_win64.exe", "Godot_v3.5.1-stable_osx.universal",
             "Godot_v3.5.1-stable_linux.x86_64", "godot3", "godot", "Godot"]
    for folder in (HERE, HERE.parent, Path.cwd()):
        try:
            for entry in folder.iterdir():
                if entry.is_file() and entry.name in names:
                    return entry
        except OSError:
            continue
    for name in names:
        found = shutil.which(name)
        if found:
            return Path(found)
    return None


def run(
    install_arg: str | None = None,
    *,
    verify: bool = False,
    unpack_only: bool = False,
    dry_run: bool = False,
    apply: bool = True,
    local: bool = True,
    launch: bool = True,
    interactive: bool = True,
    export: bool = False,
    target: str | None = None,
    install_flag: bool = False,
    shortcut: bool = False,
    uninstall: bool = False,
    godot: str | None = None,
    gdre: str | None = None,
) -> int:
    """Do the whole job. Returns a process exit code; raises LauncherError on user-fixable trouble."""
    if uninstall:
        return uninstall_game()

    install = find_install(install_arg, interactive=interactive)
    if is_source_project(install):
        return build_from_source(install, apply=apply, local=local, launch=launch, godot=godot,
                                 export=export, platform_target=target,
                                 install=install_flag, shortcut=shortcut, gdre=gdre)
    exe = find_executable(install)
    pack_path = find_pack(install, exe)
    log(f"game:     {install}")
    log(f"exe:      {exe.name}")
    log(f"data:     {pack_path.name}{' (embedded)' if pack_path == exe else ''}")

    MANAGED.mkdir(parents=True, exist_ok=True)
    source = _open_embedded(exe) if pack_path == exe else pack_path

    try:
        p = pck.Pck(source)
    except pck.PckError as exc:
        die(f"{source.name} is not a Godot pack: {exc}")
    log(f"pack:     {len(p.entries)} files, engine {p.version[0]}.{p.version[1]}.{p.version[2]}")

    if verify:
        return do_verify(p)
    if unpack_only:
        return do_unpack(p)

    entries = [(e.path, p.read(e.path)) for e in p.entries]
    bad = check_originals(entries)
    if bad:
        log(f"warning:  {len(bad)} upstream file(s) differ from the ones the patches were made against")
        for b in bad[:10]:
            log("          " + b)

    # Debug scaffolding must never reach a finished build: a leftover probe file is a script
    # error at boot in a build that is otherwise clean.
    stray_names = [Path(n).name for n, _ in entries
                   if Path(n).name.startswith("ZZProbe") or Path(n).name.startswith("ZZShot")]
    if stray_names:
        entries = [(n, d) for n, d in entries if Path(n).name not in stray_names]
        log(f"stripped: {len(stray_names)} debug file(s) from your pack: {', '.join(stray_names[:5])}")
        for i, (n, d) in enumerate(entries):
            if n != "res://project.godot":
                continue
            kept = []
            for line in d.decode("utf-8", "replace").splitlines():
                if any(("res://" + name) in line for name in stray_names):
                    continue          # an autoload pointing at a file we just removed
                kept.append(line)
            entries[i] = (n, ("\n".join(kept) + "\n").encode("utf-8"))

    if apply:
        ok, why = patchable(p)
        if not ok:
            # A compiled release is still usable: decompile it first, then patch the result.
            log(f"build:    {why}")
            log("          recovering it to source instead (decompile, patch, run)...")
            return build_from_pack(pack_path, apply=apply, local=local, launch=launch,
                                   godot=godot, gdre=gdre, install=install,
                                   export=export, target=target, install_flag=install_flag,
                                   shortcut=shortcut)
        entries, report = apply_patches(entries, allow_local=local)
        log(f"patched:  {len(report['patched'])} upstream files, {len(report['added'])} added")
        if report["skipped"] and not report["patched"]:
            die("not one of the diffs applied, so this is not the patched game. Nothing was built.")
        if report["skipped"]:
            log(f"WARNING:  {len(report['skipped'])} of {len(report['skipped']) + len(report['patched'])}"
                " patched files were skipped — the build will be PARTIAL and some features will "
                "be missing.")
            explain_skips(report["skipped"], [e[0] for e in entries])
        if report.get("local"):
            log(f"local:    {len(report['local'])} art/music file(s) from localspot/"
                f", {len(report.get('local_cache', []))} import cache(s)")
    else:
        log("patched:  none (patches skipped)")

    if dry_run:
        log("dry run:  nothing written")
        return 0

    staged = MANAGED / "staged.pck"
    size = pck.write_pck(staged, entries, engine=p.version)
    log(f"repacked: {len(entries)} files, {size} bytes")

    out_dir = MANAGED / "game"
    if out_dir.exists():
        shutil.rmtree(out_dir)
    if pack_path == exe:
        body = exe.read_bytes()[:embedded_offset(exe)]
        out_dir.mkdir(parents=True, exist_ok=True)
        out_exe = out_dir / exe.name
        out_exe.write_bytes(body + staged.read_bytes())
        log(f"wrote:    {out_exe}")
    else:
        copy_install(install, out_dir, pack_path, staged, exe)
        out_exe = out_dir / exe.name
        log(f"wrote:    {out_dir}")

    # A copied tree is only useful if it is runnable: keep the executable bit, and make sure the
    # launcher we are about to start actually survived the copy.
    if not out_exe.is_file():
        die(f"the build is there but {out_exe.name} is not — expected it next to "
            f"{pack_path.name}. Nothing was changed in your own copy.")
    if platform.system() != "Windows":
        try:
            os.chmod(out_exe, 0o755)
        except OSError:
            pass

    if not launch:
        log("not launching")
        return 0

    log(f"running:  {out_exe}")
    try:
        if platform.system() == "Darwin":
            subprocess.Popen(["open", str(out_exe)])
        else:
            subprocess.Popen([str(out_exe)], cwd=str(out_dir))
    except OSError as exc:
        die(f"built {out_dir} but could not start {out_exe.name}: {exc}. "
            "You can run it by hand from build/game/.")
    return 0


def do_verify(p: "pck.Pck") -> int:
    entries = [(e.path, p.read(e.path)) for e in p.entries]
    bad = check_originals(entries)
    log(f"engine:   {p.version[0]}.{p.version[1]}.{p.version[2]}")
    log(f"files:    {len(p.entries)}")
    have_originals = (PATCH / "original").is_dir()
    if not have_originals:
        log("note:     no patch/original/ in this clone, so versions are checked by presence only")
    if bad:
        log(f"MISMATCH: {len(bad)} upstream file(s) differ from the ones these patches were made against")
        for b in bad:
            log("          " + b)
        log("The patches may still apply cleanly; they will not be exact. Try a dry run.")
        return 2
    log("OK:       every patched file matches the upstream version these patches were made against")
    return 0


def do_unpack(p: "pck.Pck") -> int:
    dest = MANAGED / "unpacked"
    if dest.exists():
        shutil.rmtree(dest)
    n = p.extract_to(dest)
    log(f"unpacked  {n} files to {dest}")
    return 0


def open_folder(p: Path) -> None:
    if not p.exists():
        return
    system = platform.system()
    if system == "Windows":
        os.startfile(str(p))                      # type: ignore[attr-defined]
    elif system == "Darwin":
        subprocess.Popen(["open", str(p)])
    else:
        subprocess.Popen(["xdg-open", str(p)])


# ---------------------------------------------------------------- the window

class LauncherWindow:
    """A small, plain tkinter shell around run(). Nothing here does any game work itself."""

    def __init__(self, root: "tk.Tk", start_dir: str | None = None) -> None:
        self.root = root
        self.q: "queue.Queue[tuple[str, object]]" = queue.Queue()
        self.busy = False
        self.buttons: list["ttk.Button"] = []

        root.title("FULL PROJECT — launcher")
        root.minsize(780, 560)
        root.protocol("WM_DELETE_WINDOW", self._quit)

        base = tkfont.nametofont("TkDefaultFont")
        self.f_title = base.copy()
        self.f_title.configure(size=max(base.cget("size"), 10) + 8, weight="bold")
        self.f_sub = base.copy()
        self.f_sub.configure(size=max(base.cget("size"), 9))

        style = ttk.Style(root)
        try:
            style.configure("Accent.TButton", font=(base.cget("family"), base.cget("size") + 1, "bold"))
        except tk.TclError:      # pragma: no cover - depends on the platform theme
            pass

        outer = ttk.Frame(root, padding=(16, 14, 16, 10))
        outer.pack(fill="both", expand=True)
        outer.columnconfigure(0, weight=1)
        outer.rowconfigure(5, weight=1)

        # header
        head = ttk.Frame(outer)
        head.grid(row=0, column=0, sticky="ew")
        ttk.Label(head, text="FULL PROJECT", font=self.f_title).pack(anchor="w")
        ttk.Label(
            head,
            text="Your Only Move Is HUSTLE — controller-first, fully offline. "
                 "Patches a copy of the game you own; never changes the original.",
            font=self.f_sub,
        ).pack(anchor="w", pady=(2, 0))

        # game folder
        gamedir = ttk.Frame(outer)
        gamedir.grid(row=1, column=0, sticky="ew", pady=(14, 0))
        gamedir.columnconfigure(1, weight=1)
        ttk.Label(gamedir, text="Game folder").grid(row=0, column=0, padx=(0, 8))
        self.dir_var = tk.StringVar()
        self.dir_entry = ttk.Entry(gamedir, textvariable=self.dir_var)
        self.dir_entry.grid(row=0, column=1, sticky="ew")
        self.browse_btn = ttk.Button(gamedir, text="Browse…", command=self._browse)
        self.browse_btn.grid(row=0, column=2, padx=(8, 0))
        self.buttons.append(self.browse_btn)

        found_row = ttk.Frame(outer)
        found_row.grid(row=2, column=0, sticky="ew", pady=(4, 0))
        found_row.columnconfigure(1, weight=1)
        self.found = ttk.Label(found_row, text="", font=self.f_sub, foreground="#666")
        self.found.grid(row=0, column=0, sticky="w")
        # Only meaningful when there is more than one copy on the machine.
        self.alt = ttk.Combobox(found_row, state="readonly", values=[])
        self.alt.grid(row=0, column=1, sticky="ew", padx=(10, 0))
        self.alt.grid_remove()
        self.alt.bind("<<ComboboxSelected>>", self._picked_alt)
        self.dir_var.trace_add("write", lambda *_: self._schedule_probe())

        # No options any more. Every build does the same thing - decompile if needed, patch,
        # import, build a real Linux game, install it, and put the icon on the desktop - so there
        # is nothing here to choose and nothing to get wrong.

        # buttons
        bar = ttk.Frame(outer)
        bar.grid(row=4, column=0, sticky="ew", pady=(12, 8))
        self.build_btn = ttk.Button(bar, text="Build and install", style="Accent.TButton",
                                    command=lambda: self._start("build"))
        self.build_btn.pack(side="left")
        quit_btn = ttk.Button(bar, text="Quit", command=self._quit)
        quit_btn.pack(side="right")
        self.buttons.extend([self.build_btn])

        # log
        logframe = ttk.Frame(outer)
        logframe.grid(row=5, column=0, sticky="nsew")
        logframe.columnconfigure(0, weight=1)
        logframe.rowconfigure(0, weight=1)
        self.text = tk.Text(logframe, height=14, wrap="word", state="disabled", relief="solid",
                            borderwidth=1, bg="#11161a", fg="#d7dee6", insertbackground="#d7dee6",
                            font=tkfont.nametofont("TkFixedFont"))
        self.text.grid(row=0, column=0, sticky="nsew")
        scroll = ttk.Scrollbar(logframe, orient="vertical", command=self.text.yview)
        scroll.grid(row=0, column=1, sticky="ns")
        self.text.configure(yscrollcommand=scroll.set)

        # status bar
        status = ttk.Frame(outer)
        status.grid(row=6, column=0, sticky="ew", pady=(8, 0))
        self.progress = ttk.Progressbar(status, mode="indeterminate", length=140)
        self.progress.pack(side="left")
        self.status_var = tk.StringVar(value="ready")
        ttk.Label(status, textvariable=self.status_var, font=self.f_sub).pack(side="left", padx=(10, 0))
        ttk.Button(status, text="Open build folder",
                   command=lambda: open_folder(MANAGED)).pack(side="right")
        ttk.Button(status, text="Clear log", command=self._clear).pack(side="right", padx=(0, 8))

        self._say("FULL PROJECT launcher.")
        self._say("Pick the folder that holds the game's executable and its data.pck — "
                  "the copy you own. Nothing is written there.")
        self._say("")
        self._say("Building from a Steam install takes a while and prints nothing while it")
        self._say("works. It is not stuck: give it at least 10 minutes before worrying.")

        if start_dir:
            p = Path(start_dir).expanduser()
            if p.is_dir():
                self.dir_var.set(str(p))
                self.found.configure(text="using the folder you passed in")
        else:
            self.scan()

        self._centre()
        self._drain()

    # -- helpers ---------------------------------------------------
    def _centre(self) -> None:
        self.root.update_idletasks()
        w, h = 900, 640
        x = max((self.root.winfo_screenwidth() - w) // 2, 0)
        y = max((self.root.winfo_screenheight() - h) // 3, 0)
        self.root.geometry(f"{w}x{h}+{x}+{y}")

    def _say(self, line: str) -> None:
        self.text.configure(state="normal")
        self.text.insert("end", line + "\n")
        self.text.see("end")
        self.text.configure(state="disabled")

    def _clear(self) -> None:
        self.text.configure(state="normal")
        self.text.delete("1.0", "end")
        self.text.configure(state="disabled")

    def scan(self) -> None:
        """Look for copies of the game and offer every one of them."""
        self.found.configure(text="looking for your copy of the game…")
        self.root.update_idletasks()

        def work() -> None:
            try:
                found = [str(p) for p in detect_installs()]
            except Exception:                              # noqa: BLE001 - never break the window
                found = []
            self.q.put(("found", found))

        threading.Thread(target=work, daemon=True).start()

    def _show_found(self, found: list[str]) -> None:
        if not found:
            self.found.configure(text="no copy found automatically — use Browse…")
            self.alt.grid_remove()
            return
        self.found.configure(text=("found it" if len(found) == 1 else
                                   f"found {len(found)} copies — pick one, or Browse…"))
        self.dir_var.set(found[0])
        self._schedule_probe()
        if len(found) > 1:
            self.alt.configure(values=found)
            self.alt.set(found[0])
            self.alt.grid()
        else:
            self.alt.grid_remove()

    def _picked_alt(self, _event=None) -> None:
        chosen = self.alt.get()
        if chosen:
            self.dir_var.set(chosen)

    def _schedule_probe(self) -> None:
        """Check the folder shortly after it changes, so the warning arrives before the build."""
        if getattr(self, "_probe_job", None):
            self.root.after_cancel(self._probe_job)
        self._probe_job = self.root.after(700, self._probe)

    def _probe(self) -> None:
        self._probe_job = None
        folder = self.dir_var.get().strip()
        if not folder:
            return

        def work() -> None:
            self.q.put(("probe", probe_folder(folder)))

        threading.Thread(target=work, daemon=True).start()

    def _show_probe(self, result: dict) -> None:
        if not result.get("ok"):
            self.found.configure(text=f"not a game folder ({result.get('why')})",
                                 foreground="#a33")
            if not self.busy:
                self.build_btn.state(["disabled"])
            return
        if result.get("can_patch"):
            kind = "source folder" if result.get("source") else result["exe"]
            self.found.configure(
                text=f"{kind}  ·  {result['pack']}  ·  {result['files']} files  ·  "
                     f"ready", foreground="#2a7")
            self.build_btn.configure(text="Build and install")
            self.build_btn.state(["!disabled"])
        elif result.get("recoverable"):
            # a compiled release: it cannot be patched as it stands, but it can be recovered
            # and then patched, which is the whole point of the decompile path
            self.found.configure(
                text=f"{result['exe']}  ·  {result['pack']}  ·  {result['files']} files  ·  "
                     f"will be decompiled, patched and rebuilt", foreground="#a77")
            self.build_btn.configure(text="Build and install")
            self.build_btn.state(["!disabled"])
            self._say("")
            self._say("this is a compiled release, so it gets recovered first:")
            for line in textwrap.wrap(result["why"], 100):
                self._say("  " + line)
            self._say("  the launcher will decompile it, apply the patches, and run the result.")
        else:
            self.found.configure(text="this copy cannot be patched — see the log",
                                 foreground="#a33")
            if not self.busy:
                self.build_btn.state(["disabled"])
            self.build_btn.configure(text="Build and run (needs a source build)")
            self._say("")
            self._say("cannot patch this copy:")
            for line in textwrap.wrap(result["why"], 100):
                self._say("  " + line)
            self._say("  you need the decompiled source build — the folder with project.godot.")

    def _browse(self) -> None:
        start = self.dir_var.get() or str(Path.home())
        chosen = filedialog.askdirectory(title="Where is Your Only Move Is HUSTLE?", initialdir=start)
        if chosen:
            self.dir_var.set(chosen)
            self.found.configure(text="")

    def _set_busy(self, busy: bool) -> None:
        self.busy = busy
        for b in self.buttons:
            b.state(["disabled"] if busy else ["!disabled"])
        self.dir_entry.state(["disabled"] if busy else ["!disabled"])

    def _quit(self) -> None:
        if self.busy and not messagebox.askokcancel(
                "Still working", "The current job has not finished. Quit anyway?"):
            return
        self.root.destroy()

    # -- the job ---------------------------------------------------
    def _start(self, mode: str) -> None:
        if self.busy:
            return
        folder = self.dir_var.get().strip()
        if not folder:
            messagebox.showwarning("No game folder", "Choose the folder your copy of the game is in.")
            return
        if not Path(folder).expanduser().is_dir():
            messagebox.showerror("Not a folder", f"{folder}\nis not a directory.")
            return

        self._set_busy(True)
        self.progress.start(12)
        self.status_var.set("building, please wait…")
        threading.Thread(target=self._work, args=(mode, folder), daemon=True).start()

    def _work(self, mode: str, folder: str) -> None:
        sink = lambda line: self.q.put(("log", line))       # noqa: E731
        set_sink(sink)
        try:
            code = run(folder, interactive=False, export=True, target="linux",
                       install_flag=True, shortcut=True, launch=False)
            self.q.put(("done", code))
        except LauncherError as exc:
            self.q.put(("error", str(exc)))
        except Exception as exc:                            # noqa: BLE001 - show, never crash silently
            self.q.put(("error", f"{type(exc).__name__}: {exc}"))
        finally:
            set_sink(None)

    def _drain(self) -> None:
        try:
            while True:
                kind, payload = self.q.get_nowait()
                if kind == "log":
                    self._say(str(payload))
                elif kind == "done":
                    self._finished(int(payload))            # type: ignore[arg-type]
                elif kind == "error":
                    self._failed(str(payload))
                elif kind == "found":
                    self._show_found(list(payload))
                elif kind == "probe":
                    self._show_probe(dict(payload))
        except queue.Empty:
            pass
        self.root.after(80, self._drain)

    def _finished(self, code: int) -> None:
        self.progress.stop()
        self._set_busy(False)
        if code == 0:
            self.status_var.set("done")
            self._say("")
            self._say("done.")
        else:
            self.status_var.set(f"finished with code {code}")
            self._say("")
            self._say(f"finished with code {code} — see the messages above.")

    def _failed(self, message: str) -> None:
        self.progress.stop()
        self._set_busy(False)
        self.status_var.set("error")
        self._say("")
        self._say("ERROR: " + message)
        messagebox.showerror("FULL PROJECT", message)


def gui_main(start_dir: str | None = None) -> int:
    try:
        root = tk.Tk()
    except Exception as exc:                                # noqa: BLE001 - headless, no display
        print(f"no display for the launcher window ({exc}).", file=sys.stderr)
        print("Run it in a terminal instead:  python3 launcher.py --cli", file=sys.stderr)
        return 1
    LauncherWindow(root, start_dir=start_dir)
    root.mainloop()
    return 0


# ---------------------------------------------------------------- the terminal

def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="launcher.py",
        description="Unpack, patch, repack and run your own copy of the game.",
        epilog="With no arguments this opens the launcher window. Any action flag below implies "
               "--cli, so scripts keep working unchanged.",
    )
    ap.add_argument("--gui", action="store_true", help="open the window, even with action flags")
    ap.add_argument("--cli", action="store_true", help="stay in the terminal (no window)")
    ap.add_argument("--game", help="folder containing the game executable and data.pck")
    ap.add_argument("--dry-run", action="store_true", help="report only, write nothing")
    ap.add_argument("--unpack-only", action="store_true", help="unpack your copy and stop")
    ap.add_argument("--no-apply", action="store_true", help="repack without the patches")
    ap.add_argument("--no-run", action="store_true", help="build but do not launch")
    ap.add_argument("--no-local", action="store_true", help="skip the local-only art and music")
    ap.add_argument("--verify", action="store_true", help="check the patch set against your copy")
    ap.add_argument("--godot", help="the Godot 3.5 binary to run a source folder with")
    ap.add_argument("--gdre", help="path to gdre_tools, if it is not already here")
    ap.add_argument("--export", action="store_true",
                    help="build a real game (template + .pck) instead of running the project folder")
    ap.add_argument("--target", choices=["auto", "linux"], default="auto",
                    help="which platform to build for (default: this machine)")
    ap.add_argument("--install", action="store_true",
                    help="copy the built game into your application folder")
    ap.add_argument("--shortcut", action="store_true", help="put a desktop icon in place")
    ap.add_argument("--uninstall", action="store_true",
                    help="remove an installed copy and its desktop icon")
    return ap


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    args = build_parser().parse_args(argv)

    action = any((args.dry_run, args.verify, args.unpack_only, args.no_apply,
                  args.no_run, args.no_local))
    want_gui = args.gui or (not args.cli and not action)

    if want_gui:
        if HAVE_TK:
            return gui_main(args.game)
        print("this Python has no tkinter, so the window is unavailable.", file=sys.stderr)
        print("falling back to the terminal launcher.", file=sys.stderr)

    try:
        return run(
            args.game,
            verify=args.verify,
            unpack_only=args.unpack_only,
            dry_run=args.dry_run,
            apply=not args.no_apply,
            local=not args.no_local,
            launch=not args.no_run,
            godot=args.godot,
            gdre=args.gdre,
            export=args.export,
            target=args.target,
            install_flag=args.install,
            shortcut=args.shortcut,
            uninstall=args.uninstall,
        )
    except LauncherError:
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
