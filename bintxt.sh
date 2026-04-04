#!/usr/bin/env bash
# =============================================================================
# bintxt.sh — Binary ↔ Text conversion tool
#
# Usage:  ./bintxt.sh [--endian little|big]
#
# Drop .bin files into ./input/ to convert → text
# Drop .txt files  into ./input/ to convert → binary
#
# Outputs land in ./output/ with SHA-256 sidecar files.
# Requires: od, python3, sha256sum (or shasum on macOS)
# =============================================================================

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="$SCRIPT_DIR/input"
OUTPUT_DIR="$SCRIPT_DIR/output"
TEMP_DIR="$(mktemp -d)"

# Byte order for 4-byte integer reconstruction (little = x86/ARM LE, big = MIPS/PowerPC)
ENDIAN="little"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --endian) ENDIAN="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "  $*"; }
ok()      { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*"; }
err()     { echo -e "  ${RED}✗${NC} $*"; }
header()  { echo -e "\n${BOLD}${BLUE}$*${NC}"; }

# ─── Dependency check ────────────────────────────────────────────────────────

check_deps() {
  local missing=()
  for cmd in od python3; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  # sha256sum (Linux) or shasum (macOS)
  if ! command -v sha256sum &>/dev/null && ! command -v shasum &>/dev/null; then
    missing+=("sha256sum or shasum")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools: ${missing[*]}"
    exit 1
  fi
}

sha256() {
  local file="$1"
  if command -v sha256sum &>/dev/null; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

# ─── First-run setup ─────────────────────────────────────────────────────────

setup_dirs() {
  local first_run=false
  [[ -d "$INPUT_DIR" ]] || first_run=true

  mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

  if $first_run; then
    echo -e "\n${CYAN}${BOLD}bintxt_tool — first run setup${NC}"
    echo -e "  Created: ${CYAN}input/${NC}  and  ${CYAN}output/${NC}"
    echo
    echo -e "  Drop files into ${CYAN}input/${NC}:"
    echo -e "    • ${BOLD}.bin${NC} files → converted to .txt  (od hex dump)"
    echo -e "    • ${BOLD}.txt${NC} files → converted to .bin  (od reverse)"
    echo
    echo -e "  Then re-run ${BOLD}./bintxt.sh${NC}"
    echo
    exit 0
  fi
}

# ─── BIN → TXT ───────────────────────────────────────────────────────────────

bin_to_txt() {
  local src="$1"
  local dst="$2"
  # od: hex addresses, 4-byte hex values, one per line, no elision
  od -tx4 -Ax -v -w4 "$src" > "$dst"
}

# ─── TXT → BIN ───────────────────────────────────────────────────────────────
# Handles both full dumps and sparse/partial files.
# Full dump:  all sequential addresses present → reconstruct entire binary
# Partial:    only some addresses present → pad gaps with 0x00

txt_to_bin() {
  local src="$1"
  local dst="$2"
  python3 - "$src" "$dst" "$ENDIAN" <<'PYEOF'
import sys
import struct

src, dst, endian = sys.argv[1], sys.argv[2], sys.argv[3]
fmt = '<I' if endian == 'little' else '>I'

entries = []
with open(src) as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) < 2:
            continue  # final address-only line or blank
        try:
            addr = int(parts[0], 16)
            val  = int(parts[1], 16)
            entries.append((addr, val))
        except ValueError:
            continue  # skip malformed lines

if not entries:
    print("ERROR: no valid address/value pairs found in text file", file=sys.stderr)
    sys.exit(1)

max_addr = max(addr for addr, _ in entries)
file_size = max_addr + 4  # last address + 4 bytes

# Build output buffer (gaps filled with 0x00)
buf = bytearray(file_size)
for addr, val in entries:
    packed = struct.pack(fmt, val)
    buf[addr:addr+4] = packed

with open(dst, 'wb') as f:
    f.write(buf)
PYEOF
}

# ─── Verification (roundtrip SHA-256) ────────────────────────────────────────

verify_bin_to_txt() {
  local original_bin="$1"
  local generated_txt="$2"
  local temp_bin="$TEMP_DIR/roundtrip_$(basename "$original_bin")"

  # Reconstruct binary from the generated text, compare SHA-256 to original
  if ! txt_to_bin "$generated_txt" "$temp_bin" 2>/dev/null; then
    err "Roundtrip reconstruction failed — cannot verify"
    return 1
  fi

  local orig_hash rt_hash
  orig_hash=$(sha256 "$original_bin")
  rt_hash=$(sha256 "$temp_bin")

  if [[ "$orig_hash" == "$rt_hash" ]]; then
    ok "Verified  SHA-256: ${orig_hash:0:16}…"
    return 0
  else
    err "Mismatch!"
    log "  Original : $orig_hash"
    log "  Roundtrip: $rt_hash"
    return 1
  fi
}

verify_txt_to_bin() {
  local original_txt="$1"
  local generated_bin="$2"
  local temp_txt="$TEMP_DIR/roundtrip_$(basename "$original_txt")"

  # Reconstruct text from the generated binary, compare against original
  bin_to_txt "$generated_bin" "$temp_txt"

  if diff -q "$original_txt" "$temp_txt" &>/dev/null; then
    local hash
    hash=$(sha256 "$generated_bin")
    ok "Verified  SHA-256: ${hash:0:16}…"
    return 0
  else
    warn "Roundtrip text differs — check diff:"
    diff "$original_txt" "$temp_txt" | head -20 | sed 's/^/      /'
    return 1
  fi
}

# ─── Process a single file ───────────────────────────────────────────────────

process_file() {
  local src="$1"
  local filename ext base outfile result_icon

  filename="$(basename "$src")"
  ext="${filename##*.}"
  base="${filename%.*}"

  case "${ext,,}" in
    bin)
      local dst="$OUTPUT_DIR/${base}.txt"
      log "${CYAN}BIN→TXT${NC}  $filename"

      bin_to_txt "$src" "$dst"

      local lines
      lines=$(grep -c ' ' "$dst" 2>/dev/null || echo 0)
      log "          → ${base}.txt  (${lines} address entries)"

      if verify_bin_to_txt "$src" "$dst"; then
        # Write SHA-256 sidecar
        sha256 "$src" > "$OUTPUT_DIR/${base}.bin.sha256"
        return 0
      else
        return 1
      fi
      ;;

    txt)
      local dst="$OUTPUT_DIR/${base}.bin"
      log "${CYAN}TXT→BIN${NC}  $filename"

      if ! txt_to_bin "$src" "$dst"; then
        err "Conversion failed for $filename"
        return 1
      fi

      local bytes
      bytes=$(wc -c < "$dst")
      log "          → ${base}.bin  (${bytes} bytes)"

      if verify_txt_to_bin "$src" "$dst"; then
        # Write SHA-256 sidecar
        sha256 "$dst" > "$OUTPUT_DIR/${base}.bin.sha256"
        return 0
      else
        return 1
      fi
      ;;

    *)
      warn "Skipping $filename — not .bin or .txt"
      return 0
      ;;
  esac
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  check_deps
  setup_dirs

  echo -e "\n${BOLD}${BLUE}bintxt_tool${NC}  (endian: ${ENDIAN})"
  echo -e "  Input:  ${CYAN}$INPUT_DIR${NC}"
  echo -e "  Output: ${CYAN}$OUTPUT_DIR${NC}"

  # Collect files
  local files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$INPUT_DIR" -maxdepth 1 -type f \( -iname "*.bin" -o -iname "*.txt" \) -print0 | sort -z)

  if [[ ${#files[@]} -eq 0 ]]; then
    warn "No .bin or .txt files found in input/"
    echo
    echo -e "  Drop files into ${CYAN}input/${NC} and re-run."
    echo
    exit 0
  fi

  header "Processing ${#files[@]} file(s)…"

  local passed=0 failed=0

  for f in "${files[@]}"; do
    echo
    if process_file "$f"; then
      (( passed++ )) || true
    else
      (( failed++ )) || true
    fi
  done

  # ─── Summary ─────────────────────────────────────────────────────────────

  echo
  echo -e "${BOLD}─────────────────────────────────────${NC}"
  echo -e "  ${GREEN}Passed: $passed${NC}  |  ${RED}Failed: $failed${NC}"
  echo -e "${BOLD}─────────────────────────────────────${NC}"

  if [[ $failed -gt 0 ]]; then
    echo -e "\n  ${RED}One or more conversions failed verification.${NC}"
    echo -e "  Check the files above for details.\n"
    exit 1
  else
    echo -e "\n  ${GREEN}All conversions verified.${NC}"
    echo -e "  Outputs + SHA-256 sidecars in ${CYAN}output/${NC}\n"
    exit 0
  fi
}

# Cleanup temp dir on exit
trap 'rm -rf "$TEMP_DIR"' EXIT

main "$@"
