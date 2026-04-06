# bintxt_tool

Convert, edit, and verify binary configuration files using human-readable hex text dumps.

Built for teams that need to **read, diff, and version-control binary files** without specialized tooling.

---

## Three Scripts

| Script | Purpose |
|--------|---------|
| `convert_inputs.sh` | Convert `.bin` ↔ `.txt` — no review, just go |
| `edit_inputs.sh` | Draft-first workflow — review before committing to binary |
| `compare_inputs.sh` | Fingerprint any mix of `.bin`/`.txt` files, group identical content, move reviewed files to `output/` |

---

## Quick Start

```bash
git clone https://github.com/NathanTrudeau/bintxt_tool.git
cd bintxt_tool

# (Optional) edit cfg/config.sh to match your binary format
# Drop files into input/ and run the appropriate script
```

---

## convert_inputs.sh — Convert

Converts everything in `input/` in one pass. No prompts.

```
.bin  →  extracted to .txt     (EXTRACT)
.txt  →  validated + converted to .bin  (APPLY)
```

```bash
./scripts/convert_inputs.sh
```

- Both directions run automatically
- Format issues in `.txt` files are flagged in the apply report but conversion still proceeds
- All output files land in `output/`
- Two reports written: `extract_conversion-report` and `apply_conversion-report`

---

## edit_inputs.sh — Edit

Two-step draft workflow. Review before anything becomes a binary.

**Step 1 — Create drafts:**
```bash
./scripts/edit_inputs.sh
```
- `.bin` files → extracted to `output/__DRAFT_name.txt`
- `.txt` files → format-checked, normalized → `output/__DRAFT_name.txt`
- Nothing is converted yet. Review the `__DRAFT_*` files first.

**Step 2 — Apply drafts to binary:**
```bash
./scripts/edit_inputs.sh apply
```
- All `__DRAFT_*.txt` files in `output/` are converted to `.bin`
- `__DRAFT_` copy is removed on success
- Apply report written to `output/reports/`

**Naming conflicts** (same base name in both `.bin` and `.txt`):
```
input/config.bin  →  output/__DRAFT_config~bin.txt  →  output/config~bin.bin
input/config.txt  →  output/__DRAFT_config~txt.txt  →  output/config~txt.bin
```
Both binaries are produced independently so you can diff them.

---

## compare_inputs.sh — Compare

Fingerprints every file in `input/` by its **normalized binary content**, then groups all files that represent identical data — regardless of filename or file type.

```bash
./scripts/compare_inputs.sh
```

- Drop any mix of `.bin` and `.txt` files into `input/` — no naming convention required
- Each file is normalized: `.bin` files are extracted using current config, `.txt` files are address-padded; then a SHA-256 is taken of the normalized form
- Files with the same content hash are grouped together as a **match group**
- Files with no match are reported as **unique**
- Files that can't be processed (bad format, unsupported type) are flagged as **errors** and left in `input/` untouched
- All successfully fingerprinted files are moved to `output/` as "reviewed"
- Compare report written to `output/reports/`

**Useful for:**
- Confirming a `.txt` edit round-trips back to the original `.bin`
- Detecting duplicate binary files hiding under different names
- Auditing a folder of configs for unintended divergence

---

## Configuration

Edit `cfg/config.sh` before running — no flags needed:

| Setting | Default | Description |
|---------|---------|-------------|
| `ENDIAN` | `little` | `little` (x86/ARM) or `big` (MIPS/PowerPC) |
| `WORD_SIZES` | `(4)` | Bytes per word, 1–6 words per row (see below) |
| `ADDRESS_BITS` | `32` | Address width: `32` (8 hex digits) or `64` (16 hex digits) |
| `INPUT_DIR` | `input` | Folder to scan |
| `OUTPUT_DIR` | `output` | Folder for converted files |
| `REPORT_DIR` | `output/reports` | Folder for reports |

**`WORD_SIZES` examples:**
```bash
WORD_SIZES=(4)        # one 32-bit word per row       → 00000000 deadbeef
WORD_SIZES=(4 4)      # two 32-bit words per row       → 00000000 deadbeef cafebabe
WORD_SIZES=(4 2 1)    # 32-bit + 16-bit + 8-bit        → 00000000 deadbeef cafe ff
WORD_SIZES=(2 2 2 2)  # four 16-bit words per row      → 00000000 dead beef cafe babe
```

**`ADDRESS_BITS` example:**
```bash
ADDRESS_BITS=32   # default → 00000000 deadbeef
ADDRESS_BITS=64   #         → 0000000000000000 deadbeef
```

Config is the source of truth. All files — `.bin` and `.txt` — are validated against it.

---

## Text Format

Each row: `ADDRESS  WORD1  [WORD2  [WORD3 ...]]`

```
00000000 deadbeef
00000004 01000000
00000008 00000000
0000000c 000000ff
...
00000080
```

- **Address** — hex, width = `ADDRESS_BITS / 4` digits (8 for 32-bit, 16 for 64-bit), increments by `sum(WORD_SIZES)` per row
- **Values** — one hex field per entry in `WORD_SIZES`, width = `word_size × 2` digits
- **Last line** — address only, marks end of file

---

## Requirements

| Tool | Notes |
|------|-------|
| `bash` 4.0+ | macOS/Linux native; Windows requires Git Bash or WSL |
| `python3` | Extraction, reconstruction, validation |
> **Windows users:** double-clicking `.sh` files won't work natively. Open **Git Bash** or **WSL**, `cd` to the repo, and run the scripts from there. Everything else works the same.

---

## Branches

| Branch | Contents |
|--------|---------|
| `main` | Core CLI tool — stable, single example pair |
| `cli_testing` | Seeded with extra example files for validation |
| `ui` | tkinter desktop UI (development) |
| `ui_testing` | Seeded mirror of `ui` for local testing |
