"""
ui/app.py — bintxt_tool Desktop UI
Requires only Python standard library. Run from repo root: python3 ui/app.py
"""

import os
import shutil
import sys
import tempfile
import threading
import zipfile
from datetime import datetime
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, font, scrolledtext

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from core.config import load as load_config, absdirs
from core.convert import (
    bin_to_txt, txt_to_bin, validate_txt_format, normalize_txt,
    sha256_file, verify_bin_to_txt, verify_txt_to_bin,
)
from core.compare import fingerprint_file, group_by_hash, format_group_report

# ── Palette ────────────────────────────────────────────────────────────────────
BG      = "#181818"
SURFACE = "#222222"
SURFACE2= "#2a2a2a"
BORDER  = "#333333"
FG      = "#d4d4d4"
FG_DIM  = "#6a6a6a"
FG_MED  = "#999999"
ACCENT  = "#4d94d4"
BTN_BG  = "#2c2c2c"
BTN_HOV = "#383838"
GREEN   = "#4ec9b0"
RED     = "#e05252"
YELLOW  = "#d4a94a"
CYAN    = "#9cdcfe"

MONO  = ("Courier New", 10)
MONO_S= ("Courier New", 9)
UI    = ("Segoe UI", 10)
UI_S  = ("Segoe UI", 9)
UI_B  = ("Segoe UI", 10, "bold")
UI_H  = ("Segoe UI", 13, "bold")


def _cfg():
    raw = load_config(str(REPO_ROOT))
    return absdirs(raw, str(REPO_ROOT))

def _ensure_dirs(cfg):
    for k in ("input_dir", "output_dir", "report_dir"):
        Path(cfg[k]).mkdir(parents=True, exist_ok=True)


class BintxtApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("bintxt_tool")
        self.configure(bg=BG)
        self.minsize(900, 600)
        self._cfg = _cfg()
        _ensure_dirs(self._cfg)
        self._selected_file = None   # currently previewed file

        self._build()
        self._refresh_file_list()

        self.update_idletasks()
        w, h = 1100, 700
        x = (self.winfo_screenwidth()  - w) // 2
        y = (self.winfo_screenheight() - h) // 2
        self.geometry(f"{w}x{h}+{x}+{y}")

    # ── Layout ────────────────────────────────────────────────────────────────

    def _build(self):
        self._build_header()
        self._build_toolbar()
        self._build_main()
        self._build_statusbar()

    def _build_header(self):
        bar = tk.Frame(self, bg=SURFACE, height=44)
        bar.pack(fill="x")
        bar.pack_propagate(False)

        tk.Label(bar, text="bintxt_tool", bg=SURFACE, fg=FG,
                 font=UI_H).pack(side="left", padx=16, pady=10)

        cfg = self._cfg
        layout = "+".join(f"{w}B" for w in cfg["word_sizes"])
        info = f"layout: {layout}   ·   endian: {cfg['endian']}   ·   input: {cfg['input_dir']}"
        tk.Label(bar, text=info, bg=SURFACE, fg=FG_DIM,
                 font=UI_S).pack(side="right", padx=16)

    def _build_toolbar(self):
        bar = tk.Frame(self, bg=SURFACE2, height=40)
        bar.pack(fill="x")
        bar.pack_propagate(False)

        # Separator line under header
        tk.Frame(self, bg=BORDER, height=1).pack(fill="x")  # already done by SURFACE2 boundary

        actions = [
            ("Convert",      self._run_convert, ACCENT),
            ("Draft",        self._run_draft,   BTN_BG),
            ("Apply Drafts", self._run_apply,   BTN_BG),
            ("Compare",      self._run_compare, BTN_BG),
        ]

        tk.Label(bar, text="Actions", bg=SURFACE2, fg=FG_DIM,
                 font=UI_S).pack(side="left", padx=(14, 8), pady=10)

        for label, cmd, bg in actions:
            self._tbtn(bar, label, cmd, bg).pack(side="left", padx=3, pady=6)

        # Separator
        tk.Frame(bar, bg=BORDER, width=1).pack(side="left", fill="y", padx=12, pady=8)

        self._tbtn(bar, "📦  Package", self._run_package, BTN_BG).pack(side="left", padx=3, pady=6)

    def _build_main(self):
        tk.Frame(self, bg=BORDER, height=1).pack(fill="x")

        main = tk.Frame(self, bg=BG)
        main.pack(fill="both", expand=True)

        # Left: file list
        left = tk.Frame(main, bg=SURFACE, width=220)
        left.pack(side="left", fill="y")
        left.pack_propagate(False)

        tk.Frame(main, bg=BORDER, width=1).pack(side="left", fill="y")

        # Center: file viewer
        center = tk.Frame(main, bg=BG)
        center.pack(side="left", fill="both", expand=True)

        tk.Frame(main, bg=BORDER, width=1).pack(side="left", fill="y")

        # Right: log
        right = tk.Frame(main, bg=SURFACE, width=300)
        right.pack(side="left", fill="y")
        right.pack_propagate(False)

        self._build_file_panel(left)
        self._build_viewer(center)
        self._build_log_panel(right)

    def _build_file_panel(self, parent):
        # Header
        hdr = tk.Frame(parent, bg=SURFACE)
        hdr.pack(fill="x", padx=10, pady=(10, 4))
        tk.Label(hdr, text="INPUT FILES", bg=SURFACE, fg=FG_DIM,
                 font=UI_S).pack(side="left")

        # Buttons
        btn_row = tk.Frame(parent, bg=SURFACE)
        btn_row.pack(fill="x", padx=8, pady=(0, 6))
        self._sbtn(btn_row, "Add", self._browse_files).pack(side="left", padx=(0, 4))
        self._sbtn(btn_row, "Clear", self._clear_input, danger=True).pack(side="left")

        tk.Frame(parent, bg=BORDER, height=1).pack(fill="x")

        # Scrollable file list
        list_container = tk.Frame(parent, bg=SURFACE)
        list_container.pack(fill="both", expand=True)

        sb = tk.Scrollbar(list_container, bg=SURFACE, troughcolor=SURFACE, width=6)
        sb.pack(side="right", fill="y")

        self._filebox = tk.Listbox(
            list_container,
            bg=SURFACE, fg=FG, selectbackground="#2a3d52",
            selectforeground=FG, font=MONO_S,
            relief="flat", borderwidth=0, highlightthickness=0,
            activestyle="none",
            yscrollcommand=sb.set,
        )
        self._filebox.pack(fill="both", expand=True)
        sb.config(command=self._filebox.yview)
        self._filebox.bind("<<ListboxSelect>>", self._on_file_select)

        # Prev/Next navigation
        nav = tk.Frame(parent, bg=SURFACE)
        nav.pack(fill="x", pady=6, padx=8)
        self._sbtn(nav, "▲ Prev", self._nav_prev).pack(side="left", padx=(0, 4))
        self._sbtn(nav, "▼ Next", self._nav_next).pack(side="left")

    def _build_viewer(self, parent):
        # Viewer header
        vhdr = tk.Frame(parent, bg=BG)
        vhdr.pack(fill="x", padx=12, pady=(8, 4))

        self._viewer_title = tk.StringVar(value="Select a file to preview")
        tk.Label(vhdr, textvariable=self._viewer_title, bg=BG, fg=FG_MED,
                 font=UI_S, anchor="w").pack(side="left")

        self._viewer_info = tk.StringVar(value="")
        tk.Label(vhdr, textvariable=self._viewer_info, bg=BG, fg=FG_DIM,
                 font=UI_S, anchor="e").pack(side="right")

        tk.Frame(parent, bg=BORDER, height=1).pack(fill="x", padx=0)

        # Text viewer
        viewer_frame = tk.Frame(parent, bg=BG)
        viewer_frame.pack(fill="both", expand=True, padx=0, pady=0)

        vsb = tk.Scrollbar(viewer_frame, bg=BG, troughcolor=BG, width=6)
        vsb.pack(side="right", fill="y")
        hsb = tk.Scrollbar(viewer_frame, orient="horizontal", bg=BG, troughcolor=BG, width=6)
        hsb.pack(side="bottom", fill="x")

        self._viewer = tk.Text(
            viewer_frame, bg=BG, fg=FG, font=MONO,
            relief="flat", borderwidth=0,
            state="disabled", wrap="none",
            padx=12, pady=8,
            insertbackground=FG,
            yscrollcommand=vsb.set,
            xscrollcommand=hsb.set,
        )
        self._viewer.pack(fill="both", expand=True)
        vsb.config(command=self._viewer.yview)
        hsb.config(command=self._viewer.xview)

        # Viewer tags
        self._viewer.tag_configure("addr",    foreground=FG_DIM)
        self._viewer.tag_configure("val",     foreground=CYAN)
        self._viewer.tag_configure("note",    foreground=FG_DIM, font=UI_S)
        self._viewer.tag_configure("heading", foreground=FG_MED, font=UI_S)

    def _build_log_panel(self, parent):
        hdr = tk.Frame(parent, bg=SURFACE)
        hdr.pack(fill="x", padx=10, pady=(10, 4))
        tk.Label(hdr, text="LOG", bg=SURFACE, fg=FG_DIM,
                 font=UI_S).pack(side="left")
        self._sbtn(hdr, "Clear", self._clear_log).pack(side="right")

        tk.Frame(parent, bg=BORDER, height=1).pack(fill="x")

        log_frame = tk.Frame(parent, bg=SURFACE)
        log_frame.pack(fill="both", expand=True)

        lsb = tk.Scrollbar(log_frame, bg=SURFACE, troughcolor=SURFACE, width=6)
        lsb.pack(side="right", fill="y")

        self._log = tk.Text(
            log_frame, bg=SURFACE, fg=FG, font=MONO_S,
            relief="flat", borderwidth=0,
            state="disabled", wrap="word",
            padx=8, pady=6,
            yscrollcommand=lsb.set,
        )
        self._log.pack(fill="both", expand=True)
        lsb.config(command=self._log.yview)

        self._log.tag_configure("ok",   foreground=GREEN)
        self._log.tag_configure("err",  foreground=RED)
        self._log.tag_configure("warn", foreground=YELLOW)
        self._log.tag_configure("info", foreground=CYAN)
        self._log.tag_configure("head", foreground=FG,    font=UI_B)
        self._log.tag_configure("dim",  foreground=FG_DIM)

    def _build_statusbar(self):
        tk.Frame(self, bg=BORDER, height=1).pack(fill="x")
        bar = tk.Frame(self, bg=SURFACE2, height=28)
        bar.pack(fill="x", side="bottom")
        bar.pack_propagate(False)

        self._status_var = tk.StringVar(value="Ready")
        tk.Label(bar, textvariable=self._status_var, bg=SURFACE2, fg=FG_DIM,
                 font=UI_S).pack(side="left", padx=12)

        # Open output folder shortcut
        self._sbtn(bar, "Open output/", self._open_output).pack(side="right", padx=8, pady=4)

    # ── Widget factories ─────────────────────────────────────────────────────

    def _tbtn(self, parent, text, cmd, bg=BTN_BG):
        """Toolbar button."""
        b = tk.Button(parent, text=text, command=cmd,
                      bg=bg, fg=FG, activebackground=BTN_HOV, activeforeground=FG,
                      font=UI, relief="flat", borderwidth=0,
                      padx=12, pady=3, cursor="hand2")
        b.bind("<Enter>", lambda _: b.configure(bg=BTN_HOV))
        b.bind("<Leave>", lambda _: b.configure(bg=bg))
        return b

    def _sbtn(self, parent, text, cmd, danger=False):
        """Small secondary button."""
        bg  = "#3a2020" if danger else BTN_BG
        hov = "#4a2020" if danger else BTN_HOV
        fg  = RED if danger else FG_MED
        b = tk.Button(parent, text=text, command=cmd,
                      bg=bg, fg=fg, activebackground=hov, activeforeground=fg,
                      font=UI_S, relief="flat", borderwidth=0,
                      padx=8, pady=2, cursor="hand2")
        b.bind("<Enter>", lambda _: b.configure(bg=hov))
        b.bind("<Leave>", lambda _: b.configure(bg=bg))
        return b

    # ── Logging ───────────────────────────────────────────────────────────────

    def _log_write(self, msg, tag=""):
        self._log.configure(state="normal")
        self._log.insert("end", msg + "\n", tag)
        self._log.see("end")
        self._log.configure(state="disabled")

    def log(self, m):      self._log_write(f"  {m}")
    def log_ok(self, m):   self._log_write(f"  ✓  {m}", "ok")
    def log_err(self, m):  self._log_write(f"  ✗  {m}", "err")
    def log_warn(self, m): self._log_write(f"  ⚠  {m}", "warn")
    def log_info(self, m): self._log_write(f"  →  {m}", "info")
    def log_head(self, m): self._log_write(f"\n{m}", "head")
    def log_dim(self, m):  self._log_write(f"     {m}", "dim")

    def _clear_log(self):
        self._log.configure(state="normal")
        self._log.delete("1.0", "end")
        self._log.configure(state="disabled")

    def _set_status(self, msg):
        self._status_var.set(msg)
        self.update_idletasks()

    # ── File list ─────────────────────────────────────────────────────────────

    def _browse_files(self):
        paths = filedialog.askopenfilenames(
            title="Select .bin or .txt files",
            filetypes=[("Binary / Text", "*.bin *.txt"), ("All files", "*.*")]
        )
        if paths:
            cfg = _cfg()
            _ensure_dirs(cfg)
            in_dir = Path(cfg["input_dir"])
            for p in paths:
                src = Path(p)
                if src.suffix.lower() in (".bin", ".txt"):
                    shutil.copy2(str(src), str(in_dir / src.name))
                    self.log_info(f"Added: {src.name}")
            self._refresh_file_list()

    def _refresh_file_list(self):
        cfg = _cfg()
        in_dir = Path(cfg["input_dir"])
        files = sorted(
            f for f in in_dir.iterdir()
            if f.suffix.lower() in (".bin", ".txt")
        )
        self._input_files = files
        self._filebox.delete(0, "end")
        for f in files:
            ext_tag = " BIN" if f.suffix.lower() == ".bin" else " TXT"
            self._filebox.insert("end", f"  {ext_tag}  {f.name}")

        # Re-select previously selected file if still present
        if self._selected_file and self._selected_file in files:
            idx = files.index(self._selected_file)
            self._filebox.selection_set(idx)
        elif files:
            self._filebox.selection_set(0)
            self._preview_file(files[0])
        else:
            self._clear_viewer("No files in input/  —  click Add to browse")

    def _on_file_select(self, event):
        sel = self._filebox.curselection()
        if sel and self._input_files:
            f = self._input_files[sel[0]]
            self._selected_file = f
            self._preview_file(f)

    def _nav_prev(self):
        if not self._input_files:
            return
        sel = self._filebox.curselection()
        idx = (sel[0] - 1) % len(self._input_files) if sel else 0
        self._filebox.selection_clear(0, "end")
        self._filebox.selection_set(idx)
        self._filebox.see(idx)
        self._selected_file = self._input_files[idx]
        self._preview_file(self._selected_file)

    def _nav_next(self):
        if not self._input_files:
            return
        sel = self._filebox.curselection()
        idx = (sel[0] + 1) % len(self._input_files) if sel else 0
        self._filebox.selection_clear(0, "end")
        self._filebox.selection_set(idx)
        self._filebox.see(idx)
        self._selected_file = self._input_files[idx]
        self._preview_file(self._selected_file)

    def _clear_input(self):
        cfg = _cfg()
        removed = 0
        for f in Path(cfg["input_dir"]).iterdir():
            if f.suffix.lower() in (".bin", ".txt"):
                f.unlink()
                removed += 1
        self.log_warn(f"Cleared {removed} file(s) from input/")
        self._selected_file = None
        self._refresh_file_list()

    # ── File viewer ───────────────────────────────────────────────────────────

    def _clear_viewer(self, msg=""):
        self._viewer.configure(state="normal")
        self._viewer.delete("1.0", "end")
        if msg:
            self._viewer.insert("end", f"\n  {msg}", "note")
        self._viewer.configure(state="disabled")
        self._viewer_title.set(msg or "")
        self._viewer_info.set("")

    def _preview_file(self, path: Path):
        cfg = _cfg()
        endian = cfg["endian"]
        ws = cfg["word_sizes"]

        self._viewer_title.set(str(path.name))
        self._viewer.configure(state="normal")
        self._viewer.delete("1.0", "end")

        try:
            if path.suffix.lower() == ".bin":
                # Convert on-the-fly to text for display
                tmp = tempfile.mktemp(suffix=".txt")
                bin_to_txt(str(path), tmp, endian, ws)
                content = Path(tmp).read_text()
                Path(tmp).unlink(missing_ok=True)
                size_bytes = path.stat().st_size
                self._viewer_info.set(f"{size_bytes} B binary   (extracted view)")
                self._render_hex_content(content)
            else:
                content = path.read_text(errors="replace")
                lines = content.splitlines()
                self._viewer_info.set(f"{path.stat().st_size} B   {len(lines)} lines")
                self._render_hex_content(content)
        except Exception as e:
            self._viewer.insert("end", f"\n  Error reading file: {e}", "note")

        self._viewer.configure(state="disabled")

    def _render_hex_content(self, content: str):
        """Render hex dump with address and value coloring."""
        for line in content.splitlines():
            parts = line.split()
            if not parts:
                self._viewer.insert("end", "\n")
                continue
            # Address column
            self._viewer.insert("end", f"  {parts[0]}", "addr")
            if len(parts) > 1:
                self._viewer.insert("end", "  ")
                self._viewer.insert("end", "  ".join(parts[1:]), "val")
            self._viewer.insert("end", "\n")

    # ── Output folder ─────────────────────────────────────────────────────────

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

    # ── Threaded runner ───────────────────────────────────────────────────────

    def _run_in_thread(self, fn):
        self._set_status("Running…")

        def _wrapper():
            try:
                fn()
            except Exception as e:
                self.log_err(f"Unexpected error: {e}")
            finally:
                self.after(0, lambda: self._set_status("Ready"))
                self.after(0, self._refresh_file_list)

        threading.Thread(target=_wrapper, daemon=True).start()

    # ── Actions ───────────────────────────────────────────────────────────────

    def _run_convert(self): self._run_in_thread(self._do_convert)
    def _run_draft(self):   self._run_in_thread(self._do_draft)
    def _run_apply(self):   self._run_in_thread(self._do_apply)
    def _run_compare(self): self._run_in_thread(self._do_compare)
    def _run_package(self): self._run_in_thread(self._do_package)

    def _do_convert(self):
        cfg = _cfg(); _ensure_dirs(cfg)
        in_dir, out_dir = Path(cfg["input_dir"]), Path(cfg["output_dir"])
        endian, ws = cfg["endian"], cfg["word_sizes"]
        tmp = tempfile.mkdtemp()

        bins = sorted(in_dir.glob("*.bin"))
        txts = sorted(in_dir.glob("*.txt"))
        if not bins and not txts:
            self.log_warn("No files in input/"); return

        self.log_head(f"CONVERT  ({len(bins)+len(txts)} file(s))")
        passed = failed = 0

        for f in bins:
            dst = out_dir / (f.stem + ".txt")
            self.log_info(f"EXTRACT  {f.name}")
            try:
                bin_to_txt(str(f), str(dst), endian, ws)
                ok, h_orig, h_rt = verify_bin_to_txt(str(f), str(dst), endian, ws, tmp)
                if ok:
                    self.log_ok(f"{dst.name}   {h_rt[:20]}…"); passed += 1
                else:
                    self.log_err(f"{f.name}  roundtrip mismatch"); failed += 1
            except Exception as e:
                self.log_err(f"{f.name}  {e}"); failed += 1

        for f in txts:
            dst = out_dir / (f.stem + ".bin")
            self.log_info(f"APPLY    {f.name}")
            try:
                ok_v, issues = validate_txt_format(str(f), endian, ws)
                if not ok_v:
                    self.log_warn(f"{f.name}  {len(issues)} format issue(s) — normalizing")
                txt_to_bin(str(f), str(dst), endian, ws)
                ok, h_bin, diff = verify_txt_to_bin(str(f), str(dst), endian, ws, tmp)
                if ok:
                    self.log_ok(f"{dst.name}   {h_bin[:20]}…"); passed += 1
                else:
                    self.log_err(f"{f.name}  roundtrip mismatch"); failed += 1
            except Exception as e:
                self.log_err(f"{f.name}  {e}"); failed += 1

        self.log_head(f"Done — {passed} passed, {failed} failed")

    def _do_draft(self):
        cfg = _cfg(); _ensure_dirs(cfg)
        in_dir, out_dir = Path(cfg["input_dir"]), Path(cfg["output_dir"])
        endian, ws = cfg["endian"], cfg["word_sizes"]
        tmp = tempfile.mkdtemp()

        bins = sorted(in_dir.glob("*.bin"))
        txts = sorted(in_dir.glob("*.txt"))
        if not bins and not txts:
            self.log_warn("No files in input/"); return

        bin_bases = {f.stem for f in bins}
        txt_bases = {f.stem for f in txts}
        conflicts = bin_bases & txt_bases

        self.log_head(f"DRAFT  ({len(bins)+len(txts)} file(s))")

        for f in bins:
            stem = f"{f.stem}~bin" if f.stem in conflicts else f.stem
            dst = out_dir / f"__DRAFT_{stem}.txt"
            self.log_info(f"BIN  {f.name}  →  {dst.name}")
            try:
                bin_to_txt(str(f), str(dst), endian, ws)
                ok, h_orig, h_rt = verify_bin_to_txt(str(f), str(dst), endian, ws, tmp)
                self.log_ok("Roundtrip verified") if ok else self.log_err("Roundtrip failed")
            except Exception as e:
                self.log_err(f"{f.name}  {e}")

        for f in txts:
            stem = f"{f.stem}~txt" if f.stem in conflicts else f.stem
            dst = out_dir / f"__DRAFT_{stem}.txt"
            self.log_info(f"TXT  {f.name}  →  {dst.name}")
            try:
                ok_v, issues = validate_txt_format(str(f), endian, ws)
                self.log_ok("Format valid") if ok_v else self.log_warn(f"{len(issues)} issue(s)")
                normalize_txt(str(f), str(dst), endian, ws)
                self.log_dim("Normalized")
            except Exception as e:
                self.log_err(f"{f.name}  {e}")

        self.log_head("Review output/__DRAFT_*  then click Apply Drafts")

    def _do_apply(self):
        cfg = _cfg(); _ensure_dirs(cfg)
        out_dir = Path(cfg["output_dir"])
        endian, ws = cfg["endian"], cfg["word_sizes"]
        tmp = tempfile.mkdtemp()

        drafts = sorted(out_dir.glob("__DRAFT_*.txt"))
        if not drafts:
            self.log_warn("No __DRAFT_*.txt in output/  —  run Draft first"); return

        self.log_head(f"APPLY  ({len(drafts)} draft(s))")
        passed = failed = 0

        for f in drafts:
            stem = f.stem[len("__DRAFT_"):]
            dst  = out_dir / f"{stem}.bin"
            self.log_info(f"{f.name}  →  {dst.name}")
            try:
                txt_to_bin(str(f), str(dst), endian, ws)
                ok, h_bin, diff = verify_txt_to_bin(str(f), str(dst), endian, ws, tmp)
                if ok:
                    self.log_ok(f"Verified   {h_bin[:20]}…")
                    f.unlink(); self.log_dim("DRAFT removed"); passed += 1
                else:
                    self.log_err("Roundtrip mismatch — DRAFT kept"); failed += 1
            except Exception as e:
                self.log_err(f"{f.name}  {e}"); failed += 1

        self.log_head(f"Done — {passed} passed, {failed} failed")

    def _do_compare(self):
        cfg = _cfg(); _ensure_dirs(cfg)
        in_dir, out_dir = Path(cfg["input_dir"]), Path(cfg["output_dir"])
        endian, ws = cfg["endian"], cfg["word_sizes"]
        tmp = tempfile.mkdtemp()

        files = sorted(f for f in in_dir.iterdir() if f.suffix.lower() in (".bin", ".txt"))
        if not files:
            self.log_warn("No files in input/"); return

        self.log_head(f"COMPARE  ({len(files)} file(s))")
        fp_list = []
        for f in files:
            ftype = "BIN" if f.suffix.lower() == ".bin" else "TXT"
            h, _, err = fingerprint_file(str(f), endian, ws, tmp)
            if err:
                self.log_err(f"[{ftype}]  {f.name}  {err}")
                fp_list.append((str(f), "ERROR", ftype, err))
            else:
                self.log_dim(f"[{ftype}]  {f.name}  {h[:20]}…")
                fp_list.append((str(f), h, ftype, ""))

        matches, singletons, errors = group_by_hash(fp_list)

        if matches:
            self.log_head(f"{len(matches)} match group(s):")
            for h, members in sorted(matches.items(), key=lambda x: -len(x[1])):
                self.log_info(f"Group — {len(members)} files   hash: {h[:16]}…")
                for fname, ftype, _ in sorted(members):
                    self.log_dim(f"  [{ftype}]  {fname}")
        else:
            self.log_head("All files unique — no matches")

        moved = 0
        for path, h, ftype, _ in fp_list:
            if h != "ERROR":
                src = Path(path)
                shutil.move(str(src), str(out_dir / src.name))
                moved += 1
        self.log_info(f"{moved} file(s) moved to output/")

    def _do_package(self):
        cfg = _cfg(); _ensure_dirs(cfg)
        out_dir    = Path(cfg["output_dir"])
        report_dir = Path(cfg["report_dir"])

        # Ask for save path
        default = f"bintxt_export_{datetime.now().strftime('%Y%m%d_%H%M%S')}.zip"
        save_path = filedialog.asksaveasfilename(
            title="Save package as…",
            initialfile=default,
            defaultextension=".zip",
            filetypes=[("ZIP archive", "*.zip")]
        )
        if not save_path:
            return

        self.log_head(f"PACKAGE  →  {Path(save_path).name}")
        collected = []

        for f in sorted(out_dir.iterdir()):
            if f.is_file() and f.suffix.lower() in (".bin", ".txt"):
                collected.append((f, f"output/{f.name}"))

        if report_dir.exists():
            for f in sorted(report_dir.glob("*.txt")):
                collected.append((f, f"output/reports/{f.name}"))

        extras = filedialog.askopenfilenames(
            title="Add extra files (cancel to skip)"
        )
        for ep in extras:
            ep = Path(ep)
            collected.append((ep, f"extras/{ep.name}"))

        if not collected:
            self.log_warn("Nothing to package — run a conversion first"); return

        with zipfile.ZipFile(save_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for src, arcname in collected:
                zf.write(str(src), arcname)
                self.log_dim(f"  + {arcname}")

        self.log_ok(f"Saved: {save_path}  ({len(collected)} files)")


if __name__ == "__main__":
    app = BintxtApp()
    app.mainloop()
