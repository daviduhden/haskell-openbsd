# Haskell OpenBSD

Haskell bindings for the security facilities that are unique to
[OpenBSD](https://www.openbsd.org/), plus the privilege-separation
practice common to OpenBSD daemons.

The package can only be built and used on OpenBSD; it fails at build
time on other platforms.

## What's implemented

| Facility | Module | Restricts/provides |
| --- | --- | --- |
| `pledge(2)` | `System.OpenBSD.Pledge` | which system operations the process may perform |
| `unveil(2)` | `System.OpenBSD.Unveil` | which filesystem paths the process may access |
| Privilege dropping | `System.OpenBSD.Privileges` | the credentials (UID/GID/groups) of the process |
| `chroot(2)` | `System.OpenBSD.Chroot` | the filesystem root for pathname resolution |
| `issetugid(2)`, `getpeereid(3)` | `System.OpenBSD.Credentials` | set-ID execution taint; Unix-domain peer credentials |
| `setproctitle(3)`, daemonization | `System.OpenBSD.Process` | process titles; background detachment |
| `arc4random(3)`, `getentropy(2)` | `System.OpenBSD.Random` | cryptographically strong random values; kernel entropy |
| `getrtable(2)`/`setrtable(2)` | `System.OpenBSD.Rtable` | routing domains |
| `mimmutable(2)`, `explicit_bzero(3)`, `freezero(3)`, `timingsafe_bcmp(3)`, `timingsafe_memcmp(3)` | `System.OpenBSD.Memory` | memory protection, secure erasure, constant-time comparison |
| `crypt_checkpass(3)`, `crypt_newhash(3)`, `bcrypt_pbkdf(3)` | `System.OpenBSD.Authentication` | password hashing and key derivation |
| `closefrom(2)`, `getdtablecount(2)`, `setprogname(3)` | `System.OpenBSD.Process` | descriptor hygiene; program name |

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

### Forking and pledge

`forkProcess` copies only the forking thread into the child and is not
well supported with multiple capabilities (`+RTS -N`), although
`-threaded` with one capability is supported (see the `unix`
documentation).  A `forkProcess` child should therefore be followed by
`exec` as directly as possible, and pledge policy for executed
children should be configured in the parent:

```haskell
pledgeChild [Stdio]            -- exec ceiling, set in the parent

pid <- forkProcess $
    executeFile "/path/to/child" False [] Nothing
```

OpenBSD preserves execpromises across `fork(2)` and applies them when
the descendant executes a new image, so the child needs no pledge
call at all in the post-fork window.  `System.OpenBSD.Process`
provides ready-made helpers with pre-fork validation of every string:

```haskell
pid <- forkExec        "/path/to/child" False [] Nothing
pid <- forkExecPledged [Stdio] "/path/to/child" False [] Nothing
```

`execPledged` replaces the current image under an exec promise
ceiling instead of forking.

```text
parent
    -> pledgeChild childPromises
    -> forkProcess
    -> executeFile immediately
    -> the new image starts under childPromises
```

Do not apply major current-process pledge reductions from arbitrary
Haskell code in the post-fork/pre-exec child: reducing the current
promise set to an extreme restriction makes the kernel unwind sibling
runtime threads while cleaning up unveil state, and the resumed
runtime threads then perform syscalls forbidden by the fresh
restriction, so the kernel aborts the process.  In particular
`pledge []` — the `_exit(2)`-only state — is a valid OpenBSD
operation whose native semantics are verified by a standalone C probe,
but it cannot be used from a live threaded Haskell child.

Setting execpromises in the parent is monotonic and affects every
future exec from that process and its descendants: use it when those
descendants share a common promise ceiling.  Independent per-child
policies require a fresh-process boundary (for example a minimal
native launcher), which this package does not provide.

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

## chroot

`System.OpenBSD.Chroot` binds `chroot(2)`:

```haskell
import System.OpenBSD

main :: IO ()
main = do
    -- privileged initialization (bind sockets, open logs, ...)
    enterChroot "/var/empty"
    -- absolute paths now resolve inside the new root
```

* `chroot path` is the exact native call: it changes pathname
  resolution but does not change the working directory.
* `enterChroot path` performs `chroot(path)` then `chdir("/")` as one
  masked, fail-closed transition — the recommended security-sensitive
  form.

`chroot(2)` is not a complete sandbox: it requires root, does not
replace `pledge`/`unveil`/privilege dropping, cannot confine an
already-root process reliably, and open descriptors keep access to
resources outside the new root.  It is not permitted at all once the
process has called `pledge(2)`, so chroot before pledging.

## Credentials

`System.OpenBSD.Credentials` provides two credential queries:

```haskell
tainted <- isSetugid        -- issetugid(2)
(euid, egid) <- getPeerCredentials socket  -- getpeereid(3)
```

`isSetugid` reports whether the process image was tainted by
set-ID execution (or by exec while real/effective/saved IDs were
mismatched).  It is not a UID/GID comparison and is not affected by
later ID changes.

`getPeerCredentials` returns the effective UID and GID of the peer of
a connected Unix-domain `SOCK_STREAM`/`SOCK_SEQPACKET` socket.  It
supplies facts for an authorization decision; it is not
authentication by itself.  Like `chroot`, it is not covered by any
pledge promise and must be used before pledging.

## Process titles and daemonization

`System.OpenBSD.Process`:

```haskell
setProcessTitle "mydaemon: serving"  -- setproctitle(3)
resetProcessTitle                   -- setproctitle(NULL)
daemonize serve                     -- run "serve" detached from the terminal
```

Titles are passed to `setproctitle(3)` only as data through a fixed
`"%s"` format literal in the package's C shim; user-controlled strings
can never become format strings.  Titles are limited to 2048 bytes and
work under the `stdio` pledge promise.

`daemonize` takes the daemon body as its argument: the body runs in
the newly detached child process and the original process exits,
exactly like `daemon(3)`.  It deliberately does not call libc
`daemon(3)`: that function forks and exits the parent with a raw C
`_exit(2)` behind the GHC runtime, which is unsafe, particularly with
the threaded runtime.  Instead it reproduces the behavior with the
runtime-aware `forkProcess` and exits the original process cleanly.
`daemonizeWith` takes positive `DaemonOptions`
(`changeDirectoryToRoot`, `redirectStandardStreams`) instead of the
inverted `nochdir`/`noclose` integers.  Daemonization is explicit and
never automatic: foreground operation (preferred under modern service
supervision such as rc.d) is fully supported.

## Random

`System.OpenBSD.Random` binds the `arc4random(3)` family:

```haskell
value <- arc4Random           -- arc4random()
bytes <- arc4RandomBytes 32   -- arc4random_buf()
die   <- arc4RandomUniform 6  -- arc4random_uniform(6)
```

`arc4RandomUniform` calls the native unbiased function — prefer it
over `arc4Random \`mod\` n`.  The API name is historical; the
implementation is ChaCha20-based and re-seeded from `getentropy(2)`.
It works inside `chroot(2)` and under the `stdio` pledge promise.

## Scope

`haskell-openbsd` provides Haskell interfaces to useful OpenBSD-specific
system and library facilities that are not adequately covered by the
standard Haskell POSIX ecosystem.  General POSIX functionality remains
the responsibility of packages such as `unix` and is reused rather
than rebound.  See the coverage table below for the audited API
surface and the precise reasons behind deferred facilities.

## API coverage

| OpenBSD facility | Haskell module | Status |
| --- | --- | --- |
| `pledge(2)` | `System.OpenBSD.Pledge` | supported (typed promises, NULL/empty distinction, execpromises) |
| `unveil(2)` | `System.OpenBSD.Unveil` | supported (rules, locking, empty permissions) |
| privilege dropping | `System.OpenBSD.Privileges` | supported (daemon sequence, verification, masking) |
| `chroot(2)` | `System.OpenBSD.Chroot` | supported (`chroot`, masked `enterChroot`) |
| `issetugid(2)`, `getpeereid(3)` | `System.OpenBSD.Credentials` | supported |
| `setproctitle(3)`, `getprogname(3)`/`setprogname(3)` | `System.OpenBSD.Process` | supported (format-safe) |
| `daemon(3)` | `System.OpenBSD.Process` | supported (runtime-safe `daemonize`) |
| fork/exec + execpromises | `System.OpenBSD.Process` | supported (`forkExec`, `forkExecPledged`, `execPledged`) |
| `closefrom(2)`, `getdtablecount(2)` | `System.OpenBSD.Process` | supported |
| `arc4random(3)` family | `System.OpenBSD.Random` | supported |
| `getentropy(2)` | `System.OpenBSD.Random` | supported (low-level, native 256-byte limit) |
| `getrtable(2)`/`setrtable(2)` | `System.OpenBSD.Rtable` | supported |
| `mimmutable(2)` | `System.OpenBSD.Memory` | supported |
| `explicit_bzero(3)`, `freezero(3)` | `System.OpenBSD.Memory` | supported (explicit native memory only) |
| `timingsafe_bcmp(3)`, `timingsafe_memcmp(3)` | `System.OpenBSD.Memory` | supported |
| `crypt_checkpass(3)`, `crypt_newhash(3)` | `System.OpenBSD.Authentication` | supported |
| `bcrypt_pbkdf(3)` | `System.OpenBSD.Authentication` | supported |
| `imsg(3)`/`ibuf(3)` | — | deferred: substantial IPC abstraction with descriptor-passing ownership; cannot be runtime-validated before shipping; `unix` `sendmsg`/`recvmsg` with `SCM_RIGHTS` covers the primitive mechanism |
| `kqueue(2)`/`kevent(2)` | — | deferred: general event facility with existing ecosystem packages; not OpenBSD-security-specific |
| `setusercontext(3)`/`login_cap(3)` | — | deferred: login-session policy framework; the daemon privilege-drop sequence remains the supported policy |
| `pidfile(3)` | — | deferred: the only public OpenBSD API is atexit-based with `/var/run`-only naming, weaker than a few lines of explicit `unix` code |
| `posix_spawn(3)` | — | deferred: no demonstrated need over the validated fork/exec architecture; a binding would need a file-actions abstraction for no gain |
| `sysctl(2)` | — | deferred: broad surface better handled per use case |
| `fsync_range(2)`, `revoke(2)` | — | deferred: niche facilities with little demand from daemons |
| `getpwnam_shadow(3)` | — | deferred: verification via `cryptCheckpass` covers authentication; direct shadow reads are niche |
| `readpassphrase(3)` | — | deferred: interactive tty handling, marginal for daemons |
| `reallocarray(3)`/`recallocarray(3)`, `strlcpy(3)`/`strlcat(3)`, `strtonum(3)`, `fmt_scaled(3)`, `fparseln(3)`, `ohash(3)`, `getbsize(3)`, `opendev(3)` | — | not useful from Haskell: C allocation/parsing helpers with existing Haskell equivalents |
| `pinsyscalls(2)`, `kbind(2)`, `__tfork(2)`, `__thrsleep(2)`, `futex(2)`, `__get_tcb(2)`, `__pledge_open(2)`, `utrace(2)`, `syscall(2)` | — | internal kernel/libc interfaces, not application APIs |
| `skey(3)` | — | obsolete |

Facilities above are audited against OpenBSD 7.9 (stable target) and
OpenBSD-current.

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
* `cabal update`, `cabal build all`, `cabal test all`, `cabal check`
  and `cabal sdist`, executed as an unprivileged `builder` user, and
  the generated source distribution is itself built and tested;
  Haddock is currently skipped there because the OpenBSD-packaged GHC
  9.10 / Haddock toolchain crashes while building this package's
  documentation on both amd64 and arm64;
* runs the test suite again as `root`, and fails if the
  privilege-dropping tests are skipped or do not pass, so the real,
  effective and saved UID/GID drops and the inability to regain root
  are exercised against the actual kernel.

Only OpenBSD 7.9 is exercised in CI (amd64 and arm64).  The workflow
configuration itself is statically validated locally with `yamllint
--strict` and `zizmor` (pedantic persona); every third-party action is
pinned to a full commit SHA and GitHub token permissions are minimal.
