"""
core/convert.py — Binary ↔ text conversion logic for bintxt_tool

All functions are importable (used by the UI).
CLI dispatch at the bottom lets bash scripts call each function directly:

    python3 core/convert.py bin_to_txt   <src> <dst> <endian> <ws...>
    python3 core/convert.py txt_to_bin   <src> <dst> <endian> <ws...>
    python3 core/convert.py validate     <src> <endian> <ws...>
    python3 core/convert.py normalize    <src> <dst> <endian> <ws...>
    python3 core/convert.py sha256       <path>
    python3 core/convert.py norm_compare <path>
    python3 core/convert.py verify_b2t   <orig_bin> <gen_txt> <tmp_dir> <endian> <ws...>
    python3 core/convert.py verify_t2b   <orig_txt> <gen_bin> <tmp_dir> <endian> <ws...>

Exit codes: 0 = success, 1 = error.
"""

import hashlib
import os
import sys
import tempfile


# ─── Low-level conversion ─────────────────────────────────────────────────────

def bin_to_txt(src: str, dst: str, endian: str, word_sizes: list[int]) -> None:
    """Extract a binary file to hex text format."""
    stride = sum(word_sizes)
    with open(src, "rb") as f:
        data = f.read()

    lines = []
    offset = 0
    while offset < len(data):
        parts = [f"{offset:08x}"]
        cur = offset
        for ws in word_sizes:
            end = cur + ws
            chunk = data[cur:end] if end <= len(data) else data[cur:] + b"\x00" * (ws - max(0, len(data) - cur))
            val = int.from_bytes(chunk[:ws], byteorder=endian)
            parts.append(f"{val:0{ws * 2}x}")
            cur += ws
        lines.append(" ".join(parts))
        offset += stride
    lines.append(f"{offset:08x}")

    with open(dst, "w") as f:
        f.write("\n".join(lines) + "\n")


def txt_to_bin(src: str, dst: str, endian: str, word_sizes: list[int]) -> None:
    """Convert a hex text file back to binary."""
    n_words = len(word_sizes)
    stride = sum(word_sizes)

    valid = {1, 2, 4, 8}
    for ws in word_sizes:
        if ws not in valid:
            raise ValueError(f"Invalid word size {ws} (must be 1, 2, 4, or 8)")

    entries = []
    with open(src) as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            try:
                addr = int(parts[0], 16)
                vals = [int(v, 16) for v in parts[1: n_words + 1]]
            except ValueError:
                continue
            if len(vals) < n_words:
                continue
            entries.append((addr, vals))

    if not entries:
        raise ValueError("No valid rows found in input file")

    last_addr = entries[-1][0]
    file_size = last_addr + stride
    buf = bytearray(file_size)

    for addr, vals in entries:
        cur = addr
        for val, ws in zip(vals, word_sizes):
            buf[cur: cur + ws] = val.to_bytes(ws, byteorder=endian)
            cur += ws

    with open(dst, "wb") as f:
        f.write(buf)


# ─── Validation & normalization ───────────────────────────────────────────────

def validate_txt_format(src: str, endian: str, word_sizes: list[int]) -> tuple[bool, list[str]]:
    """Validate a .txt file against the current config.

    Returns (ok, issues) where issues is an empty list when ok=True.
    """
    n_words = len(word_sizes)
    stride = sum(word_sizes)
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
                continue  # address-only terminator line — ok
            if len(parts) < 2:
                issues.append(f"line {line_num}: unparseable — '{line[:60]}'")
                continue

            try:
                addr = int(parts[0], 16)
            except ValueError:
                issues.append(f"line {line_num}: bad address '{parts[0]}'")
                continue

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
                    issues.append(f"line {line_num}: word {i + 1}: bad hex '{vp}'")
                    continue
                if val > (1 << (ws * 8)) - 1:
                    issues.append(f"line {line_num}: word {i + 1}: value 0x{val:x} overflows {ws}-byte field")
                if len(vp) != expected_len:
                    issues.append(f"line {line_num}: word {i + 1}: width {len(vp)} chars (expected {expected_len} for {ws}B)")

    return (len(issues) == 0, issues)


def normalize_txt(src: str, dst: str, endian: str, word_sizes: list[int]) -> None:
    """Normalize a .txt file to canonical address-padded format."""
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
                        val = int(parts[i + 1], 16) if i + 1 < len(parts) else 0
                        row.append(f"{val:0{ws * 2}x}")
                    lines_out.append(" ".join(row))
                    continue
                except ValueError:
                    pass
            lines_out.append(line)

    with open(dst, "w") as f:
        f.write("\n".join(lines_out) + "\n")


def normalize_for_compare(path: str) -> str:
    """Return normalized string representation of a .txt file for diffing."""
    lines = []
    for raw in open(path):
        line = raw.strip().lower()
        if not line:
            continue
        parts = line.split()
        try:
            parts[0] = f"{int(parts[0], 16):08x}"
        except (ValueError, IndexError):
            pass
        lines.append(" ".join(parts))
    return "\n".join(lines)


# ─── Hashing ──────────────────────────────────────────────────────────────────

def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


# ─── Roundtrip verification ───────────────────────────────────────────────────

def verify_bin_to_txt(
    orig_bin: str, gen_txt: str, endian: str, word_sizes: list[int], tmp_dir: str = None
) -> tuple[bool, str, str]:
    """Verify BIN→TXT by reconstructing binary and comparing hashes.

    Returns (ok, hash_orig_bin, hash_roundtrip_bin).
    """
    td = tmp_dir or tempfile.mkdtemp()
    rt_bin = os.path.join(td, "rt_" + os.path.basename(orig_bin))
    try:
        txt_to_bin(gen_txt, rt_bin, endian, word_sizes)
    except Exception as e:
        return (False, sha256_file(orig_bin), "ROUNDTRIP_FAILED")

    h_orig = sha256_file(orig_bin)
    h_rt = sha256_file(rt_bin)
    return (h_orig == h_rt, h_orig, h_rt)


def verify_txt_to_bin(
    orig_txt: str, gen_bin: str, endian: str, word_sizes: list[int], tmp_dir: str = None
) -> tuple[bool, str, str]:
    """Verify TXT→BIN by re-extracting and comparing normalized text.

    Returns (ok, hash_gen_bin, diff_or_empty).
    """
    td = tmp_dir or tempfile.mkdtemp()
    rt_txt = os.path.join(td, "rt_" + os.path.basename(orig_txt))
    bin_to_txt(gen_bin, rt_txt, endian, word_sizes)

    h_bin = sha256_file(gen_bin)
    norm_orig = normalize_for_compare(orig_txt)
    norm_rt = normalize_for_compare(rt_txt)

    if norm_orig == norm_rt:
        return (True, h_bin, "")

    # Build a simple diff summary
    orig_lines = norm_orig.splitlines()
    rt_lines = norm_rt.splitlines()
    diff_lines = []
    for i, (a, b) in enumerate(zip(orig_lines, rt_lines)):
        if a != b:
            diff_lines.append(f"  line {i + 1}: orig={a}  rt={b}")
    if len(orig_lines) != len(rt_lines):
        diff_lines.append(f"  line count: orig={len(orig_lines)}  rt={len(rt_lines)}")
    return (False, h_bin, "\n".join(diff_lines[:10]))


# ─── CLI dispatch ─────────────────────────────────────────────────────────────

def _cli():
    if len(sys.argv) < 2:
        print("Usage: python3 core/convert.py <command> [args...]", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "bin_to_txt":
        # bin_to_txt <src> <dst> <endian> <ws...>
        src, dst, endian = sys.argv[2], sys.argv[3], sys.argv[4]
        ws = [int(x) for x in sys.argv[5:]]
        bin_to_txt(src, dst, endian, ws)

    elif cmd == "txt_to_bin":
        # txt_to_bin <src> <dst> <endian> <ws...>
        src, dst, endian = sys.argv[2], sys.argv[3], sys.argv[4]
        ws = [int(x) for x in sys.argv[5:]]
        try:
            txt_to_bin(src, dst, endian, ws)
        except ValueError as e:
            print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)

    elif cmd == "validate":
        # validate <src> <endian> <ws...>
        src, endian = sys.argv[2], sys.argv[3]
        ws = [int(x) for x in sys.argv[4:]]
        ok, issues = validate_txt_format(src, endian, ws)
        if ok:
            print("OK")
        else:
            print("ISSUES")
            for i in issues:
                print(i)

    elif cmd == "normalize":
        # normalize <src> <dst> <endian> <ws...>
        src, dst, endian = sys.argv[2], sys.argv[3], sys.argv[4]
        ws = [int(x) for x in sys.argv[5:]]
        normalize_txt(src, dst, endian, ws)

    elif cmd == "sha256":
        # sha256 <path>
        print(sha256_file(sys.argv[2]))

    elif cmd == "norm_compare":
        # norm_compare <path>  → prints normalized content to stdout
        print(normalize_for_compare(sys.argv[2]))

    elif cmd == "verify_b2t":
        # verify_b2t <orig_bin> <gen_txt> <tmp_dir> <endian> <ws...>
        orig_bin, gen_txt, tmp_dir, endian = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
        ws = [int(x) for x in sys.argv[6:]]
        ok, h_orig, h_rt = verify_bin_to_txt(orig_bin, gen_txt, endian, ws, tmp_dir)
        print(f"{h_orig} {h_rt}")
        sys.exit(0 if ok else 1)

    elif cmd == "verify_t2b":
        # verify_t2b <orig_txt> <gen_bin> <tmp_dir> <endian> <ws...>
        orig_txt, gen_bin, tmp_dir, endian = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
        ws = [int(x) for x in sys.argv[6:]]
        ok, h_bin, diff = verify_txt_to_bin(orig_txt, gen_bin, endian, ws, tmp_dir)
        if ok:
            print(h_bin)
            sys.exit(0)
        else:
            print("MISMATCH")
            if diff:
                print(diff)
            sys.exit(1)

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    _cli()
