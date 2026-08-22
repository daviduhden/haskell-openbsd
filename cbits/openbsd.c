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

/*
 * Restrict the process to the empty promise set and exit.  Used by
 * the test suite to verify that pledge("") allows only _exit(2).
 *
 * All signals are blocked first: between the pledge call and the
 * exit, no Haskell code runs, and blocking signals ensures that no
 * runtime signal handler (for example the threaded runtime's ticker,
 * which performs stdio-class syscalls) can fire and violate the fresh
 * restriction.
 */
void
hs_pledge_empty_then_exit(void)
{
	sigset_t set;

	sigfillset(&set);
	(void)sigprocmask(SIG_BLOCK, &set, NULL);

	if (pledge("", NULL) == -1)
		_exit(3);
	_exit(0);
}
