# bintxt_tool

**v1.2.0**

Bash script for converting binary files ↔ human-readable text (od hex dump format), with SHA-256 roundtrip verification and detailed conversion reports.

Built for teams that need to **read, edit, diff, and version-control binary configuration files** without specialized tooling.

---

## Repository Structure

```
bintxt_tool/
  input/                     ← drop your .bin or .txt files here
    cfg-example.bin          ← example binary (32-word, 128-byte config)
    cfg-example.txt          ← example text dump of the above
  output/                    ← converted files land here
    reports/                 ← timestamped conversion reports
      example_success_*.txt  ← example of a clean all-pass report
      example_failure_*.txt  ← example of a report with errors
  convert_inputs.sh          ← the script
  config.sh                  ← edit word size, byte order, folder paths
  README.md
  .gitignore
```

---

## Quick Start

```bash
# 1. Clone
git clone https://github.com/NathanTrudeau/bintxt_tool.git
cd bintxt_tool

# 2. (Optional) Edit config.sh to match your binary format

# 3. Drop your files into input/
#    .bin files → extracted to .txt immediately
#    .txt files → validated and saved as __DRAFT, then prompted for binary conversion

# 4. Run
./convert_inputs.sh
```

Converted files and reports all land in `output/`.

---

## How It Works

### .bin files (EXTRACT)

Binary files are converted to human-readable text using `od`:

```
od -tx4 -Ax -v -w4 file.bin
```

Output format — one 4-byte word per line:
```
00000000 bef3a4c2
00000004 01000000
00000008 00000000
0000000c deadbeef
...
000000fc 00000001
00000100
```

- **Left column**: hex address
- **Right column**: hex value (width determined by `WORD_SIZE` in config.sh)
- **Last line**: final address only — marks end of file

### .txt files (DRAFT → APPLY)

Text files go through a two-step flow:

1. **DRAFT** — the file is validated against your config settings (word size, alignment, byte order) and a normalized `__DRAFT_filename.txt` is written to `output/` for review
2. **Prompt** — `Review them, then convert to binary? [y/N]`
   - `y` → applies all .txt files to binary, cleans up `__DRAFT` copies, writes apply report
   - `n` (or timeout) → stops here; `__DRAFT` files are preserved in `output/` for inspection

This lets you catch format mismatches **before** committing to binary.

---

## Configuration

Edit `config.sh` before running — no flags needed:

| Setting | Default | Description |
|---------|---------|-------------|
| `ENDIAN` | `little` | Byte order: `little` (x86/ARM) or `big` (MIPS/PowerPC) |
| `WORD_SIZE` | `4` | Bytes per address entry: `1`, `2`, `4`, or `8` |
| `INPUT_DIR` | `input` | Folder to scan for files |
| `OUTPUT_DIR` | `output` | Folder for converted files |
| `REPORT_DIR` | `output/reports` | Folder for conversion reports |

**Config is the source of truth.** All incoming .txt files are validated against `WORD_SIZE` and `ENDIAN` before conversion. Mismatches are flagged in the apply report with line-level detail.

---

## Conversion Reports

Two separate reports are generated per run (only written if that direction ran):

| Report | Filename pattern |
|--------|-----------------|
| Extract (BIN→TXT) | `YYYY-MM-DD_HHMMam_bintxt-tool_binary-to-text_extract_conversion-report.txt` |
| Apply (TXT→BIN) | `YYYY-MM-DD_HHMMam_bintxt-tool_text-to-binary_apply_conversion-report.txt` |

Each report includes:
- Full config block (source of truth at time of run)
- Summary: total / passed / failed / draft-only
- Per-file detail: input size, output file, SHA-256 of both, roundtrip pass/fail, format notes
- Error section with line-level diff and cause guidance

See `output/reports/example_success_*.txt` and `output/reports/example_failure_*.txt` for real examples.

---

## Verification

Every conversion is verified via SHA-256 roundtrip:

- **BIN→TXT**: generated `.txt` is reconstructed to `.bin`; SHA-256 compared to original
- **TXT→BIN**: generated `.bin` is converted back to `.txt`; normalized diff compared to original

A mismatch is a `FAIL` and is detailed in the error section of the report.

---

## Handling Partial / Edited Files

| Input | Behavior |
|-------|----------|
| Full sequential dump | Full binary reconstruction |
| Sparse / partial (some addresses only) | Gaps filled with `0x00` |

To patch a specific value: open the `.txt`, change the value at the address you care about, leave everything else untouched, then run and press `y`.

---

## Diffing Binaries

```bash
diff output/version_a.txt output/version_b.txt
```

Or with git:

```bash
git diff HEAD~1 HEAD -- output/config_v2.txt
```

---

## Adding to an Existing Repo

```
your_config_repo/
  configs/
    device_a.bin
  bintxt_tool/        ← drop here
    convert_inputs.sh
    config.sh
    input/
    output/
```

```bash
cd bintxt_tool
cp ../configs/device_a.bin input/
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

## Branches

| Branch | Purpose |
|--------|---------|
| `main` | Core tool — stable, single example pair, no extras |
| `seeded_testing` | Extra example files for testing and validation |
| `ui` | Optional drag-drop web UI (Flask + HTML) — not required to use the tool |

---

## Example Run

```
bintxt_tool  (word: 4B · endian: little)
  Input:   ./input
  Output:  ./output
  Reports: ./output/reports

EXTRACT — 1 binary file(s)…

  EXTRACT  BIN→TXT  hw_config.bin
           → hw_config.txt  (32 address entries)
  ✓ Roundtrip verified  SHA-256: ae1d5f650fed5f171918…

  Archiving input .bin files → output/

DRAFT — 1 text file(s) found…

  DRAFT    TXT      hw_config.txt
  ✓ Format valid — matches config
           → __DRAFT_hw_config.txt written to output/

  __DRAFT copies written to output/
  Review them, then convert to binary? [y/N] y

APPLY — converting 1 text file(s) to binary…

  APPLY    TXT→BIN  hw_config.txt
           → Normalized txt: hw_config.txt
           → hw_config.bin  (128 bytes)
  ✓ Roundtrip verified  SHA-256: ae1d5f650fed5f171918…
           → __DRAFT cleaned up

Writing reports…
  ✓ Extract report: 2026-04-01_0215pm_bintxt-tool_binary-to-text_extract_conversion-report.txt
  ✓ Apply report:   2026-04-01_0215pm_bintxt-tool_text-to-binary_apply_conversion-report.txt

─────────────────────────────────────
  Passed: 2  |  Failed: 0  |  Total: 2
  Outputs + reports in output/
─────────────────────────────────────

  All conversions verified successfully.

  Closing in 5 seconds…
```
