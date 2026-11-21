#!/usr/bin/env bash
# Build the pinned Termux libandroid-shmem source as a static archive.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/PINS"
ABI="${1:?usage: $0 <arm64-v8a|x86_64>}"
OUT_DIR="${2:?usage: $0 <abi> <out-dir>}"
NDK_ROOT="${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME}"
API="${MIN_SDK}"

case "$ABI" in
    arm64-v8a) TARGET=aarch64-linux-android ;;
    x86_64) TARGET=x86_64-linux-android ;;
    *) echo "unsupported ABI: $ABI" >&2; exit 2 ;;
esac

TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64"
CC="$TOOLCHAIN/bin/${TARGET}${API}-clang"
AR="$TOOLCHAIN/bin/llvm-ar"
RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
SRC_DIR="$ROOT_DIR/.cache/sources/libandroid-shmem"
BUILD_DIR="$OUT_DIR/work/libandroid-shmem-$ABI"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Termux's package build exports _PATH_TMP through its patched sysroot. The
# stock NDK does not. The runtime path comes from PROOT_TMP_DIR, which the app
# sets below its own filesDir, so this build contains no package-name path.
cp "$SRC_DIR/shmem.c" "$BUILD_DIR/shmem.c"
python3 - "$BUILD_DIR/shmem.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old_define = '#define ASHV_KEY_SYMLINK_PATH _PATH_TMP "ashv_key_%d"\n'
if old_define not in text:
    raise SystemExit("libandroid-shmem key path definition not found")
text = text.replace(old_define, '', 1)
old_call = '\t\tsprintf(symlink_path, ASHV_KEY_SYMLINK_PATH, key);'
new_call = '''\t\tconst char *tmp_path = getenv("PROOT_TMP_DIR");
\t\tif (tmp_path == NULL || tmp_path[0] == '\\0') tmp_path = "/tmp/";
\t\tsize_t tmp_path_length = strlen(tmp_path);
\t\tif (tmp_path[tmp_path_length - 1] == '/') {
\t\t\tsnprintf(symlink_path, sizeof(symlink_path), "%sashv_key_%d", tmp_path, key);
\t\t} else {
\t\t\tsnprintf(symlink_path, sizeof(symlink_path), "%s/ashv_key_%d", tmp_path, key);
\t\t}'''
if old_call not in text:
    raise SystemExit("libandroid-shmem key path call not found")
path.write_text(text.replace(old_call, new_call, 1))
PY
$CC -fPIC -std=c11 -Wall -Wextra -ffunction-sections -fdata-sections \
    -I"$SRC_DIR" -I"$BUILD_DIR" -c "$BUILD_DIR/shmem.c" -o "$BUILD_DIR/shmem.o"
"$AR" rcsD "$OUT_DIR/libandroid-shmem-$ABI.a" "$BUILD_DIR/shmem.o"
"$RANLIB" "$OUT_DIR/libandroid-shmem-$ABI.a"
cp "$SRC_DIR/shm.h" "$OUT_DIR/shm-$ABI.h"
cp "$SRC_DIR/LICENSE" "$OUT_DIR/LICENSE.libandroid-shmem"
