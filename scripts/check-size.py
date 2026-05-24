#!/usr/bin/env python3
"""Verify boot.bin size and report code+data footprint.

Exit codes:
  0 — boot.bin is exactly 256 bytes and the code+data fits the limit
  1 — file is wrong size or code+data exceeds the limit
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


SIZE_LIMIT = 256


def measure(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if len(data) != SIZE_LIMIT:
        raise SystemExit(f"FAIL: {path} is {len(data)} bytes, expected {SIZE_LIMIT}")

    last = len(data)
    while last > 0 and data[last - 1] == 0:
        last -= 1
    return last, SIZE_LIMIT - last


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("path", type=Path)
    p.add_argument("--short", action="store_true", help="One-line output")
    args = p.parse_args()

    used, free = measure(args.path)

    if args.short:
        print(f"{used} / {SIZE_LIMIT} bytes ({free} free)")
        return 0 if used <= SIZE_LIMIT else 1

    print(f"File:           {args.path}")
    print(f"Size:           {SIZE_LIMIT} bytes")
    print(f"Code + data:    {used} bytes")
    print(f"Padding:        {free} bytes")
    if used > SIZE_LIMIT:
        print(f"FAIL: exceeds {SIZE_LIMIT}-byte limit by {used - SIZE_LIMIT} bytes")
        return 1
    print(f"OK: {free} bytes free")
    return 0


if __name__ == "__main__":
    sys.exit(main())
