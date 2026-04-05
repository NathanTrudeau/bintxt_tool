# bintxt_tool

Convert binary configuration files to human-readable hex text — and back.

Built for teams that need to **read, diff, and version-control binary files** without specialized tooling.

---

## Quick Start

```bash
git clone https://github.com/NathanTrudeau/bintxt_tool.git
cd bintxt_tool

# (Optional) edit cfg/config.sh to match your binary format
# Drop files into input/ and run:
./convert_inputs.sh
```

---

## convert_inputs.sh

Converts everything in `input/` in one pass. No prompts.

```
.bin  →  extracted to .txt     (EXTRACT)
.txt  →  validated + converted to .bin  (APPLY)
```

- Both directions run automatically
- All output files land in `output/`
- Two reports written to `output/reports/`: one for extract, one for apply

---

## Configuration

Edit `cfg/config.sh` before running — no flags needed:

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
| `bash` 4.0+ | macOS/Linux native; Windows requires Git Bash or WSL |
| `python3` | Extraction, reconstruction, validation |
| `sha256sum` | Linux — or `shasum` on macOS (auto-detected) |

> **Windows users:** `.sh` files don't double-click on Windows. Open **Git Bash** or **WSL**, `cd` to the repo, and run `./convert_inputs.sh` from there.

---

## Branches

| Branch | Contents |
|--------|---------|
| `main` | Full tool — convert, edit, and compare scripts |
| `seeded_testing` | Extra example files for validation |
| `ui` | Optional drag-drop web UI (in development) |
