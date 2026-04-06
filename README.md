# bintxt_tool

Convert, edit, and verify binary configuration files using human-readable hex text dumps.

Built for teams that need to **read, diff, and version-control binary files** without specialized tooling.

---

## Three Scripts

| Script | Purpose |
|--------|---------|
| `convert_inputs.sh` | Convert `.bin` ↔ `.txt` — no review, just go |
| `edit_inputs.sh` | Draft-first workflow — review before writing binary |
| `compare_inputs.sh` | Fingerprint any mix of `.bin`/`.txt` files, group identical content |

---

## Quick Start

```bash
git clone https://github.com/NathanTrudeau/bintxt_tool.git
cd bintxt_tool

# Edit cfg/config.sh to match your binary format (optional — defaults work for most cases)
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
- Format issues in `.txt` are flagged in the report but conversion still proceeds
- All outputs land in `output/`, reports in `output/reports/`

---

## edit_inputs.sh — Draft Workflow

Two-step process. Review before anything becomes a binary.

**Step 1 — Create drafts:**
```bash
./scripts/edit_inputs.sh
```
- `.bin` → `output/__DRAFT_name.txt`
- `.txt` → format-checked, normalized → `output/__DRAFT_name.txt`
- Nothing is converted yet — review the `__DRAFT_*` files first.

**Step 2 — Apply drafts:**
```bash
./scripts/edit_inputs.sh apply
```
- All `__DRAFT_*.txt` in `output/` are converted to `.bin`
- Draft copy is removed on success; report written to `output/reports/`

**Naming conflicts** (same base name exists as both `.bin` and `.txt` in input/):
```
input/config.bin  →  output/__DRAFT_config~bin.txt  →  output/config~bin.bin
input/config.txt  →  output/__DRAFT_config~txt.txt  →  output/config~txt.bin
```

---

## compare_inputs.sh — Compare

Fingerprints every file in `input/` by **normalized binary content**, groups files that represent identical data — regardless of filename or type.

```bash
./scripts/compare_inputs.sh
```

- Any mix of `.bin` and `.txt` — no naming convention required
- Files are normalized (extracted + address-padded), then SHA-256 fingerprinted
- Matching content → grouped; no match → unique; unreadable → error (left in `input/`)
- Successfully fingerprinted files are moved to `output/` as reviewed
- Report written to `output/reports/`

**Useful for:**
- Confirming a `.txt` edit round-trips back to the original `.bin`
- Detecting duplicate configs hiding under different filenames
- Auditing a folder for unintended divergence

---

## Configuration

Edit `cfg/config.sh` — no flags needed at runtime:

| Setting | Default | Description |
|---------|---------|-------------|
| `ENDIAN` | `little` | `little` (x86/ARM) or `big` (MIPS/PowerPC) |
| `WORD_SIZES` | `(4)` | Bytes per word, 1–6 words per row |
| `ADDRESS_BITS` | `32` | `32` = 8 hex digit addresses, `64` = 16 hex digit addresses |
| `INPUT_DIR` | `input` | Folder to scan |
| `OUTPUT_DIR` | `output` | Folder for converted files |
| `REPORT_DIR` | `output/reports` | Folder for reports |

**`WORD_SIZES` examples:**
```bash
WORD_SIZES=(4)        # one 32-bit word per row    → 00000000 deadbeef
WORD_SIZES=(4 4)      # two 32-bit words per row   → 00000000 deadbeef cafebabe
WORD_SIZES=(4 2 1)    # 32-bit + 16-bit + 8-bit    → 00000000 deadbeef cafe ff
WORD_SIZES=(2 2 2 2)  # four 16-bit words per row  → 00000000 dead beef cafe babe
```

**`ADDRESS_BITS` example:**
```bash
ADDRESS_BITS=32   # default → 00000000 deadbeef
ADDRESS_BITS=64   #         → 0000000000000000 deadbeef
```

---

## Text Format

Each row: `ADDRESS  WORD1  [WORD2  ...]`

```
00000000 deadbeef
00000004 cafebabe
00000008 00000000
0000000c 000000ff
...
00000010
```

- **Address** — hex, `ADDRESS_BITS / 4` digits wide, increments by `sum(WORD_SIZES)` per row
- **Values** — one hex field per `WORD_SIZES` entry, `word_size × 2` digits wide
- **Last line** — address only, marks end of file

---

## Requirements

| Tool | Notes |
|------|-------|
| `bash` 4.0+ | macOS/Linux native; Windows requires Git Bash or WSL |
| `python3` | All conversion, validation, and hashing |

> **Windows users:** open **Git Bash** or **WSL**, `cd` to the repo, and run scripts from there.

---

## Branches

| Branch | Contents |
|--------|---------|
| `main` | Core CLI tool — stable |
| `cli_testing` | Seeded with example files for validation |
| `ui` | Desktop UI (tkinter) + build scripts — see that branch's README |
| `ui_testing` | Seeded mirror of `ui` for local testing |
