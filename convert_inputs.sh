#!/usr/bin/env bash
# =============================================================================
# convert_inputs.sh — Binary ↔ Text conversion tool
#
# Usage:  ./convert_inputs.sh
#
# Drop .bin or .txt files into ./input/ to convert.
# Outputs land in ./output/  A conversion report is written to ./output/
# Edit config.sh to change word size, byte order, or folder paths.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Load config ─────────────────────────────────────────────────────────────

if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
  source "$SCRIPT_DIR/config.sh"
else
  # Defaults if config.sh is missing
  ENDIAN="little"
  WORD_SIZE=4
  INPUT_DIR="input"
  OUTPUT_DIR="output"
  REPORT_DIR="output"
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

# ─── Report helpers ──────────────────────────────────────────────────────────

REPORT_ENTRIES=()   # collects per-file report blocks
REPORT_ERRORS=()    # collects error detail lines

report_add() { REPORT_ENTRIES+=("$1"); }
report_err()  { REPORT_ERRORS+=("$1"); }

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

# ─── od format string derived from WORD_SIZE ─────────────────────────────────

od_format() {
  echo "-tx${WORD_SIZE} -Ax -v -w${WORD_SIZE}"
}

# ─── BIN → TXT ───────────────────────────────────────────────────────────────

bin_to_txt() {
  local src="$1" dst="$2"
  eval od $(od_format) '"$src"' > "$dst"
}

# ─── TXT → BIN ───────────────────────────────────────────────────────────────

txt_to_bin() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" "$ENDIAN" "$WORD_SIZE" <<'PYEOF'
import sys, struct

src, dst, endian, word_size = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

fmt_map = {
    1: ('B', 'B'),
    2: ('<H', '>H'),
    4: ('<I', '>I'),
    8: ('<Q', '>Q'),
}
if word_size not in fmt_map:
    print(f"ERROR: unsupported WORD_SIZE {word_size} (must be 1, 2, 4, or 8)", file=sys.stderr)
    sys.exit(1)

le_fmt, be_fmt = fmt_map[word_size]
fmt = le_fmt if endian == 'little' else be_fmt

# For 1-byte words there's no endian ambiguity
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
  local orig_hash rt_hash

  txt_to_bin "$gen_txt" "$temp_bin" 2>/dev/null || {
    echo "ROUNDTRIP_FAILED"
    return 1
  }

  orig_hash=$(sha256 "$orig_bin")
  rt_hash=$(sha256 "$temp_bin")

  echo "$orig_hash $rt_hash"
  [[ "$orig_hash" == "$rt_hash" ]]
}

verify_txt_to_bin() {
  local orig_txt="$1" gen_bin="$2"
  local temp_txt="$TEMP_DIR/rt_$(basename "$orig_txt")"

  bin_to_txt "$gen_bin" "$temp_txt"

  local gen_hash
  gen_hash=$(sha256 "$gen_bin")

  if diff -q "$orig_txt" "$temp_txt" &>/dev/null; then
    echo "$gen_hash $gen_hash"
    return 0
  else
    echo "MISMATCH"
    diff "$orig_txt" "$temp_txt" 2>&1
    return 1
  fi
}

# ─── Process a single file ───────────────────────────────────────────────────

process_file() {
  local src="$1"
  local filename ext base
  filename="$(basename "$src")"
  ext="${filename##*.}"
  base="${filename%.*}"

  local direction input_size output_info hash_a hash_b status detail
  status="PASS"
  detail=""

  case "${ext,,}" in
    bin)
      direction="BIN → TXT"
      local dst="$OUTPUT_DIR/${base}.txt"

      log "${CYAN}BIN→TXT${NC}  $filename"
      input_size=$(wc -c < "$src")
      bin_to_txt "$src" "$dst"

      local entries
      entries=$(grep -c ' ' "$dst" 2>/dev/null || echo 0)
      output_info="${base}.txt  (${entries} entries)"
      log "          → $output_info"

      local verify_out
      if verify_out=$(verify_bin_to_txt "$src" "$dst" 2>&1); then
        read -r hash_a hash_b <<< "$verify_out"
        ok "Verified  SHA-256: ${hash_a:0:20}…"
      else
        status="FAIL"
        hash_a="n/a"; hash_b="n/a"
        detail="Roundtrip reconstruction mismatch. Output may be corrupt."
        err "Verification failed"
        report_err "[$filename] $detail"
      fi
      ;;

    txt)
      direction="TXT → BIN"
      local dst="$OUTPUT_DIR/${base}.bin"

      log "${CYAN}TXT→BIN${NC}  $filename"

      local py_err
      if ! py_err=$(txt_to_bin "$src" "$dst" 2>&1); then
        status="FAIL"
        hash_a="n/a"; hash_b="n/a"
        input_size=$(wc -l < "$src")
        output_info="${base}.bin  (conversion failed)"
        detail="$py_err"
        err "Conversion failed: $py_err"
        report_err "[$filename] $detail"

        report_add "$(format_entry "$direction" "$filename" "$output_info" "${input_size} lines" "$hash_a" "$hash_b" "$status" "$detail")"
        return 1
      fi

      input_size=$(wc -l < "$src")
      local bytes
      bytes=$(wc -c < "$dst")
      output_info="${base}.bin  (${bytes} bytes)"
      log "          → $output_info"

      local verify_out
      if verify_out=$(verify_txt_to_bin "$src" "$dst" 2>&1); then
        read -r hash_a hash_b <<< "$verify_out"
        ok "Verified  SHA-256: ${hash_a:0:20}…"
      else
        status="FAIL"
        hash_a="n/a"; hash_b="n/a"
        detail="$(echo "$verify_out" | tail -10)"
        err "Verification failed — roundtrip diff:"
        echo "$detail" | head -5 | sed 's/^/      /'
        report_err "[$filename] Roundtrip diff detected:"$'\n'"$detail"
      fi
      ;;

    *)
      warn "Skipping $filename — not .bin or .txt"
      return 0
      ;;
  esac

  report_add "$(format_entry "$direction" "$filename" "$output_info" "${input_size} bytes" "$hash_a" "$hash_b" "$status" "$detail")"
  [[ "$status" == "PASS" ]]
}

format_entry() {
  local direction="$1" filename="$2" output="$3" size="$4"
  local hash_a="$5" hash_b="$6" status="$7" detail="$8"
  local icon="✓  PASS"
  [[ "$status" == "FAIL" ]] && icon="✗  FAIL"

  cat <<EOF
  File        : $filename
  Direction   : $direction
  Input size  : $size
  Output      : $output
  SHA-256 (A) : $hash_a
  SHA-256 (B) : $hash_b
  Roundtrip   : $icon
$([ -n "$detail" ] && echo "  Error       : $detail" || true)
EOF
}

# ─── Write report ────────────────────────────────────────────────────────────

write_report() {
  local passed="$1" failed="$2" total="$3"
  local dt_file dt_display

  # Filename: YYYY-MM-DD_HHMM[AM|PM]
  dt_file=$(date '+%Y-%m-%d_%I%M%p')
  # Display: Month DD YYYY  HH:MM AM/PM
  dt_display=$(date '+%Y-%m-%d  %I:%M %p')

  local report_file="$REPORT_DIR/${dt_file}_conversion_report.txt"

  local overall="ALL PASSED"
  [[ $failed -gt 0 ]] && overall="COMPLETED WITH ERRORS"

  {
    echo "============================================================"
    echo "  BINTXT_TOOL — CONVERSION REPORT"
    echo "  $dt_display"
    echo "============================================================"
    echo
    echo "  Config"
    echo "  ------"
    echo "  Word size : ${WORD_SIZE} byte(s)"
    echo "  Endian    : $ENDIAN"
    echo "  Input dir : $INPUT_DIR"
    echo "  Output dir: $OUTPUT_DIR"
    echo
    echo "  Summary"
    echo "  -------"
    echo "  Total     : $total"
    echo "  Passed    : $passed"
    echo "  Failed    : $failed"
    echo "  Status    : $overall"
    echo
    echo "============================================================"
    echo "  CONVERSIONS"
    echo "============================================================"
    echo

    local i=1
    for entry in "${REPORT_ENTRIES[@]}"; do
      echo "  [$i]"
      echo "$entry"
      echo
      (( i++ ))
    done

    if [[ ${#REPORT_ERRORS[@]} -gt 0 ]]; then
      echo "============================================================"
      echo "  ERROR DETAILS"
      echo "============================================================"
      echo
      for e in "${REPORT_ERRORS[@]}"; do
        echo "$e"
        echo
      done
    fi

    echo "============================================================"
    echo "  END OF REPORT"
    echo "============================================================"
  } > "$report_file"

  echo "$report_file"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  check_deps

  echo -e "\n${BOLD}${BLUE}bintxt_tool${NC}  (word: ${WORD_SIZE}B · endian: ${ENDIAN})"
  echo -e "  Input:  ${CYAN}$INPUT_DIR${NC}"
  echo -e "  Output: ${CYAN}$OUTPUT_DIR${NC}"

  local files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$INPUT_DIR" -maxdepth 1 -type f \( -iname "*.bin" -o -iname "*.txt" \) -print0 | sort -z)

  if [[ ${#files[@]} -eq 0 ]]; then
    warn "No .bin or .txt files found in input/"
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

  local total=$(( passed + failed ))

  # Write report
  echo
  local report_path
  report_path=$(write_report "$passed" "$failed" "$total")
  log "Report: ${CYAN}$(basename "$report_path")${NC}"

  # Summary
  echo
  echo -e "${BOLD}─────────────────────────────────────${NC}"
  echo -e "  ${GREEN}Passed: $passed${NC}  |  ${RED}Failed: $failed${NC}"
  echo -e "${BOLD}─────────────────────────────────────${NC}"

  if [[ $failed -gt 0 ]]; then
    echo -e "\n  ${RED}One or more conversions failed — see report for details.${NC}\n"
    exit 1
  else
    echo -e "\n  ${GREEN}All conversions verified.${NC}  Outputs in ${CYAN}output/${NC}\n"
    exit 0
  fi
}

trap 'rm -rf "$TEMP_DIR"' EXIT
main "$@"
