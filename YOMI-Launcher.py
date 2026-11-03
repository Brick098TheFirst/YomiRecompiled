#!/usr/bin/env python3
"""Your Only Move Is RECOMPILED - the little window on your desktop.

Three buttons and nothing else:

    Launch      start the game you have installed
    Update      rebuild it from your own copy of the game, then install the result
    Uninstall   remove the installed game and this shortcut

This file is deliberately standalone: it only needs Python 3 and tkinter, both of which come with
Python on Windows and macOS and with most Linux distributions. It keeps its settings in
launcher-settings.json next to itself.
"""
from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

GAME_NAME = "YourOnlyMoveIsRECOMPILED"
HERE = Path(__file__).resolve().parent
SETTINGS = HERE / "launcher-settings.json"


def app_dir() -> Path:
    system = platform.system()
    if system == "Windows":
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
        return base / "Programs" / GAME_NAME
    if system == "Darwin":
        return Path.home() / "Applications" / GAME_NAME
    return Path.home() / ".local" / "share" / GAME_NAME


def desktop_dir() -> Path:
    for name in ("Desktop", "Escritorio", "Bureau", "Schreibtisch", "桌面", "デスクトップ"):
        d = Path.home() / name
        if d.is_dir():
            return d
    return Path.home() / "Desktop"


def installed_exe() -> Path | None:
    system = platform.system()
    name = GAME_NAME + (".exe" if system == "Windows" else ".x86_64")
    candidate = app_dir() / name
    return candidate if candidate.is_file() else None


def load_settings() -> dict:
    try:
        return json.loads(SETTINGS.read_text())
    except (OSError, ValueError):
        return {}


def save_settings(data: dict) -> None:
    try:
        SETTINGS.write_text(json.dumps(data, indent=2))
    except OSError:
        pass


class Window:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.busy = False
        root.title("Your Only Move Is RECOMPILED")
        root.geometry("620x430")
        root.minsize(560, 400)
        self.set_window_icon()

        style = ttk.Style()
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass

        head = ttk.Frame(root, padding=(18, 16, 18, 6))
        head.pack(fill="x")
        ttk.Label(head, text="Your Only Move Is RECOMPILED",
                  font=("Helvetica", 19, "bold")).pack(anchor="w")
        ttk.Label(head, text="A private, offline build. Controller-first, no services.",
                  foreground="#555").pack(anchor="w")

        body = ttk.Frame(root, padding=(18, 8, 18, 8))
        body.pack(fill="both", expand=True)

        self.status = ttk.Label(body, text="", font=("Helvetica", 11, "bold"))
        self.status.pack(anchor="w", pady=(2, 10))

        row = ttk.Frame(body)
        row.pack(fill="x", pady=(0, 12))
        self.play_btn = ttk.Button(row, text="Launch", command=self.launch, width=16)
        self.play_btn.pack(side="left")
        self.update_btn = ttk.Button(row, text="Update", command=self.update, width=16)
        self.update_btn.pack(side="left", padx=(10, 0))
        self.remove_btn = ttk.Button(row, text="Uninstall", command=self.uninstall, width=16)
        self.remove_btn.pack(side="left", padx=(10, 0))

        src = ttk.LabelFrame(body, text="Where your own copy of the game is", padding=10)
        src.pack(fill="x", pady=(0, 10))
        self.folder = tk.StringVar(value=load_settings().get("game_folder", ""))
        picker = ttk.Frame(src)
        picker.pack(fill="x")
        entry = ttk.Entry(picker, textvariable=self.folder)
        entry.pack(side="left", fill="x", expand=True)
        ttk.Button(picker, text="Browse...", command=self.browse, width=10).pack(side="left", padx=(8, 0))
        ttk.Label(src, text="Used by Update. Nothing in that folder is ever changed.",
                  foreground="#777").pack(anchor="w", pady=(7, 0))

        logbox = ttk.Frame(body)
        logbox.pack(fill="both", expand=True)
        self.log = tk.Text(logbox, height=8, wrap="word", relief="flat", bg="#1b1b1b",
                           fg="#d8d8d8", insertbackground="#d8d8d8", font=("Menlo", 9))
        self.log.pack(side="left", fill="both", expand=True)
        bar = ttk.Scrollbar(logbox, command=self.log.yview)
        bar.pack(side="right", fill="y")
        self.log.configure(yscrollcommand=bar.set)
        self.log.configure(state="disabled")

        foot = ttk.Frame(root, padding=(18, 0, 18, 14))
        foot.pack(fill="x")
        self.progress = ttk.Progressbar(foot, mode="indeterminate", length=180, value=0)
        self.progress.pack(side="left")
        ttk.Button(foot, text="Quit", command=root.destroy).pack(side="right")

        self.say("Ready.")
        self.refresh()

    # ---------------------------------------------------------------- helpers
    def set_window_icon(self) -> None:
        """Give the window its own icon so it is recognisable in a taskbar or dock."""
        for candidate in (HERE / "icon.png", HERE / "icon.gif"):
            if not candidate.is_file():
                continue
            try:
                if candidate.suffix == ".gif":
                    self._icon = tk.PhotoImage(file=str(candidate))
                else:
                    self._icon = tk.PhotoImage(file=str(candidate))
                self.root.iconphoto(True, self._icon)
                return
            except (tk.TclError, OSError):
                continue

    def say(self, message: str) -> None:
        self.log.configure(state="normal")
        self.log.insert("end", message.rstrip() + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def refresh(self) -> None:
        """Enable what can be done right now and say what that is."""
        exe = installed_exe()
        if exe:
            self.status.configure(text="Installed and ready.", foreground="#1a7f37")
            self.play_btn.state(["!disabled"])
        else:
            self.status.configure(text="Not installed yet. Use Update to build it.",
                                  foreground="#a15c00")
            self.play_btn.state(["disabled"])
        has_source = bool(self.folder.get().strip())
        self.update_btn.state(["disabled"] if self.busy or not has_source else ["!disabled"])

    def set_busy(self, busy: bool) -> None:
        self.busy = busy
        if busy:
            self.progress.start(12)
            for b in (self.play_btn, self.update_btn, self.remove_btn):
                b.state(["disabled"])
        else:
            self.progress.stop()
            self.refresh()

    def browse(self) -> None:
        chosen = filedialog.askdirectory(
            title="Where is Your Only Move Is HUSTLE?",
            initialdir=self.folder.get() or str(Path.home()))
        if chosen:
            self.folder.set(chosen)
            data = load_settings()
            data["game_folder"] = chosen
            save_settings(data)
            self.refresh()

    # ---------------------------------------------------------------- actions
    def launch(self) -> None:
        exe = installed_exe()
        if not exe:
            messagebox.showinfo("Not installed", "Use Update first to build and install the game.")
            return
        self.say(f"Launching {exe.name}")
        try:
            subprocess.Popen([str(exe)], cwd=str(exe.parent))
        except OSError as exc:
            self.say(f"Could not start it: {exc}")
            messagebox.showerror("Could not launch", str(exc))

    def update(self) -> None:
        folder = self.folder.get().strip()
        if not folder:
            messagebox.showinfo("Where is the game?",
                                "Pick the folder holding the copy of the game you own first.")
            return
        # the full toolchain lives next to this file when installed from the repo
        tool = HERE / "launcher.py"
        if not tool.is_file():
            tool = Path(folder) / "launcher.py"
        if not tool.is_file():
            messagebox.showerror(
                "Can't find the builder",
                "launcher.py needs to sit next to this file.\n\n"
                "Copy it beside YOMI-Launcher.py and try again.")
            return

        self.set_busy(True)
        self.say("")
        self.say("Rebuilding from your copy. This takes a while and prints little "
                 "while it works - give it at least 10 minutes.")
        command = [sys.executable, str(tool), "--cli", "--game", folder,
                   "--export", "--install", "--shortcut", "--no-run"]

        def work() -> None:
            try:
                proc = subprocess.Popen(command, cwd=str(tool.parent), stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, text=True, bufsize=1)
                for line in proc.stdout or []:
                    self.root.after(0, self.say, line.rstrip())
                proc.wait()
                ok = proc.returncode == 0
            except OSError as exc:
                self.root.after(0, self.say, f"failed to start the builder: {exc}")
                ok = False
            self.root.after(0, self.done, ok)

        threading.Thread(target=work, daemon=True).start()

    def done(self, ok: bool) -> None:
        self.set_busy(False)
        if ok:
            self.say("Done. The game is installed and the desktop icon is in place.")
        else:
            self.say("That did not finish. The messages above say why.")

    def uninstall(self) -> None:
        if not messagebox.askokcancel(
                "Uninstall", "Remove the installed game and the desktop icon?\n\n"
                             "Your saves and replays are kept."):
            return
        target = app_dir()
        if target.is_dir():
            shutil.rmtree(target, ignore_errors=True)
            self.say(f"Removed {target}")
        for name in (GAME_NAME + ".desktop", GAME_NAME + ".lnk"):
            shortcut = desktop_dir() / name
            if shortcut.is_file():
                try:
                    shortcut.unlink()
                    self.say(f"Removed {shortcut}")
                except OSError:
                    pass
        self.refresh()


def main() -> int:
    root = tk.Tk()
    Window(root)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
