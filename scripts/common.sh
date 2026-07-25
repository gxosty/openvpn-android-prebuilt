#!/usr/bin/env bash
# Shared helpers for the build scripts. Source, do not execute.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

# Working directories. Overridable so the workflow can point them at a cache.
WORK_DIR="${WORK_DIR:-$REPO_ROOT/work}"
DEPS_ROOT="${DEPS_ROOT:-$WORK_DIR/deps}"
BUILD_ROOT="${BUILD_ROOT:-$WORK_DIR/build}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"
SRC_DIR="${SRC_DIR:-$WORK_DIR/src}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- NDK ---------------------------------------------------------------------

ndk_root() {
    local ndk="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-}}"
    [ -n "$ndk" ] || die "ANDROID_NDK_ROOT is not set"
    [ -f "$ndk/build/cmake/android.toolchain.cmake" ] \
        || die "ANDROID_NDK_ROOT=$ndk does not look like an NDK (no build/cmake/android.toolchain.cmake)"
    printf '%s' "$ndk"
}

# Path to the LLVM toolchain bin/ dir inside the NDK, whichever host it was built for.
ndk_toolchain_bin() {
    local ndk prebuilt
    ndk="$(ndk_root)"
    for prebuilt in "$ndk"/toolchains/llvm/prebuilt/*/; do
        if [ -x "$prebuilt/bin/clang" ]; then
            printf '%s' "${prebuilt%/}/bin"
            return 0
        fi
    done
    die "no LLVM toolchain found under $ndk/toolchains/llvm/prebuilt"
}

# NDK revision string, read back from source.properties so build-info records
# what was actually used rather than what we asked for.
ndk_revision() {
    local ndk
    ndk="$(ndk_root)"
    if [ -f "$ndk/source.properties" ]; then
        sed -n 's/^Pkg.Revision *= *//p' "$ndk/source.properties" | tr -d '[:space:]'
    else
        printf '%s' "$NDK_VERSION"
    fi
}

# --- ABI mapping -------------------------------------------------------------

abi_triple() {
    case "$1" in
        armeabi-v7a) printf 'armv7a-linux-androideabi' ;;
        arm64-v8a)   printf 'aarch64-linux-android' ;;
        x86)         printf 'i686-linux-android' ;;
        x86_64)      printf 'x86_64-linux-android' ;;
        *) die "unknown ABI: $1" ;;
    esac
}

abi_openssl_target() {
    case "$1" in
        armeabi-v7a) printf 'android-arm' ;;
        arm64-v8a)   printf 'android-arm64' ;;
        x86)         printf 'android-x86' ;;
        x86_64)      printf 'android-x86_64' ;;
        *) die "unknown ABI: $1" ;;
    esac
}

# Expected ELF class / machine, used by verify.sh. The machine strings are the
# ones llvm-readelf prints (it mirrors GNU readelf's naming).
abi_elf_class()   { case "$1" in armeabi-v7a|x86) printf 'ELF32' ;; *) printf 'ELF64' ;; esac; }
abi_elf_machine() {
    case "$1" in
        armeabi-v7a) printf 'ARM' ;;
        arm64-v8a)   printf 'AArch64' ;;
        x86)         printf 'Intel 80386' ;;
        x86_64)      printf 'Advanced Micro Devices X86-64' ;;
        *) die "unknown ABI: $1" ;;
    esac
}

# Only 64-bit ABIs are subject to Android's 16 KB page size requirement.
abi_is_64bit() { case "$1" in arm64-v8a|x86_64) return 0 ;; *) return 1 ;; esac; }

# The NDK's per-API clang wrapper for an ABI, e.g. aarch64-linux-android21-clang.
abi_clang() { printf '%s/%s%s-clang' "$(ndk_toolchain_bin)" "$(abi_triple "$1")" "$API_LEVEL"; }

# --- misc --------------------------------------------------------------------

nproc_or() { command -v nproc >/dev/null 2>&1 && nproc || printf '%s' "${1:-4}"; }

# Download to a path, skipping if already present (so caches short-circuit).
fetch() {
    local url="$1" dest="$2"
    if [ -s "$dest" ]; then
        log "cached: $(basename "$dest")"
        return 0
    fi
    log "fetching $url"
    mkdir -p "$(dirname "$dest")"
    curl -fsSL --retry 3 --retry-delay 2 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
}

require_cmds() {
    local c missing=()
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    [ ${#missing[@]} -eq 0 ] || die "missing required commands: ${missing[*]}"
}
