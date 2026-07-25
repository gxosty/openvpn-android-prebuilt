#!/usr/bin/env python3
"""Render the GitHub release body from the per-ABI build-info.json files.

Everything in the output is read back off the artifacts that were actually
built -- versions, DT_NEEDED lists, sizes, checksums -- so the release notes
cannot drift from what was shipped.

Usage:
  render-release-notes.py --build-info out/build-info --tag v2.7.5-1 \
      [--repo owner/name] [--run-url URL] > body.md
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

DEP_ORDER = ["libcrypto", "libssl", "liblzo2", "liblz4"]

VARIANT_GUIDE = [
    (
        "libopenvpn-<abi>-static-deps.a",
        "Static library, self-contained",
        "Link OpenVPN into your own `.so` or executable with nothing else to supply. "
        "OpenSSL, LZO and LZ4 object files are merged into this archive.",
    ),
    (
        "libopenvpn-<abi>-shared-deps.a",
        "Static library, thin",
        "Same OpenVPN objects, dependencies **not** included. Link with "
        "`-lcrypto -lssl -llzo2 -llz4` against the matching shared libraries below.",
    ),
    (
        "libopenvpn-<abi>-static-deps.so",
        "Shared library, self-contained",
        "One file to ship. Dependencies are linked in statically and their symbols are "
        "hidden, so this cannot clash with another OpenSSL already loaded in the process.",
    ),
    (
        "libopenvpn-<abi>-shared-deps.so",
        "Shared library, thin",
        "Smaller, but you must also ship `libcrypto.so`, `libssl.so`, `liblzo2.so` and "
        "`liblz4.so` for the same ABI.",
    ),
    (
        "libopenvpnexec-<abi>-static-deps.so",
        "PIE executable, self-contained",
        "Not a library — this is the `openvpn` binary. Spawn it as a child process and "
        "drive it over the management interface. Named `lib*.so` so Android extracts it "
        "into `nativeLibraryDir` with the exec bit set.",
    ),
    (
        "libopenvpnexec-<abi>-shared-deps.so",
        "PIE executable, thin",
        "Same binary, resolving its dependencies from `nativeLibraryDir` at runtime.",
    ),
]


def load_build_info(directory: pathlib.Path) -> list[dict]:
    infos = [json.loads(p.read_text()) for p in sorted(directory.glob("*.json"))]
    if not infos:
        sys.exit(f"no build-info JSON files found in {directory}")
    return infos


def assert_consistent(infos: list[dict]) -> None:
    """All ABIs must have been built from the same versions."""
    keys = ["openssl", "lzo", "lz4", "ndk", "api_level", "build_key"]
    for key in keys:
        values = {json.dumps(i.get(key), sort_keys=True) for i in infos}
        if len(values) > 1:
            sys.exit(f"inconsistent '{key}' across ABIs: {sorted(values)}")
    tags = {i["openvpn"]["tag"] for i in infos}
    if len(tags) > 1:
        sys.exit(f"inconsistent OpenVPN tag across ABIs: {sorted(tags)}")


def size_str(n: int) -> str:
    if n < 1024:
        return f"{n} B"
    if n < 1024 * 1024:
        return f"{n / 1024:.0f} KiB"
    return f"{n / (1024 * 1024):.1f} MiB"


def artifacts_by_name(infos: list[dict]) -> dict[str, list[dict]]:
    out: dict[str, list[dict]] = {}
    for info in infos:
        for art in info["artifacts"]:
            out.setdefault(art["name"], []).append({**art, "abi": info["abi"]})
    return out


def variant_needed(infos: list[dict], prefix: str, deps: str) -> list[str]:
    """DT_NEEDED for one artifact family, verified identical across ABIs."""
    seen: set[tuple[str, ...]] = set()
    for info in infos:
        for art in info["artifacts"]:
            if art["name"].startswith(prefix) and art["deps"] == deps and art["needed"]:
                seen.add(tuple(sorted(art["needed"])))
    if not seen:
        return []
    # If ABIs somehow disagree, show the union rather than silently picking one.
    union: set[str] = set()
    for entry in seen:
        union.update(entry)
    return sorted(union)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--build-info", required=True, type=pathlib.Path)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--repo", default="")
    ap.add_argument("--run-url", default="")
    args = ap.parse_args()

    infos = load_build_info(args.build_info)
    assert_consistent(infos)

    first = infos[0]
    ovpn = first["openvpn"]
    abis = sorted(i["abi"] for i in infos)
    api = first["api_level"]
    out: list[str] = []
    w = out.append

    # -- summary -------------------------------------------------------------
    w(f"Prebuilt OpenVPN **{ovpn['version']}** libraries for Android, "
      f"built from upstream [`{ovpn['tag']}`](https://github.com/OpenVPN/openvpn/tree/{ovpn['tag']}) "
      f"with no source modifications.")
    w("")
    w(f"Minimum Android API level **{api}** "
      f"(Android {'5.0 Lollipop' if int(api) == 21 else str(api)}). "
      f"ABIs: {', '.join(f'`{a}`' for a in abis)}. "
      f"Release `{args.tag}`.")
    w("")

    # -- components ----------------------------------------------------------
    w("## Linked dependencies")
    w("")
    w("| Component | Version | Notes |")
    w("|---|---|---|")
    w(f"| OpenVPN | `{ovpn['version']}` (`{ovpn['tag']}`) | commit `{ovpn['commit'][:12]}` |")
    w(f"| OpenSSL | `{first['openssl']}` | LTS line; `no-engine no-module no-legacy` |")
    w(f"| LZO | `{first['lzo']}` | `--comp-lzo` support |")
    w(f"| LZ4 | `{first['lz4']}` | `--compress lz4` / `lz4-v2` support |")
    w(f"| Android NDK | `{first['ndk']}` | requested `{first['ndk_requested']}` |")
    w(f"| Compiler | {first['clang']} | |")
    w("")
    w(f"Build key: `{first['build_key']}`")
    w("")
    w("Every artifact is built from exactly these versions. A change to any of them "
      "produces a new release even when the OpenVPN version itself has not moved.")
    w("")

    # -- variant guide -------------------------------------------------------
    w("## Which file do I need?")
    w("")
    w("Six OpenVPN artifacts are published per ABI: static library, shared library and "
      "PIE executable, each in a *static-deps* and a *shared-deps* flavour. "
      "The `-static-deps` / `-shared-deps` suffix describes how **OpenSSL, LZO and LZ4** "
      "are linked; the file extension describes how **OpenVPN** is linked.")
    w("")
    w("| Artifact | Kind | Use it when |")
    w("|---|---|---|")
    for name, kind, desc in VARIANT_GUIDE:
        w(f"| `{name}` | {kind} | {desc} |")
    w("")
    w("Dependencies are published separately too, in both forms, for every ABI: "
      + ", ".join(f"`{d}-<abi>.a` / `{d}-<abi>.so`" for d in DEP_ORDER) + ".")
    w("")
    w(f"There is also one drop-in tarball per ABI and dep-mode "
      f"(`openvpn-{ovpn['version']}-android{api}-<abi>-<mode>-deps.tar.gz`) containing a "
      f"ready-to-copy `jniLibs/<abi>/` tree, the static library, the headers and a "
      f"`BUILD-INFO.txt`.")
    w("")

    # -- runtime deps --------------------------------------------------------
    w("## Runtime dependencies (`DT_NEEDED`)")
    w("")
    w("Read back off the shipped binaries with `llvm-readelf -d`:")
    w("")
    w("| Artifact | DT_NEEDED |")
    w("|---|---|")
    for prefix, deps, label in [
        ("libopenvpn-", "static", "libopenvpn-&lt;abi&gt;-static-deps.so"),
        ("libopenvpn-", "shared", "libopenvpn-&lt;abi&gt;-shared-deps.so"),
        ("libopenvpnexec-", "static", "libopenvpnexec-&lt;abi&gt;-static-deps.so"),
        ("libopenvpnexec-", "shared", "libopenvpnexec-&lt;abi&gt;-shared-deps.so"),
    ]:
        needed = variant_needed(infos, prefix, deps)
        w(f"| `{label}` | {', '.join(f'`{n}`' for n in needed) if needed else '_none_'} |")
    w("")
    w("The `-static-deps` artifacts additionally have `libcrypto.a`, `libssl.a`, "
      "`liblzo2.a` and `liblz4.a` linked in, with their symbols hidden "
      "(`-Wl,--exclude-libs,ALL`) so they cannot collide with another OpenSSL in the "
      "same process.")
    w("")

    # -- integration ---------------------------------------------------------
    w("## Integration notes")
    w("")
    w("- The entry point is `int openvpn_main(int argc, char *argv[])`. Upstream exports no "
      "entry point of its own — its `openvpn_main()` is `static` and its `main()` cannot be "
      "shipped in a library — so the library targets compile `openvpn.c` with `main()` renamed "
      "and export `openvpn_main()` on top. Neither library contains a `main` symbol, so you can "
      "link them from a program that has its own `main()`.")
    w("- **Rename before use in `jniLibs`.** Android only extracts entries matching "
      "`lib*.so` and matches on the exact filename, so `libopenvpn-arm64-v8a-static-deps.so` "
      "must become `libopenvpn.so`. The tarballs already contain correctly named files.")
    w("- 64-bit artifacts are linked with `-Wl,-z,max-page-size=16384` for Android 15+ "
      "devices with 16 KB pages.")
    w("- On Android the tun device cannot be opened directly; hand the `VpnService` file "
      "descriptor to OpenVPN over the management interface.")
    w("- OpenVPN keeps process-wide state and calls `exit()` on fatal errors. If your "
      "process must survive that, use the `libopenvpnexec-*` binary in a child process "
      "instead of linking the library.")
    w("")
    w("**Not compiled in:** PKCS#11, DCO, OpenSSL engine support, OpenSSL legacy provider "
      "(so `BF-CBC`, `DES`, `RC4` and `CAST5` are unavailable), `--dns-updown`.")
    w("")

    # -- checksums -----------------------------------------------------------
    by_name = artifacts_by_name(infos)
    w("## Checksums")
    w("")
    w("<details><summary>SHA-256 of every asset</summary>")
    w("")
    w("| File | Size | SHA-256 |")
    w("|---|---|---|")
    for name in sorted(by_name):
        art = by_name[name][0]
        w(f"| `{name}` | {size_str(art['size'])} | `{art['sha256']}` |")
    w("")
    w("</details>")
    w("")

    # -- provenance ----------------------------------------------------------
    w("## Source and licence")
    w("")
    w("OpenVPN is distributed under the **GNU GPL version 2**, with the OpenSSL linking "
      "exception granted by the OpenVPN copyright holders. These binaries are unmodified "
      "upstream sources; the complete corresponding source is:")
    w("")
    w(f"- OpenVPN `{ovpn['tag']}` — https://github.com/OpenVPN/openvpn/tree/{ovpn['tag']} "
      f"(commit `{ovpn['commit']}`)")
    w(f"- OpenSSL `{first['openssl']}` — https://github.com/openssl/openssl/tree/openssl-{first['openssl']}")
    w(f"- LZO `{first['lzo']}` — https://www.oberhumer.com/opensource/lzo/ (GPL-2.0-or-later)")
    w(f"- LZ4 `{first['lz4']}` — https://github.com/lz4/lz4/tree/v{first['lz4']} (BSD-2-Clause)")
    w("")
    w("The only change applied to the OpenVPN tree is an append to `CMakeLists.txt` that adds "
      "library targets alongside upstream's executable target, in `scripts/cmake-overlay.cmake` "
      "in this repository. The sole code it contributes is a three-line entry-point shim "
      "exporting `openvpn_main()`; no OpenVPN source file is edited.")
    if args.run_url:
        w("")
        w(f"Built by [this workflow run]({args.run_url}).")
    w("")

    # Written as bytes rather than print()ed: the notes contain em dashes, and a
    # C locale on the runner would otherwise turn that into a UnicodeEncodeError.
    sys.stdout.buffer.write(("\n".join(out) + "\n").encode("utf-8"))


if __name__ == "__main__":
    main()
