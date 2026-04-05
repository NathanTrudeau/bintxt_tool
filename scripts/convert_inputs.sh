#!/usr/bin/env bash
# =============================================================================
# convert_inputs.sh — Binary ↔ Text conversion (EXTRACT + APPLY)
#
# Usage:  ./convert_inputs.sh
#
# Drop .bin or .txt files into ./input/ to convert them.
#
#   .bin files → extracted to .txt  (EXTRACT)
#   .txt files → validated against config, then converted to .bin  (APPLY)
#
# All files are validated against WORD_SIZES and ENDIAN from config.sh.
# Format issues are flagged in the apply report; conversion still proceeds.
#
# For a review-before-commit workflow (DRAFT copies + deliberate apply),
# use edit_inputs.sh instead.
#
# Outputs land in ./output/   Reports land in ./output/reports/
# Config is the source of truth — all files validated against it.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Load config ─────────────────────────────────────────────────────────────

if [[ -f "$REPO_DIR/cfg/config.sh" ]]; then
  source "$REPO_DIR/cfg/config.sh"
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

INPUT_DIR="$REPO_DIR/$INPUT_DIR"
OUTPUT_DIR="$REPO_DIR/$OUTPUT_DIR"
REPORT_DIR="$REPO_DIR/$REPORT_DIR"
TEMP_DIR="$(mktemp -d)"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" "$REPORT_DIR"

# Derived: row stride and human-readable layout label
STRIDE=0
LAYOUT_LABEL=""
for ws in "${WORD_SIZES[@]}"; do
  (( STRIDE += ws )) || true
  LAYOUT_LABEL+="${ws}B+"
done
LAYOUT_LABEL="${LAYOUT_LABEL%+}"   # strip trailing +

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
  # Validate WORD_SIZES
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

# ─── BIN → TXT (Python, supports multi-word WORD_SIZES) ──────────────────────

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
    remaining = len(data) - offset
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

lines.append(f"{offset:08x}")  # final address marker

with open(dst, 'w') as f:
    f.write('\n'.join(lines) + '\n')
PYEOF
}

# ─── TXT → BIN (Python, supports multi-word WORD_SIZES) ──────────────────────

txt_to_bin() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" "$ENDIAN" "${WORD_SIZES[@]}" <<'PYEOF'
import sys

src, dst, endian = sys.argv[1], sys.argv[2], sys.argv[3]
word_sizes = [int(x) for x in sys.argv[4:]]
n_words = len(word_sizes)
stride  = sum(word_sizes)

valid = {1, 2, 4, 8}
for ws in word_sizes:
    if ws not in valid:
        print(f"ERROR: invalid word size {ws} (must be 1, 2, 4, or 8)", file=sys.stderr)
        sys.exit(1)

entries = []
with open(src) as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) < 2:
            continue  # address-only line or blank
        try:
            addr = int(parts[0], 16)
            vals = [int(v, 16) for v in parts[1:n_words + 1]]
        except ValueError:
            continue
        if len(vals) < n_words:
            continue  # incomplete row
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

# ─── TXT format validation against config ────────────────────────────────────

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
            continue  # final address-only line — ok
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

# ─── Normalize TXT to canonical config format ─────────────────────────────────

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
  local hash_a="$5" hash_b="$6" status="$7" detail="$8" fmt_notes="${9:-}"
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
    if [[ -n "$fmt_notes" ]]; then echo "  Format notes    : $fmt_notes"; fi
    if [[ -n "$detail"    ]]; then echo "  Error detail    : $detail";    fi
  }
}

# ─── EXTRACT: .bin → .txt ────────────────────────────────────────────────────

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

  local rows; rows=$(grep -c ' ' "$dst" 2>/dev/null || echo 0)
  output_info="${base}.txt  (${rows} rows, layout: ${LAYOUT_LABEL})"
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

# ─── APPLY: .txt → .bin ──────────────────────────────────────────────────────

apply_file() {
  local src="$1"
  local filename; filename="$(basename "$src")"
  local base="${filename%.*}"
  local dst="$OUTPUT_DIR/${base}.bin"
  local norm_dst="$OUTPUT_DIR/${base}.txt"
  local status="PASS" detail="" fmt_notes="" hash_a hash_b output_info input_size

  log "${CYAN}APPLY${NC}    TXT→BIN  $filename"

  local fmt_result
  fmt_result=$(validate_txt_format "$src" 2>&1)
  if [[ "$fmt_result" == OK ]]; then
    fmt_notes="Format matches config (WORD_SIZES=${WORD_SIZES[*]}, ENDIAN=${ENDIAN})"
    ok "Format valid"
  else
    local issue_lines; issue_lines=$(echo "$fmt_result" | tail -n +2)
    fmt_notes="Mismatches corrected. Issues: $(echo "$issue_lines" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    warn "Format issues vs config — normalizing:"
    echo "$issue_lines" | head -5 | sed 's/^/         /'
  fi

  input_size="$(wc -l < "$src") lines"
  hash_a=$(sha256 "$src")

  normalize_txt "$src" "$norm_dst"
  log "         → Normalized: $(basename "$norm_dst")"

  local py_err
  if ! py_err=$(txt_to_bin "$src" "$dst" 2>&1); then
    status="FAIL"; hash_b="n/a"
    detail="$py_err"
    output_info="${base}.bin  (conversion failed)"
    err "Conversion failed: $py_err"
    APPLY_ERRORS+=("[$filename] $detail")
    APPLY_ENTRIES+=("$(format_entry "TXT → BIN  [APPLY]" "$filename" "$output_info" "$input_size" "$hash_a" "$hash_b" "$status" "$detail" "$fmt_notes")")
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

  APPLY_ENTRIES+=("$(format_entry "TXT → BIN  [APPLY]" "$filename" "$output_info" "$input_size" "$hash_a" "$hash_b" "$status" "$detail" "$fmt_notes")")
  [[ "$status" == "PASS" ]]
}

# ─── Write report ─────────────────────────────────────────────────────────────

write_report() {
  local label="$1" direction_label="$2"
  local -n _entries="$3"
  local -n _errors="$4"
  local passed="$5" failed="$6" total="$7"

  [[ ${#_entries[@]} -eq 0 ]] && return

  local dt_file dt_display
  dt_file=$(date '+%Y-%m-%d_%I%M%p' | tr '[:upper:]' '[:lower:]')
  dt_display=$(date '+%Y-%m-%d  %I:%M %p')

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
    echo "  Word layout : ${LAYOUT_LABEL}  (${#WORD_SIZES[@]} word(s), ${STRIDE}B stride)"
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
    echo "  Status      : $([ $failed -gt 0 ] && echo "COMPLETED WITH ERRORS" || echo "ALL PASSED")"
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
    echo "  END OF REPORT  —  bintxt_tool  (${LAYOUT_LABEL}, ENDIAN=${ENDIAN})"
    echo "============================================================"
  } > "$report_file"

  echo "$report_file"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  check_deps

  echo -e "\n${BOLD}${BLUE}bintxt_tool${NC}  (layout: ${LAYOUT_LABEL} · endian: ${ENDIAN})"
  echo -e "  Input:   ${CYAN}$INPUT_DIR${NC}"
  echo -e "  Output:  ${CYAN}$OUTPUT_DIR${NC}"
  echo -e "  Reports: ${CYAN}$REPORT_DIR${NC}"

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

  local extract_pass=0 extract_fail=0 apply_pass=0 apply_fail=0

  # ── EXTRACT ─────────────────────────────────────────────────────────────────
  if [[ ${#bin_files[@]} -gt 0 ]]; then
    header "EXTRACT — ${#bin_files[@]} binary file(s)…"
    for f in "${bin_files[@]}"; do
      echo
      if extract_file "$f"; then
        (( extract_pass++ )) || true
      else
        (( extract_fail++ )) || true
      fi
    done
    echo
    log "Archiving input .bin files → output/"
    for f in "${bin_files[@]}"; do
      local fname; fname="$(basename "$f")"
      cp "$f" "$OUTPUT_DIR/${fname}"
      log "  ${CYAN}${fname}${NC}"
    done
  fi

  # ── APPLY ───────────────────────────────────────────────────────────────────
  if [[ ${#txt_files[@]} -gt 0 ]]; then
    header "APPLY — ${#txt_files[@]} text file(s)…"
    for f in "${txt_files[@]}"; do
      echo
      if apply_file "$f"; then
        (( apply_pass++ )) || true
      else
        (( apply_fail++ )) || true
      fi
    done
  fi

  # ── Reports ─────────────────────────────────────────────────────────────────
  local extract_total=$(( extract_pass + extract_fail ))
  local apply_total=$(( apply_pass + apply_fail ))
  echo
  header "Writing reports…"
  if [[ $extract_total -gt 0 ]]; then
    local rpt1
    rpt1=$(write_report "extract" "BINARY → TEXT  [EXTRACT]" EXTRACT_ENTRIES EXTRACT_ERRORS "$extract_pass" "$extract_fail" "$extract_total")
    ok "Extract report: ${CYAN}$(basename "$rpt1")${NC}"
  fi
  if [[ $apply_total -gt 0 ]]; then
    local rpt2
    rpt2=$(write_report "apply" "TEXT → BINARY  [APPLY]" APPLY_ENTRIES APPLY_ERRORS "$apply_pass" "$apply_fail" "$apply_total")
    ok "Apply report:   ${CYAN}$(basename "$rpt2")${NC}"
  fi

  # ── Summary ─────────────────────────────────────────────────────────────────
  local total_pass=$(( extract_pass + apply_pass ))
  local total_fail=$(( extract_fail + apply_fail ))
  echo
  echo -e "${BOLD}─────────────────────────────────────${NC}"
  echo -e "  ${GREEN}Passed: $total_pass${NC}  |  ${RED}Failed: $total_fail${NC}  |  Total: $(( total_pass + total_fail ))"
  echo -e "  Outputs in ${CYAN}output/${NC}"
  echo -e "${BOLD}─────────────────────────────────────${NC}"

  if [[ $total_fail -gt 0 ]]; then
    echo -e "\n  ${RED}One or more conversions failed — see reports for details.${NC}"
  else
    echo -e "\n  ${GREEN}All conversions verified successfully.${NC}"
    if [[ ${#bin_files[@]} -gt 0 ]]; then
      echo -e "  To edit and re-apply a .txt, run ${CYAN}./scripts/edit_inputs.sh${NC} for the DRAFT review flow."
    fi
  fi

  echo -e "\n  ${YELLOW}Closing in 5 seconds…${NC}"
  sleep 5

  [[ $total_fail -eq 0 ]]
}

trap 'rm -rf "$TEMP_DIR"' EXIT
main "$@"
