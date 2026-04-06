"""
ui/app.py — bintxt_tool Desktop UI
Requires only Python standard library. Run from repo root: python3 ui/app.py
"""

import os
import platform
import shutil
import subprocess
import sys
import tempfile
import threading
import zipfile
from datetime import datetime
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

REPO_ROOT = Path(__file__).resolve().parent.parent

# ─── Version ──────────────────────────────────────────────────────────────────
UI_VERSION  = "v1.0.0"   # update on UI releases only
CLI_VERSION = "v1.4.1"   # update when shipping a new CLI core tag


def _asset_path(name: str) -> Path:
    """Resolve a ui/assets/<name> path — works both from source and PyInstaller frozen."""
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / "ui" / "assets" / name
    return Path(__file__).resolve().parent / "assets" / name
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
BORDER_S = "#383838"
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

def _open_folder(path: str):
    """Open a folder in the native file manager (cross-platform)."""
    p = str(path)
    try:
        if platform.system() == "Windows":
            os.startfile(p)
        elif platform.system() == "Darwin":
            subprocess.Popen(["open", p])
        else:
            subprocess.Popen(["xdg-open", p])
    except Exception:
        pass


def _border_h(parent, thick=1, color=BORDER):
    return tk.Frame(parent, bg=color, height=thick)

def _border_v(parent, thick=1, color=BORDER):
    return tk.Frame(parent, bg=color, width=thick)

def _dt_tag():
    return datetime.now().strftime("%Y-%m-%d_%I%M%p").lower()


class BintxtApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("bintxt_tool")
        self.configure(bg=BG)
        self.minsize(1000, 650)

        # App icon — resolves relative to this file so it works both
        # when running from source and when frozen by PyInstaller
        try:
            if platform.system() == "Windows":
                self.iconbitmap(str(_asset_path("icon.ico")))
            else:
                _img = tk.PhotoImage(file=str(_asset_path("icon_1024.png")))
                self.iconphoto(True, _img)
        except Exception:
            pass  # no icon is fine

        self._cfg = _cfg()
        _ensure_dirs(self._cfg)
        self._sel_input  = None
        self._sel_output = None
        self._input_files  = []
        self._output_files = []
        self._undo_stack   = []   # list of {"files": [(Path, bytes)], "desc": str}

        self._apply_scrollbar_style()
        self._build()
        self._refresh_all()

        self.update_idletasks()
        w, h = 1280, 780
        x = (self.winfo_screenwidth()  - w) // 2
        y = (self.winfo_screenheight() - h) // 2
        self.geometry(f"{w}x{h}+{x}+{y}")

    # ── Scrollbar style ───────────────────────────────────────────────────────

    def _apply_scrollbar_style(self):
        style = ttk.Style(self)
        style.theme_use("clam")
        for orient in ("Vertical", "Horizontal"):
            style.configure(
                f"Dark.{orient}.TScrollbar",
                background=BORDER_S,
                troughcolor=SURFACE,
                arrowcolor=FG_DIM,
                bordercolor=SURFACE,
                lightcolor=SURFACE,
                darkcolor=SURFACE,
                gripcount=0,
            )
            style.map(
                f"Dark.{orient}.TScrollbar",
                background=[("active", BORDER), ("pressed", ACCENT)],
            )

    def _vscroll(self, parent):
        return ttk.Scrollbar(parent, orient="vertical",   style="Dark.Vertical.TScrollbar")

    def _hscroll(self, parent):
        return ttk.Scrollbar(parent, orient="horizontal", style="Dark.Horizontal.TScrollbar")

    # ── Layout ────────────────────────────────────────────────────────────────

    def _build(self):
        self._build_toolbar()
        _border_h(self, thick=2, color=BORDER).pack(fill="x")
        self._build_body()
        _border_h(self, thick=1, color=BORDER).pack(fill="x")
        self._build_statusbar()


    def _build_toolbar(self):
        bar = tk.Frame(self, bg=SURFACE2, height=42)
        bar.pack(fill="x")
        bar.pack_propagate(False)

        # Logo — upper left
        try:
            self._toolbar_logo = tk.PhotoImage(file=str(_asset_path("icon_32.png")))
            tk.Label(bar, image=self._toolbar_logo, bg=SURFACE2).pack(
                side="left", padx=(8, 4), pady=5)
        except Exception:
            pass

        _border_v(bar, thick=1, color=BORDER_S).pack(side="left", fill="y", padx=(0, 6), pady=8)

        # Left: action buttons
        for label, cmd, primary in [
            ("Convert",      self._run_convert, True),
            ("Draft",        self._run_draft,   False),
            ("Apply Drafts", self._run_apply,   False),
            ("Compare",      self._run_compare, False),
        ]:
            bg = BTN_ACT if primary else BTN_BG
            self._tbtn(bar, label, cmd, bg=bg).pack(side="left", padx=3, pady=6)

        # Right: Save Log + Package + Settings
        self._tbtn(bar, "⚙  Settings", self._open_settings).pack(side="right", padx=(3, 10), pady=6)
        _border_v(bar, thick=1, color=BORDER_S).pack(side="right", fill="y", padx=6, pady=8)
        self._tbtn(bar, "📦  Package",  self._run_package).pack(side="right", padx=3, pady=6)
        self._tbtn(bar, "💾  Save Log", self._save_log).pack(side="right", padx=3, pady=6)
        _border_v(bar, thick=1, color=BORDER_S).pack(side="right", fill="y", padx=6, pady=8)

    def _build_body(self):
        paned = tk.PanedWindow(self, orient="horizontal",
                               bg=BORDER, sashwidth=4,
                               sashrelief="flat", opaqueresize=True)
        paned.pack(fill="both", expand=True)

        left = tk.Frame(paned, bg=BG)
        paned.add(left, minsize=200, width=240)

        vpaned = tk.PanedWindow(left, orient="vertical",
                                bg=BORDER, sashwidth=4,
                                sashrelief="flat", opaqueresize=True)
        vpaned.pack(fill="both", expand=True)

        inp_frame = tk.Frame(vpaned, bg=BG)
        vpaned.add(inp_frame, minsize=120)
        out_frame = tk.Frame(vpaned, bg=BG)
        vpaned.add(out_frame, minsize=120)

        self._build_file_panel(inp_frame, "INPUT",  is_input=True)
        self._build_file_panel(out_frame, "OUTPUT", is_input=False)

        center = tk.Frame(paned, bg=BG)
        paned.add(center, minsize=300)
        self._build_viewer(center)

        right = tk.Frame(paned, bg=BG)
        paned.add(right, minsize=200, width=280)
        self._build_log_panel(right)

    def _build_file_panel(self, parent, title, is_input):
        # Header
        hdr = tk.Frame(parent, bg=SURFACE2, height=28)
        hdr.pack(fill="x")
        hdr.pack_propagate(False)
        tk.Label(hdr, text=f"  {title}", bg=SURFACE2, fg=FG_MED,
                 font=UI_SB).pack(side="left", pady=4)

        dir_key = "input_dir" if is_input else "output_dir"
        folder_btn = tk.Label(
            hdr, text="📂", bg=SURFACE2, fg=FG_DIM,
            font=("Segoe UI Emoji", 11) if platform.system() == "Windows" else UI_S,
            cursor="hand2",
        )
        folder_btn.pack(side="left", padx=(4, 0), pady=4)
        folder_btn.bind("<Button-1>", lambda _e, k=dir_key: _open_folder(_cfg()[k]))
        folder_btn.bind("<Enter>",    lambda _e, w=folder_btn: w.config(fg=FG))
        folder_btn.bind("<Leave>",    lambda _e, w=folder_btn: w.config(fg=FG_DIM))

        if is_input:
            self._sbtn(hdr, "Add", self._browse_files).pack(side="right", padx=(0, 6), pady=4)
        else:
            self._sbtn(hdr, "Move to Input", self._move_to_input).pack(side="right", padx=(0, 6), pady=4)

        _border_h(parent, thick=2, color=BORDER).pack(fill="x")

        # Listbox
        box_frame = tk.Frame(parent, bg=SURFACE)
        box_frame.pack(fill="both", expand=True)

        sb = self._vscroll(box_frame)
        sb.pack(side="right", fill="y", padx=(0, 2), pady=2)

        lb = tk.Listbox(
            box_frame,
            bg=SURFACE, fg=FG,
            selectbackground=SEL_BG, selectforeground=FG,
            font=MONO_S, relief="flat", borderwidth=0, highlightthickness=0,
            activestyle="none", yscrollcommand=sb.set,
            selectmode="extended",
        )
        lb.pack(fill="both", expand=True, padx=(4, 0), pady=2)
        sb.config(command=lb.yview)

        # Action row
        _border_h(parent, thick=1, color=BORDER_S).pack(fill="x")
        act = tk.Frame(parent, bg=SURFACE2, height=28)
        act.pack(fill="x")
        act.pack_propagate(False)

        if is_input:
            self._input_lb = lb
            lb.bind("<<ListboxSelect>>", self._on_input_select)
            self._sbtn(act, "Clear Selected", lambda: self._clear_selected(inp=True),  danger=True).pack(side="left", padx=(6, 3), pady=4)
            self._sbtn(act, "Clear All",      self._clear_input, danger=True).pack(side="left", pady=4)
            self._undo_btn_input = self._sbtn(act, "Undo", lambda: self._undo(inp=True))
            self._undo_btn_input.pack(side="right", padx=(0, 6), pady=4)
        else:
            self._output_lb = lb
            lb.bind("<<ListboxSelect>>", self._on_output_select)
            self._sbtn(act, "Clear Selected", lambda: self._clear_selected(inp=False), danger=True).pack(side="left", padx=(6, 3), pady=4)
            self._sbtn(act, "Clear All",      self._clear_output, danger=True).pack(side="left", pady=4)
            self._undo_btn_output = self._sbtn(act, "Undo", lambda: self._undo(inp=False))
            self._undo_btn_output.pack(side="right", padx=(0, 6), pady=4)

    def _build_viewer(self, parent):
        vhdr = tk.Frame(parent, bg=SURFACE2, height=28)
        vhdr.pack(fill="x")
        vhdr.pack_propagate(False)

        self._viewer_title = tk.StringVar(value="Select a file to preview")
        tk.Label(vhdr, textvariable=self._viewer_title, bg=SURFACE2, fg=FG_MED,
                 font=UI_SB, anchor="w").pack(side="left", padx=10, pady=4)

        # Edit / Save / Cancel buttons (shown only for editable .txt files)
        self._edit_cancel_btn = self._sbtn(vhdr, "Cancel", self._cancel_edit)
        self._edit_save_btn   = self._sbtn(vhdr, "Save",   self._save_edit)
        self._edit_toggle_btn = self._sbtn(vhdr, "Edit",   self._start_edit)
        # Pack right-to-left so order reads: Edit | Save | Cancel
        self._edit_cancel_btn.pack(side="right", padx=(0, 6), pady=4)
        self._edit_save_btn.pack(side="right",   padx=(0, 3), pady=4)
        self._edit_toggle_btn.pack(side="right", padx=(0, 6), pady=4)
        self._edit_cancel_btn.pack_forget()
        self._edit_save_btn.pack_forget()

        self._viewer_info = tk.StringVar(value="")
        tk.Label(vhdr, textvariable=self._viewer_info, bg=SURFACE2, fg=FG_DIM,
                 font=UI_S).pack(side="right", padx=10)

        _border_h(parent, thick=2, color=BORDER).pack(fill="x")

        frame = tk.Frame(parent, bg=BG)
        frame.pack(fill="both", expand=True)

        vsb = self._vscroll(frame)
        vsb.pack(side="right", fill="y", padx=(0, 2), pady=2)
        hsb = self._hscroll(frame)
        hsb.pack(side="bottom", fill="x", padx=2, pady=(0, 2))

        self._viewer = tk.Text(
            frame, bg=BG, fg=FG, font=MONO,
            relief="flat", borderwidth=0, state="disabled", wrap="none",
            padx=14, pady=10, insertbackground=FG,
            yscrollcommand=vsb.set, xscrollcommand=hsb.set,
        )
        self._viewer.pack(fill="both", expand=True)
        vsb.config(command=self._viewer.yview)
        hsb.config(command=self._viewer.xview)

        self._viewer.tag_configure("addr", foreground=FG_DIM)
        self._viewer.tag_configure("val",  foreground=CYAN)
        self._viewer.tag_configure("note", foreground=FG_DIM, font=UI_S)
        self._viewer.tag_configure("warn_line", background="#2a2010")

        self._editing_file  = None   # Path currently being edited
        self._editing       = False

    def _build_log_panel(self, parent):
        hdr = tk.Frame(parent, bg=SURFACE2, height=28)
        hdr.pack(fill="x")
        hdr.pack_propagate(False)
        tk.Label(hdr, text="  LOG", bg=SURFACE2, fg=FG_MED,
                 font=UI_SB).pack(side="left", pady=4)
        self._sbtn(hdr, "Clear", self._clear_log).pack(side="right", padx=(0, 6), pady=4)

        _border_h(parent, thick=2, color=BORDER).pack(fill="x")

        frame = tk.Frame(parent, bg=SURFACE)
        frame.pack(fill="both", expand=True)

        lsb = self._vscroll(frame)
        lsb.pack(side="right", fill="y", padx=(0, 2), pady=2)

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

        # Version watermark — centered
        tk.Label(bar,
                 text=f"UI {UI_VERSION}   ·   core {CLI_VERSION}",
                 bg=SURFACE2, fg=FG_DIM, font=UI_S).place(relx=0.5, rely=0.5, anchor="center")

    # ── Widget factories ──────────────────────────────────────────────────────

    def _tbtn(self, parent, text, cmd, bg=BTN_BG):
        """Toolbar button with 1px border frame."""
        wrap = tk.Frame(parent, bg=BORDER, padx=1, pady=1)
        b = tk.Button(wrap, text=text, command=cmd,
                      bg=bg, fg=FG, activebackground=BTN_HOV, activeforeground=FG,
                      font=UI, relief="flat", borderwidth=0,
                      padx=11, pady=2, cursor="hand2")
        b.pack()
        b.bind("<Enter>", lambda _: b.configure(bg=BTN_HOV))
        b.bind("<Leave>", lambda _: b.configure(bg=bg))
        return wrap

    def _sbtn(self, parent, text, cmd, danger=False):
        """Small secondary button."""
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
    def log_ok(self, m):   self._lw(f"  OK   {m}", "ok")
    def log_err(self, m):  self._lw(f"  FAIL {m}", "err")
    def log_warn(self, m): self._lw(f"  WARN {m}", "warn")
    def log_info(self, m): self._lw(f"  -->  {m}", "info")
    def log_head(self, m): self._lw(f"\n{m}", "head")
    def log_dim(self, m):  self._lw(f"       {m}", "dim")

    def _clear_log(self):
        self._log.configure(state="normal")
        self._log.delete("1.0", "end")
        self._log.configure(state="disabled")

    def _save_log(self):
        """Save log to reports/ with standard naming convention."""
        cfg = _cfg(); _ensure_dirs(cfg)
        report_dir = Path(cfg["report_dir"])
        filename   = f"{_dt_tag()}_bintxt-tool_ui-session-log.txt"
        path       = report_dir / filename

        raw = self._log.get("1.0", "end")

        # Build formatted report (plain text, UI-log style)
        lines = [
            "============================================================",
            "  BINTXT_TOOL — UI SESSION LOG",
            f"  Generated : {datetime.now().strftime('%Y-%m-%d  %I:%M %p')}",
            "============================================================",
            "",
        ]
        # Strip unicode symbols for safe cross-platform reading
        # (keep original in UI, write sanitized to file)
        for line in raw.splitlines():
            lines.append(line)

        lines += [
            "",
            "============================================================",
            "  END OF LOG",
            "============================================================",
        ]

        path.write_text("\n".join(lines), encoding="utf-8")
        self.log_ok(f"Log saved: {filename}")

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
            # Preview first selected
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

    # ── File operations ───────────────────────────────────────────────────────

    def _files_for_panel(self, inp):
        return self._input_files if inp else self._output_files

    def _lb_for_panel(self, inp):
        return self._input_lb if inp else self._output_lb

    def _push_undo(self, files_to_delete, desc):
        """Read file contents into memory and push to undo stack."""
        record = {"files": [], "desc": desc, "inp": None}
        for f in files_to_delete:
            try:
                record["files"].append((f, f.read_bytes()))
            except Exception:
                pass
        if record["files"]:
            self._undo_stack.append(record)

    def _undo(self, inp=True):
        # Find the most recent undo record for this panel
        # We track panel by directory
        cfg = _cfg()
        target_dir = Path(cfg["input_dir"]) if inp else Path(cfg["output_dir"])

        # Search stack in reverse for records matching this dir
        for i in range(len(self._undo_stack) - 1, -1, -1):
            record = self._undo_stack[i]
            if record["files"] and Path(record["files"][0][0]).parent == target_dir:
                restored = 0
                for path, data in record["files"]:
                    try:
                        path.write_bytes(data)
                        restored += 1
                    except Exception as e:
                        self.log_err(f"Undo failed for {path.name}: {e}")
                self._undo_stack.pop(i)
                self.log_info(f"Undo: restored {restored} file(s)  [{record['desc']}]")
                self._refresh_all()
                return
        self.log_warn("Nothing to undo")

    def _clear_selected(self, inp=True):
        lb    = self._lb_for_panel(inp)
        files = self._files_for_panel(inp)
        sel   = lb.curselection()
        if not sel:
            self.log_warn("No files selected"); return

        to_delete = [files[i] for i in sel if i < len(files)]
        self._push_undo(to_delete, f"Clear Selected ({len(to_delete)} file(s))")

        for f in to_delete:
            f.unlink()
        self.log_warn(f"Deleted {len(to_delete)} file(s)  (Undo to restore)")

        if inp: self._sel_input  = None
        else:   self._sel_output = None
        self._clear_viewer()
        self._refresh_all()

    def _clear_input(self):
        files = [f for f in Path(_cfg()["input_dir"]).iterdir()
                 if f.suffix.lower() in (".bin", ".txt")]
        self._push_undo(files, "Clear All input/")
        for f in files: f.unlink()
        self.log_warn(f"Cleared {len(files)} file(s) from input/  (Undo to restore)")
        self._sel_input = None
        self._clear_viewer()
        self._refresh_all()

    def _clear_output(self):
        files = [f for f in Path(_cfg()["output_dir"]).iterdir()
                 if f.is_file() and f.suffix.lower() in (".bin", ".txt")]
        self._push_undo(files, "Clear All output/")
        for f in files: f.unlink()
        self.log_warn(f"Cleared {len(files)} file(s) from output/  (Undo to restore)")
        self._sel_output = None
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
        self._editing = False
        self._editing_file = None
        self._viewer.configure(state="normal")
        self._viewer.delete("1.0", "end")
        if msg:
            self._viewer.insert("end", f"\n  {msg}", "note")
        self._viewer.configure(state="disabled")
        self._viewer.configure(bg=BG)
        self._viewer_title.set(msg)
        self._viewer_info.set("")
        self._edit_toggle_btn.pack_forget()
        self._edit_save_btn.pack_forget()
        self._edit_cancel_btn.pack_forget()

    def _preview(self, path: Path):
        # Cancel any active edit
        if self._editing:
            self._cancel_edit()

        cfg = _cfg()
        endian, ws, ab = cfg["endian"], cfg["word_sizes"], cfg.get("address_bits", 32)
        self._viewer_title.set(path.name)
        self._viewer.configure(state="normal", bg=BG)
        self._viewer.delete("1.0", "end")

        is_txt = path.suffix.lower() == ".txt"

        try:
            if not is_txt:
                tmp = tempfile.mktemp(suffix=".txt")
                bin_to_txt(str(path), tmp, endian, ws, ab)
                content = Path(tmp).read_text()
                Path(tmp).unlink(missing_ok=True)
                self._viewer_info.set(f"{path.stat().st_size} B  ·  binary (extracted view — read only)")
            else:
                content = path.read_text(errors="replace")
                lines   = content.splitlines()
                self._viewer_info.set(f"{path.stat().st_size} B  ·  {len(lines)} lines")

            self._render_hex(content)

        except Exception as e:
            self._viewer.insert("end", f"\n  Error: {e}", "note")

        self._viewer.configure(state="disabled")
        self._editing_file = path if is_txt else None

        # Show Edit only for .txt files
        self._edit_save_btn.pack_forget()
        self._edit_cancel_btn.pack_forget()
        if is_txt:
            self._edit_toggle_btn.pack(side="right", padx=(0, 6), pady=4)
        else:
            self._edit_toggle_btn.pack_forget()

    def _render_hex(self, content: str):
        """Render hex text with address/value coloring."""
        for line in content.splitlines():
            parts = line.split()
            if not parts:
                self._viewer.insert("end", "\n"); continue
            self._viewer.insert("end", f"  {parts[0]}", "addr")
            if len(parts) > 1:
                self._viewer.insert("end", "    ")
                self._viewer.insert("end", "  ".join(parts[1:]), "val")
            self._viewer.insert("end", "\n")

    # ── Inline editor ─────────────────────────────────────────────────────────

    def _start_edit(self):
        if not self._editing_file:
            return
        self._editing = True
        self._viewer.configure(state="normal", bg=SURFACE)

        # Swap Edit → Save + Cancel
        self._edit_toggle_btn.pack_forget()
        self._edit_save_btn.pack(side="right",   padx=(0, 3), pady=4)
        self._edit_cancel_btn.pack(side="right", padx=(0, 6), pady=4)

        self._viewer_info.set("editing — format validated on save")
        self._viewer.focus_set()

    def _cancel_edit(self):
        if not self._editing_file:
            return
        self._editing = False
        # Restore from disk
        self._preview(self._editing_file)

    def _save_edit(self):
        if not self._editing_file:
            return
        cfg    = _cfg()
        endian = cfg["endian"]
        ws     = cfg["word_sizes"]
        content = self._viewer.get("1.0", "end-1c")

        # Validate
        import tempfile as _tmp
        tmp_path = Path(_tmp.mktemp(suffix=".txt"))
        tmp_path.write_text(content, encoding="utf-8")
        ok, issues = validate_txt_format(str(tmp_path), endian, ws)
        tmp_path.unlink(missing_ok=True)

        # Highlight problem lines
        self._viewer.tag_remove("warn_line", "1.0", "end")
        if issues:
            # Parse line numbers from issue strings
            for issue in issues:
                try:
                    ln = int(issue.split("line ")[1].split(":")[0])
                    self._viewer.tag_add("warn_line", f"{ln}.0", f"{ln}.end")
                except Exception:
                    pass
            self._viewer_info.set(f"  {len(issues)} format issue(s) — highlighted  (save anyway?)")
            # Give user a moment to see, then save anyway after confirm
            if not messagebox.askyesno(
                "Format Issues",
                f"{len(issues)} format issue(s) found:\n\n" +
                "\n".join(issues[:8]) +
                ("\n..." if len(issues) > 8 else "") +
                "\n\nSave anyway?",
                parent=self
            ):
                return

        # Write
        self._editing_file.write_text(content, encoding="utf-8")
        self.log_ok(f"Saved: {self._editing_file.name}")
        self._editing = False
        self._refresh_all()

        # Return to read view
        self._preview(self._editing_file)

    # ── Output folder ─────────────────────────────────────────────────────────

    def _open_output(self):
        _open_folder(_cfg()["output_dir"])

    # ── Threaded runner ───────────────────────────────────────────────────────

    def _run_in_thread(self, fn):
        self._set_status("Running...")
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
        endian, ws, ab = cfg["endian"], cfg["word_sizes"], cfg.get("address_bits", 32)
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
                bin_to_txt(str(f), str(dst), endian, ws, ab)
                ok, h_orig, h_rt = verify_bin_to_txt(str(f), str(dst), endian, ws, tmp)
                if ok:   self.log_ok(f"{dst.name}  {h_rt}"); passed += 1
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
                if ok:   self.log_ok(f"{dst.name}  {h_bin}"); passed += 1
                else:    self.log_err(f"{f.name}  roundtrip mismatch"); failed += 1
            except Exception as e:
                self.log_err(f"{f.name}  {e}"); failed += 1

        self.log_head(f"Done -- {passed} passed, {failed} failed")

    # ── Draft ─────────────────────────────────────────────────────────────────

    def _do_draft(self):
        cfg = _cfg(); _ensure_dirs(cfg)
        in_dir, out_dir = Path(cfg["input_dir"]), Path(cfg["output_dir"])
        endian, ws, ab = cfg["endian"], cfg["word_sizes"], cfg.get("address_bits", 32)
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
            self.log_info(f"BIN  {f.name}  -->  {dst.name}")
            try:
                bin_to_txt(str(f), str(dst), endian, ws, ab)
                ok, h_orig, h_rt = verify_bin_to_txt(str(f), str(dst), endian, ws, tmp)
                self.log_ok("Roundtrip verified") if ok else self.log_err("Roundtrip failed")
            except Exception as e:
                self.log_err(f"{f.name}  {e}")

        for f in txts:
            stem = f"{f.stem}~txt" if f.stem in conflicts else f.stem
            dst  = out_dir / f"__DRAFT_{stem}.txt"
            self.log_info(f"TXT  {f.name}  -->  {dst.name}")
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
        endian, ws, ab = cfg["endian"], cfg["word_sizes"], cfg.get("address_bits", 32)
        tmp = tempfile.mkdtemp()

        drafts = sorted(out_dir.glob("__DRAFT_*.txt"))
        if not drafts:
            self.log_warn("No __DRAFT_*.txt in output/  --  run Draft first"); return

        self.log_head(f"APPLY  ({len(drafts)} draft(s))")
        passed = failed = 0

        for f in drafts:
            stem = f.stem[len("__DRAFT_"):]
            dst  = out_dir / f"{stem}.bin"
            self.log_info(f"{f.name}  -->  {dst.name}")
            try:
                txt_to_bin(str(f), str(dst), endian, ws)
                ok, h_bin, _ = verify_txt_to_bin(str(f), str(dst), endian, ws, tmp)
                if ok:
                    self.log_ok(f"Verified  {h_bin}")
                    f.unlink(); self.log_dim("DRAFT removed"); passed += 1
                else:
                    self.log_err("Roundtrip mismatch -- DRAFT kept"); failed += 1
            except Exception as e:
                self.log_err(f"{f.name}  {e}"); failed += 1

        self.log_head(f"Done -- {passed} passed, {failed} failed")

    # ── Compare ───────────────────────────────────────────────────────────────

    def _do_compare(self):
        cfg = _cfg(); _ensure_dirs(cfg)
        in_dir, out_dir = Path(cfg["input_dir"]), Path(cfg["output_dir"])
        endian, ws, ab = cfg["endian"], cfg["word_sizes"], cfg.get("address_bits", 32)
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
                self.log_dim(f"[{ftype}]  {f.name}  {h}")
                fp_list.append((str(f), h, ftype, ""))

        matches, singletons, _ = group_by_hash(fp_list)

        if matches:
            self.log_head(f"{len(matches)} match group(s):")
            for h, members in sorted(matches.items(), key=lambda x: -len(x[1])):
                self.log_info(f"Group -- {len(members)} files  hash: {h}")
                for fname, ftype, _ in sorted(members):
                    self.log_dim(f"  [{ftype}]  {fname}")
        else:
            self.log_head("All files unique -- no matches")

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
        out_dir = Path(cfg["output_dir"])

        selected = filedialog.askopenfilenames(
            title="Select files to package",
            initialdir=str(out_dir),
            filetypes=[("Binary / Text / All", "*.bin *.txt *.*"), ("All files", "*.*")]
        )
        if not selected:
            return

        default = f"bintxt_export_{datetime.now().strftime('%Y%m%d_%H%M%S')}.zip"
        save_path = filedialog.asksaveasfilename(
            title="Save package as...",
            initialfile=default,
            defaultextension=".zip",
            filetypes=[("ZIP archive", "*.zip")]
        )
        if not save_path:
            return

        self.log_head(f"PACKAGE  -->  {Path(save_path).name}")
        with zipfile.ZipFile(save_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for p in selected:
                src = Path(p)
                zf.write(str(src), src.name)
                self.log_dim(f"  + {src.name}")

        self.log_ok(f"Saved: {save_path}  ({len(selected)} files)")


    def _open_settings(self):
        SettingsDialog(self)


# ─────────────────────────────────────────────────────────────────────────────
# Settings Dialog
# ─────────────────────────────────────────────────────────────────────────────

# Sample binary data for live preview (32 bytes)
_PREVIEW_DATA = bytes([
    0xDE, 0xAD, 0xBE, 0xEF,  0xCA, 0xFE, 0xBA, 0xBE,
    0x01, 0x23, 0x45, 0x67,  0x89, 0xAB, 0xCD, 0xEF,
    0x00, 0x00, 0x00, 0x00,  0xFF, 0xFF, 0xFF, 0xFF,
    0x10, 0x20, 0x30, 0x40,  0x50, 0x60, 0x70, 0x80,
])

def _build_preview(word_sizes, endian, address_bits=32):
    """Generate a few sample hex rows from _PREVIEW_DATA using given config."""
    try:
        ws   = [int(x) for x in word_sizes if str(x).strip()]
        if not ws or any(w not in (1, 2, 4, 8) for w in ws):
            return "  (invalid word size — must be 1, 2, 4, or 8)"
        if not (1 <= len(ws) <= 6):
            return "  (1–6 words per row)"
        stride  = sum(ws)
        addr_w  = address_bits // 4
        data    = _PREVIEW_DATA
        lines   = []
        offset  = 0
        while offset < len(data) and len(lines) < 6:
            parts = [f"{offset:0{addr_w}x}"]
            cur   = offset
            for w in ws:
                chunk = data[cur:cur+w] if cur+w <= len(data) else data[cur:] + b"\x00"*(w-(len(data)-cur))
                val   = int.from_bytes(chunk[:w], byteorder=endian)
                parts.append(f"{val:0{w*2}x}")
                cur  += w
            lines.append("  " + "  ".join(parts))
            offset += stride
        lines.append(f"  {offset:0{addr_w}x}")
        return "\n".join(lines)
    except Exception as e:
        return f"  (error: {e})"


class SettingsDialog(tk.Toplevel):
    def __init__(self, parent: BintxtApp):
        super().__init__(parent)
        self._parent = parent
        self.title("Settings")
        self.configure(bg=BG)
        self.resizable(False, False)
        self.grab_set()   # modal

        cfg = _cfg()

        # ── State vars ────────────────────────────────────────────────────────
        self._endian      = tk.StringVar(value=cfg["endian"])
        self._word_sizes  = tk.StringVar(value=" ".join(str(w) for w in cfg["word_sizes"]))
        self._addr_bits   = tk.StringVar(value=str(cfg.get("address_bits", 32)))
        self._input_dir   = tk.StringVar(value=cfg["input_dir"])
        self._output_dir  = tk.StringVar(value=cfg["output_dir"])
        self._report_dir  = tk.StringVar(value=cfg["report_dir"])

        # Trigger preview rebuild on any change
        for v in (self._endian, self._word_sizes, self._addr_bits):
            v.trace_add("write", lambda *_: self._update_preview())

        self._build()
        self._update_preview()

        self.update_idletasks()
        w, h = 1080, 680
        px = parent.winfo_x() + (parent.winfo_width()  - w) // 2
        py = parent.winfo_y() + (parent.winfo_height() - h) // 2
        self.geometry(f"{w}x{h}+{px}+{py}")

    def _build(self):
        # Header
        hdr = tk.Frame(self, bg=SURFACE, height=40)
        hdr.pack(fill="x")
        hdr.pack_propagate(False)
        tk.Label(hdr, text="  Settings", bg=SURFACE, fg=FG,
                 font=UI_B).pack(side="left", pady=8)
        _border_h(self, thick=2, color=BORDER).pack(fill="x")

        # Body: left = controls, right = preview
        body = tk.Frame(self, bg=BG)
        body.pack(fill="both", expand=True, padx=0)

        left  = tk.Frame(body, bg=BG, width=430)
        left.pack(side="left", fill="y", padx=0)
        left.pack_propagate(False)

        _border_v(body, thick=2, color=BORDER).pack(side="left", fill="y")

        right = tk.Frame(body, bg=BG)
        right.pack(side="left", fill="both", expand=True)

        self._build_controls(left)
        self._build_preview_panel(right)

        # Footer
        _border_h(self, thick=1, color=BORDER).pack(fill="x")
        foot = tk.Frame(self, bg=SURFACE2, height=40)
        foot.pack(fill="x")
        foot.pack_propagate(False)

        self._status = tk.StringVar(value="")
        tk.Label(foot, textvariable=self._status, bg=SURFACE2, fg=GREEN,
                 font=UI_S).pack(side="left", padx=12)

        self._mk_btn(foot, "Cancel", self.destroy, danger=False).pack(side="right", padx=(4, 12), pady=6)
        self._mk_btn(foot, "Save",   self._save,   primary=True).pack(side="right", padx=4, pady=6)

    def _build_controls(self, parent):
        pad = {"padx": 16, "pady": 0}

        def section(text):
            tk.Label(parent, text=text, bg=BG, fg=FG_DIM,
                     font=UI_SB).pack(anchor="w", padx=16, pady=(14, 4))

        def row(parent, label, widget_fn):
            r = tk.Frame(parent, bg=BG)
            r.pack(fill="x", **pad, pady=3)
            tk.Label(r, text=label, bg=BG, fg=FG_MED, font=UI_S,
                     width=12, anchor="w").pack(side="left")
            widget_fn(r)

        # ── Format ────────────────────────────────────────────────────────────
        section("FORMAT")

        # Endian — stacked vertically
        tk.Label(parent, text="Byte order", bg=BG, fg=FG_MED, font=UI_S,
                 anchor="w").pack(anchor="w", padx=16, pady=(2, 4))
        for val, lbl, sub in (
            ("little", "little-endian", "x86 / ARM"),
            ("big",    "big-endian",    "MIPS / PowerPC"),
        ):
            r = tk.Frame(parent, bg=BG)
            r.pack(fill="x", padx=20, pady=2)
            tk.Radiobutton(r, text=lbl, variable=self._endian, value=val,
                           bg=BG, fg=FG, selectcolor=SURFACE2,
                           activebackground=BG, activeforeground=FG,
                           font=UI_S).pack(side="left")
            tk.Label(r, text=f"  —  {sub}", bg=BG, fg=FG_DIM,
                     font=UI_S).pack(side="left")

        # Address width — stacked radio
        tk.Label(parent, text="Address width", bg=BG, fg=FG_MED, font=UI_S,
                 anchor="w").pack(anchor="w", padx=16, pady=(12, 4))
        for val, lbl, sub in (
            ("32", "32-bit", "8 hex digits — up to 4 GB\n(standard config files)"),
            ("64", "64-bit", "16 hex digits — up to 16 EB\n(large firmware / ELF)"),
        ):
            r = tk.Frame(parent, bg=BG)
            r.pack(fill="x", padx=20, pady=2)
            tk.Radiobutton(r, text=lbl, variable=self._addr_bits, value=val,
                           bg=BG, fg=FG, selectcolor=SURFACE2,
                           activebackground=BG, activeforeground=FG,
                           font=UI_S).pack(side="left", anchor="n")
            tk.Label(r, text=f"  —  {sub}", bg=BG, fg=FG_DIM,
                     font=UI_S, justify="left").pack(side="left", anchor="n")

        # Word sizes — description below entry
        tk.Label(parent, text="Word sizes", bg=BG, fg=FG_MED, font=UI_S,
                 anchor="w").pack(anchor="w", padx=16, pady=(14, 4))
        ws_entry = tk.Entry(parent, textvariable=self._word_sizes,
                            bg=SURFACE2, fg=FG, insertbackground=FG,
                            font=MONO, relief="flat", width=22)
        ws_entry.pack(anchor="w", padx=20)
        tk.Label(parent, text="bytes per word, space-separated  (1 2 4 or 8 only)",
                 bg=BG, fg=FG_DIM, font=UI_S, anchor="w").pack(anchor="w", padx=20, pady=(3, 0))

        # Presets — 3-column grid
        tk.Label(parent, text="Word Presets", bg=BG, fg=FG_DIM, font=UI_SB,
                 anchor="w").pack(anchor="w", padx=16, pady=(14, 6))

        presets = [
            ("32-bit",     "4"),
            ("64-bit",     "8"),
            ("8-bit",      "1"),
            ("2×32-bit",   "4 4"),
            ("4×16-bit",   "2 2 2 2"),
            ("32+16+8",    "4 2 1"),
            ("16+8",       "2 1"),
            ("32+8",       "4 1"),
            ("2×16-bit",   "2 2"),
        ]

        COLS = 3
        grid = tk.Frame(parent, bg=BG)
        grid.pack(fill="x", padx=16, pady=(0, 6))
        for col in range(COLS):
            grid.columnconfigure(col, weight=1)

        for i, (lbl, val) in enumerate(presets):
            row_idx = i // COLS
            col_idx = i %  COLS
            b = tk.Button(grid, text=lbl, bg=BTN_BG, fg=FG_MED,
                          font=UI_S, relief="flat", borderwidth=0,
                          padx=0, pady=4, cursor="hand2",
                          command=lambda v=val: self._word_sizes.set(v))
            b.grid(row=row_idx, column=col_idx, sticky="ew", padx=3, pady=3)
            b.bind("<Enter>", lambda e, b=b: b.configure(bg=BTN_HOV))
            b.bind("<Leave>", lambda e, b=b: b.configure(bg=BTN_BG))

        # ── Directories ────────────────────────────────────────────────────────
        section("DIRECTORIES")

        for label, var, key in [
            ("Input",   self._input_dir,  "input_dir"),
            ("Output",  self._output_dir, "output_dir"),
            ("Reports", self._report_dir, "report_dir"),
        ]:
            dr = tk.Frame(parent, bg=BG)
            dr.pack(fill="x", padx=16, pady=3)
            tk.Label(dr, text=label, bg=BG, fg=FG_MED, font=UI_S,
                     width=8, anchor="w").pack(side="left")
            e = tk.Entry(dr, textvariable=var, bg=SURFACE2, fg=FG,
                         insertbackground=FG, font=UI_S, relief="flat")
            e.pack(side="left", fill="x", expand=True, padx=(0, 4))
            b = tk.Button(dr, text="Browse", bg=BTN_BG, fg=FG_MED, font=UI_S,
                          relief="flat", borderwidth=0, padx=6, pady=1,
                          cursor="hand2",
                          command=lambda v=var: self._browse_dir(v))
            b.pack(side="left")
            b.bind("<Enter>", lambda e, b=b: b.configure(bg=BTN_HOV))
            b.bind("<Leave>", lambda e, b=b: b.configure(bg=BTN_BG))

    def _build_preview_panel(self, parent):
        phdr = tk.Frame(parent, bg=SURFACE2, height=28)
        phdr.pack(fill="x")
        phdr.pack_propagate(False)
        tk.Label(phdr, text="  FORMAT PREVIEW", bg=SURFACE2, fg=FG_MED,
                 font=UI_SB).pack(side="left", pady=4)
        self._preview_info = tk.StringVar(value="")
        tk.Label(phdr, textvariable=self._preview_info, bg=SURFACE2, fg=FG_DIM,
                 font=UI_S).pack(side="right", padx=10)

        _border_h(parent, thick=2, color=BORDER).pack(fill="x")

        tk.Label(parent, text="  address  →  word columns (sample data)",
                 bg=BG, fg=FG_DIM, font=UI_S, anchor="w").pack(fill="x", pady=(8, 2))

        self._preview_text = tk.Text(
            parent, bg=BG, fg=CYAN, font=MONO,
            relief="flat", borderwidth=0, state="disabled", wrap="none",
            padx=14, pady=6, height=8,
        )
        self._preview_text.pack(fill="x", padx=0)
        self._preview_text.tag_configure("addr", foreground=FG_DIM)
        self._preview_text.tag_configure("val",  foreground=CYAN)
        self._preview_text.tag_configure("err",  foreground=RED)

        _border_h(parent, thick=1, color=BORDER_S).pack(fill="x", pady=(8, 0))
        tk.Label(parent,
                 text="  Each row:  ADDRESS(8 hex)  WORD1  [WORD2 ...]  \n"
                      "  Final line: address-only end marker\n"
                      "  Values are width = word_size × 2 hex digits",
                 bg=BG, fg=FG_DIM, font=UI_S, justify="left", anchor="w",
                 ).pack(fill="x", padx=14, pady=8)

    def _update_preview(self):
        try:
            ws_raw = [x for x in self._word_sizes.get().split() if x]
            ws     = [int(x) for x in ws_raw]
            endian = self._endian.get()
            stride = sum(ws)
            self._preview_info.set(
                f"layout: {'+'.join(str(w)+'B' for w in ws)}   stride: {stride}B   endian: {endian}"
            )
        except Exception:
            ws_raw = []
            self._preview_info.set("")

        preview = _build_preview(
            [x for x in self._word_sizes.get().split() if x],
            self._endian.get(),
            int(self._addr_bits.get()) if self._addr_bits.get() in ("32","64") else 32,
        )

        self._preview_text.configure(state="normal")
        self._preview_text.delete("1.0", "end")

        if preview.startswith("  ("):
            self._preview_text.insert("end", preview, "err")
        else:
            for line in preview.splitlines():
                parts = line.split()
                if not parts:
                    self._preview_text.insert("end", "\n"); continue
                self._preview_text.insert("end", f"  {parts[0]}", "addr")
                if len(parts) > 1:
                    self._preview_text.insert("end", "    ")
                    self._preview_text.insert("end", "  ".join(parts[1:]), "val")
                self._preview_text.insert("end", "\n")

        self._preview_text.configure(state="disabled")

    def _browse_dir(self, var):
        d = filedialog.askdirectory(title="Select directory",
                                    initialdir=var.get())
        if d:
            var.set(d)

    def _save(self):
        # Validate
        try:
            ws = [int(x) for x in self._word_sizes.get().split() if x]
            if not ws:
                raise ValueError("At least one word size required")
            if any(w not in (1, 2, 4, 8) for w in ws):
                raise ValueError("Word sizes must be 1, 2, 4, or 8")
            if len(ws) > 6:
                raise ValueError("Maximum 6 words per row")
        except ValueError as e:
            self._status.set(f"Error: {e}")
            return

        endian = self._endian.get()
        if endian not in ("little", "big"):
            self._status.set("Error: endian must be little or big"); return

        cfg_path = REPO_ROOT / "cfg" / "config.sh"

        # Make dirs relative to repo root where possible
        def _rel(p):
            try:   return str(Path(p).relative_to(REPO_ROOT))
            except: return p

        addr_bits = int(self._addr_bits.get()) if self._addr_bits.get() in ("32","64") else 32

        content = (
            f'#!/usr/bin/env bash\n'
            f'# bintxt_tool configuration — edited via UI settings\n\n'
            f'ENDIAN="{endian}"\n\n'
            f'# Word sizes per row (bytes each — must be 1, 2, 4, or 8)\n'
            f'# Examples: (4)  (4 4)  (4 2 1)  (2 2 2 2)\n'
            f'WORD_SIZES=({" ".join(str(w) for w in ws)})\n\n'
            f'# Address field width in bits (32 = 8 hex digits, 64 = 16 hex digits)\n'
            f'ADDRESS_BITS={addr_bits}\n\n'
            f'INPUT_DIR="{_rel(self._input_dir.get())}"\n'
            f'OUTPUT_DIR="{_rel(self._output_dir.get())}"\n'
            f'REPORT_DIR="{_rel(self._report_dir.get())}"\n'
        )

        cfg_path.write_text(content, encoding="utf-8")

        # Refresh parent header
        self._parent._cfg = _cfg()
        self._parent._refresh_all()

        # Update header label
        layout = "+".join(f"{w}B" for w in ws)
        info   = f"layout: {layout}   ·   endian: {endian}"
        # Rebuild header (simplest: destroy + rebuild)
        # Instead just log the change and note restart for header
        self._parent.log_ok(f"Settings saved  —  layout: {layout}  endian: {endian}")

        self._status.set("Saved.")
        self.after(800, self.destroy)

    def _mk_btn(self, parent, text, cmd, primary=False, danger=False):
        bg = BTN_ACT if primary else ("#3a1f1f" if danger else BTN_BG)
        fg = FG if primary else (RED if danger else FG_MED)
        hov = BTN_HOV
        wrap = tk.Frame(parent, bg=BORDER, padx=1, pady=1)
        b = tk.Button(wrap, text=text, command=cmd,
                      bg=bg, fg=fg, activebackground=hov, activeforeground=FG,
                      font=UI, relief="flat", borderwidth=0,
                      padx=14, pady=3, cursor="hand2")
        b.pack()
        b.bind("<Enter>", lambda _: b.configure(bg=hov))
        b.bind("<Leave>", lambda _: b.configure(bg=bg))
        return wrap


if __name__ == "__main__":
    app = BintxtApp()
    app.mainloop()
