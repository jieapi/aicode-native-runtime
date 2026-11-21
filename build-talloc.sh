#!/usr/bin/env bash
# Build the pinned talloc source into a static archive for one Android ABI.
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

[ -x "$CC" ] || { echo "missing compiler: $CC" >&2; exit 1; }
SRC_ROOT="$ROOT_DIR/.cache/sources/talloc"
TARBALL="$ROOT_DIR/.cache/downloads/talloc-${TALLOC_VERSION}.tar.gz"
if [ ! -d "$SRC_ROOT" ]; then
    mkdir -p "$(dirname "$SRC_ROOT")"
    tar -xzf "$TARBALL" -C "$(dirname "$SRC_ROOT")"
    mv "$(dirname "$SRC_ROOT")/talloc-${TALLOC_VERSION}" "$SRC_ROOT"
fi

BUILD_DIR="$OUT_DIR/work/talloc-$ABI"
PREFIX="$OUT_DIR/prefix/$ABI"
rm -rf "$BUILD_DIR" "$PREFIX"
mkdir -p "$BUILD_DIR" "$PREFIX"
cp -R "$SRC_ROOT/." "$BUILD_DIR/"

cat > "$BUILD_DIR/cross-answers.txt" <<'EOF'
Checking uname sysname type: "Linux"
Checking uname machine type: "dontcare"
Checking uname release type: "dontcare"
Checking uname version type: "dontcare"
Checking simple C program: OK
building library support: OK
Checking for large file support: OK
Checking for -D_FILE_OFFSET_BITS=64: OK
Checking for WORDS_BIGENDIAN: OK
Checking for C99 vsnprintf: OK
Checking for HAVE_SECURE_MKSTEMP: OK
rpath library support: OK
-Wl,--version-script support: FAIL
Checking correct behavior of strtoll: OK
Checking correct behavior of strptime: OK
Checking for HAVE_IFACE_GETIFADDRS: OK
Checking for HAVE_IFACE_IFCONF: OK
Checking for HAVE_IFACE_IFREQ: OK
Checking getconf LFS_CFLAGS: OK
Checking for large file support without additional flags: OK
Checking for working strptime: OK
Checking for HAVE_SHARED_MMAP: OK
Checking for HAVE_MREMAP: OK
Checking for HAVE_INCOHERENT_MMAP: OK
Checking getconf large file support flags work: OK
EOF

(
    cd "$BUILD_DIR"
    CC="$CC" AR="$AR" RANLIB="$RANLIB" \
    CFLAGS="-O2 -fPIC -ffunction-sections -fdata-sections" \
    LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
    ./configure --prefix="$PREFIX" --disable-rpath --disable-python \
        --cross-compile --cross-answers=cross-answers.txt
    CC="$CC" AR="$AR" RANLIB="$RANLIB" make -j"${JOBS:-$(nproc)}"
    CC="$CC" AR="$AR" RANLIB="$RANLIB" make install
    mkdir -p "$PREFIX/lib" "$PREFIX/include"
    mapfile -t objects < <(find bin/default -type f -name '*.o' | sort)
    [ "${#objects[@]}" -gt 0 ] || { echo "talloc produced no object files" >&2; exit 1; }
    "$AR" rcsD "$PREFIX/lib/libtalloc.a" "${objects[@]}"
    "$RANLIB" "$PREFIX/lib/libtalloc.a"
    cp talloc.h "$PREFIX/include/talloc.h"
)

cp "$PREFIX/lib/libtalloc.a" "$OUT_DIR/libtalloc-$ABI.a"
cp "$PREFIX/include/talloc.h" "$OUT_DIR/talloc-$ABI.h"
printf '%s\n' "$PREFIX" > "$OUT_DIR/talloc-$ABI.prefix"
