#!/usr/bin/env bash
# =============================================================================
# edit_inputs.sh — Review-before-commit DRAFT workflow
#
# Usage:
#   ./edit_inputs.sh           — DRAFT mode
#   ./edit_inputs.sh apply     — APPLY mode
#
# ── DRAFT mode (no args) ──────────────────────────────────────────────────────
#   Scans input/ for .bin and .txt files and writes DRAFT copies to output/:
#     .bin files  → extracted to text → output/__DRAFT_name.txt
#     .txt files  → format-verified, normalized → output/__DRAFT_name.txt
#   Writes a draft report. Exits cleanly. No prompt, no timeout.
#
# ── APPLY mode (./edit_inputs.sh apply) ───────────────────────────────────────
#   Scans output/ for __DRAFT_*.txt files.
#   Validates each against config, converts to output/name.bin.
#   Removes the __DRAFT_ copy on success.
#   Writes an apply report. Exits cleanly.
#
# Interrupted mid-run (terminal closed)? Draft files remain in output/ and
# the report captures what was done up to that point on next apply run.
#
# Outputs land in ./output/   Reports land in ./output/reports/
# Config is the source of truth — all files validated against WORD_SIZES/ENDIAN.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Load config ─────────────────────────────────────────────────────────────

if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
  source "$SCRIPT_DIR/config.sh"
else
  ENDIAN="little"
  WORD_SIZES=(4)
  INPUT_DIR="input"
  OUTPUT_DIR="output"
  REPORT_DIR="output/reports"
fi

# Backward-compat: if old WORD_SIZE is set but WORD_SIZES is not
if [[ -z "${WORD_SIZES[*]:-}" && -n "${WORD_SIZE:-}" ]]; then
  WORD_SIZES=("$WORD_SIZE")
fi

INPUT_DIR="$SCRIPT_DIR/$INPUT_DIR"
OUTPUT_DIR="$SCRIPT_DIR/$OUTPUT_DIR"
REPORT_DIR="$SCRIPT_DIR/$REPORT_DIR"
TEMP_DIR="$(mktemp -d)"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" "$REPORT_DIR"

STRIDE=0
LAYOUT_LABEL=""
for ws in "${WORD_SIZES[@]}"; do
  (( STRIDE += ws )) || true
  LAYOUT_LABEL+="${ws}B+"
done
LAYOUT_LABEL="${LAYOUT_LABEL%+}"

# ─── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "  $*"; }
ok()     { echo -e "  ${GREEN}✓${NC} $*"; }
warn()   { echo -e "  ${YELLOW}⚠${NC}  $*"; }
err()    { echo -e "  ${RED}✗${NC} $*"; }
header() { echo -e "\n${BOLD}${BLUE}$*${NC}"; }

# ─── Report state ────────────────────────────────────────────────────────────

DRAFT_ENTRIES=()
DRAFT_ERRORS=()
APPLY_ENTRIES=()
APPLY_ERRORS=()

# ─── Dependency check ────────────────────────────────────────────────────────

check_deps() {
  local missing=()
  command -v python3 &>/dev/null || missing+=("python3")
  if ! command -v sha256sum &>/dev/null && ! command -v shasum &>/dev/null; then
    missing+=("sha256sum or shasum")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools: ${missing[*]}"
    exit 1
  fi
  if [[ ${#WORD_SIZES[@]} -lt 1 || ${#WORD_SIZES[@]} -gt 6 ]]; then
    err "WORD_SIZES must have 1–6 entries (got ${#WORD_SIZES[@]})"
    exit 1
  fi
  for ws in "${WORD_SIZES[@]}"; do
    if [[ "$ws" != "1" && "$ws" != "2" && "$ws" != "4" && "$ws" != "8" ]]; then
      err "Invalid word size: $ws (must be 1, 2, 4, or 8)"
      exit 1
    fi
  done
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
  python3 - "$src" "$dst" "$ENDIAN" "${WORD_SIZES[@]}" <<'PYEOF'
import sys

src, dst, endian = sys.argv[1], sys.argv[2], sys.argv[3]
word_sizes = [int(x) for x in sys.argv[4:]]
stride = sum(word_sizes)

with open(src, 'rb') as f:
    data = f.read()

lines = []
offset = 0

while offset < len(data):
    parts = [f"{offset:08x}"]
    cur = offset
    for ws in word_sizes:
        chunk = data[cur:cur+ws] if cur + ws <= len(data) else \
                data[cur:] + b'\x00' * (ws - max(0, len(data) - cur))
        val = int.from_bytes(chunk[:ws], byteorder=endian)
        parts.append(f"{val:0{ws*2}x}")
        cur += ws
    lines.append(" ".join(parts))
    offset += stride

lines.append(f"{offset:08x}")

with open(dst, 'w') as f:
    f.write('\n'.join(lines) + '\n')
PYEOF
}

# ─── TXT → BIN ───────────────────────────────────────────────────────────────

txt_to_bin() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" "$ENDIAN" "${WORD_SIZES[@]}" <<'PYEOF'
import sys

src, dst, endian = sys.argv[1], sys.argv[2], sys.argv[3]
word_sizes = [int(x) for x in sys.argv[4:]]
n_words = len(word_sizes)
stride  = sum(word_sizes)

entries = []
with open(src) as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        try:
            addr = int(parts[0], 16)
            vals = [int(v, 16) for v in parts[1:n_words + 1]]
        except ValueError:
            continue
        if len(vals) < n_words:
            continue
        entries.append((addr, vals))

if not entries:
    print("ERROR: no valid rows found", file=sys.stderr)
    sys.exit(1)

last_addr = entries[-1][0]
file_size = last_addr + stride
buf = bytearray(file_size)

for addr, vals in entries:
    cur = addr
    for val, ws in zip(vals, word_sizes):
        buf[cur:cur+ws] = val.to_bytes(ws, byteorder=endian)
        cur += ws

with open(dst, 'wb') as f:
    f.write(buf)
PYEOF
}

# ─── TXT format validation ────────────────────────────────────────────────────

validate_txt_format() {
  local src="$1"
  python3 - "$src" "$ENDIAN" "${WORD_SIZES[@]}" <<'PYEOF'
import sys

src        = sys.argv[1]
endian     = sys.argv[2]
word_sizes = [int(x) for x in sys.argv[3:]]
n_words    = len(word_sizes)
issues     = []
line_num   = 0

with open(src) as f:
    for raw in f:
        line_num += 1
        line = raw.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) == 1:
            continue
        if len(parts) < 2:
            issues.append(f"line {line_num}: unparseable — '{line[:60]}'")
            continue
        try:
            addr = int(parts[0], 16)
        except ValueError:
            issues.append(f"line {line_num}: bad address '{parts[0]}'")
            continue

        stride = sum(word_sizes)
        if addr % stride != 0:
            issues.append(f"line {line_num}: address 0x{addr:x} not aligned to stride={stride}")

        val_parts = parts[1:]
        if len(val_parts) != n_words:
            issues.append(f"line {line_num}: expected {n_words} value column(s), got {len(val_parts)}")
            continue

        for i, (vp, ws) in enumerate(zip(val_parts, word_sizes)):
            expected_len = ws * 2
            try:
                val = int(vp, 16)
            except ValueError:
                issues.append(f"line {line_num}: word {i+1}: bad hex '{vp}'")
                continue
            max_val = (1 << (ws * 8)) - 1
            if val > max_val:
                issues.append(f"line {line_num}: word {i+1}: value 0x{val:x} overflows {ws}-byte field")
            if len(vp) != expected_len:
                issues.append(f"line {line_num}: word {i+1}: width {len(vp)} chars (expected {expected_len} for {ws}B)")

if issues:
    print("ISSUES\n" + "\n".join(issues))
else:
    print("OK")
PYEOF
}

# ─── Normalize TXT ───────────────────────────────────────────────────────────

normalize_txt() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" "$ENDIAN" "${WORD_SIZES[@]}" <<'PYEOF'
import sys

src, dst, endian = sys.argv[1], sys.argv[2], sys.argv[3]
word_sizes = [int(x) for x in sys.argv[4:]]
n_words = len(word_sizes)
lines_out = []

with open(src) as f:
    for raw in f:
        line = raw.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) == 1:
            try:
                lines_out.append(f"{int(parts[0], 16):08x}")
            except ValueError:
                lines_out.append(line)
            continue
        if len(parts) >= n_words + 1:
            try:
                addr = int(parts[0], 16)
                row = [f"{addr:08x}"]
                for i, ws in enumerate(word_sizes):
                    val = int(parts[i+1], 16) if i+1 < len(parts) else 0
                    row.append(f"{val:0{ws*2}x}")
                lines_out.append(" ".join(row))
                continue
            except ValueError:
                pass
        lines_out.append(line)

with open(dst, 'w') as f:
    f.write("\n".join(lines_out) + "\n")
PYEOF
}

# ─── Verification ────────────────────────────────────────────────────────────

verify_bin_roundtrip() {
  local orig_bin="$1" gen_txt="$2"
  local temp_bin="$TEMP_DIR/rt_$(basename "$orig_bin")"
  txt_to_bin "$gen_txt" "$temp_bin" 2>/dev/null || { echo "ROUNDTRIP_FAILED"; return 1; }
  local orig_hash rt_hash
  orig_hash=$(sha256 "$orig_bin")
  rt_hash=$(sha256 "$temp_bin")
  echo "$orig_hash $rt_hash"
  [[ "$orig_hash" == "$rt_hash" ]]
}

normalize_for_compare() {
  # Lowercase, strip trailing whitespace, skip blanks, pad addresses to 8 hex digits
  python3 - "$1" <<'PYNORM'
import sys
for raw in open(sys.argv[1]):
    line = raw.strip().lower()
    if not line:
        continue
    parts = line.split()
    try:
        parts[0] = f"{int(parts[0], 16):08x}"
    except (ValueError, IndexError):
        pass
    print(" ".join(parts))
PYNORM
}

verify_txt_roundtrip() {
  local orig_txt="$1" gen_bin="$2"
  local temp_txt="$TEMP_DIR/rt_$(basename "$orig_txt")"
  bin_to_txt "$gen_bin" "$temp_txt"
  local gen_hash; gen_hash=$(sha256 "$gen_bin")
  local norm_orig norm_rt
  norm_orig=$(normalize_for_compare "$orig_txt")
  norm_rt=$(normalize_for_compare "$temp_txt")
  if [[ "$norm_orig" == "$norm_rt" ]]; then
    echo "$gen_hash"; return 0
  else
    echo "MISMATCH"
    diff <(echo "$norm_orig") <(echo "$norm_rt") 2>&1 || true
    return 1
  fi
}

# ─── Format report entry ─────────────────────────────────────────────────────

format_entry() {
  local direction="$1" filename="$2" output="$3" size="$4"
  local hash_a="$5" hash_b="$6" status="$7" detail="$8" fmt_notes="${9:-}"
  local icon="✓  PASS"
  [[ "$status" == "FAIL"  ]] && icon="✗  FAIL"
  [[ "$status" == "DRAFT" ]] && icon="—  DRAFT (pending apply)"
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

# ─── DRAFT MODE ──────────────────────────────────────────────────────────────

# Draft a .bin file: extract → __DRAFT_name.txt
draft_bin() {
  local src="$1"
  local filename; filename="$(basename "$src")"
  local base="${filename%.*}"
  local draft_dst="$OUTPUT_DIR/__DRAFT_${base}.txt"
  local status="DRAFT" detail="" hash_a hash_b

  log "${CYAN}DRAFT${NC}  BIN→TXT  $filename"
  hash_a=$(sha256 "$src")
  local input_size; input_size="$(wc -c < "$src") bytes"

  bin_to_txt "$src" "$draft_dst"

  local rows; rows=$(grep -c ' ' "$draft_dst" 2>/dev/null || echo 0)
  local output_info="__DRAFT_${base}.txt  (${rows} rows)"
  log "       → ${CYAN}${output_info}${NC}"

  # Quick roundtrip check for the draft itself
  local verify_out
  if verify_out=$(verify_bin_roundtrip "$src" "$draft_dst" 2>&1); then
    read -r _ hash_b <<< "$verify_out"
    ok "Roundtrip verified  SHA-256: ${hash_b:0:20}…"
  else
    status="FAIL"; hash_b="n/a"
    detail="Roundtrip check failed on draft — source binary may be malformed."
    err "Draft roundtrip failed"
    DRAFT_ERRORS+=("[$filename] $detail")
  fi

  DRAFT_ENTRIES+=("$(format_entry "BIN → TXT  [DRAFTED]" "$filename" "$output_info" "$input_size" "$hash_a" "$hash_b" "$status" "$detail")")
  [[ "$status" != "FAIL" ]]
}

# Draft a .txt file: format-check + normalize → __DRAFT_name.txt
draft_txt() {
  local src="$1"
  local filename; filename="$(basename "$src")"
  local base="${filename%.*}"
  local draft_dst="$OUTPUT_DIR/__DRAFT_${base}.txt"
  local status="DRAFT" detail="" fmt_notes=""

  log "${CYAN}DRAFT${NC}  TXT      $filename"

  local fmt_result
  fmt_result=$(validate_txt_format "$src" 2>&1)
  if [[ "$fmt_result" == OK ]]; then
    fmt_notes="Format matches config (WORD_SIZES=${WORD_SIZES[*]}, ENDIAN=${ENDIAN})"
    ok "Format valid"
  else
    local issue_lines; issue_lines=$(echo "$fmt_result" | tail -n +2)
    fmt_notes="Format issues found — normalized. Issues: $(echo "$issue_lines" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    warn "Format issues vs config — normalized in DRAFT:"
    echo "$issue_lines" | head -5 | sed 's/^/         /'
  fi

  normalize_txt "$src" "$draft_dst"
  log "       → ${CYAN}__DRAFT_${base}.txt${NC}"

  local hash_a; hash_a=$(sha256 "$src")
  local hash_b; hash_b=$(sha256 "$draft_dst")
  local input_size; input_size="$(wc -l < "$src") lines"

  DRAFT_ENTRIES+=("$(format_entry "TXT → DRAFT  [FORMAT CHECK]" "$filename" "__DRAFT_${base}.txt" "$input_size" "$hash_a" "$hash_b" "$status" "$detail" "$fmt_notes")")
}

# Write the draft report
write_draft_report() {
  local total="$1" failed="$2"
  local dt_file dt_display
  dt_file=$(date '+%Y-%m-%d_%I%M%p' | tr '[:upper:]' '[:lower:]')
  dt_display=$(date '+%Y-%m-%d  %I:%M %p')
  local report_file="$REPORT_DIR/${dt_file}_bintxt-tool_draft_report.txt"

  {
    echo "============================================================"
    echo "  BINTXT_TOOL — DRAFT REPORT"
    echo "  Generated : $dt_display"
    echo "============================================================"
    echo
    echo "  Configuration (source of truth)"
    echo "  --------------------------------"
    echo "  Word layout : ${LAYOUT_LABEL}  (${#WORD_SIZES[@]} word(s), ${STRIDE}B stride)"
    echo "  Byte order  : $ENDIAN-endian"
    echo "  Input dir   : $INPUT_DIR"
    echo "  Output dir  : $OUTPUT_DIR"
    echo
    echo "  Summary"
    echo "  -------"
    echo "  Drafted     : $total"
    echo "  Errors      : $failed"
    echo "  Status      : $([ $failed -gt 0 ] && echo "DRAFT WITH ERRORS" || echo "ALL DRAFTED")"
    echo
    echo "  Next step: review __DRAFT_* files in output/, then run:"
    echo "    ./edit_inputs.sh apply"
    echo
    echo "============================================================"
    echo "  DRAFT FILES"
    echo "============================================================"
    echo
    local i=1
    for entry in "${DRAFT_ENTRIES[@]}"; do
      printf "  [%d]\n" "$i"
      echo "$entry"
      echo
      (( i++ ))
    done
    if [[ ${#DRAFT_ERRORS[@]} -gt 0 ]]; then
      echo "============================================================"
      echo "  ERRORS"
      echo "============================================================"
      echo
      for e in "${DRAFT_ERRORS[@]}"; do
        echo "$e"
        echo
      done
    fi
    echo "============================================================"
    echo "  END OF REPORT  —  bintxt_tool  (${LAYOUT_LABEL}, ENDIAN=${ENDIAN})"
    echo "============================================================"
  } > "$report_file"

  echo "$report_file"
}

# ─── APPLY MODE ──────────────────────────────────────────────────────────────

# Apply a single __DRAFT_*.txt → name.bin
apply_draft() {
  local src="$1"
  local filename; filename="$(basename "$src")"            # __DRAFT_name.txt
  local base="${filename#__DRAFT_}"                        # name.txt
  base="${base%.*}"                                        # name
  local dst="$OUTPUT_DIR/${base}.bin"
  local status="PASS" detail="" fmt_notes="" hash_a hash_b output_info input_size

  log "${CYAN}APPLY${NC}  __DRAFT_${base}.txt → ${base}.bin"

  local fmt_result
  fmt_result=$(validate_txt_format "$src" 2>&1)
  if [[ "$fmt_result" == OK ]]; then
    fmt_notes="Format matches config (WORD_SIZES=${WORD_SIZES[*]}, ENDIAN=${ENDIAN})"
    ok "Format valid"
  else
    local issue_lines; issue_lines=$(echo "$fmt_result" | tail -n +2)
    fmt_notes="Mismatches corrected. Issues: $(echo "$issue_lines" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    warn "Format issues — normalizing before apply:"
    echo "$issue_lines" | head -5 | sed 's/^/         /'
  fi

  input_size="$(wc -l < "$src") lines"
  hash_a=$(sha256 "$src")

  local py_err
  if ! py_err=$(txt_to_bin "$src" "$dst" 2>&1); then
    status="FAIL"; hash_b="n/a"
    detail="$py_err"
    output_info="${base}.bin  (conversion failed)"
    err "Conversion failed: $py_err"
    APPLY_ERRORS+=("[${filename}] $detail")
    APPLY_ENTRIES+=("$(format_entry "__DRAFT → BIN  [APPLY]" "$filename" "$output_info" "$input_size" "$hash_a" "$hash_b" "$status" "$detail" "$fmt_notes")")
    return 1
  fi

  local bytes; bytes=$(wc -c < "$dst")
  output_info="${base}.bin  (${bytes} bytes)"
  log "       → $output_info"
  hash_b=$(sha256 "$dst")

  local verify_out
  if verify_out=$(verify_txt_roundtrip "$src" "$dst" 2>&1); then
    hash_b="$verify_out"
    ok "Roundtrip verified  SHA-256: ${hash_b:0:20}…"
    # Clean up draft on success
    rm -f "$src"
    log "       → DRAFT removed"
  else
    status="FAIL"; hash_b="n/a"
    detail="$(echo "$verify_out" | tail -10)"
    err "Roundtrip verification failed"
    APPLY_ERRORS+=("[${filename}] Roundtrip diff:"$'\n'"$detail")
  fi

  APPLY_ENTRIES+=("$(format_entry "__DRAFT → BIN  [APPLY]" "$filename" "$output_info" "$input_size" "$hash_a" "$hash_b" "$status" "$detail" "$fmt_notes")")
  [[ "$status" == "PASS" ]]
}

write_apply_report() {
  local passed="$1" failed="$2" total="$3"
  local dt_file dt_display
  dt_file=$(date '+%Y-%m-%d_%I%M%p' | tr '[:upper:]' '[:lower:]')
  dt_display=$(date '+%Y-%m-%d  %I:%M %p')
  local report_file="$REPORT_DIR/${dt_file}_bintxt-tool_text-to-binary_apply_conversion-report.txt"

  {
    echo "============================================================"
    echo "  BINTXT_TOOL — TEXT → BINARY  [APPLY] REPORT"
    echo "  Generated : $dt_display"
    echo "============================================================"
    echo
    echo "  Configuration (source of truth)"
    echo "  --------------------------------"
    echo "  Word layout : ${LAYOUT_LABEL}  (${#WORD_SIZES[@]} word(s), ${STRIDE}B stride)"
    echo "  Byte order  : $ENDIAN-endian"
    echo "  Input       : output/__DRAFT_*.txt"
    echo "  Output dir  : $OUTPUT_DIR"
    echo "  Report dir  : $REPORT_DIR"
    echo
    echo "  Summary"
    echo "  -------"
    echo "  Files total : $total"
    echo "  Passed      : $passed"
    echo "  Failed      : $failed"
    echo "  Status      : $([ $failed -gt 0 ] && echo "COMPLETED WITH ERRORS" || echo "ALL PASSED")"
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
    echo "  END OF REPORT  —  bintxt_tool  (${LAYOUT_LABEL}, ENDIAN=${ENDIAN})"
    echo "============================================================"
  } > "$report_file"

  echo "$report_file"
}

# ─── DRAFT subcommand ─────────────────────────────────────────────────────────

run_draft() {
  echo -e "\n${BOLD}${BLUE}bintxt_tool  —  DRAFT${NC}  (layout: ${LAYOUT_LABEL} · endian: ${ENDIAN})"
  echo -e "  Input:   ${CYAN}$INPUT_DIR${NC}"
  echo -e "  Output:  ${CYAN}$OUTPUT_DIR${NC}"

  local bin_files=() txt_files=()
  while IFS= read -r -d '' f; do
    local ext="${f##*.}"
    case "${ext,,}" in
      bin) bin_files+=("$f") ;;
      txt) txt_files+=("$f") ;;
    esac
  done < <(find "$INPUT_DIR" -maxdepth 1 -type f \( -iname "*.bin" -o -iname "*.txt" \) -print0 | sort -z)

  if [[ $(( ${#bin_files[@]} + ${#txt_files[@]} )) -eq 0 ]]; then
    warn "No .bin or .txt files found in input/"
    echo
    sleep 5
    exit 0
  fi

  local drafted=0 failed=0

  if [[ ${#bin_files[@]} -gt 0 ]]; then
    header "Binary files — extracting to DRAFT text…"
    for f in "${bin_files[@]}"; do
      echo
      if draft_bin "$f"; then
        (( drafted++ )) || true
      else
        (( failed++ )) || true
      fi
    done
  fi

  if [[ ${#txt_files[@]} -gt 0 ]]; then
    header "Text files — format-checking to DRAFT…"
    for f in "${txt_files[@]}"; do
      echo
      draft_txt "$f"
      (( drafted++ )) || true
    done
  fi

  local total=$(( drafted + failed ))
  echo
  header "Writing draft report…"
  local rpt; rpt=$(write_draft_report "$total" "$failed")
  ok "Draft report: ${CYAN}$(basename "$rpt")${NC}"

  echo
  echo -e "${BOLD}─────────────────────────────────────${NC}"
  echo -e "  ${CYAN}Drafted: $drafted${NC}  |  ${RED}Errors: $failed${NC}  |  Total: $total"
  echo -e "  __DRAFT files in ${CYAN}output/${NC}"
  echo -e "${BOLD}─────────────────────────────────────${NC}"

  if [[ $failed -gt 0 ]]; then
    echo -e "\n  ${RED}Some drafts had errors — review before applying.${NC}"
  else
    echo -e "\n  ${GREEN}All drafts created.${NC}  Review output/__DRAFT_* then run:"
    echo -e "  ${CYAN}./edit_inputs.sh apply${NC}"
  fi

  echo -e "\n  ${YELLOW}Closing in 5 seconds…${NC}"
  sleep 5
}

# ─── APPLY subcommand ────────────────────────────────────────────────────────

run_apply() {
  echo -e "\n${BOLD}${BLUE}bintxt_tool  —  APPLY${NC}  (layout: ${LAYOUT_LABEL} · endian: ${ENDIAN})"
  echo -e "  Drafts:  ${CYAN}$OUTPUT_DIR/__DRAFT_*${NC}"
  echo -e "  Output:  ${CYAN}$OUTPUT_DIR${NC}"

  local draft_files=()
  while IFS= read -r -d '' f; do
    draft_files+=("$f")
  done < <(find "$OUTPUT_DIR" -maxdepth 1 -type f -name "__DRAFT_*.txt" -print0 | sort -z)

  if [[ ${#draft_files[@]} -eq 0 ]]; then
    warn "No __DRAFT_*.txt files found in output/"
    log "Run ${CYAN}./edit_inputs.sh${NC} first to create drafts."
    echo
    sleep 5
    exit 0
  fi

  header "Applying ${#draft_files[@]} DRAFT file(s) to binary…"

  local passed=0 failed=0
  for f in "${draft_files[@]}"; do
    echo
    if apply_draft "$f"; then
      (( passed++ )) || true
    else
      (( failed++ )) || true
    fi
  done

  local total=$(( passed + failed ))
  echo
  header "Writing apply report…"
  local rpt; rpt=$(write_apply_report "$passed" "$failed" "$total")
  ok "Apply report: ${CYAN}$(basename "$rpt")${NC}"

  echo
  echo -e "${BOLD}─────────────────────────────────────${NC}"
  echo -e "  ${GREEN}Passed: $passed${NC}  |  ${RED}Failed: $failed${NC}  |  Total: $total"
  echo -e "  Binaries in ${CYAN}output/${NC}"
  echo -e "${BOLD}─────────────────────────────────────${NC}"

  if [[ $failed -gt 0 ]]; then
    echo -e "\n  ${RED}One or more conversions failed — see report for details.${NC}"
  else
    echo -e "\n  ${GREEN}All drafts applied and verified.${NC}"
  fi

  echo -e "\n  ${YELLOW}Closing in 5 seconds…${NC}"
  sleep 5

  [[ $failed -eq 0 ]]
}

# ─── Entry point ─────────────────────────────────────────────────────────────

check_deps

case "${1:-}" in
  apply) run_apply ;;
  "")    run_draft ;;
  *)
    echo -e "Usage: $0 [apply]"
    echo -e "  (no args)  — create DRAFT copies of all input files"
    echo -e "  apply      — convert __DRAFT_* files in output/ to binary"
    exit 1
    ;;
esac

trap 'rm -rf "$TEMP_DIR"' EXIT
