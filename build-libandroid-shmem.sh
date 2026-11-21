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

$CC -fPIC -std=c11 -Wall -Wextra -ffunction-sections -fdata-sections \
    -I"$SRC_DIR" -c "$SRC_DIR/shmem.c" -o "$BUILD_DIR/shmem.o"
"$AR" rcsD "$OUT_DIR/libandroid-shmem-$ABI.a" "$BUILD_DIR/shmem.o"
"$RANLIB" "$OUT_DIR/libandroid-shmem-$ABI.a"
cp "$SRC_DIR/shm.h" "$OUT_DIR/shm-$ABI.h"
cp "$SRC_DIR/LICENSE" "$OUT_DIR/LICENSE.libandroid-shmem"
