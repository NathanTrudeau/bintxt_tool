# bintxt_tool

Bash script for converting binary files ↔ human-readable text (od hex dump format), with SHA-256 roundtrip verification.

Built for teams that need to **read, edit, diff, and version-control binary configuration files** without specialized tooling.

---

## Repository Structure

```
bintxt_tool/
  input/                  ← drop your .bin or .txt files here
  output/                 ← converted files + conversion report land here
  convert_inputs.sh       ← the script
  config.sh               ← edit word size, byte order, folder paths
  README.md
  .gitignore
```

---

## Quick Start

```bash
# 1. Clone anywhere (including inside your existing config repo)
git clone https://github.com/NathanTrudeau/bintxt_tool.git
cd bintxt_tool

# 2. (Optional) Edit config.sh to match your binary format

# 3. Drop your files into input/
#    .bin files → converted to .txt
#    .txt files → converted back to .bin

# 4. Run the script
./convert_inputs.sh
```

Converted files land in `output/` along with a timestamped conversion report.

---

## Text Format

Binary files are converted using `od`:

```
od -tx4 -Ax -v -w4 file.bin
```

Output (one 4-byte word per line):
```
000000 bef3a4c2
000004 01000000
000008 00000000
00000c deadbeef
...
0000fc 00000001
000100
```

- **Left column**: hex address
- **Right column**: 4-byte value in hex (host byte order)
- **Last line**: final address only (no value) — marks end of file

This format is easy to diff, grep, and edit in any text editor.

---

## Configuration

Edit `config.sh` before running — no command-line flags needed:

| Setting | Default | Description |
|---------|---------|-------------|
| `ENDIAN` | `little` | Byte order: `little` (x86/ARM) or `big` (MIPS/PowerPC) |
| `WORD_SIZE` | `4` | Bytes per address entry: `1`, `2`, `4`, or `8` |
| `INPUT_DIR` | `input` | Folder to scan for files |
| `OUTPUT_DIR` | `output` | Folder for converted files |
| `REPORT_DIR` | `output` | Folder for conversion reports |

---

## Verification & Conversion Report

Every conversion is verified via SHA-256 roundtrip:

- **bin→txt**: the generated `.txt` is reconstructed back to `.bin` and its SHA-256 is compared to the original. Match → ✓
- **txt→bin**: the generated `.bin` is converted back to `.txt` and diff'd against the original. Match → ✓

After every run a `[YYYY-MM-DD_HHMMAP]_conversion_report.txt` is written to `output/`:

```
============================================================
  BINTXT_TOOL — CONVERSION REPORT
  2026-04-04  03:15 AM
============================================================

  Config
  ------
  Word size : 4 byte(s)
  Endian    : little

  Summary
  -------
  Total     : 2
  Passed    : 2
  Failed    : 0
  Status    : ALL PASSED

============================================================
  CONVERSIONS
============================================================

  [1]
  File        : cfg-example.bin
  Direction   : BIN → TXT
  Input size  : 128 bytes
  Output      : cfg-example.txt  (32 entries)
  SHA-256 (A) : 3f8a92d1c4e7b051...
  SHA-256 (B) : 3f8a92d1c4e7b051...
  Roundtrip   : ✓  PASS
```

Errors are appended at the bottom of the report with full detail.

---

## Handling Partial / Edited Files

| Input | Behavior |
|-------|----------|
| Full dump (all sequential addresses) | Full binary reconstruction |
| Partial / sparse (only some addresses) | Gaps filled with `0x00` |

When editing a `.txt` file: change the values at the addresses you care about, leave all other lines untouched, then convert back to `.bin`.

---

## Diffing Binaries

Convert both `.bin` files to `.txt`, then diff:

```bash
diff output/version_a.txt output/version_b.txt
```

Or with git:
```bash
git diff HEAD~1 HEAD -- output/config_v2.txt
```

---

## Adding to an Existing Repo

No structural changes required. Drop the `bintxt_tool/` folder anywhere:

```
your_config_repo/
  configs/
    a_example.bin
    b_example.bin
  bintxt_tool/        ← drop here
    convert_inputs.sh
    README.md
    .gitignore
    input/
    output/
```

```bash
cd bintxt_tool
cp ../configs/*.bin input/
./convert_inputs.sh
```

---

## Requirements

| Tool | Notes |
|------|-------|
| `bash` | 4.0+ |
| `od` | Standard on Linux/macOS |
| `python3` | Used for binary reconstruction (txt→bin) |
| `sha256sum` | Linux — or `shasum` on macOS (auto-detected) |

---

## Example Output

```
bintxt_tool  (endian: little)
  Input:  /path/to/bintxt_tool/input
  Output: /path/to/bintxt_tool/output

Processing 2 file(s)…

  BIN→TXT  cfg-example.bin
            → cfg-example.txt  (32 address entries)
  ✓ Verified  SHA-256: 3f8a92d1c4e7b051…

  TXT→BIN  cfg-example2.txt
            → cfg-example2.bin  (128 bytes)
  ✓ Verified  SHA-256: a1c9f3e20d8b6742…

─────────────────────────────────────
  Passed: 2  |  Failed: 0
─────────────────────────────────────

  All conversions verified.
  Outputs + SHA-256 sidecars in output/
```
