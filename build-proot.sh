#!/usr/bin/env bash
# Build Termux PRoot and its unbundled loaders from pinned source.
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
STRIP="$TOOLCHAIN/bin/llvm-strip"
OBJCOPY="$TOOLCHAIN/bin/llvm-objcopy"
OBJDUMP="$TOOLCHAIN/bin/llvm-objdump"
SRC_ROOT="$ROOT_DIR/.cache/sources/proot"
WORK_DIR="$OUT_DIR/work/proot-$ABI"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR/jniLibs/$ABI"
cp -R "$SRC_ROOT/." "$WORK_DIR/"

# Keep the loaders paired with this PRoot build and make their ELF load
# segments 16 KB aligned as well. The upstream makefile only adds the
# max-page-size flag to the main executable's linker flags.
python3 - "$WORK_DIR/src/GNUmakefile" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
needle = 'LOADER_LDFLAGS$1 += -static -nostdlib '
replacement = needle + '-Wl,-z,max-page-size=16384,-z,common-page-size=16384 '
if needle not in text:
    raise SystemExit("cannot find PRoot loader linker flags")
path.write_text(text.replace(needle, replacement, 1))
PY

# NDK r28c does not expose this include transitively on all API levels.
if ! grep -q '#include <string.h>' "$WORK_DIR/src/extension/ashmem_memfd/ashmem_memfd.c"; then
    perl -0pi -e 's/#include <stdlib.h>\n/#include <stdlib.h>\n#include <string.h>\n/' \
        "$WORK_DIR/src/extension/ashmem_memfd/ashmem_memfd.c"
fi

bash "$ROOT_DIR/build-talloc.sh" "$ABI" "$OUT_DIR"
bash "$ROOT_DIR/build-libandroid-shmem.sh" "$ABI" "$OUT_DIR"

TALLOC_PREFIX="$OUT_DIR/prefix/$ABI"
mkdir -p "$TALLOC_PREFIX/lib" "$TALLOC_PREFIX/include"
cp "$OUT_DIR/libtalloc-$ABI.a" "$TALLOC_PREFIX/lib/libtalloc.a"
cp "$OUT_DIR/talloc-$ABI.h" "$TALLOC_PREFIX/include/talloc.h"

# Build the proot binary and both loaders together. The two loader files are
# matched to this proot build and must never be mixed across revisions.
LOADER_DIR="$OUT_DIR/loader/$ABI"
# Runtime always supplies PROOT_LOADER/PROOT_LOADER_32. Keep the compiled
# fallback path stable so the build directory never leaks into the ELF.
PROOT_LOADER_DEFINE='-DPROOT_UNBUNDLE_LOADER=\\"/system/lib64\\"'
(
    cd "$WORK_DIR/src"
    make clean >/dev/null 2>&1 || true
    make -j"${JOBS:-$(nproc)}" \
        V=1 \
        CC="$CC" \
        AR="$AR" \
        STRIP="$STRIP" \
        OBJCOPY="$OBJCOPY" \
        OBJDUMP="$OBJDUMP" \
        CPPFLAGS="-D_FILE_OFFSET_BITS=64 -D_GNU_SOURCE -DARG_MAX=131072 -I. -I$WORK_DIR/src -I$TALLOC_PREFIX/include" \
        CFLAGS="-Wall -Wextra -O2 -fPIC -ffunction-sections -fdata-sections $PROOT_LOADER_DEFINE" \
        LDFLAGS="$TALLOC_PREFIX/lib/libtalloc.a $OUT_DIR/libandroid-shmem-$ABI.a -landroid -llog -Wl,--gc-sections -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 -Wl,-z,noexecstack" \
        PROOT_UNBUNDLE_LOADER="$LOADER_DIR"
)

cp "$WORK_DIR/src/proot" "$OUT_DIR/jniLibs/$ABI/libproot.so"
cp "$WORK_DIR/src/loader/loader" "$OUT_DIR/jniLibs/$ABI/libproot-loader.so"
if [ -f "$WORK_DIR/src/loader/loader-m32" ]; then
    cp "$WORK_DIR/src/loader/loader-m32" "$OUT_DIR/jniLibs/$ABI/libproot-loader32.so"
else
    echo "missing 32-bit PRoot loader for $ABI" >&2
    exit 1
fi

ALLOW_INTERP=1 LLVM_READELF="$TOOLCHAIN/bin/llvm-readelf" bash "$ROOT_DIR/verify-elf.sh" \
    "$OUT_DIR/jniLibs/$ABI/libproot.so"
LLVM_READELF="$TOOLCHAIN/bin/llvm-readelf" bash "$ROOT_DIR/verify-elf.sh" \
    "$OUT_DIR/jniLibs/$ABI/libproot-loader.so" \
    "$OUT_DIR/jniLibs/$ABI/libproot-loader32.so"
