#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <elf>..." >&2
    exit 2
fi

READ_ELF="${LLVM_READELF:-llvm-readelf}"
ALLOW_INTERP="${ALLOW_INTERP:-0}"
command -v "$READ_ELF" >/dev/null 2>&1 || {
    echo "llvm-readelf not found; set LLVM_READELF" >&2
    exit 1
}

for elf in "$@"; do
    [ -f "$elf" ] || { echo "missing: $elf" >&2; exit 1; }
    echo "=== $elf ==="
    headers="$($READ_ELF -lW "$elf")"
    "$READ_ELF" -h "$elf" | grep -E 'Class:|Type:|Machine:'
    printf '%s\n' "$headers" | grep -E 'LOAD|GNU_RELRO|GNU_STACK|INTERP' || true
    ELF_HEADERS="$headers" python3 - <<'PY'
import os
import sys

headers = os.environ["ELF_HEADERS"].splitlines()
loads = []
for line in headers:
    fields = line.split()
    if fields and fields[0] == "LOAD":
        raw = fields[-1]
        try:
            loads.append(int(raw, 0))
        except ValueError:
            loads.append(int(raw, 16) if raw.startswith("0x") else -1)
if not loads or any(value < 0x4000 for value in loads):
    print("ERROR: LOAD segment is not 16 KB aligned", file=sys.stderr)
    sys.exit(1)
for line in headers:
    fields = line.split()
    if fields and fields[0] == "GNU_STACK" and len(fields) > 6:
        flags = fields[6]
        if "E" in flags:
            print("ERROR: executable stack", file=sys.stderr)
            sys.exit(1)
for line in headers:
    if line.split() and line.split()[0] == "INTERP" and os.environ.get("ALLOW_INTERP") != "1":
        print("ERROR: PT_INTERP is not allowed for an exec-only runtime", file=sys.stderr)
        sys.exit(1)
PY
done
