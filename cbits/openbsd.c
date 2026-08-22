/*
 * C shims for the openbsd package.
 *
 * These wrappers exist to make OpenBSD libc interfaces safe for
 * Haskell callers:
 *
 * - setproctitle(3) is variadic printf-style.  User-controlled
 *   strings must never be passed as the format argument, so the
 *   shim passes a fixed "%s" literal and the caller's string as the
 *   data argument.  No format string ever crosses this boundary.
 *
 * Everything else in the package is bound directly via foreign
 * imports in System.OpenBSD.Internal.
 */

#include <signal.h>
#include <stdlib.h>
#include <unistd.h>

#if !defined(__OpenBSD__)
#error "haskell-openbsd requires OpenBSD"
#endif

void
hs_setproctitle(const char *title)
{
	setproctitle("%s", title);
}

void
hs_resetproctitle(void)
{
	setproctitle(NULL);
}
