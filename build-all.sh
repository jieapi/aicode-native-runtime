#!/usr/bin/env bash
# Build tawcroot, PRoot, Termux JNI and their native dependencies from source.
# No prebuilt .so is consumed by this script.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/PINS"

OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist/native-runtime}"
WORK_DIR="$OUT_DIR/work"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/jniLibs" "$WORK_DIR"

find_ndk() {
    local version="$1" explicit="${2:-}" candidate
    if [ -n "$explicit" ] && [ -d "$explicit" ]; then
        printf '%s\n' "$explicit"
        return
    fi
    for candidate in \
        "$HOME/Android/Sdk/ndk/$version" \
        "$HOME/android-sdk/ndk/$version" \
        "$HOME/android/ndk/$version" \
        "/opt/android-sdk/ndk/$version" \
        "/usr/local/lib/android/sdk/ndk/$version"
    do
        if [ -d "$candidate" ]; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    echo "NDK $version not found; set ANDROID_NDK_$version or install it with sdkmanager." >&2
    exit 1
}

NDK_TAWC="$(find_ndk "$TAWC_NDK_VERSION" "${ANDROID_NDK_TAWC:-}")"
NDK_NATIVE="$(find_ndk "$PROOT_NDK_VERSION" "${ANDROID_NDK_NATIVE:-}")"
export ANDROID_NDK_HOME="$NDK_TAWC"

# Build tawcroot using its pinned NDK and upstream commit.
"$ROOT_DIR/build.sh" \
    --out "$OUT_DIR/tawcroot" \
    --ref "$TAWC_COMMIT"

# Build PRoot and Termux JNI using the 16 KB-capable NDK.
for abi in arm64-v8a x86_64; do
    ANDROID_NDK_HOME="$NDK_NATIVE" "$ROOT_DIR/build-proot.sh" "$abi" "$OUT_DIR/proot"
done
OUT_DIR="$OUT_DIR/termux-jni" ANDROID_NDK_HOME="$NDK_NATIVE" "$ROOT_DIR/build-termux-jni.sh"

# Merge only verified runtime files into the consumer-facing jniLibs tree.
for abi in arm64-v8a x86_64; do
    mkdir -p "$OUT_DIR/jniLibs/$abi"
    cp "$OUT_DIR/tawcroot/jniLibs/$abi/libtawcroot.so" "$OUT_DIR/jniLibs/$abi/"
    cp "$OUT_DIR/proot/jniLibs/$abi/"*.so "$OUT_DIR/jniLibs/$abi/"
    cp "$OUT_DIR/termux-jni/jniLibs/$abi/libtermux.so" "$OUT_DIR/jniLibs/$abi/"
done

LLVM_READELF="$NDK_NATIVE/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
mapfile -t ELFS < <(find "$OUT_DIR/jniLibs" -type f -name '*.so' | sort)
[ "${#ELFS[@]}" -gt 0 ] || { echo "no native outputs" >&2; exit 1; }
"$ROOT_DIR/verify-elf.sh" "${ELFS[@]}"

# Preserve upstream notices alongside the binary release.
cp "$ROOT_DIR/LICENSE.MIT" "$OUT_DIR/LICENSE.tawcroot.MIT"
cp "$ROOT_DIR/.cache/sources/proot/COPYING" "$OUT_DIR/LICENSE.proot.GPL-2.0"
cp "$ROOT_DIR/.cache/sources/libandroid-shmem/LICENSE" "$OUT_DIR/LICENSE.libandroid-shmem.BSD-3-Clause"
cp "$ROOT_DIR/.cache/sources/termux-app/LICENSE.md" "$OUT_DIR/LICENSE.termux-app.Apache-2.0"
cp "$ROOT_DIR/.cache/sources/talloc/LICENSE" "$OUT_DIR/LICENSE.talloc"
cp "$ROOT_DIR/PINS" "$OUT_DIR/PINS"

(
    cd "$OUT_DIR"
    find jniLibs -type f -name '*.so' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
    python3 - <<'PY'
import os
import shutil
out = os.getcwd()
shutil.make_archive(os.path.join(out, "native-runtime-jniLibs"), "zip", os.path.join(out, "jniLibs"))
PY
    sha256sum native-runtime-jniLibs.zip >> SHA256SUMS
)

cat > "$OUT_DIR/BUILD-INFO.txt" <<EOF
native-runtime build
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
abis=$ABIS
tawcroot=$TAWC_COMMIT
proot=$PROOT_COMMIT
termux_app=$TERMUX_APP_COMMIT
libandroid_shmem=$SHMEM_COMMIT
talloc=$TALLOC_VERSION
tawc_ndk=$TAWC_NDK_VERSION
native_ndk=$PROOT_NDK_VERSION
min_sdk=$MIN_SDK
elf_flags=-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384
EOF

cat > "$OUT_DIR/RELEASE-NOTES.md" <<'EOF'
# Native runtime artifacts

This release contains native files rebuilt from the pinned upstream sources in `PINS`.
The `native-runtime-jniLibs.zip` archive is a drop-in Android `jniLibs` tree.

The files named `libproot.so`, `libproot-loader*.so`, and `libtawcroot.so` are executables named with a `.so` suffix so Android extracts them into `nativeLibraryDir`. They must be started with `ProcessBuilder`; they must not be passed to `System.loadLibrary()`.

`libtermux.so` is the actual JNI shared library loaded by `System.loadLibrary("termux")`.

All packaged ELF files are checked for 16 KB `PT_LOAD` alignment, no executable stack, and no `PT_INTERP` on exec-only runtime files. Check `SHA256SUMS` and preserve the license files when redistributing.
EOF

printf 'native runtime built in %s\n' "$OUT_DIR"
