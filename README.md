# bintxt_tool

Convert, edit, and verify binary configuration files using human-readable hex text dumps.

Built for teams that need to **read, diff, and version-control binary files** without specialized tooling.

---

## Three Scripts

| Script | Purpose |
|--------|---------|
| `convert_inputs.sh` | Convert `.bin` ↔ `.txt` — no review, just go |
| `edit_inputs.sh` | Draft-first workflow — review before committing to binary |
| `compare_inputs.sh` | Verify that a `.bin` and `.txt` pair contain identical data |

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

Verifies that `.bin`/`.txt` pairs contain identical data.

```bash
./scripts/compare_inputs.sh
```

- **Strict pairing required** — every `.bin` must have a `.txt` with the same base name, and vice versa
- Unpaired files are flagged and left in `input/` untouched
- For each pair: extracts the `.bin` using current config, normalizes both sides, compares
- Result is `MATCH` or `MISMATCH` — mismatches include a line-level diff
- Reviewed pairs (both files) are moved to `output/` regardless of result
- Compare report written to `output/reports/`

---

## Configuration

Edit `config.sh` before running — no flags needed:

| Setting | Default | Description |
|---------|---------|-------------|
| `ENDIAN` | `little` | `little` (x86/ARM) or `big` (MIPS/PowerPC) |
| `WORD_SIZES` | `(4)` | Bytes per word, 1–6 words per row (see below) |
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

- **Address** — 8-digit hex, increments by `sum(WORD_SIZES)` per row
- **Values** — one hex field per entry in `WORD_SIZES`, width = `word_size × 2` digits
- **Last line** — address only, marks end of file

---

## Requirements

| Tool | Notes |
|------|-------|
| `bash` 4.0+ | |
| `python3` | Extraction, reconstruction, validation |
| `sha256sum` | Linux — or `shasum` on macOS (auto-detected) |

---

## Branches

| Branch | Contents |
|--------|---------|
| `main` | Core tool — stable, single example pair |
| `seeded_testing` | Extra example files for validation |
| `ui` | Optional drag-drop web UI (in development) |
