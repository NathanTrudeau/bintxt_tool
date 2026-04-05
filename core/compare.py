"""
core/compare.py — Content fingerprinting and grouping logic for compare_inputs

Importable by the UI; also callable as:
    python3 core/compare.py fingerprint <path> <tmp_dir> <endian> <ws...>
    python3 core/compare.py group       <group_data_file> <hash1> ... ---PATHS--- <p1> ... ---TYPES--- <t1> ... ---ERRORS--- <e1> ...

Exit codes: 0 = success/ok, 1 = error/unparseable.
"""

import collections
import hashlib
import os
import sys
import tempfile

# Allow running as a script from the repo root or any working directory
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from core.convert import bin_to_txt, normalize_for_compare, sha256_file


# ─── Fingerprinting ───────────────────────────────────────────────────────────

def fingerprint_file(
    src: str, endian: str, word_sizes: list[int], tmp_dir: str = None
) -> tuple[str | None, str | None, str | None]:
    """Compute a content fingerprint (SHA-256 of normalized form) for src.

    Returns (hash, norm_path, error).
      - On success: (hex_hash, norm_path, None)
      - On failure: (None, None, error_message)
    """
    td = tmp_dir or tempfile.mkdtemp()
    fname = os.path.basename(src)
    ext = fname.rsplit(".", 1)[-1].lower() if "." in fname else ""

    norm_path = os.path.join(td, f"norm_{fname}.txt")

    try:
        if ext == "bin":
            extracted = os.path.join(td, f"extracted_{fname}.txt")
            bin_to_txt(src, extracted, endian, word_sizes)
            # Write normalized form
            content = normalize_for_compare(extracted)
        elif ext == "txt":
            content = normalize_for_compare(src)
        else:
            return (None, None, "Unsupported file type")

        with open(norm_path, "w") as f:
            f.write(content)

        h = hashlib.sha256(content.encode()).hexdigest()
        return (h, norm_path, None)

    except Exception as e:
        return (None, None, str(e))


# ─── Grouping ─────────────────────────────────────────────────────────────────

def group_by_hash(
    files: list[tuple[str, str, str, str]]
) -> tuple[dict, dict, list]:
    """Group files by content hash.

    Input: list of (path, hash_or_ERROR, type_label, error_msg)
    Returns:
        matches    — dict {hash: [(fname, type)]} for groups with 2+ members
        singletons — dict {hash: [(fname, type)]} for groups with 1 member
        errors     — list of (fname, type, error_msg)
    """
    groups = collections.defaultdict(list)
    errors = []

    for path, h, type_label, error in files:
        fname = os.path.basename(path)
        if h == "ERROR" or h is None:
            errors.append((fname, type_label.strip(), error or "Unknown error"))
        else:
            groups[h].append((fname, type_label.strip(), h))

    matches = {h: v for h, v in groups.items() if len(v) >= 2}
    singletons = {h: v for h, v in groups.items() if len(v) == 1}
    return matches, singletons, errors


def format_group_report(matches: dict, singletons: dict, errors: list) -> str:
    """Render match groups, singletons, and errors as a report string."""
    lines = []

    if matches:
        lines += [
            "============================================================",
            "  MATCH GROUPS",
            "============================================================",
            "",
        ]
        for i, (h, members) in enumerate(sorted(matches.items(), key=lambda x: -len(x[1])), 1):
            lines.append(f"  GROUP {i}  —  {len(members)} files  (content hash: {h[:20]}…)")
            for fname, ftype, _ in sorted(members):
                lines.append(f"    [{ftype}]  {fname}")
            lines.append("")

    if singletons:
        lines += [
            "============================================================",
            "  UNIQUE FILES  (no match found)",
            "============================================================",
            "",
        ]
        for h, members in sorted(singletons.items()):
            fname, ftype, _ = members[0]
            lines.append(f"    [{ftype}]  {fname}  (hash: {h[:20]}…)")
        lines.append("")

    if errors:
        lines += [
            "============================================================",
            "  ERRORS  (could not fingerprint — left in input/)",
            "============================================================",
            "",
        ]
        for fname, ftype, e in errors:
            lines.append(f"    [{ftype}]  {fname}  —  {e}")
        lines.append("")

    return "\n".join(lines)


# ─── CLI dispatch ─────────────────────────────────────────────────────────────

def _cli():
    if len(sys.argv) < 2:
        print("Usage: python3 core/compare.py <command> [args...]", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "fingerprint":
        # fingerprint <path> <tmp_dir> <endian> <ws...>
        path, tmp_dir, endian = sys.argv[2], sys.argv[3], sys.argv[4]
        ws = [int(x) for x in sys.argv[5:]]
        h, norm_path, error = fingerprint_file(path, endian, ws, tmp_dir)
        if error:
            print(f"ERROR {error}")
            sys.exit(1)
        else:
            print(f"OK {h} {norm_path}")

    elif cmd == "group":
        # group <out_file> <hash1>... ---PATHS--- <p1>... ---TYPES--- <t1>... ---ERRORS--- <e1>...
        out_file = sys.argv[2]
        args = sys.argv[3:]
        sep_p = args.index("---PATHS---")
        sep_t = args.index("---TYPES---")
        sep_e = args.index("---ERRORS---")

        hashes = args[:sep_p]
        paths  = args[sep_p + 1:sep_t]
        types  = args[sep_t + 1:sep_e]
        errors = args[sep_e + 1:]

        files = list(zip(paths, hashes, types, errors))
        matches, singletons, err_list = group_by_hash(files)
        report = format_group_report(matches, singletons, err_list)

        n_groups = len(matches)
        n_singletons = len(singletons)
        n_errors = len(err_list)

        with open(out_file, "w") as f:
            f.write(f"COUNTS {n_groups} {n_singletons} {n_errors}\n")
            f.write(report)

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    _cli()
