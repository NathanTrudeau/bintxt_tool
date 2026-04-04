#!/usr/bin/env bash
# =============================================================================
# edit_inputs.sh — Edit binary files workflow
#
# Usage:
#   ./edit_inputs.sh extract   — convert all input/*.bin → output/*__DRAFT.txt
#   ./edit_inputs.sh apply     — convert all output/*__DRAFT.txt → .bin, verify, prompt
#
# Edit config.sh to change word size, byte order, or folder paths.
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

DRAFT_SUFFIX="__DRAFT"

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

fmt_map = { 1: ('B','B'), 2: ('<H','>H'), 4: ('<I','>I'), 8: ('<Q','>Q') }
if word_size not in fmt_map:
    print(f"ERROR: unsupported WORD_SIZE {word_size}", file=sys.stderr)
    sys.exit(1)

fmt = fmt_map[word_size][0] if endian == 'little' else fmt_map[word_size][1]
if word_size == 1:
    fmt = 'B'

entries = []
with open(src) as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        try:
            entries.append((int(parts[0], 16), int(parts[1], 16)))
        except ValueError:
            continue

if not entries:
    print("ERROR: no valid address/value pairs found", file=sys.stderr)
    sys.exit(1)

max_addr  = max(a for a, _ in entries)
buf       = bytearray(max_addr + word_size)
for addr, val in entries:
    buf[addr:addr+word_size] = struct.pack(fmt, val)

with open(dst, 'wb') as f:
    f.write(buf)
PYEOF
}

# ─── Normalize for comparison ─────────────────────────────────────────────────

normalize_txt() {
  sed 's/[[:space:]]*$//' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | grep -v '^[[:space:]]*$'
}

# ─── Report helpers ───────────────────────────────────────────────────────────

REPORT_ENTRIES=()
REPORT_ERRORS=()

report_entry() {
  local label="$1" src="$2" dst="$3" hash_a="$4" hash_b="$5" status="$6" detail="${7:-}"
  local icon="✓  PASS"; [[ "$status" == "FAIL" ]] && icon="✗  FAIL"
  REPORT_ENTRIES+=("$(cat <<EOF
  File        : $(basename "$src")
  Output      : $(basename "$dst")
  SHA-256 (A) : $hash_a
  SHA-256 (B) : $hash_b
  Verified    : $icon
$([ -n "$detail" ] && echo "  Error       : $detail" || true)
EOF
)")
}

write_report() {
  local mode="$1" passed="$2" failed="$3"
  local dt_file dt_display overall
  dt_file=$(date '+%Y-%m-%d_%I%M%p')
  dt_display=$(date '+%Y-%m-%d  %I:%M %p')
  overall="ALL PASSED"; [[ $failed -gt 0 ]] && overall="COMPLETED WITH ERRORS"

  local report_file="$REPORT_DIR/${dt_file}_edit_report.txt"

  {
    echo "============================================================"
    echo "  BINTXT_TOOL — EDIT REPORT  ($mode)"
    echo "  $dt_display"
    echo "============================================================"
    echo
    echo "  Config"
    echo "  ------"
    echo "  Word size : ${WORD_SIZE} byte(s)"
    echo "  Endian    : $ENDIAN"
    echo
    echo "  Summary"
    echo "  -------"
    echo "  Total     : $(( passed + failed ))"
    echo "  Passed    : $passed"
    echo "  Failed    : $failed"
    echo "  Status    : $overall"
    echo
    echo "============================================================"
    echo "  FILES"
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

# ─── EXTRACT ─────────────────────────────────────────────────────────────────

cmd_extract() {
  header "edit_inputs — EXTRACT"
  echo -e "  Scanning ${CYAN}input/${NC} for .bin files…"

  local files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$INPUT_DIR" -maxdepth 1 -type f -iname "*.bin" -print0 | sort -z)

  if [[ ${#files[@]} -eq 0 ]]; then
    warn "No .bin files found in input/"
    exit 0
  fi

  local passed=0 failed=0

  for src in "${files[@]}"; do
    local base filename draft_txt
    filename="$(basename "$src")"
    base="${filename%.*}"
    draft_txt="$OUTPUT_DIR/${base}${DRAFT_SUFFIX}.txt"

    echo
    log "${CYAN}EXTRACT${NC}  $filename  →  ${base}${DRAFT_SUFFIX}.txt"

    if bin_to_txt "$src" "$draft_txt"; then
      local entries hash_orig
      entries=$(grep -c ' ' "$draft_txt" 2>/dev/null || echo 0)
      hash_orig=$(sha256 "$src")
      ok "Done  (${entries} entries)  SHA-256: ${hash_orig:0:20}…"

      report_entry "EXTRACT" "$src" "$draft_txt" "$hash_orig" "n/a (text file)" "PASS"
      (( passed++ )) || true
    else
      err "Failed to extract $filename"
      REPORT_ERRORS+=("[$filename] Extraction failed")
      report_entry "EXTRACT" "$src" "$draft_txt" "n/a" "n/a" "FAIL" "bin_to_txt failed"
      (( failed++ )) || true
    fi
  done

  echo
  local report_path
  report_path=$(write_report "EXTRACT" "$passed" "$failed")
  log "Report: ${CYAN}output/reports/$(basename "$report_path")${NC}"

  echo
  echo -e "${BOLD}─────────────────────────────────────${NC}"
  echo -e "  ${GREEN}Extracted: $passed${NC}  |  ${RED}Failed: $failed${NC}"
  echo -e "${BOLD}─────────────────────────────────────${NC}"
  echo
  if [[ $passed -gt 0 ]]; then
    echo -e "  ${BOLD}Next step:${NC}"
    echo -e "  Edit the ${CYAN}*${DRAFT_SUFFIX}.txt${NC} files in ${CYAN}output/${NC}"
    echo -e "  Then run:  ${BOLD}./edit_inputs.sh apply${NC}"
  fi
  echo
}

# ─── APPLY ───────────────────────────────────────────────────────────────────

cmd_apply() {
  header "edit_inputs — APPLY"
  echo -e "  Scanning ${CYAN}output/${NC} for *${DRAFT_SUFFIX}.txt files…"

  local files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$OUTPUT_DIR" -maxdepth 1 -type f -name "*${DRAFT_SUFFIX}.txt" -print0 | sort -z)

  if [[ ${#files[@]} -eq 0 ]]; then
    warn "No *${DRAFT_SUFFIX}.txt files found in output/"
    echo -e "  Run ${BOLD}./edit_inputs.sh extract${NC} first."
    echo
    exit 0
  fi

  local passed=0 failed=0

  for draft in "${files[@]}"; do
    local draft_name base_name orig_bin temp_bin hash_a hash_b
    draft_name="$(basename "$draft")"
    base_name="${draft_name%${DRAFT_SUFFIX}.txt}"
    orig_bin="$INPUT_DIR/${base_name}.bin"
    temp_bin="$TEMP_DIR/${base_name}.bin"

    echo
    log "${CYAN}APPLY${NC}  $draft_name  →  ${base_name}.bin"

    # Convert edited draft → temp bin
    local py_err
    if ! py_err=$(txt_to_bin "$draft" "$temp_bin" 2>&1); then
      err "Conversion failed: $py_err"
      REPORT_ERRORS+=("[$draft_name] $py_err")
      report_entry "APPLY" "$draft" "${base_name}.bin" "n/a" "n/a" "FAIL" "$py_err"
      (( failed++ )) || true
      continue
    fi

    local bytes
    bytes=$(wc -c < "$temp_bin")
    log "          Generated ${base_name}.bin  (${bytes} bytes)"

    # Roundtrip verify: od the new bin → normalize → compare with edited draft
    local temp_txt="$TEMP_DIR/${base_name}_rt.txt"
    bin_to_txt "$temp_bin" "$temp_txt"

    local norm_draft norm_rt
    norm_draft=$(normalize_txt "$draft")
    norm_rt=$(normalize_txt "$temp_txt")

    hash_a=$(sha256 "$temp_bin")

    if [[ "$norm_draft" != "$norm_rt" ]]; then
      err "Roundtrip verification failed"
      local diff_out
      diff_out=$(diff <(echo "$norm_draft") <(echo "$norm_rt") 2>&1 || true)
      REPORT_ERRORS+=("[$draft_name] Roundtrip diff:"$'\n'"$diff_out")
      report_entry "APPLY" "$draft" "${base_name}.bin" "$hash_a" "MISMATCH" "FAIL" "Roundtrip diff detected — see error details"
      (( failed++ )) || true
      continue
    fi

    hash_b="$hash_a"
    ok "Verified  SHA-256: ${hash_a:0:20}…"

    # ── Overwrite prompt ─────────────────────────────────────────────────────
    local final_bin="$OUTPUT_DIR/${base_name}.bin"

    if [[ -f "$orig_bin" ]]; then
      echo
      echo -ne "  Overwrite original ${CYAN}input/${base_name}.bin${NC}? [y/n] "
      read -r answer
      if [[ "${answer,,}" == "y" ]]; then
        cp "$temp_bin" "$orig_bin"
        final_bin="$orig_bin"
        ok "Overwrote input/${base_name}.bin"
      else
        cp "$temp_bin" "$OUTPUT_DIR/${base_name}.bin"
        log "Saved as output/${base_name}.bin (original unchanged)"
      fi
    else
      # No original found — just save to output
      cp "$temp_bin" "$OUTPUT_DIR/${base_name}.bin"
      log "Saved as output/${base_name}.bin"
    fi

    report_entry "APPLY" "$draft" "$final_bin" "$hash_a" "$hash_b" "PASS"
    (( passed++ )) || true
  done

  echo
  local report_path
  report_path=$(write_report "APPLY" "$passed" "$failed")
  log "Report: ${CYAN}output/reports/$(basename "$report_path")${NC}"

  echo
  echo -e "${BOLD}─────────────────────────────────────${NC}"
  echo -e "  ${GREEN}Applied: $passed${NC}  |  ${RED}Failed: $failed${NC}"
  echo -e "${BOLD}─────────────────────────────────────${NC}"
  echo

  [[ $failed -gt 0 ]] && exit 1 || exit 0
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  check_deps

  local cmd="${1:-}"
  case "$cmd" in
    extract) cmd_extract ;;
    apply)   cmd_apply   ;;
    *)
      echo
      echo -e "${BOLD}edit_inputs.sh${NC} — Binary edit workflow"
      echo
      echo -e "  ${BOLD}./edit_inputs.sh extract${NC}"
      echo -e "    Convert all input/*.bin → output/*${DRAFT_SUFFIX}.txt"
      echo
      echo -e "  ${BOLD}./edit_inputs.sh apply${NC}"
      echo -e "    Convert all output/*${DRAFT_SUFFIX}.txt → .bin, verify, prompt to overwrite"
      echo
      exit 0
      ;;
  esac
}

trap 'rm -rf "$TEMP_DIR"' EXIT
main "$@"
