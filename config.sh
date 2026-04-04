# =============================================================================
# config.sh — User settings for bintxt_tool
# Edit this file to match your binary format and folder preferences.
# =============================================================================

# ─── Byte Order ───────────────────────────────────────────────────────────────
# How multi-byte values are stored in the binary.
#   "little" — least significant byte first (x86, ARM, most modern hardware)
#   "big"    — most significant byte first (MIPS, PowerPC, some network formats)
ENDIAN="little"

# ─── Word Size ────────────────────────────────────────────────────────────────
# How many bytes are grouped into one address entry in the text dump.
# This must evenly divide your binary file size.
#
#   4 — 32-bit words  (default, most common for config binaries)
#   1 — byte-by-byte  (maximum detail, largest text files)
#   2 — 16-bit words
#   8 — 64-bit words
WORD_SIZE=4

# ─── Folders ──────────────────────────────────────────────────────────────────
# Paths are relative to the script's location (bintxt_tool/).
# Change these if you want to point input/output elsewhere.
INPUT_DIR="input"
OUTPUT_DIR="output"
REPORT_DIR="output/reports"   # Conversion reports land here
