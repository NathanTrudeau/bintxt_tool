"""
core/config.py — Load bintxt_tool configuration from cfg/config.sh

Importable by the UI; also callable as:
    python3 core/config.py <repo_root>   → prints JSON config
"""

import json
import os
import re
import sys


DEFAULT_CONFIG = {
    "endian": "little",
    "word_sizes": [4],
    "input_dir": "input",
    "output_dir": "output",
    "report_dir": "output/reports",
}


def load(repo_root: str) -> dict:
    """Parse cfg/config.sh and return a config dict.

    Falls back to DEFAULT_CONFIG for any missing key.
    Supports WORD_SIZES=(4) array and scalar WORD_SIZE=4 shim.
    """
    cfg = dict(DEFAULT_CONFIG)
    path = os.path.join(repo_root, "cfg", "config.sh")
    if not os.path.isfile(path):
        return cfg

    text = open(path).read()

    # ENDIAN
    m = re.search(r'^\s*ENDIAN\s*=\s*["\']?(\w+)["\']?', text, re.MULTILINE)
    if m:
        cfg["endian"] = m.group(1).lower()

    # WORD_SIZES array: WORD_SIZES=(4 2 1)
    m = re.search(r'^\s*WORD_SIZES\s*=\s*\(([^)]*)\)', text, re.MULTILINE)
    if m:
        parts = m.group(1).split()
        cfg["word_sizes"] = [int(x) for x in parts if x.isdigit()]
    else:
        # Scalar shim: WORD_SIZE=4
        m = re.search(r'^\s*WORD_SIZE\s*=\s*["\']?(\d+)["\']?', text, re.MULTILINE)
        if m:
            cfg["word_sizes"] = [int(m.group(1))]

    # Dirs
    for key, var in [("input_dir", "INPUT_DIR"), ("output_dir", "OUTPUT_DIR"), ("report_dir", "REPORT_DIR")]:
        m = re.search(rf'^\s*{var}\s*=\s*["\']?([^"\'\s#]+)["\']?', text, re.MULTILINE)
        if m:
            cfg[key] = m.group(1)

    return cfg


def absdirs(cfg: dict, repo_root: str) -> dict:
    """Return a copy of cfg with all dir keys resolved to absolute paths."""
    out = dict(cfg)
    for key in ("input_dir", "output_dir", "report_dir"):
        out[key] = os.path.join(repo_root, cfg[key])
    return out


if __name__ == "__main__":
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    print(json.dumps(load(root), indent=2))
