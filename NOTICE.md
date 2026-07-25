# Notices and attribution

The binaries published by this repository are built from unmodified upstream sources. Each release
records the exact versions and commit it was built from; the summary below explains the licence
terms those binaries carry.

## OpenVPN — GPL-2.0-only, with an OpenSSL linking exception

Copyright © OpenVPN Inc.
https://github.com/OpenVPN/openvpn

OpenVPN is distributed under the GNU General Public License version 2. The OpenVPN copyright holders
grant an additional permission to link with the OpenSSL library, which is what makes the binaries
here distributable:

> Special exception for linking OpenVPN with OpenSSL: In addition, as a special exception, the
> copyright holders give permission to link the code of this program with the OpenSSL library, and
> distribute linked combinations including the two.

Because the published artifacts are covered by the GPL, anyone receiving them is entitled to the
corresponding source. That obligation is met by the links in every release body, which point at the
exact upstream tag and commit, together with this repository, which contains the complete build
recipe. The only change applied to the OpenVPN tree is `scripts/cmake-overlay.cmake`, appended to
`CMakeLists.txt` to add library targets alongside upstream's executable target; it adds no code.

## OpenSSL — Apache-2.0

Copyright © The OpenSSL Project Authors.
https://github.com/openssl/openssl

OpenSSL 3.x is licensed under the Apache License 2.0.

## LZO — GPL-2.0-or-later

Copyright © Markus F.X.J. Oberhumer.
https://www.oberhumer.com/opensource/lzo/

LZO is distributed under the GNU General Public License version 2 or later. Commercial licences are
available from the author for use in non-GPL software.

## LZ4 — BSD-2-Clause

Copyright © Yann Collet.
https://github.com/lz4/lz4

The LZ4 library (`lib/`, which is what is linked here) is BSD-2-Clause licensed.

## Android NDK

Binaries are cross-compiled with the Android NDK toolchain. The NDK's runtime support pieces linked
into these artifacts are covered by their respective Android Open Source Project licences
(Apache-2.0 for AOSP components, plus the LLVM licences for compiler runtime).

## This repository's build scripts — MIT

The workflows, shell scripts and the CMake overlay in this repository are released under the MIT
licence. They do not affect the licensing of the binaries they produce, which is determined by the
upstream projects listed above.
