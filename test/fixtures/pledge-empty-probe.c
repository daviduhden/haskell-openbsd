/*
 * Native regression probe for the _exit-only pledge state.
 *
 * OpenBSD defines pledge("", NULL) as the state in which only
 * _exit(2) may be called.  This probe verifies that behavior with
 * plain fork(2), entirely outside the GHC runtime:
 *
 *   1. fork();
 *   2. child: pledge("", NULL), then _exit(0);
 *   3. parent: waitpid(2) and strict status inspection.
 *
 * The same process then applies pledge("", NULL) to itself directly
 * and calls _exit(0), covering the non-forked case.
 *
 * This probe deliberately does NOT run under the GHC runtime: when a
 * threaded GHC child created by forkProcess reduces itself to the
 * _exit-only state, OpenBSD's pledge transition unwinds and resumes
 * sibling RTS threads, whose next syscall violates the fresh
 * restriction and kills the process with SIGABRT.  That is an
 * interaction between the kernel's thread handling and the runtime
 * environment, not a defect of pledge(2) itself.
 *
 * Exit statuses are distinct so each failure mode is identifiable:
 *
 *   3   child: pledge("", NULL) failed
 *   20  fork(2) failed
 *   30  waitpid(2) failed
 *   40  child killed by a signal (SIGABRT included)
 *   41  child exited with an unexpected status
 *   42  child wait status was neither exit nor signal
 */

#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

enum {
	PROBE_CHILD_PLEDGE_FAILED = 3,
	PROBE_FORK_FAILED = 20,
	PROBE_WAIT_FAILED = 30,
	PROBE_CHILD_SIGNALED = 40,
	PROBE_CHILD_EXIT = 41,
	PROBE_CHILD_WAIT_STATUS = 42
};

static void
child_probe(void)
{
	if (pledge("", NULL) == -1)
		_exit(PROBE_CHILD_PLEDGE_FAILED);
	_exit(0);
}

static int
forked_probe(void)
{
	pid_t pid;
	int status;

	pid = fork();
	if (pid == -1)
		return PROBE_FORK_FAILED;
	if (pid == 0)
		child_probe();

	if (waitpid(pid, &status, 0) == -1)
		return PROBE_WAIT_FAILED;

	if (WIFEXITED(status)) {
		if (WEXITSTATUS(status) == 0)
			return 0;
		if (WEXITSTATUS(status) == PROBE_CHILD_PLEDGE_FAILED) {
			(void)fprintf(stderr, "child: pledge(\"\") failed\n");
			return PROBE_CHILD_EXIT;
		}
		(void)fprintf(stderr, "child exited with status %d\n",
		    WEXITSTATUS(status));
		return PROBE_CHILD_EXIT;
	}
	if (WIFSIGNALED(status)) {
		(void)fprintf(stderr, "child killed by signal %d\n",
		    WTERMSIG(status));
		return PROBE_CHILD_SIGNALED;
	}
	(void)fprintf(stderr, "child wait status 0x%x\n", status);
	return PROBE_CHILD_WAIT_STATUS;
}

int
main(void)
{
	int error;

	error = forked_probe();
	if (error != 0)
		return error;

	/* Direct case: reduce this process to the _exit-only state and
	 * leave immediately. */
	if (pledge("", NULL) == -1)
		_exit(PROBE_CHILD_PLEDGE_FAILED);
	_exit(0);
}
