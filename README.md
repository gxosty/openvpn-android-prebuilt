# openvpn-android-prebuilt

Prebuilt [OpenVPN 2.x](https://github.com/OpenVPN/openvpn) libraries for Android, published
automatically whenever upstream cuts a new stable release.

Upstream ships no Android binaries, and its CMake build produces only an executable — there is no
library target at all. This repository cross-compiles OpenVPN and its dependencies with the Android
NDK, adds library targets on top of upstream's own source list, and publishes the result as GitHub
release assets.

**Minimum API level 21 (Android 5.0).** ABIs: `armeabi-v7a`, `arm64-v8a`, `x86`, `x86_64`.

---

## What gets published

Six OpenVPN artifacts per ABI. The `-static-deps` / `-shared-deps` suffix describes how **OpenSSL,
LZO and LZ4** are linked; the file extension describes how **OpenVPN** is linked.

| Artifact | What it is |
|---|---|
| `libopenvpn-<abi>-static-deps.a` | Static library with OpenSSL, LZO and LZ4 merged in. Links standalone. |
| `libopenvpn-<abi>-shared-deps.a` | Static library, OpenVPN objects only. Supply `-lcrypto -lssl -llzo2 -llz4` yourself. |
| `libopenvpn-<abi>-static-deps.so` | Shared library, dependencies linked in statically and their symbols hidden. |
| `libopenvpn-<abi>-shared-deps.so` | Shared library with `DT_NEEDED` on `libcrypto.so`, `libssl.so`, `liblzo2.so`, `liblz4.so`. |
| `libopenvpnexec-<abi>-static-deps.so` | The `openvpn` **binary** (PIE), self-contained. |
| `libopenvpnexec-<abi>-shared-deps.so` | The `openvpn` binary, resolving its dependencies at runtime. |

Plus, per ABI: `libcrypto-<abi>.{a,so}`, `libssl-<abi>.{a,so}`, `liblzo2-<abi>.{a,so}`,
`liblz4-<abi>.{a,so}`, a drop-in tarball per dependency mode, `openvpn-lib.h`, and `SHA256SUMS`.

### Why `libopenvpnexec-*.so` is an executable

Android's package installer only extracts entries matching `lib*.so` into `nativeLibraryDir`, and
only those come out with the exec bit set. Naming a PIE executable `lib….so` is the standard trick
(used by [ics-openvpn](https://github.com/schwabe/ics-openvpn)) for shipping a runnable binary inside an APK. Spawn it as a child process and
drive it over OpenVPN's management interface — do not try to link it.

---

## Using it

### Drop-in (recommended)

Download `openvpn-<version>-android21-<abi>-<mode>-deps.tar.gz` for each ABI you support and copy
each `jniLibs/` directory into `src/main/`. The filenames inside are already the ones Android
requires:

```
app/src/main/jniLibs/
  arm64-v8a/libopenvpn.so
  arm64-v8a/libopenvpnexec.so
  armeabi-v7a/libopenvpn.so
  ...
```

> **Do not rename files inside `jniLibs/`.** Android matches on the exact filename, so the flat
> release assets (`libopenvpn-arm64-v8a-static-deps.so`) will *not* work there as-is.

### Linking from your own JNI code

```cmake
add_library(openvpn SHARED IMPORTED)
set_target_properties(openvpn PROPERTIES
    IMPORTED_LOCATION ${PREBUILT_DIR}/jniLibs/${ANDROID_ABI}/libopenvpn.so)

target_include_directories(myjni PRIVATE ${PREBUILT_DIR}/include)
target_link_libraries(myjni PRIVATE openvpn)
```

```c
#include "openvpn-lib.h"

char *argv[] = { "openvpn", "--config", path, "--management", ..., NULL };
int rc = openvpn_main(sizeof(argv) / sizeof(*argv) - 1, argv);
```

`openvpn_main()` is the entry point of the openvpn program. Upstream exports no entry point of its
own — its `openvpn_main()` is declared `static`, and its `main()` cannot be shipped in a library
because it would collide with yours — so the library targets compile `openvpn.c` with `main()`
renamed and export `openvpn_main()` on top. The libraries contain no `main` symbol at all, so you can
link them from a program that has its own `main()`.

Two things to know before running OpenVPN in-process: it keeps process-wide state and installs
signal handlers, so it is neither re-entrant nor safe to run twice concurrently; and it calls
`exit()` on fatal errors, which takes your whole process with it. If that is unacceptable, use
`libopenvpnexec.so` in a child process instead.

On Android the tun device cannot be opened directly — hand the `VpnService` file descriptor to
OpenVPN over the management interface.

### Choosing a variant

- **One file, no thinking:** `libopenvpn-<abi>-static-deps.so`.
- **Your app already loads its own OpenSSL:** still `-static-deps` — its dependency symbols are
  hidden with `-Wl,--exclude-libs,ALL`, so the two cannot collide.
- **Several native libraries in your app share one OpenSSL:** `-shared-deps`, and ship the
  `libcrypto.so` / `libssl.so` / `liblzo2.so` / `liblz4.so` from the same release.
- **Static linking into your own `.so`:** `libopenvpn-<abi>-static-deps.a`. It is built PIC.

>[!Important]
>Directly linking OpenVPN library to with your project (both static or shared) will force you to make
>your project source code publicly available. That's because OpenVPN is licensed under GPL-2.0 license.
>You can still use PIE version to keep your source code private.

---

## Not compiled in

| Feature | Why |
|---|---|
| PKCS#11 | `pkcs11-helper` is autotools-only and cross-compiling it for Android is a project of its own. |
| DCO | Linux kernel module; not applicable on Android. |
| OpenSSL legacy provider | Built with `no-module no-legacy`, so there is nothing to load at runtime and no `OPENSSL_MODULES` path to configure. **`BF-CBC`, `DES`, `RC4` and `CAST5` are unavailable.** |
| OpenSSL engines | OpenVPN's CMake build hard-disables `HAVE_OPENSSL_ENGINE` (`config.h.cmake.in` has a plain `#undef`), so engine support is unreachable either way. |
| mbedTLS backend | OpenSSL only, for now. |
| `--dns-updown` | No such hook script on Android. |

---

## Building locally

Needs Linux or macOS with `bash`, `cmake`, `ninja` (or `make`), `pkg-config`, `python3`, `perl`,
`git` and `curl`, plus an [Android NDK](https://developer.android.com/ndk/downloads).

```bash
export ANDROID_NDK_ROOT=/path/to/android-ndk-r28c
eval "$(scripts/resolve-versions.sh)"      # resolves OpenVPN + OpenSSL versions

scripts/build-deps.sh    arm64-v8a         # OpenSSL, LZO, LZ4 -- both forms
scripts/build-openvpn.sh arm64-v8a static
scripts/build-openvpn.sh arm64-v8a shared
scripts/package.sh       arm64-v8a
scripts/verify.sh        arm64-v8a
```

Artifacts land in `out/dist/`. Pin different versions by editing `scripts/versions.env`, or override
any of them from the environment (`OPENSSL_LINE=3.6 scripts/build-deps.sh …`).

### How the OpenVPN library targets are produced

`scripts/cmake-overlay.cmake` is appended to the end of upstream's `CMakeLists.txt`. It reuses
upstream's `${SOURCE_FILES}` and `add_library_deps()`, so the source list tracks upstream
automatically and no patch has to be rebased. Appending at EOF depends on no line numbers or
surrounding context; if a future release renames either symbol, configure fails with an explicit
message rather than producing a subtly wrong artifact.

No OpenVPN source is modified.

---

## Automation

| Workflow | Trigger | What it does |
|---|---|---|
| `check-upstream.yml` | every 6 h, or manually | Calls `build-release.yml` with `publish: true`. |
| `build-release.yml` | called, or manually | Resolves versions, decides whether the build is new, builds 4 ABIs, verifies, publishes. |

The **build key** — `openvpn`, `openssl`, `lzo`, `lz4`, `ndk` and `api` — is recorded verbatim in
every release body. A scheduled run rebuilds exactly when no existing release carries the current
key, so a new OpenSSL patch release produces a new build even if OpenVPN itself has not moved.
Releases are tagged `v<openvpn-version>-<build-number>`, e.g. `v2.7.5-2`.

Upstream selection takes the newest stable release on the highest `X.Y` line and ignores
alpha/beta/rc tags. It does not use GitHub's "latest release" pointer, because OpenVPN publishes on
multiple lines on the same day and that pointer can flip back to an older one.

### Every artifact is verified before release

`scripts/verify.sh` fails the build on any mismatch: ELF class and machine against the ABI, PIE
executables having an interpreter and shared libraries not, `DT_NEEDED` matching the dependency mode
exactly, 16 KB page alignment on 64-bit, `openvpn_main` exported, `main` local in the archives, no
OpenSSL symbols re-exported from `-static-deps` artifacts — and a real link test at API 21 from a
caller that defines its own `main()`.

The API 21 claim is self-enforcing: bionic annotates newer functions with `__INTRODUCED_IN`, so
compiling against `android-21` turns any use of a post-21 API into a hard compile error.

---

## Licence

OpenVPN is **GPL-2.0** with the OpenSSL linking exception granted by its copyright holders; the
published binaries inherit that. See [NOTICE.md](NOTICE.md) for the full attribution and for where
to get the corresponding sources. The build scripts in this repository are MIT-licensed.
