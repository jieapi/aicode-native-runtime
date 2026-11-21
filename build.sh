#!/usr/bin/env bash
# Build tawcroot's `libtawcroot.so` for the Android ABIs we ship and stage
# release-ready artifacts in dist/.
#
# tawcroot (from https://github.com/wmww/tawc) is a rootless chroot
# replacement written in freestanding C. It is NOT a JNI library: upstream
# links it as a static non-PIE ET_EXEC and names it `libtawcroot.so` only so
# Android's jniLibs extractor accepts it and puts it in nativeLibraryDir,
# the one place an untrusted_app may exec from. There is nothing to
# System.loadLibrary() — you exec the file.
#
# Requirements: Linux (or WSL), bash, git, curl-less (NDK already present),
# Android NDK r27c (27.2.12479018 — the version upstream pins in
# app/build.gradle.kts). Upstream's build.sh hardcodes
# `toolchains/llvm/prebuilt/linux-x86_64`, so a Windows-native NDK will not
# work.
#
# Usage:
#   ./build.sh                          # build PIN's commit into ./dist
#   ./build.sh --ref v6                 # build an upstream tag
#   ./build.sh --tawc-dir /path/to/tawc # use an existing checkout
#   ./build.sh --abi aarch64            # arm64-v8a only
#   ./build.sh --out /tmp/out
#
# Env:
#   ANDROID_NDK_HOME   NDK root (auto-probed from a few common locations)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/wmww/tawc}"
NDK_PINNED="27.2.12479018"
CACHE_DIR="$REPO_DIR/.cache/upstream"
JNI_SO_NAME="libtawcroot.so"

TAWC_DIR=""
REF=""
ABI_SPEC="both"
OUT_DIR=""

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tawc-dir) [ $# -ge 2 ] || die "--tawc-dir needs a value"; TAWC_DIR="$2"; shift 2 ;;
        --ref)      [ $# -ge 2 ] || die "--ref needs a value";      REF="$2";      shift 2 ;;
        --abi)      [ $# -ge 2 ] || die "--abi needs a value";      ABI_SPEC="$2"; shift 2 ;;
        --out)      [ $# -ge 2 ] || die "--out needs a value";      OUT_DIR="$2";  shift 2 ;;
        -h|--help)  usage ;;
        *)          die "unknown argument: $1 (try --help)" ;;
    esac
done

[ -n "$OUT_DIR" ] || OUT_DIR="$REPO_DIR/dist"

# ---------------------------------------------------------------------------
# Android ABIs. Upstream only implements aarch64 and x86_64 (see
# tawcroot/src/arch/); there is no armeabi-v7a or x86 build, and no
# --abi=armeabi option to ask for one.
case "$ABI_SPEC" in
    both)           ABIS=(arm64-v8a x86_64) ;;
    aarch64|arm64|arm64-v8a) ABIS=(arm64-v8a) ;;
    x86_64|x86-64)  ABIS=(x86_64) ;;
    *)              die "unsupported --abi '$ABI_SPEC' (both|aarch64|x86_64)" ;;
esac

# ---------------------------------------------------------------------------
# NDK. Upstream's own script treats a missing ANDROID_NDK_HOME as an error
# when an abi is requested, so probe a few standard locations first.
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    for candidate in \
        "$HOME/android-ndk-r27c" \
        "$HOME/Android/Sdk/ndk/$NDK_PINNED" \
        "/usr/local/lib/android/sdk/ndk/$NDK_PINNED" \
        "/opt/android-sdk/ndk/$NDK_PINNED"
    do
        if [ -d "$candidate" ]; then
            ANDROID_NDK_HOME="$candidate"
            break
        fi
    done
fi
[ -n "${ANDROID_NDK_HOME:-}" ] || die "no NDK found. Set ANDROID_NDK_HOME to an NDK r27 (${NDK_PINNED}) install."
[ -d "$ANDROID_NDK_HOME" ] || die "ANDROID_NDK_HOME=$ANDROID_NDK_HOME does not exist"
export ANDROID_NDK_HOME
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
[ -x "$NDK_BIN/llvm-readelf" ] || die "NDK toolchain incomplete (expected $NDK_BIN/llvm-readelf)"
NDK_ACTUAL="$(basename "$ANDROID_NDK_HOME")"

# ---------------------------------------------------------------------------
# Upstream source: either a checkout the caller prepared, or a cached clone
# pinned to PIN / --ref. We never vendor the tree into this repo.
if [ -z "$TAWC_DIR" ]; then
    [ -n "$REF" ] || REF="$(tr -d '[:space:]' < "$REPO_DIR/PIN")"
    [ -n "$REF" ] || die "PIN is empty and no --ref was given"
    if [ ! -d "$CACHE_DIR/.git" ]; then
        echo "==> cloning $UPSTREAM_URL -> ${CACHE_DIR#$REPO_DIR/}"
        mkdir -p "$(dirname "$CACHE_DIR")"
        git clone --quiet --filter=blob:none "$UPSTREAM_URL" "$CACHE_DIR"
    else
        echo "==> fetching upstream"
        git -C "$CACHE_DIR" fetch --quiet --filter=blob:none origin
    fi
    git -C "$CACHE_DIR" -c advice.detachedHead=false checkout --quiet --force "$REF" \
        || die "cannot check out '$REF' in the cached clone"
    TAWC_DIR="$CACHE_DIR"
else
    TAWC_DIR="$(cd "$TAWC_DIR" && pwd)" || die "--tawc-dir does not exist"
    [ -d "$TAWC_DIR/tawcroot/src" ] || die "$TAWC_DIR does not look like a tawc checkout"
fi
[ -n "$REF" ] || REF="$(git -C "$TAWC_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
COMMIT_DATE="$(git -C "$TAWC_DIR" log -1 --format=%cI 2>/dev/null || echo unknown)"
[ -f "$TAWC_DIR/tawcroot/build.sh" ] || die "missing $TAWC_DIR/tawcroot/build.sh"

echo "==> tawc:  $TAWC_DIR @ $REF"
echo "==> NDK:   $ANDROID_NDK_HOME"
echo "==> abis:  ${ABIS[*]}"

# ---------------------------------------------------------------------------
# Upstream build: NDK clang, -nostdlib -static, non-PIE. Produces only the
# production binary (--testhost/--tests, and with them the cleat dependency,
# are test scaffolding we do not ship). Invoked through `bash` so a checkout
# made on a filesystem without the exec bit still works.
bash "$TAWC_DIR/tawcroot/build.sh" --abi="$ABI_SPEC"

# ---------------------------------------------------------------------------
# Verify what came out, then stage it. These checks are the same contract
# upstream relies on: ET_EXEC with no interpreter (so it can be exec'd
# straight out of nativeLibraryDir), 16 KB-aligned LOAD segments (required
# on 16 KB-page devices), and a non-executable stack.
verify_so() {
    local so="$1" abi="$2" hdr align bad=0
    hdr="$("$NDK_BIN/llvm-readelf" -h "$so")"
    grep -qE '^[[:space:]]*Type:[[:space:]]+EXEC' <<<"$hdr" \
        || die "$so is not a non-PIE ET_EXEC (Android will refuse to exec it)"
    case "$abi" in
        arm64-v8a) grep -q 'AArch64' <<<"$hdr" || die "$so is not AArch64" ;;
        x86_64)    grep -q 'X86-64'  <<<"$hdr" || die "$so is not x86-64" ;;
    esac
    if "$NDK_BIN/llvm-readelf" -lW "$so" | grep -q 'INTERP'; then
        die "$so has a PT_INTERP segment (it would need a dynamic loader)"
    fi
    while read -r align; do
        [ -n "$align" ] || continue
        if [ $((align)) -lt $((0x4000)) ]; then
            echo "ERROR: $so has a LOAD segment aligned to $align (< 16 KB)" >&2
            bad=1
        fi
    done < <("$NDK_BIN/llvm-readelf" -lW "$so" | awk '$1=="LOAD" {print $NF}')
    [ "$bad" -eq 0 ] || die "$so is not 16 KB-page compatible"
    if "$NDK_BIN/llvm-readelf" -lW "$so" | awk '$1=="GNU_STACK" {print $7}' | grep -q 'E'; then
        die "$so has an executable stack"
    fi
}

mkdir -p "$OUT_DIR/jniLibs"
STAGED=()
for abi in "${ABIS[@]}"; do
    src="$TAWC_DIR/app/src/main/jniLibs/$abi/$JNI_SO_NAME"
    [ -f "$src" ] || die "upstream did not produce $src"
    verify_so "$src" "$abi"
    mkdir -p "$OUT_DIR/jniLibs/$abi"
    cp -f "$src" "$OUT_DIR/jniLibs/$abi/$JNI_SO_NAME"
    cp -f "$src" "$OUT_DIR/libtawcroot-$abi.so"   # flat, ABI-suffixed copy
    STAGED+=("$OUT_DIR/libtawcroot-$abi.so")
    echo "==> staged $abi: $(stat -c %s "$src" | numfmt --to=iec) bytes"
done

# ---------------------------------------------------------------------------
# Release artifacts.
cp -f "$REPO_DIR/LICENSE.MIT" "$OUT_DIR/LICENSE.MIT"

(
    cd "$OUT_DIR"
    sha256sum libtawcroot-*.so jniLibs/*/libtawcroot.so | sed 's|jniLibs/||' > SHA256SUMS
)

# jniLibs-shaped zip so a consumer can drop it straight into
# `app/src/main/jniLibs` (or point a sourceSet at the extracted dir).
python3 - "$OUT_DIR" <<'PY'
import os, shutil, sys
out = sys.argv[1]
shutil.make_archive(os.path.join(out, "tawcroot-jniLibs"), "zip", os.path.join(out, "jniLibs"))
PY

{
    echo "tawcroot prebuilt binaries (libtawcroot.so)"
    echo
    echo "upstream:    $UPSTREAM_URL"
    echo "commit:      $REF"
    echo "committed:   $COMMIT_DATE"
    echo "ndk:         $NDK_ACTUAL (pinned: $NDK_PINNED)"
    echo "abis:        ${ABIS[*]}"
    echo "built:       $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "builder:     $(uname -srm)"
    echo
    echo "Each .so is a static non-PIE ET_EXEC with no PT_INTERP and 16 KB"
    echo "LOAD alignment. It is not a JNI library: exec it from"
    echo "applicationInfo.nativeLibraryDir. Requires minSdk 29."
    echo
    echo "Assets:"
    echo "  libtawcroot-<abi>.so     single-ABI binary"
    echo "  tawcroot-jniLibs.zip     arm64-v8a/ + x86_64/ layout for jniLibs"
    echo "  SHA256SUMS               checksums"
    echo "  LICENSE.MIT              upstream license (MIT, Sophie Winter)"
} > "$OUT_DIR/BUILD-INFO.txt"

{
    cat "$OUT_DIR/BUILD-INFO.txt"
    echo
    echo "## Usage"
    echo
    echo '```'
    echo "# unzip into your module and make sure natives are extracted:"
    echo "#   android { packaging { jniLibs { useLegacyPackaging = true } } }"
    echo "unzip tawcroot-jniLibs.zip -d app/src/main/jniLibs"
    echo
    echo "# then, at runtime, exec it (it is a program, not a JNI lib):"
    echo 'val so = File(applicationInfo.nativeLibraryDir, "libtawcroot.so")'
    echo 'ProcessBuilder(so.path, "-r", rootfs, "--", "/bin/true").start()'
    echo '```'
    echo
    echo "Licensed MIT — see LICENSE.MIT (Copyright (c) 2026 Sophie Winter)."
} > "$OUT_DIR/RELEASE-NOTES.md"

echo
echo "==> artifacts in $OUT_DIR"
ls -1 "$OUT_DIR"
cat "$OUT_DIR/SHA256SUMS"