/*
 * openvpn-lib.h -- public entry point of the prebuilt OpenVPN libraries.
 *
 * Part of https://github.com/<owner>/openvpn-android-prebuilt. The libraries
 * themselves are unmodified OpenVPN 2.x, built for Android; this header only
 * declares the entry point so callers do not have to pull in OpenVPN's private
 * headers (which require config.h and a matching set of -D flags).
 *
 * OpenVPN is distributed under the GNU GPL version 2; see NOTICE.md.
 */

#ifndef OPENVPN_LIB_H
#define OPENVPN_LIB_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Run OpenVPN. This is the entry point of the openvpn program.
 *
 * Upstream has no exported entry point of its own: src/openvpn/openvpn.c
 * declares its openvpn_main() `static`, and its main() cannot be shipped in a
 * library because it would collide with yours. The prebuilt libraries therefore
 * compile that translation unit with main() renamed and export this function on
 * top of it. It is the same code path the openvpn binary takes.
 *
 * argv follows the usual convention: argv[0] is the program name and argv[argc]
 * must be NULL. Options are the same ones you would pass on the command line,
 * e.g. { "openvpn", "--config", "/data/.../profile.ovpn", "--management", ... }.
 *
 * Notes for in-process use (linking libopenvpn.so / libopenvpn.a):
 *
 *   - OpenVPN keeps process-wide state and installs signal handlers. It is not
 *     re-entrant and not safe to run more than once concurrently in a process.
 *   - Fatal errors call exit(), which will take your whole process down. If
 *     that is unacceptable, use the libopenvpnexec-*.so PIE binary instead and
 *     run it as a separate process, driving it over the management interface.
 *   - On Android the tun device cannot be opened directly; the VpnService file
 *     descriptor has to be handed over through the management interface
 *     (--management-external-... / "needok"). See the ics-openvpn project for a
 *     complete working example of that protocol.
 *
 * @return the process exit code OpenVPN would have returned.
 */
int openvpn_main(int argc, char *argv[]);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* OPENVPN_LIB_H */
