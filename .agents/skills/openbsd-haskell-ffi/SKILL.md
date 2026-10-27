---
name: openbsd-haskell-ffi
description: Use when editing or reviewing the raw Haskell/FFI boundary of the openbsd package, including foreign imports, C shims, CString marshaling, errno propagation, pointer ownership, and native ABI types.
---

# OpenBSD Haskell FFI

## When to use

Activate this skill when a change touches:

- `src/System/OpenBSD/Internal.hs` or any `foreign import`;
- `cbits/openbsd.c`;
- conversion between Haskell and C types (`CString`, `CInt`, `CSize`,
  `CUid`, `CGid`, `Fd`, `Ptr`, `Word32`, `COff`);
- `checkNoNul`, `withMaybeCString`, `throwErrnoIfMinus1_`,
  `throwErrnoPathIfMinus1_`, or `throwErrno`;
- memory allocation or lifetime across a native call.

Read `AGENTS.md` first for project-wide policy.

## Layout

| Path | Role |
| --- | --- |
| `src/System/OpenBSD/Internal.hs` | the only raw FFI library module; also the non-OpenBSD `#error` guard |
| `cbits/openbsd.c` | only the fixed-format `setproctitle(3)` shim |
| `src/System/OpenBSD/*.hs` | typed wrappers; no raw imports outside `Internal` |
| `openbsd.cabal` | `c-sources`, `cc-options`, `extra-libraries` |

The package is OpenBSD-only.  A non-OpenBSD build is supposed to fail
in `cbits/openbsd.c` (`#error "haskell-openbsd requires OpenBSD"`) and
in `Internal.hs` (`#error "haskell-openbsd requires OpenBSD: ..."`).
Do not make it silently build elsewhere.

## Procedure for a new or changed binding

1. **Find the native declaration.**  Confirm the prototype from the
   installed OpenBSD header or the manual page: return type, parameter
   types, `const`, ownership, and whether the function can fail and set
   `errno`.  Do not infer a signature from the function name.
2. **Choose the Haskell type deliberately.**
   - `CString` is a NUL-terminated `char *`; it is not a length-carrying
     buffer.
   - `CSize` is `size_t`; `CInt` is `int`; `COff` is `off_t`.
   - `CUid`/`CGid` are the `unix` package's `uid_t`/`gid_t` wrappers.
   - `Fd` is the `unix` file-descriptor newtype; it is passed by value.
   - `Ptr a` with an explicit length is used where the API is not a C
     string (for example `getentropy(2)` and `mimmutable(2)`).
3. **Keep `errno` meaningful.**  Call the native function and check the
   documented failure value with `throwErrnoIfMinus1_`,
   `throwErrnoPathIfMinus1_`, or an explicit `getErrno` branch.  Do not
   discard a return value that reports failure.  If a function returns
   a non-`-1` error (for example `crypt_checkpass(3)` returning
   `EACCES` for a mismatch), inspect `errno` and preserve the
   distinction between "false" and a real error.
4. **Validate before marshaling.**  Reject embedded NUL bytes with
   `checkNoNul` (for `String`) or the local byte-string check (for
   `ByteString`).  Reject negative lengths and values that cannot fit
   the native type instead of relying on `fromIntegral` truncation.
5. **Own every buffer.**  `withCString`, `useAsCString`, and
   `allocaBytes` keep a buffer alive only for the callback.  If C
   stores the pointer beyond the call, allocate with `newCString` or
   `mallocBytes` and document who frees it.  `setprogname(3)` is the
   existing example: its buffer is intentionally never freed.
6. **Wrap fallible allocations.**  Use `bracket` or `bracket_` so a
   native failure or asynchronous exception cannot leak a temporary
   buffer.  The random and authentication modules were fixed this way;
   follow that pattern.
7. **Pick the calling convention.**  Use `unsafe` only for short,
   non-blocking calls that cannot call back into Haskell and cannot
   throw while a pointer is live.  Use `safe` for calls whose duration
   is caller-controlled (`bcrypt_pbkdf`, `crypt_newhash`,
   `crypt_checkpass`) so the RTS can run other capabilities.  "Unsafe"
   is an FFI convention, not a security property.
8. **Guard version-specific symbols with CPP.**  `getexecpath(3)` is
   compiled only under `OPENBSD_80`; the import, export, and test must
   agree.  Do not put CPP in an export list without the project's
   `FOURMOLU_DISABLE` markers.
9. **Document the contract.**  State the native prototype, the failure
   value, whether `errno` is used, pointer lifetime, process-wide
   effects, and any pledge requirement in the Haddock comment.

## Validation

Static checks (safe on any host):

- compare the import against the header/prototype and the README;
- check every `foreign import` has a caller and every exported name is
  in the module export list;
- inspect `#ifdef OPENBSD_80` and `openbsd_HOST_OS` guards;
- run `git diff --check` and `git status --short`;
- confirm no new raw FFI appears in the library outside
  `System.OpenBSD.Internal` (the test suite has its own test-only
  imports).

Build checks (OpenBSD only):

```sh
cabal build all
cabal build all -fopenbsd80
```

Runtime checks: use the test suite on OpenBSD; see
`ffi-unit-and-integration-tests`.  Do not claim an FFI ABI check passed
from a Linux host.

## Common problems

- **Discarding a return value.**  `closefrom(2)` returns `int` and
  reports `EBADF` beyond the table; an `IO ()` import hides a real
  failure.  The current binding uses `CInt` and propagates the error.
- **Wrong integer width.**  `off_t` is not `CInt`; the test `mmap`
  binding was corrected to `COff`.  Use the same care for `time_t`,
  `size_t`, and `ssize_t`.
- **Dangling `CString`.**  `setprogname(3)` stores the pointer, so a
  `withCString` buffer would dangle.  Allocate and keep it alive.
- **NUL truncation.**  A Haskell `String` can contain `'\0'`; C sees a
  shorter string.  Reject it before the call.
- **`NULL` vs empty string.**  For `pledge(2)`, `Nothing` is `NULL`
  ("leave unchanged") and `Just []` is `""` ("restrict to nothing").
  `withMaybeCString` implements this; do not collapse the two.
- **Leaking on failure.**  A `mallocBytes` followed by a throwing
  native check leaks unless it is inside `bracket`.
- **`safe` vs `unsafe`.**  Putting a slow bcrypt call behind `unsafe`
  stalls the timer manager, GC, and other capabilities.
- **C shim creep.**  Do not add convenience C wrappers that hide
  syscall failures.  The only justified shim is the variadic-format
  boundary in `cbits/openbsd.c`.

## Maintenance & Continuous Learning

When this skill is used to modify this repository, review it after the implementation and before reporting completion. Update this skill when the procedure, tools, configuration, validation commands, safety constraints, or project assumptions in its area have changed. Add reusable knowledge discovered during the work and correct guidance that proved inaccurate. Keep examples, paths, and validation steps current; exclude one-off details that will not help a future task.

Also review the governing `AGENTS.md`, related skills, and any specialized agent instructions. Synchronize cross-references and avoid conflicting or duplicated procedures. Run the repository maintenance validator (`python3 scripts/check-agent-sync.py --base BASE --head HEAD`, or its documented local default) and the validations above where applicable. Report which instructions were reviewed/updated and the actual validation result. A failed or skipped synchronization means the task is incomplete. For a task that changes agent/skill policy itself, one full final coherence review is sufficient; rerun checks only after correcting a detected issue.

## References

- `src/System/OpenBSD/Internal.hs`
- `cbits/openbsd.c`
- `src/System/OpenBSD/Memory.hs`
- `src/System/OpenBSD/Authentication.hs`
- `src/System/OpenBSD/Random.hs`
- `test/Spec.hs` (raw `mmap`, `socketpair`, `_exit` test imports)
- `openbsd.cabal`
- `README.md` sections "Errors" and "Language standards"
