#!/usr/bin/env bash
# =============================================================================
# compare_inputs.sh — Content fingerprinting + cross-match comparison
#
# Usage:  ./scripts/compare_inputs.sh
#
# Dump any mix of .bin and .txt files into input/. The script fingerprints
# every file by its normalized binary content, then groups all files that
# represent identical data — regardless of filename or file type.
#
# All successfully fingerprinted files are moved to output/ as "reviewed".
# A compare report is written to output/reports/ for every run.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_COMPARE="$REPO_DIR/core/compare.py"

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

ADDRESS_BITS="${ADDRESS_BITS:-32}"

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

# ─── Write report ────────────────────────────────────────────────────────────

write_report() {
  local n_groups="$1" n_singletons="$2" n_errors="$3" n_total="$4"
  local group_data_file="$5"

  local dt_file dt_display
  dt_file=$(date '+%Y-%m-%d_%I%M%p' | tr '[:upper:]' '[:lower:]')
  dt_display=$(date '+%Y-%m-%d  %I:%M %p')
  local report_file="$REPORT_DIR/${dt_file}_bintxt-tool_compare_report.txt"

  local overall="ALL FILES UNIQUE"
  [[ $n_groups -gt 0 ]] && overall="${n_groups} MATCH GROUP(S) FOUND"

  {
    echo "============================================================"
    echo "  BINTXT_TOOL — COMPARE REPORT"
    echo "  Generated : $dt_display"
    echo "============================================================"
    echo
    echo "  Configuration (source of truth)"
    echo "  --------------------------------"
    echo "  Word layout : ${LAYOUT_LABEL}  (${#WORD_SIZES[@]} word(s), ${STRIDE}B stride)"
    echo "  Byte order  : $ENDIAN-endian"
    echo "  Address bits: $ADDRESS_BITS-bit"
    echo "  Input dir   : $INPUT_DIR"
    echo "  Output dir  : $OUTPUT_DIR  (reviewed files moved here)"
    echo "  Report dir  : $REPORT_DIR"
    echo
    echo "  Summary"
    echo "  -------"
    echo "  Files processed  : $n_total"
    echo "  Match groups     : $n_groups  (2+ files with identical content)"
    echo "  Unique files     : $n_singletons  (no match found)"
    echo "  Errors           : $n_errors  (left in input/ untouched)"
    echo "  Status           : $overall"
    echo
    cat "$group_data_file"
    echo
    echo "============================================================"
    echo "  END OF REPORT  —  bintxt_tool  (${LAYOUT_LABEL}, ENDIAN=${ENDIAN})"
    echo "============================================================"
  } > "$report_file"

  echo "$report_file"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  check_deps

  echo -e "\n${BOLD}${BLUE}bintxt_tool  —  COMPARE${NC}  (layout: ${LAYOUT_LABEL} · endian: ${ENDIAN})"
  echo -e "  Input:   ${CYAN}$INPUT_DIR${NC}"
  echo -e "  Output:  ${CYAN}$OUTPUT_DIR${NC}  (reviewed files moved here)"
  echo -e "  Reports: ${CYAN}$REPORT_DIR${NC}"

  # ── Collect all input files ──────────────────────────────────────────────
  local all_files=()
  while IFS= read -r -d '' f; do
    all_files+=("$f")
  done < <(find "$INPUT_DIR" -maxdepth 1 -type f \( -iname "*.bin" -o -iname "*.txt" \) -print0 | sort -z)

  if [[ ${#all_files[@]} -eq 0 ]]; then
    warn "No .bin or .txt files found in input/"
    echo
    sleep 5
    exit 0
  fi

  echo -e "  Found:   ${BOLD}${#all_files[@]}${NC} file(s) to fingerprint\n"

  # ── Fingerprint every file via core/compare.py ──────────────────────────
  header "Fingerprinting ${#all_files[@]} file(s)…"

  local fp_paths=() fp_hashes=() fp_types=() fp_errors=()

  for f in "${all_files[@]}"; do
    local fname; fname="$(basename "$f")"
    local ext="${fname##*.}"
    local type_label
    [[ "${ext,,}" == "bin" ]] && type_label="BINARY" || type_label="TEXT  "

    echo
    log "${CYAN}${type_label}${NC}  $fname"

    local fp_out fp_status fp_hash fp_rest
    if fp_out=$(python3 "$CORE_COMPARE" fingerprint "$f" "$TEMP_DIR" "$ENDIAN" "$ADDRESS_BITS" "${WORD_SIZES[@]}" 2>&1); then
      read -r fp_status fp_hash fp_rest <<< "$fp_out"
      if [[ "$fp_status" == "OK" ]]; then
        fp_paths+=("$f")
        fp_hashes+=("$fp_hash")
        fp_types+=("$type_label")
        fp_errors+=("")
        log "         Content hash: ${fp_hash:0:20}…"
        ok "Fingerprinted"
      else
        fp_paths+=("$f")
        fp_hashes+=("ERROR")
        fp_types+=("$type_label")
        fp_errors+=("$fp_hash $fp_rest")
        err "Failed: $fp_hash $fp_rest  (left in input/)"
      fi
    else
      fp_paths+=("$f")
      fp_hashes+=("ERROR")
      fp_types+=("$type_label")
      fp_errors+=("Fingerprint call failed")
      err "Failed: Fingerprint call failed  (left in input/)"
    fi
  done

  # ── Group by content hash via core/compare.py ───────────────────────────
  header "Grouping by content…"

  local group_data_file="$TEMP_DIR/group_data.txt"

  python3 "$CORE_COMPARE" group \
    "$group_data_file" \
    "${fp_hashes[@]}" \
    "---PATHS---"  "${fp_paths[@]}" \
    "---TYPES---"  "${fp_types[@]}" \
    "---ERRORS---" "${fp_errors[@]}"

  # Read counts from first line
  local count_line
  count_line=$(head -1 "$group_data_file")
  local n_groups n_singletons n_errors
  read -r _ n_groups n_singletons n_errors <<< "$count_line"

  local clean_group_file="$TEMP_DIR/group_data_clean.txt"
  tail -n +2 "$group_data_file" > "$clean_group_file"

  cat "$clean_group_file"

  # ── Move reviewed files to output/ ──────────────────────────────────────
  header "Moving reviewed files to output/…"
  local moved=0
  for i in "${!fp_hashes[@]}"; do
    if [[ "${fp_hashes[$i]}" != "ERROR" ]]; then
      local fname; fname="$(basename "${fp_paths[$i]}")"
      mv "${fp_paths[$i]}" "$OUTPUT_DIR/${fname}"
      log "  ${CYAN}${fname}${NC}"
      (( moved++ )) || true
    fi
  done
  log "${moved} file(s) moved to output/"

  # ── Write report ────────────────────────────────────────────────────────
  echo
  header "Writing compare report…"
  local n_processed=$(( ${#all_files[@]} - n_errors ))
  local rpt
  rpt=$(write_report "$n_groups" "$n_singletons" "$n_errors" "$n_processed" "$clean_group_file")
  ok "Compare report: ${CYAN}$(basename "$rpt")${NC}"

  # ── Summary ─────────────────────────────────────────────────────────────
  echo
  echo -e "${BOLD}─────────────────────────────────────${NC}"
  echo -e "  ${BOLD}Files:${NC} ${#all_files[@]}  |  ${GREEN}Groups: $n_groups${NC}  |  Unique: $n_singletons  |  ${RED}Errors: $n_errors${NC}"
  echo -e "  Reviewed files moved to ${CYAN}output/${NC}"
  echo -e "${BOLD}─────────────────────────────────────${NC}"

  if [[ $n_groups -gt 0 ]]; then
    echo -e "\n  ${GREEN}${n_groups} match group(s) found — see report for details.${NC}"
  elif [[ $n_errors -eq 0 ]]; then
    echo -e "\n  All files are unique — no content matches."
  fi

  echo -e "\n  ${YELLOW}Closing in 5 seconds…${NC}"
  sleep 5

  [[ $n_errors -eq 0 ]]
}

trap 'rm -rf "$TEMP_DIR"' EXIT
main "$@"
