#!/usr/bin/env bash
# Rebuild the Termux terminal JNI shim from source with 16 KB ELF alignment.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/PINS"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist/termux-jni}"
CACHE_DIR="${CACHE_DIR:-$ROOT_DIR/.cache}"
NDK_ROOT="${ANDROID_NDK_HOME:-}"

[ -d "$NDK_ROOT" ] || { echo "Set ANDROID_NDK_HOME to the NDK used for Termux JNI." >&2; exit 1; }
[ -x "$NDK_ROOT/ndk-build" ] || { echo "ndk-build not found under $NDK_ROOT" >&2; exit 1; }

SRC_DIR="$CACHE_DIR/sources/termux-app"
if [ ! -d "$SRC_DIR/.git" ]; then
    git clone --filter=blob:none "$TERMUX_APP_REPO" "$SRC_DIR"
fi
git -C "$SRC_DIR" fetch --quiet --filter=blob:none origin
git -C "$SRC_DIR" checkout --quiet --force "$TERMUX_APP_COMMIT"

WORK_DIR="$OUT_DIR/work"
rm -rf "$OUT_DIR"
mkdir -p "$WORK_DIR/jni" "$OUT_DIR/jniLibs"
cp "$SRC_DIR/terminal-emulator/src/main/jni/termux.c" "$WORK_DIR/jni/termux.c"

cat > "$WORK_DIR/jni/Android.mk" <<'EOF'
LOCAL_PATH := $(call my-dir)
include $(CLEAR_VARS)
LOCAL_MODULE := termux
LOCAL_SRC_FILES := termux.c
LOCAL_LDFLAGS += -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384
include $(BUILD_SHARED_LIBRARY)
EOF

cat > "$WORK_DIR/jni/Application.mk" <<EOF
APP_ABI := arm64-v8a x86_64
APP_PLATFORM := android-${MIN_SDK}
APP_STL := none
APP_SUPPORT_FLEXIBLE_PAGE_SIZES := true
EOF

"$NDK_ROOT/ndk-build" \
    NDK_PROJECT_PATH=null \
    APP_BUILD_SCRIPT="$WORK_DIR/jni/Android.mk" \
    NDK_APPLICATION_MK="$WORK_DIR/jni/Application.mk" \
    NDK_OUT="$WORK_DIR/obj" \
    NDK_LIBS_OUT="$WORK_DIR/lib" \
    V=1

for abi in arm64-v8a x86_64; do
    src="$WORK_DIR/lib/$abi/libtermux.so"
    [ -f "$src" ] || { echo "missing $src" >&2; exit 1; }
    mkdir -p "$OUT_DIR/jniLibs/$abi"
    cp "$src" "$OUT_DIR/jniLibs/$abi/libtermux.so"
done

LLVM_READELF="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf" \
    "$ROOT_DIR/verify-elf.sh" \
    "$OUT_DIR/jniLibs/arm64-v8a/libtermux.so" \
    "$OUT_DIR/jniLibs/x86_64/libtermux.so"

cat > "$OUT_DIR/BUILD-INFO.txt" <<EOF
component=termux-jni
source=$TERMUX_APP_REPO
commit=$TERMUX_APP_COMMIT
ndk=$NDK_ROOT
abis=arm64-v8a x86_64
flags=-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384
EOF
