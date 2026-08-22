# Haskell OpenBSD

Haskell bindings for the security facilities that are unique to
[OpenBSD](https://www.openbsd.org/), plus the privilege-separation
practice common to OpenBSD daemons.

The package can only be built and used on OpenBSD; it fails at build
time on other platforms.

## What's implemented

| Facility | Module | Restricts |
| --- | --- | --- |
| `pledge(2)` | `System.OpenBSD.Pledge` | which system operations the process may perform |
| `unveil(2)` | `System.OpenBSD.Unveil` | which filesystem paths the process may access |
| Privilege dropping | `System.OpenBSD.Privileges` | the credentials (UID/GID/groups) of the process |

These mechanisms restrict *different dimensions* of process authority
and are normally complementary: a typical OpenBSD daemon uses all
three.  They are not interchangeable.

## pledge

`pledge(2)` partitions the POSIX feature set into subsystems called
*promises*.  After a `pledge()` call, using an operation outside the
declared promises aborts the process with an uncatchable `SIGABRT`.

```haskell
import System.OpenBSD

main :: IO ()
main = do
    -- privileged initialization (bind sockets, open logs, ...)
    pledge [Stdio, Rpath, Inet, Dns]
    -- main loop: any other operation now aborts the process
```

Calls are monotonic: a later call may only *reduce* the promise set.
An attempt to increase it raises an `IOError` carrying `EPERM`.

### Exec promises

The second argument of `pledge(2)` restricts programs executed later
via `execve(2)`:

```haskell
-- children may only use stdio; we keep stdio, rpath, proc and exec
pledgeBoth [Stdio, Rpath, Proc, Exec] [Stdio]
```

`pledgeChild [Stdio]` sets exec promises only.  A child that is
started with exec promises in place runs pledged from its first
instruction, unless the executed file has setuid/setgid bits, in which
case execution is blocked with `EACCES`.

### NULL vs empty string

`pledgeParts` is the full typed interface to
`int pledge(const char *promises, const char *execpromises)`:

| Argument | Meaning |
| --- | --- |
| `Nothing` | `NULL` — do not change this value |
| `Just []` | `""` — restrict to `_exit(2)` only |
| `Just ps` | set this value to `ps` |

`pledge`, `pledgeChild` and `pledgeBoth` are conveniences over
`pledgeParts`.

### Notes

* The `Error` promise changes violations from aborting the process to
  returning `ENOSYS`; promise increases are then silently ignored.
* The `tmppath` promise has been removed from OpenBSD (`pledge(2)`
  returns `EINVAL` for it) and is deliberately not exposed.  Use
  `rpath wpath cpath` plus `unveil "/tmp" "rwc"` instead.
* The `Promise` enumeration matches the promise list accepted by the
  kernel on OpenBSD 7.9 and OpenBSD-current.

## unveil

`unveil(2)` restricts the filesystem view of the process.  The first
call removes visibility of the entire filesystem except for explicitly
unveiled paths.

```haskell
import System.OpenBSD

setup :: IO ()
setup = unveilAndLock
    [ ("/",               [Read, Execute])
    , ("/var/www",        [Read])
    , ("/var/log/myapp",  [Read, Write, Create])
    ]
```

* `unveil path perms` adds a single rule.
* `unveilPaths rules` adds several rules.
* `lockUnveil` is `unveil(NULL, NULL)`: it permanently locks the
  configuration.  OpenBSD strongly recommends locking unveil once all
  rules are installed; after locking, further `unveil` calls fail with
  `EPERM`.
* `unveilAndLock rules` installs the rules and locks.

Permissions are `r`, `w`, `x`, `c` (`Read`, `Write`, `Execute`,
`Create`).  The empty permission list is valid and unveils a path
without permitting any operation on it.

If the process is pledged, `unveil(2)` itself requires the `unveil`
promise.  Conversely, a `pledge(2)` call that removes all
path-accessing promises destroys the unveil state.

## Privilege dropping

`System.OpenBSD.Privileges` implements the privilege-dropping sequence
used by OpenBSD base-system daemons such as httpd(8), unwind(8) and
smtpd(8):

1. resolve the target account while still privileged;
2. reduce supplementary groups while still privileged;
3. drop the real, effective and saved GIDs (`setresgid(2)`);
4. drop the real, effective and saved UIDs last (`setresuid(2)`).

This ordering matters: `setgroups(2)` requires privilege, and once
root is gone the saved IDs must not allow the process to regain it.

```haskell
import System.OpenBSD

main :: IO ()
main = do
    -- privileged initialization
    dropPrivileges "_mydaemon"
    -- irreversibly unprivileged from here on
```

`dropPrivileges` resolves the account to its UID and primary GID and
drops all three UID and GID flavors to those values.  By default it
replaces the supplementary group list with *only* the primary GID
(`setgroups(1, &pw_gid)`), which is the restrictive daemon-style
behavior and never accidentally retains root's supplementary groups;
this policy is called `PrimaryGroupOnly`.

`dropPrivilegesWith Initgroups` adopts all supplementary groups of the
account via `initgroups(3)` instead; this is login-style behavior for
processes that genuinely need the account's group memberships.
`accountByName` resolves a user to an `Account`, and
`dropPrivilegesTo` applies either policy to an account resolved
earlier — useful when the account must be looked up before `chroot(2)`
hides the password database.

After the drop, the library verifies that the real, effective and
saved UIDs/GIDs and the supplementary groups are the expected values
and raises an exception otherwise.  The whole transition runs with
Haskell asynchronous exceptions masked, so another thread cannot
interrupt it halfway through.  Each failing step raises an `IOError`
carrying the underlying `errno` (typically `EPERM` if the process is
not root); after a partial failure the process may already have
reduced privileges, so callers must treat the exception as fatal for
the current process.

### Why not setusercontext(3)?

`setusercontext(3)` applies a full login class from `login.conf(5)`
(resource limits, umask, priority, environment, `initgroups(3)`, ...).
OpenBSD uses it in login programs such as login(1) and su(1); native
daemons deliberately do not use it for privilege separation — they
perform the explicit sequence above.  This library therefore binds the
explicit sequence and leaves login-session management to
`setusercontext(3)` users.

## Interaction between pledge and privilege dropping

The `id` pledge promise covers the identity-changing calls
(`setuid`, `seteuid`, `setreuid`, `setresuid`, `setgid`, `setegid`,
`setregid`, `setresgid`, `setgroups`), and the `getpw` promise is
needed to resolve account names.  An application that pledges before
dropping privileges must keep `id` (and `getpw` for name resolution)
until the drop is complete, then pledge again without them:

```text
start privileged
    |
    +-- perform privileged initialization
    |
    +-- pledge including "id" if pledge is already enabled
    |
    +-- drop privileges
    |
    +-- pledge again without "id"
    |
    +-- continue as unprivileged process
```

```haskell
pledge [Stdio, Rpath, Getpw, Id]
dropPrivileges "_mydaemon"
pledge [Stdio, Rpath]
```

This library never adds promises behind the application's back.

## Complete example

A daemon combining all three mechanisms:

```haskell
import System.OpenBSD

main :: IO ()
main = do
    -- 1. privileged initialization: bind port 80, open log files,
    --    parse configuration, resolve the target account

    -- 2. restrict the filesystem view
    unveilAndLock
        [ ("/",              [Read, Execute])
        , ("/var/www",       [Read])
        , ("/var/log/myapp", [Read, Write, Create])
        ]

    -- 3. restrict system calls, keeping what the drop still needs
    pledge [Stdio, Rpath, Inet, Unix, Getpw, Id]

    -- 4. drop credentials irreversibly
    dropPrivileges "_mydaemon"

    -- 5. remove the identity-changing promises
    pledge [Stdio, Rpath, Inet, Unix]

    -- 6. main service loop
    serve

serve :: IO ()
serve = pure ()
```

## Errors

* Every failing call raises an `IOError` whose `errno` is the error
  reported by the kernel (`EPERM`, `EINVAL`, `ENOENT`, ...).
* `pledge(2)` violations do not raise Haskell exceptions: the kernel
  aborts the process with an uncatchable `SIGABRT`.
* `unveil(2)` denials surface later as `EACCES`/`ENOENT` errors at the
  filesystem call site.
* Strings that cross the FFI boundary (account names, unveil paths)
  must not contain embedded `NUL` bytes; the library rejects them
  explicitly instead of letting C string conversion truncate them.

## Out of scope

This package deliberately stays small.  Adjacent OpenBSD facilities
that are not exposed (and may be added separately later if justified)
include `chroot(2)`, `issetugid(2)`, `getpeereid(2)`,
`setproctitle(3)`, `arc4random(3)`, and daemonization helpers.  The
`unix` package already covers general POSIX functionality.

## Supported OpenBSD versions

* Targets OpenBSD 7.9 and OpenBSD-current.
* The `Promise` list was verified against the kernel's
  `pledgereq` table in `sys/kern/kern_pledge.c` (rev 1.356 for 7.9,
  1.360 for current): 35 promises, `tmppath` removed, `disklabel`,
  `drm` and `vmm` included.
* Unveil permissions verified against `sys/kern/kern_unveil.c`:
  `r`, `w`, `x`, `c`, with the empty permission set valid.
* Built and tested with GHC 9.10 / Cabal 3.x as shipped on OpenBSD.

## Testing

```
cabal test
```

Runtime tests exercise the real kernel interfaces in forked child
processes.  Tests that require root (privilege dropping, the
`id`-promise lifecycle) are skipped cleanly when the test runner is
not root.  Some pledge tests expect the child process to die with
`SIGABRT`, which is normal and part of the test.

## Continuous integration

GitHub Actions boots a real OpenBSD 7.9 virtual machine
(`vmactions/openbsd-vm`), on both amd64 and arm64, for every push to
`main` and every pull request, and runs the full validation inside
it:

* installs the native OpenBSD Haskell toolchain (GHC and
  cabal-install) with `pkg_add`;
* `cabal update`, `cabal build all`, `cabal test all`, `cabal check`,
  `cabal haddock all` and `cabal sdist`, executed as an unprivileged
  `builder` user, and the generated source distribution is itself
  built and tested;
* runs the test suite again as `root`, and fails if the
  privilege-dropping tests are skipped or do not pass, so the real,
  effective and saved UID/GID drops and the inability to regain root
  are exercised against the actual kernel.

Only OpenBSD 7.9 is exercised in CI (amd64 and arm64).  The workflow
configuration itself is statically validated locally with `yamllint
--strict` and `zizmor` (pedantic persona); every third-party action is
pinned to a full commit SHA and GitHub token permissions are minimal.
