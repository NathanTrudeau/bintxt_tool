# =============================================================================
# config.sh — User settings for bintxt_tool
# Edit this file to match your binary format and folder preferences.
# =============================================================================

# ─── Byte Order ───────────────────────────────────────────────────────────────
# How multi-byte values are stored in the binary.
#   "little" — least significant byte first (x86, ARM, most modern hardware)
#   "big"    — most significant byte first (MIPS, PowerPC, some network formats)
ENDIAN="little"

# ─── Word Layout ──────────────────────────────────────────────────────────────
# WORD_SIZES defines how many words appear per address row in the text dump,
# and how many bytes wide each word is.
#
# Each value must be 1, 2, 4, or 8.
# Between 1 and 6 words per row are supported.
#
# The row stride (bytes advanced per row) = sum of all word sizes.
#
# Examples:
#   WORD_SIZES=(4)          — one 32-bit word per row  (default)
#   WORD_SIZES=(4 4)        — two 32-bit words per row (8 bytes/row)
#   WORD_SIZES=(2 2 2 2)    — four 16-bit words per row (8 bytes/row)
#   WORD_SIZES=(4 2 1)      — 32-bit + 16-bit + 8-bit  (7 bytes/row, mixed)
#   WORD_SIZES=(8 8 8)      — three 64-bit words per row (24 bytes/row)
#
# Text dump format produced:
#   ADDRESS  WORD1  [WORD2  [WORD3 ...]]
#   00000000 deadbeef cafe ab
#   00000007 12345678 0001 ff
WORD_SIZES=(4)

# ─── Folders ──────────────────────────────────────────────────────────────────
# Paths are relative to the script's location (bintxt_tool/).
INPUT_DIR="input"
OUTPUT_DIR="output"
REPORT_DIR="output/reports"
