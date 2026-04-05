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
from tkinter import filedialog

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from core.config import load as load_config, absdirs
from core.convert import (
    bin_to_txt, txt_to_bin, validate_txt_format, normalize_txt,
    sha256_file, verify_bin_to_txt, verify_txt_to_bin,
)
from core.compare import fingerprint_file, group_by_hash

# ── Palette ────────────────────────────────────────────────────────────────────
BG       = "#181818"
SURFACE  = "#212121"
SURFACE2 = "#282828"
BORDER   = "#444444"
BORDER_S = "#333333"
FG       = "#d4d4d4"
FG_DIM   = "#6a6a6a"
FG_MED   = "#909090"
ACCENT   = "#4d94d4"
SEL_BG   = "#2a3d52"
BTN_BG   = "#2e2e2e"
BTN_HOV  = "#3a3a3a"
BTN_ACT  = "#1e3a5a"
GREEN    = "#4ec9b0"
RED      = "#e05252"
YELLOW   = "#d4a94a"
CYAN     = "#9cdcfe"

MONO   = ("Courier New", 10)
MONO_S = ("Courier New", 9)
UI     = ("Segoe UI", 10)
UI_S   = ("Segoe UI", 9)
UI_B   = ("Segoe UI", 10, "bold")
UI_H   = ("Segoe UI", 13, "bold")
UI_SB  = ("Segoe UI", 9, "bold")


def _cfg():
    raw = load_config(str(REPO_ROOT))
    return absdirs(raw, str(REPO_ROOT))

def _ensure_dirs(cfg):
    for k in ("input_dir", "output_dir", "report_dir"):
        Path(cfg[k]).mkdir(parents=True, exist_ok=True)

def _border(parent, thick=1, color=BORDER):
    return tk.Frame(parent, bg=color, height=thick)

def _vborder(parent, thick=1, color=BORDER):
    return tk.Frame(parent, bg=color, width=thick)


class BintxtApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("bintxt_tool")
        self.configure(bg=BG)
        self.minsize(1000, 650)

        self._cfg = _cfg()
        _ensure_dirs(self._cfg)
        self._sel_input  = None
        self._sel_output = None
        self._input_files  = []
        self._output_files = []

        self._build()
        self._refresh_all()

        self.update_idletasks()
        w, h = 1280, 780
        x = (self.winfo_screenwidth()  - w) // 2
        y = (self.winfo_screenheight() - h) // 2
        self.geometry(f"{w}x{h}+{x}+{y}")

    # ── Layout ────────────────────────────────────────────────────────────────

    def _build(self):
        self._build_header()
        _border(self, thick=1, color=BORDER).pack(fill="x")
        self._build_toolbar()
        _border(self, thick=2, color=BORDER).pack(fill="x")
        self._build_body()
        _border(self, thick=1, color=BORDER).pack(fill="x")
        self._build_statusbar()

    def _build_header(self):
        bar = tk.Frame(self, bg=SURFACE, height=46)
        bar.pack(fill="x")
        bar.pack_propagate(False)
        tk.Label(bar, text="bintxt_tool", bg=SURFACE, fg=FG,
                 font=UI_H).pack(side="left", padx=16)
        cfg = self._cfg
        layout = "+".join(f"{w}B" for w in cfg["word_sizes"])
        info = f"layout: {layout}   ·   endian: {cfg['endian']}"
        tk.Label(bar, text=info, bg=SURFACE, fg=FG_DIM,
                 font=UI_S).pack(side="right", padx=16)

    def _build_toolbar(self):
        bar = tk.Frame(self, bg=SURFACE2, height=42)
        bar.pack(fill="x")
        bar.pack_propagate(False)

        tk.Label(bar, text="Actions", bg=SURFACE2, fg=FG_DIM,
                 font=UI_SB).pack(side="left", padx=(14, 6), pady=10)

        for label, cmd, primary in [
            ("Convert",      self._run_convert, True),
            ("Draft",        self._run_draft,   False),
            ("Apply Drafts", self._run_apply,   False),
            ("Compare",      self._run_compare, False),
        ]:
            bg = BTN_ACT if primary else BTN_BG
            self._tbtn(bar, label, cmd, bg=bg).pack(side="left", padx=3, pady=7)

        _vborder(bar, thick=1, color=BORDER_S).pack(side="left", fill="y", padx=10, pady=8)
        self._tbtn(bar, "📦  Package", self._run_package).pack(side="left", padx=3, pady=7)
        self._tbtn(bar, "💾  Save Log", self._save_log).pack(side="left", padx=3, pady=7)

    def _build_body(self):
        # Three-pane resizable layout: [files] | [viewer] | [log]
        paned = tk.PanedWindow(self, orient="horizontal",
                               bg=BORDER, sashwidth=3,
                               sashrelief="flat", opaqueresize=True)
        paned.pack(fill="both", expand=True)

        # ── Left: file panels ─────────────────────────────────────────────────
        left = tk.Frame(paned, bg=BG)
        paned.add(left, minsize=200, width=240)

        # Input / Output split vertically
        vpaned = tk.PanedWindow(left, orient="vertical",
                                bg=BORDER, sashwidth=3,
                                sashrelief="flat", opaqueresize=True)
        vpaned.pack(fill="both", expand=True)

        inp_frame = tk.Frame(vpaned, bg=BG)
        vpaned.add(inp_frame, minsize=120)

        out_frame = tk.Frame(vpaned, bg=BG)
        vpaned.add(out_frame, minsize=120)

        self._build_file_panel(inp_frame, "INPUT",  is_input=True)
        self._build_file_panel(out_frame, "OUTPUT", is_input=False)

        # ── Center: viewer ────────────────────────────────────────────────────
        center = tk.Frame(paned, bg=BG)
        paned.add(center, minsize=300)
        self._build_viewer(center)

        # ── Right: log ────────────────────────────────────────────────────────
        right = tk.Frame(paned, bg=BG)
        paned.add(right, minsize=200, width=280)
        self._build_log_panel(right)

    def _build_file_panel(self, parent, title, is_input):
        # Header row
        hdr = tk.Frame(parent, bg=SURFACE2, height=28)
        hdr.pack(fill="x")
        hdr.pack_propagate(False)
        tk.Label(hdr, text=f"  {title}", bg=SURFACE2, fg=FG_MED,
                 font=UI_SB).pack(side="left", pady=4)

        if is_input:
            self._sbtn(hdr, "Add", self._browse_files).pack(side="right", padx=(0, 4), pady=4)

        _border(parent, thick=2, color=BORDER).pack(fill="x")

        # Listbox (multi-select)
        box_frame = tk.Frame(parent, bg=SURFACE)
        box_frame.pack(fill="both", expand=True)

        sb = tk.Scrollbar(box_frame, bg=SURFACE2, troughcolor=SURFACE2,
                          activebackground=BORDER, width=8, relief="flat")
        sb.pack(side="right", fill="y")

        lb = tk.Listbox(
            box_frame,
            bg=SURFACE, fg=FG,
            selectbackground=SEL_BG, selectforeground=FG,
            font=MONO_S, relief="flat", borderwidth=0, highlightthickness=0,
            activestyle="none", yscrollcommand=sb.set,
            selectmode="extended",
        )
        lb.pack(fill="both", expand=True, padx=(4, 0))
        sb.config(command=lb.yview)

        # Action buttons row below the listbox
        act = tk.Frame(parent, bg=SURFACE2)
        act.pack(fill="x")
        _border(parent, thick=1, color=BORDER_S).pack(fill="x")

        if is_input:
            self._input_lb = lb
            lb.bind("<<ListboxSelect>>", self._on_input_select)
            self._sbtn(act, "Clear Selected", lambda: self._clear_selected(input=True),  danger=True).pack(side="left", padx=4, pady=4)
            self._sbtn(act, "Clear All",      self._clear_input, danger=True).pack(side="left", pady=4)
        else:
            self._output_lb = lb
            lb.bind("<<ListboxSelect>>", self._on_output_select)
            self._sbtn(act, "Move to Input",  self._move_to_input).pack(side="left", padx=4, pady=4)
            self._sbtn(act, "Clear Selected", lambda: self._clear_selected(input=False), danger=True).pack(side="left", pady=4)
            self._sbtn(act, "Clear All",      self._clear_output, danger=True).pack(side="left", padx=4, pady=4)

    def _build_viewer(self, parent):
        vhdr = tk.Frame(parent, bg=SURFACE2, height=28)
        vhdr.pack(fill="x")
        vhdr.pack_propagate(False)

        self._viewer_title = tk.StringVar(value="Select a file to preview")
        tk.Label(vhdr, textvariable=self._viewer_title, bg=SURFACE2, fg=FG_MED,
                 font=UI_SB, anchor="w").pack(side="left", padx=10, pady=4)

        self._viewer_info = tk.StringVar(value="")
        tk.Label(vhdr, textvariable=self._viewer_info, bg=SURFACE2, fg=FG_DIM,
                 font=UI_S).pack(side="right", padx=10)

        _border(parent, thick=2, color=BORDER).pack(fill="x")

        frame = tk.Frame(parent, bg=BG)
        frame.pack(fill="both", expand=True)

        vsb = tk.Scrollbar(frame, bg=SURFACE2, troughcolor=SURFACE2,
                           activebackground=BORDER, width=8, relief="flat")
        vsb.pack(side="right", fill="y")
        hsb = tk.Scrollbar(frame, orient="horizontal", bg=SURFACE2, troughcolor=SURFACE2,
                           activebackground=BORDER, width=8, relief="flat")
        hsb.pack(side="bottom", fill="x")

        self._viewer = tk.Text(
            frame, bg=BG, fg=FG, font=MONO,
            relief="flat", borderwidth=0, state="disabled", wrap="none",
            padx=14, pady=10, insertbackground=FG,
            yscrollcommand=vsb.set, xscrollcommand=hsb.set,
        )
        self._viewer.pack(fill="both", expand=True)
        vsb.config(command=self._viewer.yview)
        hsb.config(command=self._viewer.xview)

        self._viewer.tag_configure("addr",  foreground=FG_DIM)
        self._viewer.tag_configure("val",   foreground=CYAN)
        self._viewer.tag_configure("note",  foreground=FG_DIM, font=UI_S)

    def _build_log_panel(self, parent):
        hdr = tk.Frame(parent, bg=SURFACE2, height=28)
        hdr.pack(fill="x")
        hdr.pack_propagate(False)
        tk.Label(hdr, text="  LOG", bg=SURFACE2, fg=FG_MED,
                 font=UI_SB).pack(side="left", pady=4)
        self._sbtn(hdr, "Clear", self._clear_log).pack(side="right", padx=(0, 4), pady=4)

        _border(parent, thick=2, color=BORDER).pack(fill="x")

        frame = tk.Frame(parent, bg=SURFACE)
        frame.pack(fill="both", expand=True)

        lsb = tk.Scrollbar(frame, bg=SURFACE2, troughcolor=SURFACE2,
                           activebackground=BORDER, width=8, relief="flat")
        lsb.pack(side="right", fill="y")

        self._log = tk.Text(
            frame, bg=SURFACE, fg=FG, font=MONO_S,
            relief="flat", borderwidth=0, state="disabled", wrap="word",
            padx=8, pady=6, yscrollcommand=lsb.set,
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
        bar = tk.Frame(self, bg=SURFACE2, height=26)
        bar.pack(fill="x", side="bottom")
        bar.pack_propagate(False)

        self._status_var = tk.StringVar(value="Ready")
        tk.Label(bar, textvariable=self._status_var, bg=SURFACE2, fg=FG_DIM,
                 font=UI_S).pack(side="left", padx=12)

        self._sbtn(bar, "Open output/", self._open_output).pack(side="right", padx=8, pady=3)

    # ── Widget factories ──────────────────────────────────────────────────────

    def _tbtn(self, parent, text, cmd, bg=BTN_BG):
        b = tk.Button(parent, text=text, command=cmd,
                      bg=bg, fg=FG, activebackground=BTN_HOV, activeforeground=FG,
                      font=UI, relief="flat", borderwidth=0,
                      padx=12, pady=3, cursor="hand2")
        b.bind("<Enter>", lambda _: b.configure(bg=BTN_HOV))
        b.bind("<Leave>", lambda _: b.configure(bg=bg))
        return b

    def _sbtn(self, parent, text, cmd, danger=False):
        bg  = "#3a1f1f" if danger else BTN_BG
        hov = "#4a2828" if danger else BTN_HOV
        fg  = RED if danger else FG_MED
        b = tk.Button(parent, text=text, command=cmd,
                      bg=bg, fg=fg, activebackground=hov, activeforeground=fg,
                      font=UI_S, relief="flat", borderwidth=0,
                      padx=7, pady=1, cursor="hand2")
        b.bind("<Enter>", lambda _: b.configure(bg=hov))
        b.bind("<Leave>", lambda _: b.configure(bg=bg))
        return b

    # ── Logging ───────────────────────────────────────────────────────────────

    def _lw(self, msg, tag=""):
        self._log.configure(state="normal")
        self._log.insert("end", msg + "\n", tag)
        self._log.see("end")
        self._log.configure(state="disabled")

    def log(self, m):      self._lw(f"  {m}")
    def log_ok(self, m):   self._lw(f"  ✓  {m}", "ok")
    def log_err(self, m):  self._lw(f"  ✗  {m}", "err")
    def log_warn(self, m): self._lw(f"  ⚠  {m}", "warn")
    def log_info(self, m): self._lw(f"  →  {m}", "info")
    def log_head(self, m): self._lw(f"\n{m}", "head")
    def log_dim(self, m):  self._lw(f"     {m}", "dim")

    def _clear_log(self):
        self._log.configure(state="normal")
        self._log.delete("1.0", "end")
        self._log.configure(state="disabled")

    def _save_log(self):
        path = filedialog.asksaveasfilename(
            title="Save log as…",
            initialfile=f"bintxt_log_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt",
            defaultextension=".txt",
            filetypes=[("Text file", "*.txt"), ("All files", "*.*")]
        )
        if not path:
            return
        content = self._log.get("1.0", "end")
        Path(path).write_text(content, encoding="utf-8")
        self.log_ok(f"Log saved: {path}")

    def _set_status(self, msg):
        self._status_var.set(msg)
        self.update_idletasks()

    # ── File lists ────────────────────────────────────────────────────────────

    def _browse_files(self):
        paths = filedialog.askopenfilenames(
            title="Select .bin or .txt files",
            filetypes=[("Binary / Text", "*.bin *.txt"), ("All files", "*.*")]
        )
        if not paths:
            return
        cfg = _cfg(); _ensure_dirs(cfg)
        in_dir = Path(cfg["input_dir"])
        for p in paths:
            src = Path(p)
            if src.suffix.lower() in (".bin", ".txt"):
                shutil.copy2(str(src), str(in_dir / src.name))
                self.log_info(f"Added: {src.name}")
        self._refresh_all()

    def _refresh_all(self):
        self.after(0, self._refresh_input)
        self.after(0, self._refresh_output)

    def _refresh_input(self):
        cfg = _cfg()
        files = sorted(
            f for f in Path(cfg["input_dir"]).iterdir()
            if f.suffix.lower() in (".bin", ".txt")
        )
        self._input_files = files
        self._input_lb.delete(0, "end")
        for f in files:
            tag = "BIN" if f.suffix.lower() == ".bin" else "TXT"
            self._input_lb.insert("end", f"  {tag}  {f.name}")
        if self._sel_input in files:
            idx = files.index(self._sel_input)
            self._input_lb.selection_set(idx)

    def _refresh_output(self):
        cfg = _cfg()
        files = sorted(
            f for f in Path(cfg["output_dir"]).iterdir()
            if f.is_file() and f.suffix.lower() in (".bin", ".txt")
        )
        self._output_files = files
        self._output_lb.delete(0, "end")
        for f in files:
            tag = "BIN" if f.suffix.lower() == ".bin" else "TXT"
            self._output_lb.insert("end", f"  {tag}  {f.name}")
        if self._sel_output in files:
            idx = files.index(self._sel_output)
            self._output_lb.selection_set(idx)

    def _on_input_select(self, _=None):
        sel = self._input_lb.curselection()
        if sel and self._input_files:
            f = self._input_files[sel[0]]
            self._sel_input = f
            self._output_lb.selection_clear(0, "end")
            self._preview(f)

    def _on_output_select(self, _=None):
        sel = self._output_lb.curselection()
        if sel and self._output_files:
            f = self._output_files[sel[0]]
            self._sel_output = f
            self._input_lb.selection_clear(0, "end")
            self._preview(f)

    def _clear_input(self):
        cfg = _cfg()
        removed = 0
        for f in Path(cfg["input_dir"]).iterdir():
            if f.suffix.lower() in (".bin", ".txt"):
                f.unlink(); removed += 1
        self.log_warn(f"Cleared {removed} file(s) from input/")
        self._sel_input = None
        self._clear_viewer()
        self._refresh_all()

    def _clear_output(self):
        cfg = _cfg()
        removed = 0
        for f in Path(cfg["output_dir"]).iterdir():
            if f.is_file() and f.suffix.lower() in (".bin", ".txt"):
                f.unlink(); removed += 1
        self.log_warn(f"Cleared {removed} file(s) from output/")
        self._sel_output = None
        self._clear_viewer()
        self._refresh_all()

    def _clear_selected(self, input=True):
        if input:
            sel = self._input_lb.curselection()
            files = self._input_files
        else:
            sel = self._output_lb.curselection()
            files = self._output_files
        if not sel:
            self.log_warn("No files selected"); return
        removed = 0
        for idx in sel:
            if idx < len(files):
                files[idx].unlink(); removed += 1
        self.log_warn(f"Deleted {removed} selected file(s)")
        if input:  self._sel_input  = None
        else:      self._sel_output = None
        self._clear_viewer()
        self._refresh_all()

    def _move_to_input(self):
        sel = self._output_lb.curselection()
        if not sel:
            self.log_warn("No output files selected"); return
        cfg = _cfg(); _ensure_dirs(cfg)
        in_dir = Path(cfg["input_dir"])
        moved = 0
        for idx in sel:
            if idx < len(self._output_files):
                f = self._output_files[idx]
                shutil.move(str(f), str(in_dir / f.name))
                self.log_info(f"Moved to input/: {f.name}")
                moved += 1
        self.log_ok(f"{moved} file(s) moved to input/")
        self._sel_output = None
        self._refresh_all()

    # ── File viewer ───────────────────────────────────────────────────────────

    def _clear_viewer(self, msg="Select a file to preview"):
        self._viewer.configure(state="normal")
        self._viewer.delete("1.0", "end")
        if msg:
            self._viewer.insert("end", f"\n  {msg}", "note")
        self._viewer.configure(state="disabled")
        self._viewer_title.set(msg)
        self._viewer_info.set("")

    def _preview(self, path: Path):
        cfg = _cfg()
        endian, ws = cfg["endian"], cfg["word_sizes"]
        self._viewer_title.set(path.name)
        self._viewer.configure(state="normal")
        self._viewer.delete("1.0", "end")

        try:
            if path.suffix.lower() == ".bin":
                tmp = tempfile.mktemp(suffix=".txt")
                bin_to_txt(str(path), tmp, endian, ws)
                content = Path(tmp).read_text()
                Path(tmp).unlink(missing_ok=True)
                self._viewer_info.set(f"{path.stat().st_size} B  ·  binary (extracted view)")
            else:
                content = path.read_text(errors="replace")
                lines = content.splitlines()
                self._viewer_info.set(f"{path.stat().st_size} B  ·  {len(lines)} lines")

            for line in content.splitlines():
                parts = line.split()
                if not parts:
                    self._viewer.insert("end", "\n"); continue
                self._viewer.insert("end", f"  {parts[0]}", "addr")
                if len(parts) > 1:
                    self._viewer.insert("end", "    ")
                    self._viewer.insert("end", "  ".join(parts[1:]), "val")
                self._viewer.insert("end", "\n")

        except Exception as e:
            self._viewer.insert("end", f"\n  Error: {e}", "note")

        self._viewer.configure(state="disabled")

    # ── Output folder ─────────────────────────────────────────────────────────

    def _open_output(self):
        import subprocess
        out = Path(_cfg()["output_dir"])
        try:
            if sys.platform == "win32":   os.startfile(str(out))
            elif sys.platform == "darwin": subprocess.Popen(["open", str(out)])
            else:                          subprocess.Popen(["xdg-open", str(out)])
        except Exception as e:
            self.log_err(f"Could not open output/: {e}")

    # ── Threaded runner ───────────────────────────────────────────────────────

    def _run_in_thread(self, fn):
        self._set_status("Running…")
        def _wrap():
            try:   fn()
            except Exception as e: self.log_err(f"Unexpected error: {e}")
            finally:
                self.after(0, lambda: self._set_status("Ready"))
                self.after(0, self._refresh_all)
        threading.Thread(target=_wrap, daemon=True).start()

    def _run_convert(self): self._run_in_thread(self._do_convert)
    def _run_draft(self):   self._run_in_thread(self._do_draft)
    def _run_apply(self):   self._run_in_thread(self._do_apply)
    def _run_compare(self): self._run_in_thread(self._do_compare)
    def _run_package(self): self._run_in_thread(self._do_package)

    # ── Convert ───────────────────────────────────────────────────────────────

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
                if ok:   self.log_ok(f"{dst.name}  {h_rt[:20]}…"); passed += 1
                else:    self.log_err(f"{f.name}  roundtrip mismatch"); failed += 1
            except Exception as e:
                self.log_err(f"{f.name}  {e}"); failed += 1

        for f in txts:
            dst = out_dir / (f.stem + ".bin")
            self.log_info(f"APPLY    {f.name}")
            try:
                ok_v, issues = validate_txt_format(str(f), endian, ws)
                if not ok_v: self.log_warn(f"{f.name}  {len(issues)} format issue(s)")
                txt_to_bin(str(f), str(dst), endian, ws)
                ok, h_bin, _ = verify_txt_to_bin(str(f), str(dst), endian, ws, tmp)
                if ok:   self.log_ok(f"{dst.name}  {h_bin[:20]}…"); passed += 1
                else:    self.log_err(f"{f.name}  roundtrip mismatch"); failed += 1
            except Exception as e:
                self.log_err(f"{f.name}  {e}"); failed += 1

        self.log_head(f"Done — {passed} passed, {failed} failed")

    # ── Draft ─────────────────────────────────────────────────────────────────

    def _do_draft(self):
        cfg = _cfg(); _ensure_dirs(cfg)
        in_dir, out_dir = Path(cfg["input_dir"]), Path(cfg["output_dir"])
        endian, ws = cfg["endian"], cfg["word_sizes"]
        tmp = tempfile.mkdtemp()

        bins = sorted(in_dir.glob("*.bin"))
        txts = sorted(in_dir.glob("*.txt"))
        if not bins and not txts:
            self.log_warn("No files in input/"); return

        conflicts = {f.stem for f in bins} & {f.stem for f in txts}
        self.log_head(f"DRAFT  ({len(bins)+len(txts)} file(s))")

        for f in bins:
            stem = f"{f.stem}~bin" if f.stem in conflicts else f.stem
            dst  = out_dir / f"__DRAFT_{stem}.txt"
            self.log_info(f"BIN  {f.name}  →  {dst.name}")
            try:
                bin_to_txt(str(f), str(dst), endian, ws)
                ok, h_orig, h_rt = verify_bin_to_txt(str(f), str(dst), endian, ws, tmp)
                self.log_ok("Roundtrip verified") if ok else self.log_err("Roundtrip failed")
            except Exception as e:
                self.log_err(f"{f.name}  {e}")

        for f in txts:
            stem = f"{f.stem}~txt" if f.stem in conflicts else f.stem
            dst  = out_dir / f"__DRAFT_{stem}.txt"
            self.log_info(f"TXT  {f.name}  →  {dst.name}")
            try:
                ok_v, issues = validate_txt_format(str(f), endian, ws)
                self.log_ok("Format valid") if ok_v else self.log_warn(f"{len(issues)} issue(s)")
                normalize_txt(str(f), str(dst), endian, ws)
                self.log_dim("Normalized draft written")
            except Exception as e:
                self.log_err(f"{f.name}  {e}")

        self.log_head("Review output/__DRAFT_*  then click Apply Drafts")

    # ── Apply ─────────────────────────────────────────────────────────────────

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
                ok, h_bin, _ = verify_txt_to_bin(str(f), str(dst), endian, ws, tmp)
                if ok:
                    self.log_ok(f"Verified  {h_bin[:20]}…")
                    f.unlink(); self.log_dim("DRAFT removed"); passed += 1
                else:
                    self.log_err("Roundtrip mismatch — DRAFT kept"); failed += 1
            except Exception as e:
                self.log_err(f"{f.name}  {e}"); failed += 1

        self.log_head(f"Done — {passed} passed, {failed} failed")

    # ── Compare ───────────────────────────────────────────────────────────────

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

        matches, singletons, _ = group_by_hash(fp_list)

        if matches:
            self.log_head(f"{len(matches)} match group(s):")
            for h, members in sorted(matches.items(), key=lambda x: -len(x[1])):
                self.log_info(f"Group — {len(members)} files  hash: {h[:16]}…")
                for fname, ftype, _ in sorted(members):
                    self.log_dim(f"  [{ftype}]  {fname}")
        else:
            self.log_head("All files unique — no matches")

        moved = 0
        for path, h, _, _ in fp_list:
            if h != "ERROR":
                src = Path(path)
                shutil.move(str(src), str(out_dir / src.name))
                moved += 1
        self.log_info(f"{moved} file(s) moved to output/")

    # ── Package ───────────────────────────────────────────────────────────────

    def _do_package(self):
        cfg = _cfg()
        in_dir  = Path(cfg["input_dir"])
        out_dir = Path(cfg["output_dir"])

        # Let user pick exactly which files to include — pre-navigate to output/ then input/
        candidates = (
            sorted(out_dir.iterdir(), key=lambda f: f.name) +
            sorted(in_dir.iterdir(),  key=lambda f: f.name)
        )

        # Show selection dialog starting in output/
        selected = filedialog.askopenfilenames(
            title="Select files to package (input/ and output/ shown — navigate freely)",
            initialdir=str(out_dir),
            filetypes=[("Binary / Text / All", "*.bin *.txt *.*"), ("All files", "*.*")]
        )
        if not selected:
            return

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

        with zipfile.ZipFile(save_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for p in selected:
                src = Path(p)
                zf.write(str(src), src.name)   # flat — no folders
                self.log_dim(f"  + {src.name}")

        self.log_ok(f"Saved: {save_path}  ({len(selected)} files)")


if __name__ == "__main__":
    app = BintxtApp()
    app.mainloop()
