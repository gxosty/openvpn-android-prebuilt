#!/usr/bin/env bash
#
# Checks the packaged artifacts for one ABI. Every check is a hard failure --
# a broken artifact must not reach a release.
#
#   * ELF class and machine match the ABI
#   * PIE executables have an interpreter, shared libraries do not
#   * DT_NEEDED matches the dependency mode exactly
#   * 64-bit artifacts are 16 KB page aligned
#   * openvpn_main() is exported; main() is local in the static archives
#   * static-deps artifacts do not re-export OpenSSL symbols
#   * every .a and .so actually links, from a caller that has its own main()
#
# Usage: verify.sh <abi>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

ABI="${1:?usage: verify.sh <abi>}"

TOOLCHAIN_BIN="$(ndk_toolchain_bin)"
READELF="$TOOLCHAIN_BIN/llvm-readelf"
NM="$TOOLCHAIN_BIN/llvm-nm"
CLANG="$(abi_clang "$ABI")"
[ -x "$CLANG" ] || die "no clang wrapper for $ABI at API $API_LEVEL: $CLANG"

DIST="$OUT_DIR/dist"
STAGE_SHARED="$DEPS_ROOT/$ABI/stage-shared"
EXPECT_CLASS="$(abi_elf_class "$ABI")"
EXPECT_MACHINE="$(abi_elf_machine "$ABI")"
DEP_SONAMES=(libcrypto.so libssl.so liblzo2.so liblz4.so)

# --- reporting -------------------------------------------------------------
# Note the if/else: `set -e` is active, so a bare failing test would abort the
# script instead of being counted as a failed check.

failures=0
_report() {
    if [ "$2" = 0 ]; then
        printf '  \033[0;32mok\033[0m    %s\n' "$1"
    else
        printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"
        failures=$(( failures + 1 ))
    fi
}
expect()     { local d="$1"; shift; if "$@"; then _report "$d" 0; else _report "$d" 1; fi; }
expect_not() { local d="$1"; shift; if "$@"; then _report "$d" 1; else _report "$d" 0; fi; }

# --- predicates ------------------------------------------------------------

elf_field()   { "$READELF" -h "$1" | sed -n "s/^ *$2: *//p" | head -n1; }
field_is()    { [ "$(elf_field "$1" "$2")" = "$3" ]; }
has_interp()  { "$READELF" -lW "$1" | grep -q '^ *INTERP'; }
needs_lib()   { "$READELF" -d "$1" 2>/dev/null | grep -qF "Shared library: [$2]"; }
exports_sym() { "$NM" -D --defined-only "$1" 2>/dev/null | grep -qw "$2"; }
exports_any_openssl() {
    "$NM" -D --defined-only "$1" 2>/dev/null \
        | grep -qE '\b(SSL_CTX_new|EVP_EncryptInit_ex|OPENSSL_init_crypto)\b'
}
archive_has_global() {
    "$NM" --defined-only "$1" 2>/dev/null | grep -qE "^[0-9a-fA-F]* T $2\$"
}

# All LOAD segments aligned to at least 16 KB. Bash arithmetic understands the
# 0x... values readelf prints, so no gawk-only strtonum() needed.
loads_16k_aligned() {
    local a
    while read -r a; do
        [ -n "$a" ] || continue
        (( a >= 16384 )) || return 1
    done < <("$READELF" -lW "$1" | awk '$1=="LOAD" { print $NF }')
    return 0
}

# --- composite checks ------------------------------------------------------

verify_elf() { # <file> <shared-library|pie-executable>
    local f="$1" kind="$2" name
    name="$(basename "$f")"

    expect "$name: ELF class is $EXPECT_CLASS"        field_is "$f" Class "$EXPECT_CLASS"
    expect "$name: machine is '$EXPECT_MACHINE'"      field_is "$f" Machine "$EXPECT_MACHINE"

    # A PIE executable and a shared library are both ET_DYN; the interpreter
    # program header is what actually distinguishes them.
    case "$kind" in
        pie-executable) expect     "$name: is a PIE executable (has INTERP)" has_interp "$f" ;;
        shared-library) expect_not "$name: is a shared library (no INTERP)"  has_interp "$f" ;;
    esac

    if abi_is_64bit "$ABI"; then
        expect "$name: LOAD segments are 16 KB aligned" loads_16k_aligned "$f"
    fi
}

verify_needed() { # <file> <static|shared>
    local f="$1" mode="$2" name dep
    name="$(basename "$f")"
    for dep in "${DEP_SONAMES[@]}"; do
        if [ "$mode" = shared ]; then
            expect "$name: DT_NEEDED contains $dep" needs_lib "$f" "$dep"
        else
            expect_not "$name: DT_NEEDED omits $dep" needs_lib "$f" "$dep"
        fi
    done
}

verify_shared_symbols() { # <file> <static|shared>
    local f="$1" mode="$2" name
    name="$(basename "$f")"
    expect "$name: exports openvpn_main" exports_sym "$f" openvpn_main

    if [ "$mode" = static ]; then
        # --exclude-libs,ALL should have hidden everything that came out of
        # libcrypto.a / libssl.a, so this .so cannot clash with a host app that
        # loads its own OpenSSL.
        expect_not "$name: does not re-export OpenSSL symbols" exports_any_openssl "$f"
    fi
}

verify_archive_symbols() { # <file>
    local f="$1" name
    name="$(basename "$f")"
    expect     "$name: openvpn_main is a global symbol" archive_has_global "$f" openvpn_main
    # The overlay renames openvpn.c's main() away for the library targets. If it
    # ever reappears, this archive can no longer be linked into a program that
    # has its own main().
    expect_not "$name: main is not a global symbol"     archive_has_global "$f" main
}

# --- link test -------------------------------------------------------------

TESTDIR="$BUILD_ROOT/verify-$ABI"
rm -rf "$TESTDIR"; mkdir -p "$TESTDIR"
cat > "$TESTDIR/main.c" <<'EOF'
#include "openvpn-lib.h"
int main(int argc, char *argv[]) { return openvpn_main(argc, argv); }
EOF

link_test() { # <label> <static|shared> <lib>
    local label="$1" mode="$2" lib="$3"
    local -a extra=()
    # if/then, not `&&`: a false test as the last command of the list would
    # abort the script under `set -e`.
    if [ "$mode" = shared ]; then
        extra=(-L"$STAGE_SHARED/lib" -lcrypto -lssl -llzo2 -llz4)
    fi

    local logfile="$TESTDIR/link-${label// /_}.log"
    if "$CLANG" -fPIE -pie -I"$REPO_ROOT/include" \
            "$TESTDIR/main.c" "$lib" "${extra[@]}" -lm \
            -o "$TESTDIR/linktest" > "$logfile" 2>&1; then
        _report "link test: $label" 0
    else
        _report "link test: $label" 1
        sed 's/^/        /' "$logfile" >&2
    fi
}

# --- run -------------------------------------------------------------------

log "verifying $ABI artifacts in $DIST"

for MODE in static shared; do
    suffix="$ABI-$MODE-deps"
    static_lib="$DIST/libopenvpn-$suffix.a"
    shared_lib="$DIST/libopenvpn-$suffix.so"
    pie_bin="$DIST/libopenvpnexec-$suffix.so"

    for f in "$static_lib" "$shared_lib" "$pie_bin"; do
        [ -f "$f" ] || die "missing artifact: $f"
    done

    verify_elf "$shared_lib" shared-library
    verify_elf "$pie_bin"    pie-executable
    verify_needed "$shared_lib" "$MODE"
    verify_needed "$pie_bin"    "$MODE"
    verify_shared_symbols "$shared_lib" "$MODE"
    verify_archive_symbols "$static_lib"

    link_test "$MODE-deps .a" "$MODE" "$static_lib"
    link_test "$MODE-deps .so" "$MODE" "$shared_lib"
done

for lib in "${DEP_SONAMES[@]}"; do
    verify_elf "$DIST/${lib%.so}-$ABI.so" shared-library
done

[ "$failures" -eq 0 ] || die "$failures verification check(s) failed for $ABI"
log "all verification checks passed for $ABI"
