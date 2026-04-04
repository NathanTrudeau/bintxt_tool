#!/usr/bin/env bash
# =============================================================================
# convert_inputs.sh — Binary → Text extraction (EXTRACT)
#
# Usage:  ./convert_inputs.sh
#
# Drop .bin files into ./input/ to extract them to human-readable text.
# Any .txt files in input/ are ignored here — use edit_inputs.sh for those.
#
# Outputs land in ./output/   Reports land in ./output/reports/
# Edit config.sh to change word size, byte order, or folder paths.
# Config is the source of truth for all binary formatting.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Load config ─────────────────────────────────────────────────────────────

if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
  source "$SCRIPT_DIR/config.sh"
else
  ENDIAN="little"
  WORD_SIZE=4
  INPUT_DIR="input"
  OUTPUT_DIR="output"
  REPORT_DIR="output/reports"
fi

INPUT_DIR="$SCRIPT_DIR/$INPUT_DIR"
OUTPUT_DIR="$SCRIPT_DIR/$OUTPUT_DIR"
REPORT_DIR="$SCRIPT_DIR/$REPORT_DIR"
TEMP_DIR="$(mktemp -d)"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" "$REPORT_DIR"

# ─── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "  $*"; }
ok()     { echo -e "  ${GREEN}✓${NC} $*"; }
warn()   { echo -e "  ${YELLOW}⚠${NC}  $*"; }
err()    { echo -e "  ${RED}✗${NC} $*"; }
header() { echo -e "\n${BOLD}${BLUE}$*${NC}"; }

# ─── Report state ────────────────────────────────────────────────────────────

EXTRACT_ENTRIES=()
EXTRACT_ERRORS=()

# ─── Dependency check ────────────────────────────────────────────────────────

check_deps() {
  local missing=()
  for cmd in od python3; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if ! command -v sha256sum &>/dev/null && ! command -v shasum &>/dev/null; then
    missing+=("sha256sum or shasum")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools: ${missing[*]}"
    exit 1
  fi
}

sha256() {
  if command -v sha256sum &>/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ─── BIN → TXT ───────────────────────────────────────────────────────────────

bin_to_txt() {
  local src="$1" dst="$2"
  od -tx${WORD_SIZE} -Ax -v -w${WORD_SIZE} "$src" > "$dst"
}

txt_to_bin() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" "$ENDIAN" "$WORD_SIZE" <<'PYEOF'
import sys, struct

src, dst, endian, word_size = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

fmt_map = {1: ('B','B'), 2: ('<H','>H'), 4: ('<I','>I'), 8: ('<Q','>Q')}
if word_size not in fmt_map:
    print(f"ERROR: unsupported WORD_SIZE {word_size}", file=sys.stderr)
    sys.exit(1)

le_fmt, be_fmt = fmt_map[word_size]
fmt = le_fmt if endian == 'little' else be_fmt
if word_size == 1:
    fmt = 'B'

entries = []
with open(src) as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        try:
            addr = int(parts[0], 16)
            val  = int(parts[1], 16)
            entries.append((addr, val))
        except ValueError:
            continue

if not entries:
    print("ERROR: no valid address/value pairs found", file=sys.stderr)
    sys.exit(1)

max_addr  = max(addr for addr, _ in entries)
file_size = max_addr + word_size
buf = bytearray(file_size)
for addr, val in entries:
    buf[addr:addr+word_size] = struct.pack(fmt, val)

with open(dst, 'wb') as f:
    f.write(buf)
PYEOF
}

# ─── Verification ────────────────────────────────────────────────────────────

verify_bin_to_txt() {
  local orig_bin="$1" gen_txt="$2"
  local temp_bin="$TEMP_DIR/rt_$(basename "$orig_bin")"

  txt_to_bin "$gen_txt" "$temp_bin" 2>/dev/null || { echo "ROUNDTRIP_FAILED"; return 1; }

  local orig_hash rt_hash
  orig_hash=$(sha256 "$orig_bin")
  rt_hash=$(sha256 "$temp_bin")
  echo "$orig_hash $rt_hash"
  [[ "$orig_hash" == "$rt_hash" ]]
}

# ─── Format report entry ─────────────────────────────────────────────────────

format_entry() {
  local direction="$1" filename="$2" output="$3" size="$4"
  local hash_a="$5" hash_b="$6" status="$7" detail="$8"
  local icon="✓  PASS"
  [[ "$status" == "FAIL" ]] && icon="✗  FAIL"
  {
    echo "  File            : $filename"
    echo "  Direction       : $direction"
    echo "  Input size      : $size"
    echo "  Output          : $output"
    echo "  SHA-256 (input) : $hash_a"
    echo "  SHA-256 (output): $hash_b"
    echo "  Roundtrip check : $icon"
    if [[ -n "$detail" ]]; then echo "  Error detail    : $detail"; fi
  }
}

# ─── Extract a single .bin file ──────────────────────────────────────────────

extract_file() {
  local src="$1"
  local filename; filename="$(basename "$src")"
  local base="${filename%.*}"
  local dst="$OUTPUT_DIR/${base}.txt"
  local status="PASS" detail="" hash_a hash_b input_size output_info

  log "${CYAN}EXTRACT${NC}  BIN→TXT  $filename"
  input_size="$(wc -c < "$src") bytes"
  hash_a=$(sha256 "$src")

  bin_to_txt "$src" "$dst"

  local entries; entries=$(grep -c ' ' "$dst" 2>/dev/null || echo 0)
  output_info="${base}.txt  (${entries} address entries)"
  log "         → $output_info"

  local verify_out
  if verify_out=$(verify_bin_to_txt "$src" "$dst" 2>&1); then
    read -r _ hash_b <<< "$verify_out"
    ok "Roundtrip verified  SHA-256: ${hash_b:0:20}…"
  else
    status="FAIL"; hash_b="n/a"
    detail="Roundtrip reconstruction mismatch — output may be corrupt."
    err "Verification failed"
    EXTRACT_ERRORS+=("[$filename] $detail")
  fi

  EXTRACT_ENTRIES+=("$(format_entry "BIN → TXT  [EXTRACT]" "$filename" "$output_info" "$input_size" "$hash_a" "$hash_b" "$status" "$detail")")
  [[ "$status" == "PASS" ]]
}

# ─── Write report ────────────────────────────────────────────────────────────

write_report() {
  local passed="$1" failed="$2" total="$3"
  local dt_file dt_display
  dt_file=$(date '+%Y-%m-%d_%I%M%p' | tr '[:upper:]' '[:lower:]')
  dt_display=$(date '+%Y-%m-%d  %I:%M %p')

  local report_file="$REPORT_DIR/${dt_file}_bintxt-tool_binary-to-text_extract_conversion-report.txt"

  local overall="ALL PASSED"
  [[ $failed -gt 0 ]] && overall="COMPLETED WITH ERRORS"

  {
    echo "============================================================"
    echo "  BINTXT_TOOL — BINARY → TEXT  [EXTRACT] REPORT"
    echo "  Generated : $dt_display"
    echo "============================================================"
    echo
    echo "  Configuration (source of truth)"
    echo "  --------------------------------"
    echo "  Word size   : ${WORD_SIZE} byte(s)  ($(( WORD_SIZE * 8 ))-bit words)"
    echo "  Byte order  : $ENDIAN-endian"
    echo "  Input dir   : $INPUT_DIR"
    echo "  Output dir  : $OUTPUT_DIR"
    echo "  Report dir  : $REPORT_DIR"
    echo
    echo "  Summary"
    echo "  -------"
    echo "  Files total : $total"
    echo "  Passed      : $passed"
    echo "  Failed      : $failed"
    echo "  Status      : $overall"
    echo
    echo "============================================================"
    echo "  CONVERSIONS"
    echo "============================================================"
    echo
    local i=1
    for entry in "${EXTRACT_ENTRIES[@]}"; do
      printf "  [%d]\n" "$i"
      echo "$entry"
      echo
      (( i++ ))
    done
    if [[ ${#EXTRACT_ERRORS[@]} -gt 0 ]]; then
      echo "============================================================"
      echo "  ERROR DETAILS"
      echo "============================================================"
      echo
      for e in "${EXTRACT_ERRORS[@]}"; do
        echo "$e"
        echo
      done
    fi
    echo "============================================================"
    echo "  END OF REPORT  —  bintxt_tool  (WORD_SIZE=${WORD_SIZE}, ENDIAN=${ENDIAN})"
    echo "============================================================"
  } > "$report_file"

  echo "$report_file"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  check_deps

  echo -e "\n${BOLD}${BLUE}bintxt_tool  —  EXTRACT${NC}  (word: ${WORD_SIZE}B · endian: ${ENDIAN})"
  echo -e "  Input:   ${CYAN}$INPUT_DIR${NC}"
  echo -e "  Output:  ${CYAN}$OUTPUT_DIR${NC}"
  echo -e "  Reports: ${CYAN}$REPORT_DIR${NC}"

  local bin_files=() txt_skipped=0
  while IFS= read -r -d '' f; do
    local ext="${f##*.}"
    case "${ext,,}" in
      bin) bin_files+=("$f") ;;
      txt) (( txt_skipped++ )) || true ;;
    esac
  done < <(find "$INPUT_DIR" -maxdepth 1 -type f \( -iname "*.bin" -o -iname "*.txt" \) -print0 | sort -z)

  if [[ ${#bin_files[@]} -eq 0 ]]; then
    warn "No .bin files found in input/"
    if [[ $txt_skipped -gt 0 ]]; then
      log "Found ${txt_skipped} .txt file(s) — run ${CYAN}edit_inputs.sh${NC} to apply those to binary."
    fi
    echo
    sleep 5
    exit 0
  fi

  if [[ $txt_skipped -gt 0 ]]; then
    warn "${txt_skipped} .txt file(s) found in input/ — skipped here. Run ${CYAN}edit_inputs.sh${NC} to apply those."
  fi

  header "Extracting ${#bin_files[@]} binary file(s)…"

  local passed=0 failed=0
  for f in "${bin_files[@]}"; do
    echo
    if extract_file "$f"; then
      (( passed++ )) || true
    else
      (( failed++ )) || true
    fi
  done

  # Archive input .bin files to output/
  echo
  log "Archiving input files → output/"
  for f in "${bin_files[@]}"; do
    local fname; fname="$(basename "$f")"
    cp "$f" "$OUTPUT_DIR/${fname}"
    log "  ${CYAN}${fname}${NC}"
  done

  local total=$(( passed + failed ))

  echo
  header "Writing report…"
  local rpt
  rpt=$(write_report "$passed" "$failed" "$total")
  ok "Extract report: ${CYAN}$(basename "$rpt")${NC}"

  echo
  echo -e "${BOLD}─────────────────────────────────────${NC}"
  echo -e "  ${GREEN}Passed: $passed${NC}  |  ${RED}Failed: $failed${NC}  |  Total: $total"
  echo -e "  Outputs in ${CYAN}output/${NC}"
  echo -e "${BOLD}─────────────────────────────────────${NC}"

  if [[ $failed -gt 0 ]]; then
    echo -e "\n  ${RED}One or more extractions failed — see report for details.${NC}"
  else
    echo -e "\n  ${GREEN}All extractions verified.${NC}  Edit the .txt files, then run ${CYAN}./edit_inputs.sh${NC}"
  fi

  echo -e "\n  ${YELLOW}Closing in 5 seconds…${NC}"
  sleep 5

  [[ $failed -eq 0 ]]
}

trap 'rm -rf "$TEMP_DIR"' EXIT
main "$@"
