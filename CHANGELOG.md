# Revision history for openbsd

## 0.2.0.0 -- 2026-08-22

* Remove `TMPPATH`/`tmppath`: the promise was removed from OpenBSD
  (`pledge(2)` now returns `EINVAL` for it).
* Add the missing promises `disklabel`, `drm` and `vmm`; the
  enumeration now matches the kernel's `pledgereq` table.
* Export the `Permission(..)` constructors (previously inaccessible).
* Replace `Show`-based serialization with dedicated `promiseName` /
  `permissionString` conversions.
* Faithful `pledge(2)` interface: `pledgeRaw` supports `NULL` and
  empty-string semantics; add `pledgeBoth`.
* Unveil API: `unveil` adds a single rule; add `unveilPaths`,
  `lockUnveil` and `unveilAndLock` (replacing `unsafeUnveil` /
  `finishUnsafeUnveil`).
* New `System.OpenBSD.Privileges`: privilege dropping following the
  OpenBSD daemon sequence (`setgroups(2)` / `setresgid(2)` /
  `setresuid(2)`), with optional `initgroups(3)` policy and
  post-drop verification.
* Reorganize into `System.OpenBSD.Pledge`, `System.OpenBSD.Unveil`
  and `System.OpenBSD.Privileges`, re-exported from
  `System.OpenBSD`.
* Rewrite the README (fixing "Privilage dropping" typo) and document
  the interaction between privilege dropping and the `id` pledge.
* Modernize Cabal metadata (repository, bug tracker, bounds, `unix`
  dependency) and build with `-Wall`.
* Add a test suite covering serialization, pledge/unveil semantics
  and privilege dropping.
* Add GitHub Actions CI running the build and test suite inside a real
  OpenBSD 7.9 amd64 VM (vmactions/openbsd-vm): unprivileged build as a
  dedicated user, then the privilege-dropping tests executed as root,
  with the workflow failing if they are skipped.

## 0.1.0.0 -- YYYY-mm-dd

* First version. Released on an unsuspecting world.
