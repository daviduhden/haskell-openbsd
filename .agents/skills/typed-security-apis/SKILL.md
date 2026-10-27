---
name: typed-security-apis
description: Use when changing the typed policy layer for pledge, unveil, privilege dropping, chroot, credentials, or routing domains, including Promise/Permission/Account/Rtable conversions and security-ordering rules.
---

# Typed security APIs

## When to use

Activate this skill when a change touches:

- `Promise`, `promiseName`, `promiseFromName`, `pledge`,
  `pledgeChild`, `pledgeBoth`, or `pledgeParts`;
- `Permission`, `permissionString`, `unveil`, `unveilPaths`,
  `lockUnveil`, or `unveilAndLock`;
- `Account`, `GroupPolicy`, `dropPrivileges*`, `setResUserID`,
  `setResGroupID`, `getResUserID`, `getResGroupID`, or `initGroups`;
- `chroot`, `enterChroot`, `isSetugid`, `getPeerCredentials`,
  `Rtable`, `getRtable`, or `setRtable`;
- the documented ordering of these operations in `System.OpenBSD`,
  the README, or tests.

These APIs change process-wide authority.  A type error is cheap; a
wrong policy can silently leave a daemon privileged or abort it with
`SIGABRT`.

## Typed models and conversions

| Typed value | Native representation | Conversion rule |
| --- | --- | --- |
| `Promise` | promise name in a space-separated `const char *` | `promiseName`; parse with `promiseFromName` |
| `[Promise]` | string for `pledge`/execpromises | `unwords . map promiseName`; `[]` becomes `""` |
| `Maybe [Promise]` | `NULL` or `""` | `Nothing` = `NULL`; `Just []` = `""` |
| `Permission` | one of `r`, `w`, `x`, `c` | `permissionString`; `[]` becomes `""` |
| `Account` | name plus UID/GID | `accountByName`; constructors are exported for known numeric IDs |
| `GroupPolicy` | `setgroups` vs `initgroups` | `PrimaryGroupOnly` or `Initgroups` |
| `Rtable` | C `int` | reject values that do not fit a C `int` before the call |

`Show` is for diagnostics.  Native serialization must go through the
dedicated function.  The derived `Show` for `Promise` and `Permission`
contains Haskell constructor names, which the kernel does not accept.

## Procedure for a typed policy change

1. **Start from the native contract.**  Identify the syscall's exact
   argument shape and error behavior.  `pledge(2)` takes two `char *`
   values; `unveil(2)` takes a path and a permission string;
   `setresuid(2)` uses `-1` for "leave unchanged"; `setrtable(2)` takes
   a C `int`.
2. **Model only what the kernel accepts.**  The `Promise` list follows
   the OpenBSD 7.9 kernel table (35 entries); `tmppath` was removed and
   is deliberately absent.  With `OPENBSD_80`, `exec` and `error` are
   absent from the typed inventory.  Do not add a constructor that the
   target kernel rejects.
3. **Keep the distinction between "no change" and "empty".**  For
   `pledgeParts`, `Nothing` is `NULL` and `Just []` is the empty
   string.  The empty current-promise set is an `_exit(2)`-only state;
   it is valid natively but generally unusable from a live GHC RTS.
4. **Preserve monotonicity.**  `pledge` and `pledgeChild` can only
   reduce their respective sets.  An increase raises `EPERM` unless the
   legacy `error` promise suppresses it.  Do not add a "restore" or
   bracket combinator.
5. **Keep exec promises separate.**  `pledgeChild` changes only future
   exec promises; it does not restrict the caller.  Exec promises do
   not grant execution permission, are inherited across `fork(2)`, and
   are a ceiling for descendants, not a universal sandbox.
6. **Order privileged initialization correctly.**  A safe daemon
   sequence is: resolve accounts and open resources while privileged;
   `chroot`/`enterChroot`; `unveil` and lock; `pledge` with `id` and
   `getpw` still present; drop privileges; pledge again without `id`
   and `getpw`; enter the service loop.  `chroot` and `getpeereid` are
   not covered by any promise and must happen before pledging.
7. **Make partial failure explicit.**  `unveilPaths` and
   `unveilAndLock` are not atomic: earlier rules remain installed if a
   later call fails.  `dropPrivileges*` and `enterChroot` use `mask_`,
   which only defers asynchronous exceptions on the calling thread; a
   partial failure is fatal for the process.  Do not catch and continue.
8. **Check the resulting identity.**  The high-level drop verifies
   real/effective/saved UIDs and GIDs and the supplementary groups.
   `dropPrivileges`/`dropPrivilegesWith` reject the `root` account by
   name; `dropPrivilegesTo` accepts an explicit `Account` for the rare
   intentional no-op.
9. **Document the policy.**  State whether the function restricts the
   caller or future children, which promise is required, whether it is
   reversible, and what the caller must do after a failure.  Keep the
   README table and module Haddocks in sync.

## Validation

Static checks:

- every exported constructor has a `promiseName`/`permissionString`
  case and appears in the round-trip test;
- `promiseFromName (promiseName p) == Just p` for every constructor;
- `OPENBSD_80` guards are consistent in the type, serializer, README,
  and tests;
- no new typed name is accepted that the kernel rejects;
- `git diff --check`, `git status --short`, and a careful diff review.

Build and runtime checks (OpenBSD only):

```sh
cabal test all --test-show-details=direct
cabal test all -fopenbsd80 --test-show-details=direct
```

The privileged ordering tests run only as root and are part of the CI
VM.  Do not run them on a workstation.

## Common problems

- **`tmppath`.**  It was removed from OpenBSD; `pledge(2)` returns
  `EINVAL`.  Use `rpath wpath cpath` plus an `unveil` rule instead.
- **`exec` on OpenBSD 8.0.**  The `openbsd80` flag removes the legacy
  `exec` and `error` promises from the typed API.  That does not change
  kernel behavior: a process pledged without execution permission
  cannot `execve(2)`.  Setting exec promises does not grant it.
- **Treating `[]` as `NULL`.**  This silently changes "leave the value
  alone" into "restrict to nothing".  Use `Nothing` for `NULL`.
- **Dropping to root by name.**  It leaves the process fully
  privileged while looking successful; the name-based API rejects it.
- **Calling `unveil` after a pledge that removed `unveil`.**  The call
  fails with `EPERM`; install and lock unveil first.
- **Assuming `unveilAndLock` is atomic.**  A failed rule leaves the
  previous rules installed and the configuration unlocked.
- **Calling `chroot` after `pledge`.**  No promise covers `chroot(2)`;
  do it before pledging.  `chroot` alone is not a sandbox.
- **Using peer credentials as authentication.**  `getpeereid(3)` gives
  facts (effective UID/GID), not an authorization decision.
- **Assuming `setrtable` is monotonic.**  It is a process-wide setting,
  not a restriction; a privileged process can change it again.
- **Assuming `mask_` makes a transition atomic.**  It does not
  synchronize other threads or make separate syscalls one operation.

## Maintenance & Continuous Learning

When this skill is used to modify this repository, review it after the implementation and before reporting completion. Update this skill when the procedure, tools, configuration, validation commands, safety constraints, or project assumptions in its area have changed. Add reusable knowledge discovered during the work and correct guidance that proved inaccurate. Keep examples, paths, and validation steps current; exclude one-off details that will not help a future task.

Also review the governing `AGENTS.md`, related skills, and any specialized agent instructions. Synchronize cross-references and avoid conflicting or duplicated procedures. Run the repository maintenance validator (`perl scripts/check-agent-sync.pl --base BASE --head HEAD`, or its documented local default) and the validations above where applicable. Report which instructions were reviewed/updated and the actual validation result. A failed or skipped synchronization means the task is incomplete. For a task that changes agent/skill policy itself, one full final coherence review is sufficient; rerun checks only after correcting a detected issue.

## References

- `src/System/OpenBSD/Pledge.hs`
- `src/System/OpenBSD/Unveil.hs`
- `src/System/OpenBSD/Privileges.hs`
- `src/System/OpenBSD/Chroot.hs`
- `src/System/OpenBSD/Credentials.hs`
- `src/System/OpenBSD/Rtable.hs`
- `src/System/OpenBSD.hs` (recommended initialization order)
- `README.md` sections "pledge", "unveil", "Privilege dropping",
  "Interaction between pledge and privilege dropping", and "API
  coverage"
