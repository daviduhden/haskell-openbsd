---
name: ffi-unit-and-integration-tests
description: Use when adding or repairing tests for the openbsd package, including the custom harness, forked-child assertions, native C fixture probes, root-only cases, expected SIGABRT, and CI test commands.
---

# FFI unit and integration tests

## When to use

Activate this skill when a change touches:

- `test/Spec.hs` or `test/fixtures/*.c`;
- a new library function that needs coverage;
- a test that must run as root, in a chroot, or in a forked child;
- expected signal/exit-status behavior;
- the CI test invocation or the sdist test.

The suite is a custom sequential harness.  It is not Hspec, Tasty, or
HUnit, and there is no automatic test discovery: tests are string/action
pairs in `pureTests` and `runtimeTests`.

## Test model

| Layer | What it proves | Where it runs |
| --- | --- | --- |
| Pure tests | serialization, NUL/negative-length rejection | any host that can build the package |
| Runtime tests | real kernel behavior in forked children | OpenBSD only |
| C fixture probes | native behavior that must not run under the GHC RTS | OpenBSD only |
| Root tests | privilege drop, chroot, set-ID taint | disposable OpenBSD VM only |
| CI | both Cabal flag states, sdist round-trip, root rerun | OpenBSD 8.0 amd64/arm64 |

The default suite has 75 tests; the `openbsd80` build adds
`getExecPathTest` for 76.  Five tests use `requireRoot` and print
`SKIP ... (requires root privileges)` when not root.  A `Skip` does not
fail the run, but CI fails if any of those five are skipped in its root
phase.

The harness prints exactly:

```text
ok   <name>
SKIP <name> (<reason>)
FAIL <name>: <reason>
```

`ok` has three spaces after it; `SKIP` and `FAIL` have one.  CI greps
for exact `ok   ...` lines for the privileged tests, so renaming one of
those tests without updating the workflow breaks CI.

## Procedure for adding a test

1. **Classify it.**  Use a pure test for type conversions, validation,
   and error construction.  Use a runtime test when the kernel, a
   pledge/unveil rule, a descriptor, a process, or a native library is
   involved.
2. **Name it with an existing prefix.**  The suite uses `pledge:`,
   `unveil:`, `priv:`, `chroot:`, `cred:`, `proc:`, `random:`,
   `rtable:`, `memory:`, and `auth:`.  Keep the name factual; do not
   put a promise in the name that the assertion does not check.
3. **Choose the isolation wrapper.**
   - `inChild label action` forks, runs `action`, writes a failure
     message to `/tmp/openbsd-test-<label>-<pid>.log`, and reports the
     child's exit status.  The runner removes that log after reading it.
   - `expectSignal signal action` forks and requires the child to die
     from the exact signal, normally `sigABRT`.
   - A manual `forkProcess` is appropriate for descriptor checks,
     title observation, daemonization, and the set-ID exec probe.
   - `requireRoot` wraps a test that genuinely needs root.
4. **Assert the errno you promise.**  `expectIOError` accepts any
   `IOException` and is only for validation tests.  Use `assertErrno`
   for a named `EPERM`, `EINVAL`, `ENOENT`, or `EBADF`; otherwise the
   test name overstates the check.  `assertErrno` is also usable inside
   `inChild`.
5. **Compile fixtures explicitly.**  Fixtures are compiled with
   `/usr/bin/cc -std=c23 -Wall -Wextra -Werror`.  The execpledge probe
   is also compiled with `-static`: a dynamically linked binary needs
   `rpath` for `ld.so`, which the `stdio` exec ceiling forbids.
6. **Validate before forking.**  For fork/exec tests, reject embedded
   NUL bytes in every argument/environment string in the parent.  The
   child should reach exec immediately.
7. **Clean up with `bracket` or `finally`.**  The suite uses
   `/tmp` names that include the runner PID; remove binaries, logs,
   chroot directories, and forbidden-file probes on success and
   failure.  Do not rely on normal control flow, and do not add
   exception-safe cleanup that hides the original test failure.
8. **Register the test.**  Add it to `pureTests` or `runtimeTests`.
   Add the `OPENBSD_80` guard only if the symbol itself is gated.  Do
   not use `openbsd_HOST_OS` as a feature flag.
9. **Update CI only when necessary.**  The workflow already runs both
   flag states and the root rerun.  If you add a privileged test, add
   its exact `ok` line to the CI grep list; if you rename one, update
   the same list.

## Fixtures

| File | Purpose |
| --- | --- |
| `test/fixtures/pledge-empty-probe.c` | native `fork`/`pledge("", NULL)`/`_exit(0)` probe with distinct failure exit codes |
| `test/fixtures/execpledge-probe.c` | static target for allowed exec and `rpath`-violation (`SIGABRT`) cases |

Both are listed in `openbsd.cabal` under `extra-source-files`; keep
that list current or the sdist round-trip fails.  Fixture paths are
relative (`test/fixtures/...`), so the test process must run with the
package root as its working directory.  `cabal test` and CI do this;
a direct binary invocation from another directory does not.

## Validation

Static checks (any host):

- list every test name and check for duplicates;
- check the `OPENBSD_80` guards in the test list and test body;
- check `pureTests ++ runtimeTests` still covers the new name;
- inspect fixture compiler flags and `extra-source-files`;
- `git diff --check`, `git status --short`.

OpenBSD checks:

```sh
cabal build all
cabal test all --test-show-details=direct
cabal test all -fopenbsd80 --test-show-details=direct
```

Privileged CI-style run (only in the disposable VM):

```sh
TESTBIN=$(cabal list-bin -fopenbsd80 test:openbsd-tests | tail -n 1)
"$TESTBIN"
```

The CI root job also fails on `SKIP .*requires root` and checks five
exact `ok   ...` lines.  Do not run this on a workstation.  The suite
is sequential by design; per-PID probe names reduce collisions, but a
single test binary at a time is still assumed.

## Common problems

- **Expecting a normal exit for a pledge violation.**  The kernel sends
  `SIGABRT`; `Terminated signal` with `sigABRT` is the correct result.
- **Using `pledge []` in a `forkProcess` child.**  That is the
  unsupported threaded-RTS transition.  Use the native
  `pledge-empty-probe.c` for the exit-only state and a normal non-empty
  promise set for violation tests.
- **Testing a chroot child with a `/tmp` log.**  After `enterChroot`,
  the `/tmp/...` failure log is outside the new root.  The child falls
  back to stderr; the parent reports a generic failure if no log is
  readable.  Keep the child's assertions simple and explicit.
- **Leaking probes.**  Compiling in the child and then exec'ing it means
  the child cannot remove it.  Compile in the runner under `bracket`
  (as `withExecPledgeProbe` does) so cleanup runs after exec/exit.
- **Calling `removeFile` after `unveil` locking.**  The child may no
  longer have `cpath`; the parent must clean up shared `/tmp` paths.
- **Assuming a timeout reaps the child.**  `timeout` around a pipe read
  does not replace `getProcessStatus`.  Use `waitForProcess`, which
  bounds the wait, sends `SIGKILL` on timeout, and reaps the child.
  Keep test bodies finite and avoid leaving a child blocked on a pipe.
- **Using `isPermissionError` for a test named EPERM.**  It accepts
  both `EACCES` and `EPERM`.  Use `assertErrno ePERM`.
- **Relying on environment variables.**  The suite does not read them.
  It does rely on fixed paths (`/tmp`, `/usr/bin/cc`, `/bin/ps`,
  `/dev/null`, `/etc/hostname`), the `nobody` and `root` accounts, and
  static linking support.
- **Running tests from the wrong directory.**  The fixtures are opened
  relatively; run `cabal test` from the package root.
- **Editing `dist-newstyle` test logs.**  They are build output, not
  source.

## Known coverage gaps

- `freeZeroTest` is a smoke test.  The erasure cannot be observed after
  `freezero(3)` has freed the buffer without committing a use-after-free.
- The `EPERM` branch of `setRtable` for a configured non-zero routing
  domain is not exercised: it needs a configured domain and root.  The
  test accepts a successful switch when domain 1 exists and checks
  `EINVAL`/`EPERM` for an unconfigured or forbidden domain.
- Haddock is not built in CI because the OpenBSD-packaged GHC 9.10 /
  Haddock toolchain crashes on this package.  Do not treat that as a
  documentation test failure.
- The suite assumes the package root is the working directory, a
  writable `/tmp`, `/usr/bin/cc`, `/bin/ps`, `/dev/null`,
  `/etc/hostname`, and the `nobody` and `root` accounts.

## Maintenance & Continuous Learning

When this skill is used to modify this repository, review it after the implementation and before reporting completion. Update this skill when the procedure, tools, configuration, validation commands, safety constraints, or project assumptions in its area have changed. Add reusable knowledge discovered during the work and correct guidance that proved inaccurate. Keep examples, paths, and validation steps current; exclude one-off details that will not help a future task.

Also review the governing `AGENTS.md`, related skills, and any specialized agent instructions. Synchronize cross-references and avoid conflicting or duplicated procedures. Run the repository maintenance validator (`python3 scripts/validate-agent-knowledge.py --scope range --base BASE --head HEAD`, or its documented local default) and the validations above where applicable. Report which instructions were reviewed/updated and the actual validation result. A failed or skipped synchronization means the task is incomplete. For a task that changes agent/skill policy itself, one full final coherence review is sufficient; rerun checks only after correcting a detected issue.

## References

- `test/Spec.hs`
- `test/fixtures/pledge-empty-probe.c`
- `test/fixtures/execpledge-probe.c`
- `openbsd.cabal` (`test-suite openbsd-tests`,
  `extra-source-files`)
- `.github/workflows/ci.yml`
- `README.md` section "Testing" and "Continuous integration"
