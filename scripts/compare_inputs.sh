#!/usr/bin/env bash
# =============================================================================
# compare_inputs.sh — Binary ↔ Text pair comparison (COMPARE)
#
# Usage:  ./scripts/compare_inputs.sh
#
# Place matching .bin/.txt pairs in ./input/ — every .bin must have a .txt
# with the exact same base name, and vice versa. Unpaired files are flagged
# as errors and left untouched in input/.
#
# For each valid pair:
#   1. The .bin is extracted to text using WORD_SIZES/ENDIAN from config.sh
#   2. Both the extracted text and the input .txt are normalized and compared
#   3. Result is MATCH or MISMATCH (with diff detail on mismatch)
#   4. Both files of the pair are moved to output/ (marking them as reviewed)
#
# Unpaired files stay in input/ untouched.
# A compare report is written to output/reports/ for every run.
#
# Config is the source of truth — the .bin is always extracted using current
# WORD_SIZES and ENDIAN settings for comparison.
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

# Backward-compat: old WORD_SIZE scalar
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

# ─── Report state ────────────────────────────────────────────────────────────

COMPARE_ENTRIES=()   # one entry per pair
UNPAIRED=()          # filenames with no matching counterpart

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

# ─── BIN → TXT extraction ────────────────────────────────────────────────────

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

# ─── Normalize for comparison ─────────────────────────────────────────────────
# Lowercase, skip blanks, zero-pad addresses to 8 hex digits

normalize_for_compare() {
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

# ─── Format a single compare report entry ────────────────────────────────────

format_pair_entry() {
  local base="$1" bin_hash="$2" txt_hash="$3" result="$4" detail="$5"
  local icon
  if [[ "$result" == "MATCH" ]]; then
    icon="✓  MATCH"
  else
    icon="✗  MISMATCH"
  fi
  {
    echo "  Pair            : ${base}.bin  ↔  ${base}.txt"
    echo "  SHA-256 (.bin)  : $bin_hash"
    echo "  SHA-256 (.txt)  : $txt_hash"
    echo "  Result          : $icon"
    if [[ -n "$detail" ]]; then
      echo "  Diff            :"
      echo "$detail" | sed 's/^/    /'
    fi
  }
}

# ─── Compare a single pair ───────────────────────────────────────────────────

compare_pair() {
  local bin_src="$1" txt_src="$2"
  local base; base="$(basename "${bin_src%.*}")"

  log "${CYAN}COMPARE${NC}  ${base}.bin  ↔  ${base}.txt"

  local bin_hash txt_hash
  bin_hash=$(sha256 "$bin_src")
  txt_hash=$(sha256 "$txt_src")
  log "         SHA-256 .bin: ${bin_hash:0:20}…"
  log "         SHA-256 .txt: ${txt_hash:0:20}…"

  # Extract bin to temp txt
  local extracted_txt="$TEMP_DIR/extracted_${base}.txt"
  if ! bin_to_txt "$bin_src" "$extracted_txt" 2>&1; then
    err "Failed to extract ${base}.bin — skipping pair"
    COMPARE_ENTRIES+=("$(format_pair_entry "$base" "$bin_hash" "$txt_hash" "ERROR" "Binary extraction failed.")")
    return 1
  fi

  # Normalize both sides
  local norm_extracted norm_input
  norm_extracted=$(normalize_for_compare "$extracted_txt")
  norm_input=$(normalize_for_compare "$txt_src")

  local result detail=""
  if [[ "$norm_extracted" == "$norm_input" ]]; then
    result="MATCH"
    ok "Contents MATCH"
  else
    result="MISMATCH"
    detail=$(diff <(echo "$norm_extracted") <(echo "$norm_input") 2>&1 || true)
    err "Contents MISMATCH"
    echo "$detail" | head -10 | sed 's/^/         /'
  fi

  # Move both files to output/ (mark as reviewed)
  mv "$bin_src" "$OUTPUT_DIR/${base}.bin"
  mv "$txt_src" "$OUTPUT_DIR/${base}.txt"
  log "         Moved to output/: ${base}.bin  ${base}.txt"

  COMPARE_ENTRIES+=("$(format_pair_entry "$base" "$bin_hash" "$txt_hash" "$result" "$detail")")
  [[ "$result" == "MATCH" ]]
}

# ─── Write compare report ────────────────────────────────────────────────────

write_report() {
  local matched="$1" mismatched="$2" errors="$3" unpaired="$4"
  local dt_file dt_display
  dt_file=$(date '+%Y-%m-%d_%I%M%p' | tr '[:upper:]' '[:lower:]')
  dt_display=$(date '+%Y-%m-%d  %I:%M %p')
  local report_file="$REPORT_DIR/${dt_file}_bintxt-tool_compare_report.txt"

  local total_pairs=$(( matched + mismatched + errors ))
  local overall="ALL PAIRS MATCHED"
  [[ $mismatched -gt 0 || $errors -gt 0 ]] && overall="COMPLETED WITH DIFFERENCES"
  [[ $unpaired -gt 0 ]] && overall="${overall} + ${unpaired} UNPAIRED FILE(S)"

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
    echo "  Input dir   : $INPUT_DIR"
    echo "  Output dir  : $OUTPUT_DIR  (reviewed pairs moved here)"
    echo "  Report dir  : $REPORT_DIR"
    echo
    echo "  Summary"
    echo "  -------"
    echo "  Pairs compared : $total_pairs"
    echo "  Matched        : $matched"
    echo "  Mismatched     : $mismatched"
    echo "  Errors         : $errors"
    echo "  Unpaired files : $unpaired  (left in input/ untouched)"
    echo "  Status         : $overall"
    echo
    echo "============================================================"
    echo "  PAIR RESULTS"
    echo "============================================================"
    echo

    local i=1
    for entry in "${COMPARE_ENTRIES[@]}"; do
      printf "  [%d]\n" "$i"
      echo "$entry"
      echo
      (( i++ ))
    done

    if [[ ${#UNPAIRED[@]} -gt 0 ]]; then
      echo "============================================================"
      echo "  UNPAIRED FILES  (no matching counterpart — left in input/)"
      echo "============================================================"
      echo
      for f in "${UNPAIRED[@]}"; do
        echo "  $f"
      done
      echo
      echo "  Each .bin requires a matching .txt with the same base name"
      echo "  and vice versa. Add the missing counterpart and re-run."
    fi

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
  echo -e "  Output:  ${CYAN}$OUTPUT_DIR${NC}  (reviewed pairs moved here)"
  echo -e "  Reports: ${CYAN}$REPORT_DIR${NC}"

  # ── Inventory input/ ────────────────────────────────────────────────────────
  declare -A bin_map txt_map   # base → full path

  while IFS= read -r -d '' f; do
    local fname; fname="$(basename "$f")"
    local ext="${fname##*.}"
    local base="${fname%.*}"
    case "${ext,,}" in
      bin) bin_map["$base"]="$f" ;;
      txt) txt_map["$base"]="$f" ;;
    esac
  done < <(find "$INPUT_DIR" -maxdepth 1 -type f \( -iname "*.bin" -o -iname "*.txt" \) -print0 | sort -z)

  if [[ ${#bin_map[@]} -eq 0 && ${#txt_map[@]} -eq 0 ]]; then
    warn "No .bin or .txt files found in input/"
    echo
    sleep 5
    exit 0
  fi

  # ── Find pairs and unpaired files ───────────────────────────────────────────
  local pairs=()
  for base in $(echo "${!bin_map[@]}" | tr ' ' '\n' | sort); do
    if [[ -n "${txt_map[$base]:-}" ]]; then
      pairs+=("$base")
    else
      UNPAIRED+=("${base}.bin  (no matching .txt)")
    fi
  done
  for base in $(echo "${!txt_map[@]}" | tr ' ' '\n' | sort); do
    if [[ -z "${bin_map[$base]:-}" ]]; then
      UNPAIRED+=("${base}.txt  (no matching .bin)")
    fi
  done

  if [[ ${#pairs[@]} -eq 0 ]]; then
    warn "No complete .bin/.txt pairs found in input/"
    if [[ ${#UNPAIRED[@]} -gt 0 ]]; then
      log "Unpaired files (need a matching counterpart):"
      for f in "${UNPAIRED[@]}"; do
        log "  ${YELLOW}${f}${NC}"
      done
    fi
    echo
    sleep 5
    exit 1
  fi

  # ── Report unpaired files upfront ───────────────────────────────────────────
  if [[ ${#UNPAIRED[@]} -gt 0 ]]; then
    echo
    warn "${#UNPAIRED[@]} unpaired file(s) found — will be left in input/ untouched:"
    for f in "${UNPAIRED[@]}"; do
      log "  ${YELLOW}${f}${NC}"
    done
  fi

  # ── Compare each pair ───────────────────────────────────────────────────────
  header "Comparing ${#pairs[@]} pair(s)…"

  local matched=0 mismatched=0 errors=0

  for base in "${pairs[@]}"; do
    echo
    if compare_pair "${bin_map[$base]}" "${txt_map[$base]}"; then
      (( matched++ )) || true
    else
      # distinguish errors vs mismatches
      if echo "${COMPARE_ENTRIES[-1]}" | grep -q "ERROR"; then
        (( errors++ )) || true
      else
        (( mismatched++ )) || true
      fi
    fi
  done

  # ── Write report ────────────────────────────────────────────────────────────
  echo
  header "Writing compare report…"
  local rpt
  rpt=$(write_report "$matched" "$mismatched" "$errors" "${#UNPAIRED[@]}")
  ok "Compare report: ${CYAN}$(basename "$rpt")${NC}"

  # ── Summary ─────────────────────────────────────────────────────────────────
  local total_pairs=$(( matched + mismatched + errors ))
  echo
  echo -e "${BOLD}─────────────────────────────────────${NC}"
  echo -e "  ${GREEN}Matched: $matched${NC}  |  ${RED}Mismatched: $mismatched${NC}  |  Pairs: $total_pairs"
  if [[ ${#UNPAIRED[@]} -gt 0 ]]; then
    echo -e "  ${YELLOW}Unpaired: ${#UNPAIRED[@]}${NC}  (left in input/ — add counterpart to compare)"
  fi
  echo -e "  Reviewed pairs moved to ${CYAN}output/${NC}"
  echo -e "${BOLD}─────────────────────────────────────${NC}"

  if [[ $mismatched -gt 0 || $errors -gt 0 ]]; then
    echo -e "\n  ${RED}Differences found — see compare report for details.${NC}"
  elif [[ $matched -gt 0 ]]; then
    echo -e "\n  ${GREEN}All pairs match.${NC}"
  fi

  echo -e "\n  ${YELLOW}Closing in 5 seconds…${NC}"
  sleep 5

  [[ $mismatched -eq 0 && $errors -eq 0 ]]
}

trap 'rm -rf "$TEMP_DIR"' EXIT
main "$@"
