#!/usr/bin/env bash
# =============================================================================
# edit_inputs.sh — Review-before-commit DRAFT workflow
#
# Usage:
#   ./scripts/edit_inputs.sh           — DRAFT mode
#   ./scripts/edit_inputs.sh apply     — APPLY mode
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE="$REPO_DIR/core/convert.py"

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

if [[ -z "${WORD_SIZES[*]:-}" && -n "${WORD_SIZE:-}" ]]; then
  WORD_SIZES=("$WORD_SIZE")
fi

INPUT_DIR="$REPO_DIR/$INPUT_DIR"
OUTPUT_DIR="$REPO_DIR/$OUTPUT_DIR"
REPORT_DIR="$REPO_DIR/$REPORT_DIR"
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

DRAFT_ENTRIES=()
DRAFT_ERRORS=()
APPLY_ENTRIES=()
APPLY_ERRORS=()

# ─── Dependency check ────────────────────────────────────────────────────────

check_deps() {
  local missing=()
  command -v python3 &>/dev/null || missing+=("python3")
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

# ─── Wrappers around core/convert.py ─────────────────────────────────────────

bin_to_txt()          { python3 "$CORE" bin_to_txt  "$1" "$2" "$ENDIAN" "${WORD_SIZES[@]}"; }
txt_to_bin()          { python3 "$CORE" txt_to_bin  "$1" "$2" "$ENDIAN" "${WORD_SIZES[@]}"; }
validate_txt()        { python3 "$CORE" validate     "$1" "$ENDIAN" "${WORD_SIZES[@]}"; }
normalize_txt()       { python3 "$CORE" normalize    "$1" "$2" "$ENDIAN" "${WORD_SIZES[@]}"; }
sha256()              { python3 "$CORE" sha256       "$1"; }
verify_bin_roundtrip(){ python3 "$CORE" verify_b2t   "$1" "$2" "$TEMP_DIR" "$ENDIAN" "${WORD_SIZES[@]}"; }
verify_txt_roundtrip(){ python3 "$CORE" verify_t2b   "$1" "$2" "$TEMP_DIR" "$ENDIAN" "${WORD_SIZES[@]}"; }

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

draft_bin() {
  local src="$1" draft_label="${2:-}"
  local filename; filename="$(basename "$src")"
  local base="${filename%.*}"
  local stem="${draft_label:-${base}}"
  local draft_dst="$OUTPUT_DIR/__DRAFT_${stem}.txt"
  local status="DRAFT" detail="" hash_a hash_b

  log "${CYAN}DRAFT${NC}  BIN→TXT  $filename"
  hash_a=$(sha256 "$src")
  local input_size; input_size="$(wc -c < "$src") bytes"

  bin_to_txt "$src" "$draft_dst"

  local rows; rows=$(grep -c ' ' "$draft_dst" 2>/dev/null || echo 0)
  local output_info="__DRAFT_${stem}.txt  (${rows} rows)"
  log "       → ${CYAN}${output_info}${NC}"

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

draft_txt() {
  local src="$1" draft_label="${2:-}"
  local filename; filename="$(basename "$src")"
  local base="${filename%.*}"
  local stem="${draft_label:-${base}}"
  local draft_dst="$OUTPUT_DIR/__DRAFT_${stem}.txt"
  local status="DRAFT" detail="" fmt_notes=""

  log "${CYAN}DRAFT${NC}  TXT      $filename"

  local fmt_result
  fmt_result=$(validate_txt "$src" 2>&1)
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
  log "       → ${CYAN}__DRAFT_${stem}.txt${NC}"

  local hash_a; hash_a=$(sha256 "$src")
  local hash_b; hash_b=$(sha256 "$draft_dst")
  local input_size; input_size="$(wc -l < "$src") lines"

  DRAFT_ENTRIES+=("$(format_entry "TXT → DRAFT  [FORMAT CHECK]" "$filename" "__DRAFT_${stem}.txt" "$input_size" "$hash_a" "$hash_b" "$status" "$detail" "$fmt_notes")")
}

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
    echo "    ./scripts/edit_inputs.sh apply"
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

apply_draft() {
  local src="$1"
  local filename; filename="$(basename "$src")"
  local base="${filename#__DRAFT_}"
  base="${base%.*}"
  local dst="$OUTPUT_DIR/${base}.bin"
  local status="PASS" detail="" fmt_notes="" hash_a hash_b output_info input_size

  log "${CYAN}APPLY${NC}  __DRAFT_${base}.txt → ${base}.bin"

  local fmt_result
  fmt_result=$(validate_txt "$src" 2>&1)
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

  declare -A bin_bases txt_bases
  for f in "${bin_files[@]}"; do
    local b; b="$(basename "${f%.*}")"
    bin_bases["$b"]="$f"
  done
  for f in "${txt_files[@]}"; do
    local b; b="$(basename "${f%.*}")"
    txt_bases["$b"]="$f"
  done

  local conflicts=()
  for b in "${!bin_bases[@]}"; do
    if [[ -n "${txt_bases[$b]:-}" ]]; then
      conflicts+=("$b")
    fi
  done

  if [[ ${#conflicts[@]} -gt 0 ]]; then
    echo
    warn "Naming conflict(s) detected — same base name in both .bin and .txt:"
    for c in "${conflicts[@]}"; do
      log "  ${YELLOW}${c}${NC}  →  both ${c}.bin and ${c}.txt present"
      log "     Tagged drafts: ${CYAN}__DRAFT_${c}~bin.txt${NC} and ${CYAN}__DRAFT_${c}~txt.txt${NC}"
      log "     Apply will produce: ${CYAN}${c}~bin.bin${NC} and ${CYAN}${c}~txt.bin${NC}  (diff them to verify)"
    done
  fi

  local drafted=0 failed=0

  if [[ ${#bin_files[@]} -gt 0 ]]; then
    header "Binary files — extracting to DRAFT text…"
    for f in "${bin_files[@]}"; do
      echo
      local b; b="$(basename "${f%.*}")"
      local stem="$b"
      if [[ -n "${txt_bases[$b]:-}" ]]; then stem="${b}~bin"; fi
      if draft_bin "$f" "$stem"; then
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
      local b; b="$(basename "${f%.*}")"
      local stem="$b"
      if [[ -n "${bin_bases[$b]:-}" ]]; then stem="${b}~txt"; fi
      draft_txt "$f" "$stem"
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
    echo -e "  ${CYAN}./scripts/edit_inputs.sh apply${NC}"
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
    log "Run ${CYAN}./scripts/edit_inputs.sh${NC} first to create drafts."
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

trap 'rm -rf "$TEMP_DIR"' EXIT

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
