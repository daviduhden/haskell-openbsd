/*
 * Execpledge probe for the fork + immediate-exec integration test.
 *
 * Started by a Haskell parent that forks with forkProcess, sets
 * execpromises to "stdio" in the child, and immediately execs this
 * program.  The fresh process image begins pledged with exactly those
 * promises.
 *
 *   no arguments: perform only stdio-class operations (getpid, a
 *                 write to the inherited stdout) and exit 0;
 *
 *   "violate":    attempt open(2) on a path, which requires rpath
 *                 and is therefore a pledge violation: the kernel
 *                 kills the process with SIGABRT.
 *
 * The parent inspects the process status to verify both behaviors.
 */

#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	if (argc > 1 && argv[1][0] == 'v') {
		/* requires "rpath"; forbidden under "stdio" */
		if (open("/etc/hostname", O_RDONLY) == -1)
			(void)fprintf(stderr, "open failed\n");
		return 1;
	}

	(void)getpid();
	(void)printf("execpledge-ok\n");
	return 0;
}
