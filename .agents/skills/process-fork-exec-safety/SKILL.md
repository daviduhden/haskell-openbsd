---
name: process-fork-exec-safety
description: Use when changing fork/exec helpers, daemonization, process titles, descriptor hygiene, or getexecpath in the openbsd package, especially where GHC runtime, pledge state, and signal behavior interact.
---

# Process, fork, and exec safety

## When to use

Activate this skill when a change touches:

- `System.OpenBSD.Process` (`setProcessTitle`, `resetProcessTitle`,
  `execPledged`, `forkExec`, `forkExecPledged`, `closeFrom`,
  `getDescriptorCount`, `setProgramName`, `getProgramName`,
  `getExecPath`, `DaemonOptions`, `daemonize`, `daemonizeWith`);
- `System.OpenBSD.Pledge.pledgeChild` or the exec-promise lifecycle;
- `forkProcess`/`executeFile` call sites in the library or tests;
- daemonization, session creation, standard-descriptor redirection;
- signal/exit-status expectations around `SIGABRT` or `_exit(2)`.

Read `typed-security-apis` for the policy model and `AGENTS.md` for
project-wide rules.

## The supported fork/exec architecture

OpenBSD preserves exec promises across `fork(2)` and applies them when a
descendant executes a new image.  The supported pattern is therefore:

```text
prepare everything in the parent
    -> pledgeChild childPromises     (exec ceiling, parent-side)
    -> forkProcess
    -> executeFile immediately       (the child does nothing else)
    -> the new image starts under childPromises
```

Do not add a pledge call, allocation, logging, or other meaningful
Haskell work in the post-fork/pre-exec child.  `forkExec` and
`forkExecPledged` implement this pattern and validate every string in
the caller before forking.

`execPledged` is the same idea without a fork: it validates arguments,
calls `pledgeChild`, and replaces the current image.  It changes the
caller's exec promises permanently, so it is only suitable when the
caller is finished and the next image may inherit that ceiling.

## Procedure for a process-related change

1. **Separate parent work from child work.**  Resolve paths, open
   files, build argument lists, and validate NUL bytes before the
   fork.  The child should reach `execve(2)` as directly as possible.
2. **Keep current and exec promises distinct.**  `pledgeChild` only
   constrains future execs.  A process that has pledged itself still
   needs its current promises for `fork`/`exec` (generally `proc` and
   `exec`).  Setting exec promises does not grant execution permission.
3. **Do not reduce the current promise set to `[]` after
   `forkProcess`.**  The `_exit(2)`-only state is valid OpenBSD, but
   from a live threaded GHC child the pledge transition can unwind
   sibling RTS threads; their resumed syscalls violate the new set and
   the kernel aborts the process.  Test that state with the native
   `test/fixtures/pledge-empty-probe.c`, not from a Haskell child.
4. **Respect the runtime caveat.**  `forkProcess` copies only the
   current thread.  Upstream GHC documents that it is not well
   supported with multiple capabilities (`+RTS -N`), although
   `-threaded` with one capability is supported.  The test suite is
   built with `-threaded` to exercise this.
5. **Make failure visible.**  `forkProcess` failures propagate in the
   parent.  If `executeFile` fails in the child, the child must not
   continue normal Haskell service code; it should terminate with a
   nonzero status.  Do not add a wrapper that hides a failed exec.
6. **Handle descriptors deliberately.**  `closeFrom` propagates
   `EBADF` when the argument is beyond the descriptor table.  Callers
   that want "close everything above the standard descriptors" must
   ensure the argument itself is open or explicitly handle that case.
   After `closeFrom`, do not use the affected `Handle`s.
7. **Preserve the daemonization contract.**  `daemonize` uses
   `forkProcess`, `setsid`, optional `chdir("/")`, optional
   `/dev/null` redirection, runs the body in the child, and exits the
   original process with `_exit(2)`.  It deliberately avoids libc
   `daemon(3)`, whose raw fork/exit is unsafe behind the GHC runtime.
   Errors after the fork are reported by the child, not by
   `daemonize`.
8. **Keep titles format-safe.**  `setProcessTitle` passes data through
   the fixed `"%s"` literal in `cbits/openbsd.c`.  Titles are limited
   to 2048 bytes and work under `stdio`.  Never pass user data as a
   format string.
9. **Keep the program-name lifetime intact.**  `setprogname(3)` stores
   the pointer it is given.  `setProgramName` allocates with
   `newCString` and intentionally never frees it; `withCString` would
   dangle.
10. **Gate `getExecPath` correctly.**  `getexecpath(3)` first appeared
    in OpenBSD 8.0 and exists only under `OPENBSD_80`.  It throws
    `ENOENT` when the kernel cannot determine the path.

## Validation

Static checks:

- inspect every `forkProcess` body for work that should be in the
  parent;
- verify `pledgeChild` is called before the fork, not in the child;
- verify no `pledge []` appears in a post-fork child;
- verify all strings crossing exec are validated before the fork;
- check `OPENBSD_80` guards in the export list, implementation, cabal
  file, and tests;
- `git diff --check` and `git status --short`.

OpenBSD-only checks:

```sh
cabal test all --test-show-details=direct
cabal test all -fopenbsd80 --test-show-details=direct
```

The suite includes allowed and forbidden exec cases.  The forbidden
case must die from `SIGABRT`; that is expected.  Do not run the
privileged or chroot tests outside the disposable CI VM.

## Common problems

- **Doing work in the child.**  Lazy evaluation, allocation, logging,
  or a second fork in the post-fork window can interact badly with the
  copied runtime and with a fresh pledge restriction.
- **Reducing current promises after fork.**  `pledge []` from a
  threaded Haskell child can abort the process for RTS reasons, not
  because `pledge` is broken.
- **Assuming exec promises are per-child.**  They are monotonic and
  inherited.  `forkExecPledged` also reduces the caller's exec
  promises, so a later independent child may be capped unexpectedly.
  Independent per-child policies need a fresh process boundary, which
  this package does not provide.
- **Assuming exec promises grant execution.**  On kernels that require
  the `exec` promise, an unpledged process may execute; a process
  pledged without it cannot.  The openbsd80 API cannot request the
  removed legacy promise.
- **Treating `closefrom` as a no-op.**  `EBADF` beyond the table is
  surfaced, not ignored.
- **Reusing standard descriptors after redirection.**  `daemonizeWith`
  assumes 0/1/2 are the standard streams; if the caller repurposed
  them, pass `redirectStandardStreams = False` and manage them
  yourself.
- **Expecting `daemonize` to report child errors.**  It returns after
  the parent exits; failures in `setsid` or redirection happen in the
  daemon child.
- **Using `setproctitle` with a format string.**  The C shim prevents
  this; do not bypass it.
- **Freeing the program-name buffer.**  It is referenced by libc for
  the process lifetime.

## References

- `src/System/OpenBSD/Process.hs`
- `src/System/OpenBSD/Pledge.hs`
- `src/System/OpenBSD/Internal.hs`
- `cbits/openbsd.c`
- `test/fixtures/pledge-empty-probe.c`
- `test/fixtures/execpledge-probe.c`
- `test/Spec.hs` (fork/exec, title, closefrom, daemonize tests)
- `README.md` sections "Forking and pledge", "Process titles and
  daemonization", and "Testing"
