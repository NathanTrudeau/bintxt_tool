#!/usr/bin/env bash
# =============================================================================
# edit_inputs.sh — Text → Binary apply (APPLY)
#
# Usage:  ./edit_inputs.sh
#
# Drop edited .txt files into ./input/ after running convert_inputs.sh.
# This script validates each file against config, writes a __DRAFT_ copy
# to output/ for review, then prompts whether to convert to .bin.
#
#   [y] → all .txt files are converted to .bin, __DRAFTs cleaned up
#   [n] → stops here; __DRAFT files are preserved in output/ for inspection
#
# Outputs land in ./output/   Reports land in ./output/reports/
# Edit config.sh to change word size, byte order, or folder paths.
# Config is the source of truth — all .txt files are validated against
# WORD_SIZE and ENDIAN before conversion.
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

# ─── BIN → TXT (used for roundtrip verification only) ────────────────────────

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

# ─── TXT format validation against config ────────────────────────────────────

validate_txt_format() {
  local src="$1"
  local expected_val_len=$(( WORD_SIZE * 2 ))

  python3 - "$src" "$WORD_SIZE" "$expected_val_len" <<'PYEOF'
import sys

src       = sys.argv[1]
word_size = int(sys.argv[2])
val_len   = int(sys.argv[3])
issues    = []
line_num  = 0

with open(src) as f:
    for raw in f:
        line_num += 1
        line = raw.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) == 1:
            continue  # final address-only line — ok
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
        if len(parts[1]) != val_len:
            issues.append(f"line {line_num}: value width {len(parts[1])} chars (expected {val_len} for WORD_SIZE={word_size})")

if issues:
    print("ISSUES\n" + "\n".join(issues))
else:
    print("OK")
PYEOF
}

# ─── Write config-normalized txt ─────────────────────────────────────────────

normalize_txt() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" "$WORD_SIZE" <<'PYEOF'
import sys

src, dst, word_size = sys.argv[1], sys.argv[2], int(sys.argv[3])
val_len  = word_size * 2
addr_len = 8
lines_out = []

with open(src) as f:
    for raw in f:
        line = raw.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) == 1:
            try:
                lines_out.append(f"{int(parts[0], 16):0{addr_len}x}")
            except ValueError:
                lines_out.append(line)
            continue
        if len(parts) >= 2:
            try:
                lines_out.append(f"{int(parts[0], 16):0{addr_len}x} {int(parts[1], 16):0{val_len}x}")
                continue
            except ValueError:
                pass
        lines_out.append(line)

with open(dst, 'w') as f:
    f.write("\n".join(lines_out) + "\n")
PYEOF
}

# ─── Verification ────────────────────────────────────────────────────────────

normalize_for_compare() {
  sed 's/[[:space:]]*$//' "$1" | tr '[:upper:]' '[:lower:]' | grep -v '^[[:space:]]*$'
}

verify_txt_to_bin() {
  local orig_txt="$1" gen_bin="$2"
  local temp_txt="$TEMP_DIR/rt_$(basename "$orig_txt")"
  bin_to_txt "$gen_bin" "$temp_txt"

  local gen_hash; gen_hash=$(sha256 "$gen_bin")
  local norm_orig norm_rt
  norm_orig=$(normalize_for_compare "$orig_txt")
  norm_rt=$(normalize_for_compare "$temp_txt")

  if [[ "$norm_orig" == "$norm_rt" ]]; then
    echo "$gen_hash"
    return 0
  else
    echo "MISMATCH"
    diff <(echo "$norm_orig") <(echo "$norm_rt") 2>&1 || true
    return 1
  fi
}

# ─── Format report entry ─────────────────────────────────────────────────────

format_entry() {
  local direction="$1" filename="$2" output="$3" size="$4"
  local hash_a="$5" hash_b="$6" status="$7" detail="$8" fmt_notes="$9"
  local icon="✓  PASS"
  [[ "$status" == "FAIL"  ]] && icon="✗  FAIL"
  [[ "$status" == "DRAFT" ]] && icon="—  DRAFT ONLY (binary conversion skipped)"
  {
    echo "  File            : $filename"
    echo "  Direction       : $direction"
    echo "  Input size      : $size"
    echo "  Output          : $output"
    echo "  SHA-256 (input) : $hash_a"
    echo "  SHA-256 (output): $hash_b"
    echo "  Result          : $icon"
    if [[ -n "$fmt_notes" ]]; then echo "  Format notes    : $fmt_notes"; fi
    if [[ -n "$detail"    ]]; then echo "  Error detail    : $detail";    fi
  }
}

# ─── DRAFT: validate and write __DRAFT_ copy ─────────────────────────────────

draft_file() {
  local src="$1"
  local filename; filename="$(basename "$src")"
  local base="${filename%.*}"
  local draft_dst="$OUTPUT_DIR/__DRAFT_${base}.txt"
  local fmt_notes

  log "${CYAN}DRAFT${NC}    $filename"

  local fmt_result
  fmt_result=$(validate_txt_format "$src" 2>&1)
  if [[ "$fmt_result" == OK ]]; then
    fmt_notes="Format matches config (WORD_SIZE=${WORD_SIZE}, ENDIAN=${ENDIAN})"
    ok "Format valid — matches config"
  else
    local issue_lines; issue_lines=$(echo "$fmt_result" | tail -n +2)
    fmt_notes="Format mismatches — normalized. Issues: $(echo "$issue_lines" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    warn "Format issues found — normalizing for DRAFT:"
    echo "$issue_lines" | head -5 | sed 's/^/         /'
  fi

  normalize_txt "$src" "$draft_dst"
  log "         → ${CYAN}__DRAFT_${base}.txt${NC} written to output/"

  local hash_a; hash_a=$(sha256 "$src")
  local input_size; input_size="$(wc -l < "$src") lines"
  APPLY_ENTRIES+=("$(format_entry "TXT → DRAFT  [APPLY PENDING]" "$filename" "__DRAFT_${base}.txt" "$input_size" "$hash_a" "n/a" "DRAFT" "" "$fmt_notes")")
}

# ─── APPLY: convert .txt to .bin (after user confirms y) ─────────────────────

apply_file() {
  local src="$1"
  local filename; filename="$(basename "$src")"
  local base="${filename%.*}"
  local dst="$OUTPUT_DIR/${base}.bin"
  local norm_dst="$OUTPUT_DIR/${base}.txt"
  local draft_dst="$OUTPUT_DIR/__DRAFT_${base}.txt"
  local status="PASS" detail="" fmt_notes="" hash_a hash_b output_info input_size

  log "${CYAN}APPLY${NC}    TXT→BIN  $filename"

  local fmt_result
  fmt_result=$(validate_txt_format "$src" 2>&1)
  if [[ "$fmt_result" == OK ]]; then
    fmt_notes="Format matches config (WORD_SIZE=${WORD_SIZE}, ENDIAN=${ENDIAN})"
  else
    local issue_lines; issue_lines=$(echo "$fmt_result" | tail -n +2)
    fmt_notes="Mismatches corrected. Issues: $(echo "$issue_lines" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  fi

  input_size="$(wc -l < "$src") lines"
  hash_a=$(sha256 "$src")

  # Write normalized canonical txt to output/
  normalize_txt "$src" "$norm_dst"
  log "         → Normalized: $(basename "$norm_dst")"

  local py_err
  if ! py_err=$(txt_to_bin "$src" "$dst" 2>&1); then
    status="FAIL"; hash_b="n/a"
    detail="$py_err"
    output_info="${base}.bin  (conversion failed)"
    err "Conversion failed: $py_err"
    APPLY_ERRORS+=("[$filename] $detail")
    _replace_draft_entry "$filename" "$(format_entry "TXT → BIN  [APPLY]" "$filename" "$output_info" "$input_size" "$hash_a" "$hash_b" "$status" "$detail" "$fmt_notes")"
    return 1
  fi

  local bytes; bytes=$(wc -c < "$dst")
  output_info="${base}.bin  (${bytes} bytes)"
  log "         → $output_info"

  local verify_out
  if verify_out=$(verify_txt_to_bin "$src" "$dst" 2>&1); then
    hash_b="$verify_out"
    ok "Roundtrip verified  SHA-256: ${hash_b:0:20}…"
  else
    status="FAIL"; hash_b="n/a"
    detail="$(echo "$verify_out" | tail -10)"
    err "Verification failed — roundtrip diff"
    APPLY_ERRORS+=("[$filename] Roundtrip diff:"$'\n'"$detail")
  fi

  # Clean up __DRAFT now that binary is committed
  if [[ -f "$draft_dst" ]]; then rm -f "$draft_dst"; log "         → __DRAFT cleaned up"; fi

  _replace_draft_entry "$filename" "$(format_entry "TXT → BIN  [APPLY]" "$filename" "$output_info" "$input_size" "$hash_a" "$hash_b" "$status" "$detail" "$fmt_notes")"
  [[ "$status" == "PASS" ]]
}

# Replace the pending DRAFT entry with the final APPLY entry
_replace_draft_entry() {
  local target="$1" new_entry="$2"
  local new_entries=() replaced=0 i
  for (( i=${#APPLY_ENTRIES[@]}-1; i>=0; i-- )); do
    if [[ $replaced -eq 0 && "${APPLY_ENTRIES[$i]}" == *"$target"* && "${APPLY_ENTRIES[$i]}" == *"APPLY PENDING"* ]]; then
      replaced=1
    else
      new_entries=("${APPLY_ENTRIES[$i]}" "${new_entries[@]+"${new_entries[@]}"}")
    fi
  done
  new_entries+=("$new_entry")
  APPLY_ENTRIES=("${new_entries[@]+"${new_entries[@]}"}")
}

# ─── Write report ────────────────────────────────────────────────────────────

write_report() {
  local passed="$1" failed="$2" draft_only="$3" total="$4"
  local dt_file dt_display
  dt_file=$(date '+%Y-%m-%d_%I%M%p' | tr '[:upper:]' '[:lower:]')
  dt_display=$(date '+%Y-%m-%d  %I:%M %p')

  local report_file="$REPORT_DIR/${dt_file}_bintxt-tool_text-to-binary_apply_conversion-report.txt"

  local overall="ALL PASSED"
  [[ $failed -gt 0 ]] && overall="COMPLETED WITH ERRORS"
  [[ $passed -eq 0 && $failed -eq 0 ]] && overall="DRAFT ONLY — binary conversion skipped"

  {
    echo "============================================================"
    echo "  BINTXT_TOOL — TEXT → BINARY  [APPLY] REPORT"
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
    if [[ $draft_only -gt 0 ]]; then echo "  Draft only  : $draft_only  (binary conversion skipped)"; fi
    echo "  Status      : $overall"
    echo
    echo "============================================================"
    echo "  CONVERSIONS"
    echo "============================================================"
    echo
    local i=1
    for entry in "${APPLY_ENTRIES[@]}"; do
      printf "  [%d]\n" "$i"
      echo "$entry"
      echo
      (( i++ ))
    done
    if [[ ${#APPLY_ERRORS[@]} -gt 0 ]]; then
      echo "============================================================"
      echo "  ERROR DETAILS"
      echo "============================================================"
      echo
      for e in "${APPLY_ERRORS[@]}"; do
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

  echo -e "\n${BOLD}${BLUE}bintxt_tool  —  APPLY${NC}  (word: ${WORD_SIZE}B · endian: ${ENDIAN})"
  echo -e "  Input:   ${CYAN}$INPUT_DIR${NC}"
  echo -e "  Output:  ${CYAN}$OUTPUT_DIR${NC}"
  echo -e "  Reports: ${CYAN}$REPORT_DIR${NC}"

  local txt_files=()
  while IFS= read -r -d '' f; do
    txt_files+=("$f")
  done < <(find "$INPUT_DIR" -maxdepth 1 -type f -iname "*.txt" -print0 | sort -z)

  if [[ ${#txt_files[@]} -eq 0 ]]; then
    warn "No .txt files found in input/"
    log "Run ${CYAN}convert_inputs.sh${NC} first to extract .bin files to text."
    echo
    sleep 5
    exit 0
  fi

  # ── DRAFT phase ─────────────────────────────────────────────────────────────
  header "DRAFT — validating ${#txt_files[@]} text file(s)…"
  for f in "${txt_files[@]}"; do
    echo
    draft_file "$f"
  done

  echo
  echo -e "  ${CYAN}__DRAFT copies written to output/${NC} — review before committing to binary."
  echo -e "  Convert all to binary? [y/N] \c"

  local answer="n"
  if read -r -t 60 answer 2>/dev/null; then
    : # got input within timeout
  else
    echo
    warn "No response after 60s — skipping binary conversion. __DRAFT files preserved."
  fi

  local draft_only=${#txt_files[@]}
  local passed=0 failed=0

  # ── APPLY phase (only if user said y) ───────────────────────────────────────
  if [[ "${answer,,}" == "y" ]]; then
    draft_only=0
    header "APPLY — converting ${#txt_files[@]} file(s) to binary…"
    for f in "${txt_files[@]}"; do
      echo
      if apply_file "$f"; then
        (( passed++ )) || true
      else
        (( failed++ )) || true
      fi
    done
  else
    log "Binary conversion skipped — __DRAFT files preserved in output/"
  fi

  # ── Write report ─────────────────────────────────────────────────────────────
  local total=$(( passed + failed + draft_only ))
  echo
  header "Writing report…"
  local rpt
  rpt=$(write_report "$passed" "$failed" "$draft_only" "$total")
  ok "Apply report: ${CYAN}$(basename "$rpt")${NC}"

  # ── Summary ──────────────────────────────────────────────────────────────────
  echo
  echo -e "${BOLD}─────────────────────────────────────${NC}"
  if [[ $draft_only -gt 0 ]]; then
    echo -e "  ${YELLOW}Draft: $draft_only${NC}  |  Total: $total"
  else
    echo -e "  ${GREEN}Passed: $passed${NC}  |  ${RED}Failed: $failed${NC}  |  Total: $total"
  fi
  echo -e "  Outputs in ${CYAN}output/${NC}"
  echo -e "${BOLD}─────────────────────────────────────${NC}"

  if [[ $failed -gt 0 ]]; then
    echo -e "\n  ${RED}One or more conversions failed — see report for details.${NC}"
  elif [[ $draft_only -gt 0 ]]; then
    echo -e "\n  ${YELLOW}DRAFT only. Rerun and press y to convert to binary.${NC}"
  else
    echo -e "\n  ${GREEN}All conversions verified successfully.${NC}"
  fi

  echo -e "\n  ${YELLOW}Closing in 5 seconds…${NC}"
  sleep 5

  [[ $failed -eq 0 ]]
}

trap 'rm -rf "$TEMP_DIR"' EXIT
main "$@"
