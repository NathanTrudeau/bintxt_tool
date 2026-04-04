#!/usr/bin/env bash
# =============================================================================
# convert_inputs.sh — Binary ↔ Text conversion tool
#
# Usage:  ./convert_inputs.sh
#
# Drop .bin or .txt files into ./input/ to convert.
# Outputs land in ./output/  Reports are written to ./output/reports/
# Edit config.sh to change word size, byte order, or folder paths.
# Config is the source of truth — all files (txt and bin) are validated
# against WORD_SIZE and ENDIAN before and after conversion.
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
# Two separate report streams: EXTRACT (BIN→TXT) and APPLY (TXT→BIN)

EXTRACT_ENTRIES=()
EXTRACT_ERRORS=()
APPLY_ENTRIES=()
APPLY_ERRORS=()

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

# ─── TXT → BIN ───────────────────────────────────────────────────────────────

txt_to_bin() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" "$ENDIAN" "$WORD_SIZE" <<'PYEOF'
import sys, struct

src, dst, endian, word_size = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

fmt_map = {1: ('B','B'), 2: ('<H','>H'), 4: ('<I','>I'), 8: ('<Q','>Q')}
if word_size not in fmt_map:
    print(f"ERROR: unsupported WORD_SIZE {word_size} (must be 1, 2, 4, or 8)", file=sys.stderr)
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

# ─── TXT format validation against config ────────────────────────────────────
# Returns "OK" if format matches config, or a description of mismatches.
# Writes a config-normalized version of the txt to $OUTPUT_DIR if any issues found.

validate_txt_format() {
  local src="$1"
  local filename; filename="$(basename "$src")"
  local expected_val_len=$(( WORD_SIZE * 2 ))

  python3 - "$src" "$WORD_SIZE" "$expected_val_len" <<'PYEOF'
import sys, re

src        = sys.argv[1]
word_size  = int(sys.argv[2])
val_len    = int(sys.argv[3])   # expected hex chars per value field

issues = []
line_num = 0

with open(src) as f:
    for raw in f:
        line_num += 1
        line = raw.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) == 1:
            # Final address-only line — fine
            continue
        if len(parts) < 2:
            issues.append(f"line {line_num}: unparseable — '{line[:60]}'")
            continue

        try:
            addr = int(parts[0], 16)
        except ValueError:
            issues.append(f"line {line_num}: bad address '{parts[0]}'")
            continue

        if addr % word_size != 0:
            issues.append(f"line {line_num}: address 0x{addr:x} not aligned to WORD_SIZE={word_size}")

        try:
            val = int(parts[1], 16)
        except ValueError:
            issues.append(f"line {line_num}: bad value '{parts[1]}'")
            continue

        max_val = (1 << (word_size * 8)) - 1
        if val > max_val:
            issues.append(f"line {line_num}: value 0x{val:x} overflows WORD_SIZE={word_size} bytes")

        actual_len = len(parts[1])
        if actual_len != val_len:
            issues.append(f"line {line_num}: value width {actual_len} chars (expected {val_len} for WORD_SIZE={word_size})")

if issues:
    print("ISSUES\n" + "\n".join(issues))
else:
    print("OK")
PYEOF
}

# Write a config-normalized version of a txt file to $OUTPUT_DIR
normalize_txt_to_output() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" "$WORD_SIZE" <<'PYEOF'
import sys

src, dst, word_size = sys.argv[1], sys.argv[2], int(sys.argv[3])
val_len = word_size * 2
addr_len = 8

lines_out = []
with open(src) as f:
    for raw in f:
        line = raw.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) == 1:
            # Final address line
            try:
                addr = int(parts[0], 16)
                lines_out.append(f"{addr:0{addr_len}x}")
            except ValueError:
                lines_out.append(line)
            continue
        if len(parts) >= 2:
            try:
                addr = int(parts[0], 16)
                val  = int(parts[1], 16)
                lines_out.append(f"{addr:0{addr_len}x} {val:0{val_len}x}")
                continue
            except ValueError:
                pass
        lines_out.append(line)

with open(dst, 'w') as f:
    f.write("\n".join(lines_out) + "\n")
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

normalize_for_compare() {
  sed 's/[[:space:]]*$//' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | grep -v '^[[:space:]]*$'
}

verify_txt_to_bin() {
  local orig_txt="$1" gen_bin="$2"
  local temp_txt="$TEMP_DIR/rt_$(basename "$orig_txt")"

  bin_to_txt "$gen_bin" "$temp_txt"

  local gen_hash
  gen_hash=$(sha256 "$gen_bin")

  local norm_orig norm_rt
  norm_orig=$(normalize_for_compare "$orig_txt")
  norm_rt=$(normalize_for_compare "$temp_txt")

  if [[ "$norm_orig" == "$norm_rt" ]]; then
    echo "$gen_hash $gen_hash"
    return 0
  else
    echo "MISMATCH"
    diff <(echo "$norm_orig") <(echo "$norm_rt") 2>&1 || true
    return 1
  fi
}

# ─── Format entry for report ─────────────────────────────────────────────────

format_entry() {
  local direction="$1" filename="$2" output="$3" size="$4"
  local hash_a="$5" hash_b="$6" status="$7" detail="$8" fmt_notes="$9"

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
    if [[ -n "$fmt_notes" ]]; then
      echo "  Format notes    : $fmt_notes"
    fi
    if [[ -n "$detail" ]]; then
      echo "  Error detail    : $detail"
    fi
  }
}

# ─── Process a single file ───────────────────────────────────────────────────

process_file() {
  local src="$1"
  local filename ext base
  filename="$(basename "$src")"
  ext="${filename##*.}"
  base="${filename%.*}"

  local status="PASS"
  local detail="" fmt_notes=""
  local hash_a="n/a" hash_b="n/a"
  local direction input_size output_info

  case "${ext,,}" in

    # ── EXTRACT: BIN → TXT ──────────────────────────────────────────────────
    bin)
      direction="BIN → TXT  [EXTRACT]"
      local dst="$OUTPUT_DIR/${base}.txt"

      log "${CYAN}EXTRACT${NC}  BIN→TXT  $filename"
      input_size="$(wc -c < "$src") bytes"
      hash_a=$(sha256 "$src")

      bin_to_txt "$src" "$dst"

      local entries
      entries=$(grep -c ' ' "$dst" 2>/dev/null || echo 0)
      output_info="${base}.txt  (${entries} address entries)"
      log "         → $output_info"

      local verify_out
      if verify_out=$(verify_bin_to_txt "$src" "$dst" 2>&1); then
        read -r _ hash_b <<< "$verify_out"
        ok "Roundtrip verified  SHA-256: ${hash_b:0:20}…"
      else
        status="FAIL"
        hash_b="n/a"
        detail="Roundtrip reconstruction mismatch — output may be corrupt."
        err "Verification failed"
        EXTRACT_ERRORS+=("[$filename] $detail")
      fi

      EXTRACT_ENTRIES+=("$(format_entry "$direction" "$filename" "$output_info" "$input_size" "$hash_a" "$hash_b" "$status" "$detail" "")")
      ;;

    # ── APPLY: TXT → BIN ────────────────────────────────────────────────────
    txt)
      direction="TXT → BIN  [APPLY]"
      local dst="$OUTPUT_DIR/${base}.bin"
      local norm_dst="$OUTPUT_DIR/${base}.txt"   # normalized txt also lands in output/

      log "${CYAN}APPLY${NC}    TXT→BIN  $filename"

      # Validate format against config before converting
      local fmt_result
      fmt_result=$(validate_txt_format "$src" 2>&1)
      if [[ "$fmt_result" == OK ]]; then
        fmt_notes="Format matches config (WORD_SIZE=${WORD_SIZE}, ENDIAN=${ENDIAN})"
        ok "Format valid — matches config"
        # Write normalized copy to output/ (canonical form)
        normalize_txt_to_output "$src" "$norm_dst"
        log "         → Normalized txt: $(basename "$norm_dst")"
      else
        local issue_lines
        issue_lines=$(echo "$fmt_result" | tail -n +2)
        fmt_notes="Format mismatches detected — normalized copy written to output/. Issues: $(echo "$issue_lines" | tr '\n' ' ')"
        warn "Format issues vs config — writing normalized version to output/"
        echo "$issue_lines" | head -5 | sed 's/^/         /'
        normalize_txt_to_output "$src" "$norm_dst"
        log "         → Normalized txt: $(basename "$norm_dst")"
      fi

      input_size="$(wc -l < "$src") lines"
      hash_a=$(sha256 "$src")

      local py_err
      if ! py_err=$(txt_to_bin "$src" "$dst" 2>&1); then
        status="FAIL"
        detail="$py_err"
        output_info="${base}.bin  (conversion failed)"
        err "Conversion failed: $py_err"
        APPLY_ERRORS+=("[$filename] $detail")
        APPLY_ENTRIES+=("$(format_entry "$direction" "$filename" "$output_info" "$input_size" "$hash_a" "$hash_b" "$status" "$detail" "$fmt_notes")")
        return 1
      fi

      local bytes; bytes=$(wc -c < "$dst")
      output_info="${base}.bin  (${bytes} bytes)"
      log "         → $output_info"
      hash_b=$(sha256 "$dst")

      local verify_out
      if verify_out=$(verify_txt_to_bin "$src" "$dst" 2>&1); then
        ok "Roundtrip verified  SHA-256: ${hash_b:0:20}…"
      else
        status="FAIL"
        hash_b="n/a"
        detail="$(echo "$verify_out" | tail -10)"
        err "Verification failed — roundtrip diff:"
        echo "$detail" | head -5 | sed 's/^/         /'
        APPLY_ERRORS+=("[$filename] Roundtrip diff:"$'\n'"$detail")
      fi

      APPLY_ENTRIES+=("$(format_entry "$direction" "$filename" "$output_info" "$input_size" "$hash_a" "$hash_b" "$status" "$detail" "$fmt_notes")")
      ;;

    *)
      warn "Skipping $filename — not .bin or .txt"
      return 0
      ;;
  esac

  [[ "$status" == "PASS" ]]
}

# ─── Write report ────────────────────────────────────────────────────────────

write_report() {
  local label="$1"   # "extract" or "apply"
  local direction_label="$2"  # "BINARY → TEXT (EXTRACT)" etc.
  local -n _entries="$3"
  local -n _errors="$4"
  local passed="$5" failed="$6" total="$7"

  [[ ${#_entries[@]} -eq 0 ]] && return  # nothing to report

  local dt_file dt_display
  dt_file=$(date '+%Y-%m-%d_%I%M%p' | tr '[:upper:]' '[:lower:]')
  dt_display=$(date '+%Y-%m-%d  %I:%M %p')

  # Long descriptive filename
  local report_file
  if [[ "$label" == "extract" ]]; then
    report_file="$REPORT_DIR/${dt_file}_bintxt-tool_binary-to-text_extract_conversion-report.txt"
  else
    report_file="$REPORT_DIR/${dt_file}_bintxt-tool_text-to-binary_apply_conversion-report.txt"
  fi

  local overall="ALL PASSED"
  [[ $failed -gt 0 ]] && overall="COMPLETED WITH ERRORS"

  {
    echo "============================================================"
    echo "  BINTXT_TOOL — ${direction_label} REPORT"
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
    for entry in "${_entries[@]}"; do
      printf "  [%d]\n" "$i"
      echo "$entry"
      echo
      (( i++ ))
    done

    if [[ ${#_errors[@]} -gt 0 ]]; then
      echo "============================================================"
      echo "  ERROR DETAILS"
      echo "============================================================"
      echo
      for e in "${_errors[@]}"; do
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

  echo -e "\n${BOLD}${BLUE}bintxt_tool${NC}  (word: ${WORD_SIZE}B · endian: ${ENDIAN})"
  echo -e "  Input:   ${CYAN}$INPUT_DIR${NC}"
  echo -e "  Output:  ${CYAN}$OUTPUT_DIR${NC}"
  echo -e "  Reports: ${CYAN}$REPORT_DIR${NC}"

  local files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$INPUT_DIR" -maxdepth 1 -type f \( -iname "*.bin" -o -iname "*.txt" \) -print0 | sort -z)

  if [[ ${#files[@]} -eq 0 ]]; then
    warn "No .bin or .txt files found in input/"
    echo
    sleep 5
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

  # ── Drop all input files into output/ (complete session snapshot) ──────────
  echo
  header "Archiving input files → output/"
  local archived=0
  for f in "${files[@]}"; do
    local fname; fname="$(basename "$f")"
    local ext="${fname##*.}"
    # Only copy .bin inputs (txt inputs already produce normalized copy in output/)
    if [[ "${ext,,}" == "bin" ]]; then
      cp "$f" "$OUTPUT_DIR/${fname}"
      log "Archived: ${CYAN}${fname}${NC}"
      (( archived++ )) || true
    fi
  done
  log "${archived} input file(s) archived to output/"

  # ── Write reports ──────────────────────────────────────────────────────────
  echo
  header "Writing reports…"

  local extract_pass=0 extract_fail=0 apply_pass=0 apply_fail=0

  for entry in "${EXTRACT_ENTRIES[@]}"; do
    if echo "$entry" | grep -q "✓  PASS"; then
      (( extract_pass++ )) || true
    else
      (( extract_fail++ )) || true
    fi
  done
  for entry in "${APPLY_ENTRIES[@]}"; do
    if echo "$entry" | grep -q "✓  PASS"; then
      (( apply_pass++ )) || true
    else
      (( apply_fail++ )) || true
    fi
  done

  local extract_total=$(( extract_pass + extract_fail ))
  local apply_total=$(( apply_pass + apply_fail ))

  local rpt1="" rpt2=""
  if [[ $extract_total -gt 0 ]]; then
    rpt1=$(write_report "extract" "BINARY → TEXT  [EXTRACT]" EXTRACT_ENTRIES EXTRACT_ERRORS "$extract_pass" "$extract_fail" "$extract_total")
    ok "Extract report: ${CYAN}$(basename "$rpt1")${NC}"
  fi
  if [[ $apply_total -gt 0 ]]; then
    rpt2=$(write_report "apply" "TEXT → BINARY  [APPLY]" APPLY_ENTRIES APPLY_ERRORS "$apply_pass" "$apply_fail" "$apply_total")
    ok "Apply report:   ${CYAN}$(basename "$rpt2")${NC}"
  fi

  # ── Final summary ──────────────────────────────────────────────────────────
  local total=$(( passed + failed ))
  echo
  echo -e "${BOLD}─────────────────────────────────────${NC}"
  echo -e "  ${GREEN}Passed: $passed${NC}  |  ${RED}Failed: $failed${NC}  |  Total: $total"
  echo -e "  Outputs + reports in ${CYAN}output/${NC}"
  echo -e "${BOLD}─────────────────────────────────────${NC}"

  if [[ $failed -gt 0 ]]; then
    echo -e "\n  ${RED}One or more conversions failed — see report for details.${NC}"
  else
    echo -e "\n  ${GREEN}All conversions verified successfully.${NC}"
  fi

  echo -e "\n  ${YELLOW}Closing in 5 seconds…${NC}"
  sleep 5

  [[ $failed -eq 0 ]]
}

trap 'rm -rf "$TEMP_DIR"' EXIT
main "$@"
