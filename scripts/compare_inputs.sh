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
#   bin vs bin  — both extracted, normalized, compared
#   txt vs txt  — both normalized, compared
#   bin vs txt  — bin extracted to text, then compared against txt
#
# Result: match groups (files with identical content), singletons (no match),
# and any files that could not be processed (left in input/).
#
# All successfully fingerprinted files are moved to output/ as "reviewed".
# A compare report is written to output/reports/ for every run.
#
# Config is the source of truth — all .bin files are extracted using current
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

# ─── BIN → normalized temp txt ───────────────────────────────────────────────

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

# ─── Normalize a txt file and write to dst ───────────────────────────────────

normalize_txt() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" <<'PYEOF'
import sys
lines_out = []
for raw in open(sys.argv[1]):
    line = raw.strip().lower()
    if not line:
        continue
    parts = line.split()
    try:
        parts[0] = f"{int(parts[0], 16):08x}"
    except (ValueError, IndexError):
        pass
    lines_out.append(" ".join(parts))
with open(sys.argv[2], 'w') as f:
    f.write('\n'.join(lines_out) + '\n')
PYEOF
}

# ─── Fingerprint a single file → content hash of normalized form ─────────────
# Sets FP_HASH and FP_NORM_PATH on success, FP_ERROR on failure.

FP_HASH=""
FP_NORM_PATH=""
FP_ERROR=""

fingerprint_file() {
  local src="$1"
  local ext; ext="${src##*.}"
  local fname; fname="$(basename "$src")"
  local norm_path="$TEMP_DIR/norm_${fname}.txt"

  FP_HASH=""; FP_NORM_PATH=""; FP_ERROR=""

  case "${ext,,}" in
    bin)
      local extracted="$TEMP_DIR/extracted_${fname}.txt"
      if ! bin_to_txt "$src" "$extracted" 2>/dev/null; then
        FP_ERROR="Binary extraction failed"
        return 1
      fi
      normalize_txt "$extracted" "$norm_path" 2>/dev/null || {
        FP_ERROR="Normalization failed after extraction"
        return 1
      }
      ;;
    txt)
      normalize_txt "$src" "$norm_path" 2>/dev/null || {
        FP_ERROR="Text normalization failed"
        return 1
      }
      ;;
    *)
      FP_ERROR="Unsupported file type"
      return 1
      ;;
  esac

  FP_HASH=$(sha256 "$norm_path")
  FP_NORM_PATH="$norm_path"
}

# ─── Write report ────────────────────────────────────────────────────────────

write_report() {
  local n_groups="$1" n_singletons="$2" n_errors="$3" n_total="$4"
  # Pass group data via temp file to avoid subshell issues
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

  # ── Collect all input files ─────────────────────────────────────────────────
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

  # ── Fingerprint every file ─────────────────────────────────────────────────
  header "Fingerprinting ${#all_files[@]} file(s)…"

  # Parallel arrays: file path, content hash, file type, error
  local fp_paths=() fp_hashes=() fp_types=() fp_errors=()

  for f in "${all_files[@]}"; do
    local fname; fname="$(basename "$f")"
    local ext="${fname##*.}"
    local type_label
    [[ "${ext,,}" == "bin" ]] && type_label="BINARY" || type_label="TEXT  "

    echo
    log "${CYAN}${type_label}${NC}  $fname"

    if fingerprint_file "$f"; then
      fp_paths+=("$f")
      fp_hashes+=("$FP_HASH")
      fp_types+=("$type_label")
      fp_errors+=("")
      log "         Content hash: ${FP_HASH:0:20}…"
      ok "Fingerprinted"
    else
      fp_paths+=("$f")
      fp_hashes+=("ERROR")
      fp_types+=("$type_label")
      fp_errors+=("$FP_ERROR")
      err "Failed: $FP_ERROR  (left in input/)"
    fi
  done

  # ── Group by content hash ──────────────────────────────────────────────────
  header "Grouping by content…"

  # Use Python to do the grouping cleanly
  local group_data_file="$TEMP_DIR/group_data.txt"

  python3 - "$group_data_file" "${fp_hashes[@]}" "---PATHS---" "${fp_paths[@]}" "---TYPES---" "${fp_types[@]}" "---ERRORS---" "${fp_errors[@]}" <<'PYEOF'
import sys, collections

args = sys.argv[1:]
out_file = args[0]
args = args[1:]

sep_p = args.index("---PATHS---")
sep_t = args.index("---TYPES---")
sep_e = args.index("---ERRORS---")

hashes = args[:sep_p]
paths  = args[sep_p+1:sep_t]
types  = args[sep_t+1:sep_e]
errors = args[sep_e+1:]

import os

# Build groups: hash → list of (path, type)
groups = collections.defaultdict(list)
error_files = []

for h, p, t, e in zip(hashes, paths, types, errors):
    fname = os.path.basename(p)
    if h == "ERROR":
        error_files.append((fname, t.strip(), e))
    else:
        groups[h].append((fname, t.strip(), h))

# Sort groups: multi-file first (matches), then singletons
matches   = {h: v for h, v in groups.items() if len(v) >= 2}
singletons = {h: v for h, v in groups.items() if len(v) == 1}

lines = []

if matches:
    lines.append("============================================================")
    lines.append("  MATCH GROUPS")
    lines.append("============================================================")
    lines.append("")
    for i, (h, members) in enumerate(sorted(matches.items(), key=lambda x: -len(x[1])), 1):
        lines.append(f"  GROUP {i}  —  {len(members)} files  (content hash: {h[:20]}…)")
        for fname, ftype, _ in sorted(members):
            lines.append(f"    [{ftype}]  {fname}")
        lines.append("")

if singletons:
    lines.append("============================================================")
    lines.append("  UNIQUE FILES  (no match found)")
    lines.append("============================================================")
    lines.append("")
    for h, members in sorted(singletons.items()):
        fname, ftype, _ = members[0]
        lines.append(f"    [{ftype}]  {fname}  (hash: {h[:20]}…)")
    lines.append("")

if error_files:
    lines.append("============================================================")
    lines.append("  ERRORS  (could not fingerprint — left in input/)")
    lines.append("============================================================")
    lines.append("")
    for fname, ftype, e in error_files:
        lines.append(f"    [{ftype}]  {fname}  —  {e}")
    lines.append("")

# Write counts as first line for bash to read back
n_groups    = len(matches)
n_singletons = len(singletons)
n_errors    = len(error_files)

with open(out_file, 'w') as f:
    f.write(f"COUNTS {n_groups} {n_singletons} {n_errors}\n")
    f.write('\n'.join(lines) + '\n')
PYEOF

  # Read counts back from first line
  local count_line
  count_line=$(head -1 "$group_data_file")
  local n_groups n_singletons n_errors
  read -r _ n_groups n_singletons n_errors <<< "$count_line"
  # Strip the counts line from the data file
  local clean_group_file="$TEMP_DIR/group_data_clean.txt"
  tail -n +2 "$group_data_file" > "$clean_group_file"

  # Print groups to terminal
  cat "$clean_group_file"

  # ── Move reviewed files to output/ ─────────────────────────────────────────
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

  # ── Write report ────────────────────────────────────────────────────────────
  echo
  header "Writing compare report…"
  local n_processed=$(( ${#all_files[@]} - n_errors ))
  local rpt
  rpt=$(write_report "$n_groups" "$n_singletons" "$n_errors" "$n_processed" "$clean_group_file")
  ok "Compare report: ${CYAN}$(basename "$rpt")${NC}"

  # ── Summary ─────────────────────────────────────────────────────────────────
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
