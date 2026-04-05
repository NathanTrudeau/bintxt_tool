"""
ui/app.py — bintxt_tool Desktop UI

Requires only Python standard library (tkinter + zipfile + threading + pathlib).
No pip installs. Run from the repo root:

    python3 ui/app.py

Or double-click a launcher script.
"""

import os
import shutil
import sys
import threading
import zipfile
from datetime import datetime
from pathlib import Path
from tkinter import (
    BooleanVar, Button, Entry, Frame, Label, Scrollbar, StringVar,
    Text, Tk, filedialog, font, messagebox, ttk
)
import tkinter as tk

# ── Resolve repo root ─────────────────────────────────────────────────────────
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from core.config import load as load_config, absdirs
from core.convert import (
    bin_to_txt, txt_to_bin, validate_txt_format, normalize_txt,
    sha256_file, verify_bin_to_txt, verify_txt_to_bin
)
from core.compare import fingerprint_file, group_by_hash, format_group_report

# ── Colors & fonts ────────────────────────────────────────────────────────────
BG       = "#1e1e2e"
PANEL    = "#2a2a3e"
BORDER   = "#3a3a5a"
FG       = "#e0e0f0"
FG_DIM   = "#888aaa"
ACCENT   = "#7c6af7"
GREEN    = "#4ade80"
RED      = "#f87171"
YELLOW   = "#facc15"
CYAN     = "#67e8f9"

FONT_MONO = ("Courier New", 10)
FONT_UI   = ("Segoe UI", 10)
FONT_HEAD = ("Segoe UI", 12, "bold")
FONT_TINY = ("Segoe UI", 8)


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def _cfg():
    raw = load_config(str(REPO_ROOT))
    return absdirs(raw, str(REPO_ROOT))


def _ensure_dirs(cfg):
    for key in ("input_dir", "output_dir", "report_dir"):
        Path(cfg[key]).mkdir(parents=True, exist_ok=True)


# ─────────────────────────────────────────────────────────────────────────────
# Main App
# ─────────────────────────────────────────────────────────────────────────────

class BintxtApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("bintxt_tool")
        self.configure(bg=BG)
        self.resizable(True, True)
        self.minsize(820, 580)

        # Load config once; refresh on each run
        self._cfg = _cfg()
        _ensure_dirs(self._cfg)

        self._build_ui()
        self._refresh_file_list()

        # Center window
        self.update_idletasks()
        w, h = 960, 660
        x = (self.winfo_screenwidth() - w) // 2
        y = (self.winfo_screenheight() - h) // 2
        self.geometry(f"{w}x{h}+{x}+{y}")

    # ── UI construction ───────────────────────────────────────────────────────

    def _build_ui(self):
        # Header bar
        hdr = Frame(self, bg=PANEL, pady=10)
        hdr.pack(fill="x")
        Label(hdr, text="bintxt_tool", bg=PANEL, fg=ACCENT,
              font=("Segoe UI", 16, "bold")).pack(side="left", padx=16)
        Label(hdr, text="binary ↔ text conversion", bg=PANEL, fg=FG_DIM,
              font=FONT_UI).pack(side="left")

        cfg_label = f"  layout: {'+'.join(str(w)+'B' for w in self._cfg['word_sizes'])}  ·  endian: {self._cfg['endian']}"
        Label(hdr, text=cfg_label, bg=PANEL, fg=FG_DIM,
              font=FONT_TINY).pack(side="right", padx=16)

        # Main area: left panel + log
        main = Frame(self, bg=BG)
        main.pack(fill="both", expand=True, padx=12, pady=8)

        left = Frame(main, bg=BG, width=320)
        left.pack(side="left", fill="y", padx=(0, 8))
        left.pack_propagate(False)

        right = Frame(main, bg=BG)
        right.pack(side="left", fill="both", expand=True)

        self._build_left(left)
        self._build_log(right)

        # Bottom bar
        self._build_bottom()

    def _build_left(self, parent):
        # ── Drop zone ─────────────────────────────────────────────────────────
        Label(parent, text="INPUT FILES", bg=BG, fg=FG_DIM,
              font=FONT_TINY).pack(anchor="w", pady=(0, 4))

        drop_frame = Frame(parent, bg=PANEL, relief="flat",
                           highlightbackground=BORDER, highlightthickness=1)
        drop_frame.pack(fill="x", pady=(0, 6))

        self._drop_label = Label(
            drop_frame,
            text="drag & drop  .bin / .txt\nor click to browse",
            bg=PANEL, fg=FG_DIM, font=FONT_UI,
            cursor="hand2", pady=18
        )
        self._drop_label.pack(fill="x")
        self._drop_label.bind("<Button-1>", lambda _: self._browse_files())

        # Enable native drag-and-drop if tkinterdnd2 is available; fall back to browse
        try:
            self.drop_target_register("*")
            self.dnd_bind("<<Drop>>", self._on_drop)
        except Exception:
            pass

        # File list
        list_frame = Frame(parent, bg=PANEL,
                           highlightbackground=BORDER, highlightthickness=1)
        list_frame.pack(fill="both", expand=True, pady=(0, 8))

        Label(list_frame, text="staged for input/", bg=PANEL, fg=FG_DIM,
              font=FONT_TINY, pady=4).pack(anchor="w", padx=8)

        self._file_listbox = tk.Listbox(
            list_frame, bg=PANEL, fg=FG, selectbackground=ACCENT,
            selectforeground="white", font=FONT_MONO,
            relief="flat", borderwidth=0, highlightthickness=0
        )
        self._file_listbox.pack(fill="both", expand=True, padx=4, pady=(0, 4))

        btn_row = Frame(list_frame, bg=PANEL)
        btn_row.pack(fill="x", padx=4, pady=(0, 6))
        self._btn(btn_row, "Add files", self._browse_files, ACCENT).pack(side="left", padx=(0, 4))
        self._btn(btn_row, "Clear", self._clear_input, "#555").pack(side="left")

        # ── Actions ───────────────────────────────────────────────────────────
        Label(parent, text="ACTIONS", bg=BG, fg=FG_DIM,
              font=FONT_TINY).pack(anchor="w", pady=(4, 4))

        actions = Frame(parent, bg=BG)
        actions.pack(fill="x")

        self._btn(actions, "▶  Convert", self._run_convert, ACCENT,
                  width=18).pack(fill="x", pady=2)
        self._btn(actions, "✏  Draft", self._run_draft, "#5a5faa",
                  width=18).pack(fill="x", pady=2)
        self._btn(actions, "✔  Apply Drafts", self._run_apply, "#3a6e4a",
                  width=18).pack(fill="x", pady=2)
        self._btn(actions, "🔍  Compare", self._run_compare, "#6a4a7a",
                  width=18).pack(fill="x", pady=2)

    def _build_log(self, parent):
        Label(parent, text="STATUS LOG", bg=BG, fg=FG_DIM,
              font=FONT_TINY).pack(anchor="w", pady=(0, 4))

        log_frame = Frame(parent, bg=PANEL,
                          highlightbackground=BORDER, highlightthickness=1)
        log_frame.pack(fill="both", expand=True)

        self._log = Text(
            log_frame, bg=PANEL, fg=FG, font=FONT_MONO,
            relief="flat", borderwidth=0, state="disabled",
            wrap="word", pady=8, padx=8
        )
        sb = Scrollbar(log_frame, command=self._log.yview, bg=PANEL)
        self._log.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y")
        self._log.pack(fill="both", expand=True)

        # Tag colors
        self._log.tag_configure("ok",     foreground=GREEN)
        self._log.tag_configure("err",    foreground=RED)
        self._log.tag_configure("warn",   foreground=YELLOW)
        self._log.tag_configure("info",   foreground=CYAN)
        self._log.tag_configure("head",   foreground=ACCENT, font=("Segoe UI", 10, "bold"))
        self._log.tag_configure("dim",    foreground=FG_DIM)

        btn_row = Frame(parent, bg=BG)
        btn_row.pack(fill="x", pady=(4, 0))
        self._btn(btn_row, "Clear log", self._clear_log, "#555").pack(side="left")
        self._btn(btn_row, "Open output/", self._open_output, "#555").pack(side="left", padx=4)

    def _build_bottom(self):
        bar = Frame(self, bg=PANEL, pady=8)
        bar.pack(fill="x", side="bottom")

        Label(bar, text="Package as zip:", bg=PANEL, fg=FG,
              font=FONT_UI).pack(side="left", padx=(12, 4))

        self._zip_name = StringVar(value=f"bintxt_export_{datetime.now().strftime('%Y%m%d')}")
        Entry(bar, textvariable=self._zip_name, bg=BORDER, fg=FG,
              font=FONT_UI, relief="flat", width=28,
              insertbackground=FG).pack(side="left", padx=(0, 4))

        Label(bar, text=".zip", bg=PANEL, fg=FG_DIM,
              font=FONT_UI).pack(side="left", padx=(0, 12))

        self._btn(bar, "📦  Package", self._run_package, ACCENT).pack(side="left")
        self._status_var = StringVar(value="Ready")
        Label(bar, textvariable=self._status_var, bg=PANEL, fg=FG_DIM,
              font=FONT_TINY).pack(side="right", padx=12)

    # ── Widget helpers ────────────────────────────────────────────────────────

    def _btn(self, parent, text, cmd, color=ACCENT, width=None):
        kw = dict(text=text, command=cmd, bg=color, fg="white",
                  font=FONT_UI, relief="flat", cursor="hand2",
                  padx=10, pady=4, activebackground=color, activeforeground="white")
        if width:
            kw["width"] = width
        return Button(parent, **kw)

    # ── Logging ───────────────────────────────────────────────────────────────

    def _log_write(self, msg, tag=""):
        self._log.configure(state="normal")
        self._log.insert("end", msg + "\n", tag)
        self._log.see("end")
        self._log.configure(state="disabled")

    def log(self, msg):       self._log_write(f"  {msg}")
    def log_ok(self, msg):    self._log_write(f"  ✓  {msg}", "ok")
    def log_err(self, msg):   self._log_write(f"  ✗  {msg}", "err")
    def log_warn(self, msg):  self._log_write(f"  ⚠  {msg}", "warn")
    def log_info(self, msg):  self._log_write(f"  →  {msg}", "info")
    def log_head(self, msg):  self._log_write(f"\n{msg}", "head")
    def log_dim(self, msg):   self._log_write(f"     {msg}", "dim")

    def _clear_log(self):
        self._log.configure(state="normal")
        self._log.delete("1.0", "end")
        self._log.configure(state="disabled")

    def _set_status(self, msg):
        self._status_var.set(msg)
        self.update_idletasks()

    # ── File management ───────────────────────────────────────────────────────

    def _browse_files(self):
        paths = filedialog.askopenfilenames(
            title="Select .bin or .txt files",
            filetypes=[("Binary/Text files", "*.bin *.txt"), ("All files", "*.*")]
        )
        if paths:
            self._stage_files(paths)

    def _on_drop(self, event):
        paths = self.tk.splitlist(event.data)
        self._stage_files(paths)

    def _stage_files(self, paths):
        cfg = _cfg()
        _ensure_dirs(cfg)
        in_dir = Path(cfg["input_dir"])
        for p in paths:
            src = Path(p)
            if src.suffix.lower() in (".bin", ".txt"):
                dst = in_dir / src.name
                shutil.copy2(str(src), str(dst))
                self.log_info(f"Staged: {src.name}")
        self._refresh_file_list()

    def _refresh_file_list(self):
        cfg = _cfg()
        in_dir = Path(cfg["input_dir"])
        self._file_listbox.delete(0, "end")
        for f in sorted(in_dir.glob("*")):
            if f.suffix.lower() in (".bin", ".txt"):
                size = f.stat().st_size
                label = f"  {f.name:<30}  {size:>6} B"
                self._file_listbox.insert("end", label)

    def _clear_input(self):
        cfg = _cfg()
        in_dir = Path(cfg["input_dir"])
        removed = 0
        for f in in_dir.glob("*"):
            if f.suffix.lower() in (".bin", ".txt"):
                f.unlink()
                removed += 1
        self.log_warn(f"Cleared {removed} file(s) from input/")
        self._refresh_file_list()

    def _open_output(self):
        cfg = _cfg()
        out = Path(cfg["output_dir"])
        import subprocess
        try:
            if sys.platform == "win32":
                os.startfile(str(out))
            elif sys.platform == "darwin":
                subprocess.Popen(["open", str(out)])
            else:
                subprocess.Popen(["xdg-open", str(out)])
        except Exception as e:
            self.log_err(f"Could not open output/: {e}")

    # ── Runners (threaded so UI doesn't freeze) ───────────────────────────────

    def _run_in_thread(self, fn):
        self._set_status("Running…")
        t = threading.Thread(target=self._thread_wrapper(fn), daemon=True)
        t.start()

    def _thread_wrapper(self, fn):
        def _inner():
            try:
                fn()
            except Exception as e:
                self.log_err(f"Unexpected error: {e}")
            finally:
                self._set_status("Done")
                self.after(0, self._refresh_file_list)
        return _inner

    # ── Convert ───────────────────────────────────────────────────────────────

    def _run_convert(self):
        self._run_in_thread(self._do_convert)

    def _do_convert(self):
        import tempfile
        cfg = _cfg()
        _ensure_dirs(cfg)
        in_dir   = Path(cfg["input_dir"])
        out_dir  = Path(cfg["output_dir"])
        endian   = cfg["endian"]
        ws       = cfg["word_sizes"]
        tmp      = tempfile.mkdtemp()

        bin_files = sorted(in_dir.glob("*.bin"))
        txt_files = sorted(in_dir.glob("*.txt"))
        total = len(bin_files) + len(txt_files)

        if total == 0:
            self.log_warn("No .bin or .txt files in input/  —  add files first")
            return

        self.log_head(f"CONVERT  ({total} file(s))")
        passed = failed = 0

        # EXTRACT: bin → txt
        for f in bin_files:
            dst = out_dir / (f.stem + ".txt")
            self.log_info(f"EXTRACT  {f.name}")
            try:
                bin_to_txt(str(f), str(dst), endian, ws)
                ok_flag, h_orig, h_rt = verify_bin_to_txt(str(f), str(dst), endian, ws, tmp)
                if ok_flag:
                    self.log_ok(f"{f.name}  →  {dst.name}  SHA-256: {h_rt[:16]}…")
                    passed += 1
                else:
                    self.log_err(f"{f.name}  roundtrip mismatch")
                    failed += 1
            except Exception as e:
                self.log_err(f"{f.name}  {e}")
                failed += 1

        # APPLY: txt → bin
        for f in txt_files:
            dst = out_dir / (f.stem + ".bin")
            self.log_info(f"APPLY    {f.name}")
            try:
                ok_v, issues = validate_txt_format(str(f), endian, ws)
                if not ok_v:
                    self.log_warn(f"{f.name}  {len(issues)} format issue(s) — normalizing")
                txt_to_bin(str(f), str(dst), endian, ws)
                ok_flag, h_bin, diff = verify_txt_to_bin(str(f), str(dst), endian, ws, tmp)
                if ok_flag:
                    self.log_ok(f"{f.name}  →  {dst.name}  SHA-256: {h_bin[:16]}…")
                    passed += 1
                else:
                    self.log_err(f"{f.name}  roundtrip mismatch")
                    failed += 1
            except Exception as e:
                self.log_err(f"{f.name}  {e}")
                failed += 1

        self.log_head(f"Passed: {passed}  |  Failed: {failed}  |  Total: {total}")

    # ── Draft ─────────────────────────────────────────────────────────────────

    def _run_draft(self):
        self._run_in_thread(self._do_draft)

    def _do_draft(self):
        import tempfile
        cfg = _cfg()
        _ensure_dirs(cfg)
        in_dir  = Path(cfg["input_dir"])
        out_dir = Path(cfg["output_dir"])
        endian  = cfg["endian"]
        ws      = cfg["word_sizes"]
        tmp     = tempfile.mkdtemp()

        bin_files = sorted(in_dir.glob("*.bin"))
        txt_files = sorted(in_dir.glob("*.txt"))

        if not bin_files and not txt_files:
            self.log_warn("No files in input/")
            return

        # Detect conflicts
        bin_bases = {f.stem for f in bin_files}
        txt_bases = {f.stem for f in txt_files}
        conflicts = bin_bases & txt_bases

        self.log_head(f"DRAFT  ({len(bin_files)+len(txt_files)} file(s))")

        for f in bin_files:
            stem = f"{f.stem}~bin" if f.stem in conflicts else f.stem
            dst = out_dir / f"__DRAFT_{stem}.txt"
            self.log_info(f"DRAFT BIN  {f.name}  →  {dst.name}")
            try:
                bin_to_txt(str(f), str(dst), endian, ws)
                ok_flag, h_orig, h_rt = verify_bin_to_txt(str(f), str(dst), endian, ws, tmp)
                if ok_flag:
                    self.log_ok(f"Roundtrip verified  SHA-256: {h_rt[:16]}…")
                else:
                    self.log_err(f"Roundtrip failed")
            except Exception as e:
                self.log_err(f"{f.name}  {e}")

        for f in txt_files:
            stem = f"{f.stem}~txt" if f.stem in conflicts else f.stem
            dst = out_dir / f"__DRAFT_{stem}.txt"
            self.log_info(f"DRAFT TXT  {f.name}  →  {dst.name}")
            try:
                ok_v, issues = validate_txt_format(str(f), endian, ws)
                if ok_v:
                    self.log_ok("Format valid")
                else:
                    self.log_warn(f"{len(issues)} format issue(s)")
                normalize_txt(str(f), str(dst), endian, ws)
                self.log_dim(f"Normalized draft written")
            except Exception as e:
                self.log_err(f"{f.name}  {e}")

        self.log_head("Drafts written to output/__DRAFT_*  —  review then click Apply Drafts")

    # ── Apply ─────────────────────────────────────────────────────────────────

    def _run_apply(self):
        self._run_in_thread(self._do_apply)

    def _do_apply(self):
        import tempfile
        cfg = _cfg()
        _ensure_dirs(cfg)
        out_dir = Path(cfg["output_dir"])
        endian  = cfg["endian"]
        ws      = cfg["word_sizes"]
        tmp     = tempfile.mkdtemp()

        drafts = sorted(out_dir.glob("__DRAFT_*.txt"))
        if not drafts:
            self.log_warn("No __DRAFT_*.txt files in output/  —  run Draft first")
            return

        self.log_head(f"APPLY  ({len(drafts)} draft(s))")
        passed = failed = 0

        for f in drafts:
            # Strip __DRAFT_ prefix and .txt suffix → stem → .bin
            stem = f.stem[len("__DRAFT_"):]
            dst  = out_dir / f"{stem}.bin"
            self.log_info(f"APPLY  {f.name}  →  {dst.name}")
            try:
                txt_to_bin(str(f), str(dst), endian, ws)
                ok_flag, h_bin, diff = verify_txt_to_bin(str(f), str(dst), endian, ws, tmp)
                if ok_flag:
                    self.log_ok(f"Verified  SHA-256: {h_bin[:16]}…")
                    f.unlink()
                    self.log_dim("DRAFT removed")
                    passed += 1
                else:
                    self.log_err(f"Roundtrip mismatch — DRAFT kept")
                    failed += 1
            except Exception as e:
                self.log_err(f"{f.name}  {e}")
                failed += 1

        self.log_head(f"Passed: {passed}  |  Failed: {failed}")

    # ── Compare ───────────────────────────────────────────────────────────────

    def _run_compare(self):
        self._run_in_thread(self._do_compare)

    def _do_compare(self):
        import tempfile
        cfg = _cfg()
        _ensure_dirs(cfg)
        in_dir = Path(cfg["input_dir"])
        out_dir = Path(cfg["output_dir"])
        endian  = cfg["endian"]
        ws      = cfg["word_sizes"]
        tmp     = tempfile.mkdtemp()

        all_files = sorted(
            f for f in in_dir.iterdir()
            if f.suffix.lower() in (".bin", ".txt")
        )
        if not all_files:
            self.log_warn("No files in input/")
            return

        self.log_head(f"COMPARE  ({len(all_files)} file(s))")

        fp_list = []
        for f in all_files:
            ftype = "BINARY" if f.suffix.lower() == ".bin" else "TEXT  "
            self.log_info(f"{ftype}  {f.name}")
            h, norm_path, error = fingerprint_file(str(f), endian, ws, tmp)
            if error:
                self.log_err(f"  {f.name}  {error}")
                fp_list.append((str(f), "ERROR", ftype, error))
            else:
                self.log_ok(f"  hash: {h[:20]}…")
                fp_list.append((str(f), h, ftype, ""))

        matches, singletons, errors = group_by_hash(fp_list)

        if matches:
            self.log_head(f"{len(matches)} match group(s) found:")
            for h, members in sorted(matches.items(), key=lambda x: -len(x[1])):
                self.log_info(f"GROUP — {len(members)} files  (hash: {h[:16]}…)")
                for fname, ftype, _ in sorted(members):
                    self.log_dim(f"  [{ftype}]  {fname}")
        else:
            self.log_head("All files unique — no content matches")

        if singletons:
            self.log_info(f"{len(singletons)} unique file(s) (no match):")
            for h, members in singletons.items():
                fname, ftype, _ = members[0]
                self.log_dim(f"  [{ftype}]  {fname}")

        # Move reviewed files to output/
        moved = 0
        for path, h, ftype, _ in fp_list:
            if h != "ERROR":
                src = Path(path)
                dst = out_dir / src.name
                shutil.move(str(src), str(dst))
                moved += 1
        self.log_info(f"{moved} file(s) moved to output/")

    # ── Package ───────────────────────────────────────────────────────────────

    def _run_package(self):
        self._run_in_thread(self._do_package)

    def _do_package(self):
        cfg = _cfg()
        out_dir    = Path(cfg["output_dir"])
        report_dir = Path(cfg["report_dir"])

        name = self._zip_name.get().strip() or f"bintxt_export_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
        if not name.endswith(".zip"):
            name += ".zip"

        # Ask where to save
        save_path = filedialog.asksaveasfilename(
            title="Save package as…",
            initialfile=name,
            defaultextension=".zip",
            filetypes=[("ZIP archive", "*.zip"), ("All files", "*.*")]
        )
        if not save_path:
            return

        self.log_head(f"PACKAGE  →  {Path(save_path).name}")

        collected = []

        # output/ files (converted bins + txts, excluding reports subdir)
        for f in sorted(out_dir.iterdir()):
            if f.is_file() and f.suffix.lower() in (".bin", ".txt"):
                collected.append((f, f"output/{f.name}"))

        # reports
        if report_dir.exists():
            for f in sorted(report_dir.glob("*.txt")):
                collected.append((f, f"output/reports/{f.name}"))

        # Ask if user wants to add extra files
        extras = filedialog.askopenfilenames(
            title="Add extra files to package (optional — cancel to skip)"
        )
        for ep in extras:
            ep = Path(ep)
            collected.append((ep, f"extras/{ep.name}"))

        if not collected:
            self.log_warn("Nothing to package — run a conversion first")
            return

        with zipfile.ZipFile(save_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for src, arcname in collected:
                zf.write(str(src), arcname)
                self.log_dim(f"  + {arcname}")

        self.log_ok(f"Package saved: {save_path}  ({len(collected)} file(s))")


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    app = BintxtApp()
    app.mainloop()
