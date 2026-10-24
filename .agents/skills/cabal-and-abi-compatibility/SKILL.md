---
name: cabal-and-abi-compatibility
description: Use when changing openbsd.cabal, Cabal flags, exposed modules, language baselines, dependency bounds, OpenBSD 7.9/8.0 gating, package versioning, or source-distribution contents.
---

# Cabal and ABI compatibility

## When to use

Activate this skill when a change touches:

- `openbsd.cabal` (`version`, `flag`, `exposed-modules`,
  `other-modules`, `c-sources`, `cc-options`, `extra-libraries`,
  `build-depends`, `default-language`, `ghc-options`,
  `extra-source-files`);
- the `openbsd80` flag or `OPENBSD_80` CPP guards;
- a new exported module or symbol whose availability depends on the
  OpenBSD version;
- GHC/Cabal/base/unix/bytestring bounds;
- `cabal check`, `cabal sdist`, or the sdist round-trip;
- a public API removal or type change that needs a version decision.

## Compatibility model

| Dimension | Current contract |
| --- | --- |
| Package | `openbsd`; see `version:` in `openbsd.cabal` |
| Cabal file | `cabal-version: 2.4` |
| Haskell | `GHC2024`, `base >= 4.20 && < 5`; GHC 9.10+ |
| C | ISO C23 (`-std=c23`), no GNU dialect |
| OpenBSD default | 7.9-compatible build |
| OpenBSD `openbsd80` | 8.0+; adds `getexecpath(3)` and removes `exec`/`error` from `Promise` |
| `unix` | `>= 2.7 && < 2.9` |
| `bytestring` | `>= 0.10 && < 0.13` |
| Native libraries | `util` (for `bcrypt_pbkdf(3)`) |

The package is OpenBSD-only by construction; `cbits/openbsd.c` and
`src/System/OpenBSD/Internal.hs` contain `#error` guards.  There is no
`buildable: False` fallback and no Linux build to keep green.

Two CPP controls are easy to confuse:

- `OPENBSD_80` is defined by the Cabal flag.  It gates the 8.0-only
  symbol and the reduced promise inventory.
- `openbsd_HOST_OS` is defined by GHC for the host OS.  It selects the
  full runtime test list; it is not the feature flag.

Both the library and the test suite receive `-DOPENBSD_80` from the
flag.  If you add a gated symbol, update the import, export list,
implementation, README, and tests together.

## Procedure for an API or ABI change

1. **Find the native availability.**  Check the OpenBSD manual page,
   header, and libc symbol.  `getexecpath(3)` first appeared in 8.0 and
   is absent from 7.9's libc; that is why it is gated.  Do not assume a
   symbol exists because it exists in `-current`.
2. **Decide the package version before editing exports.**  This
   package follows the Package Versioning Policy:
   - adding a module/function/constructor: minor or major according to
     the existing scheme;
   - removing or renaming an exported function/constructor, or
     changing an exported type: major bump.
   Record the decision in the change description; the repository has no
   changelog to update.
3. **Keep the default build 7.9-compatible.**  Put 8.0-only imports
   and definitions behind `#ifdef OPENBSD_80`.  Do not reference an
   8.0 symbol unconditionally: it will fail to link on 7.9.
4. **Update the Cabal file in one pass.**  Add the module to
   `exposed-modules` (or `other-modules` if internal); add C sources and
   `extra-source-files`; keep `default-language: GHC2024`; keep
   `cc-options: -std=c23 -Wall -Wextra`; add `extra-libraries` only for
   a real native library.
5. **Add the flag to every component that needs it.**  A symbol gated
   in the library but not in the test suite produces link failures;
   `openbsd.cabal` currently sets `cpp-options: -DOPENBSD_80` for both.
6. **Keep the sdist complete.**  Test fixtures are listed in
   `extra-source-files`; a new fixture must be added there.  The CI
   extracts the tarball and rebuilds it, so a missing fixture fails the
   sdist round-trip even if the working tree passes.
7. **Check the ABI, not just the Haskell type.**  Compare `foreign
   import` signatures with the OpenBSD headers: `off_t` vs `CInt`,
   `size_t` vs `Int`, `uid_t`/`gid_t` wrappers, and return types.
   `closefrom(2)` returns `int`; `mmap(2)` takes `off_t`.
8. **Update documentation.**  The README "What's implemented",
   "API coverage", "Supported OpenBSD versions", and "Language
   standards" tables are part of the compatibility contract.  State
   which flag enables a gated feature and which OS version it requires.
9. **Do not claim Haddock coverage in CI.**  The workflow deliberately
   skips Haddock because the OpenBSD-packaged GHC 9.10/Haddock
   toolchain crashes on this package.  That is a known CI limitation,
   not a reason to remove Haddock comments.

## Validation

Static checks (any host):

- `cabal check` (if Cabal is available; it does not need OpenBSD);
- inspect `openbsd.cabal` for module/flag/source consistency;
- grep for `OPENBSD_80` and `openbsd_HOST_OS` and verify each use;
- confirm every new file is in `extra-source-files` or a source dir;
- `git diff --check`, `git status --short`.

Build checks (OpenBSD only):

```sh
cabal build all
cabal build all -fopenbsd80
cabal check
cabal sdist
```

Full CI-equivalent checks:

```sh
cabal test all --test-show-details=direct
cabal test all -fopenbsd80 --test-show-details=direct
```

Then extract the sdist and build/test it in the default flag state, as
the workflow does.  On a non-OpenBSD host, static inspection cannot
prove that the symbol exists or that the ABI matches.

## Common problems

- **Unconditional 8.0 symbol.**  A direct `foreign import` of
  `getexecpath` breaks the 7.9 build; the import, export, and call must
  all be under `OPENBSD_80`.
- **Flag not propagated to tests.**  The test suite has its own
  `if flag(openbsd80)` block.  Adding a gated test without it makes the
  default build fail.
- **Wrong Cabal field.**  `cpp-options` passes `-D` to GHC's CPP;
  `cc-options` passes flags to the C compiler.  `-std=c23` belongs in
  `cc-options`; `-DOPENBSD_80` belongs in `cpp-options`.
- **Missing `extra-libraries`.**  `bcrypt_pbkdf(3)` is in `libutil`;
  without `extra-libraries: util`, linking fails on OpenBSD.
- **Missing fixture in the sdist.**  `test/fixtures/*.c` must remain in
  `extra-source-files`; the sdist test compiles them from the extracted
  tree.
- **Breaking change without a version bump.**  Removing an exported
  function (for example the old bytestring-based `immutableBytes`) or
  changing an exported type is a major-version change under the PVP.
- **Assuming `base` 4.20 is enough for GHC2024.**  GHC 9.10 is the
  first compiler with GHC2024; keep `tested-with: GHC == 9.10.*` and
  the `base >= 4.20` bound aligned.
- **Assuming C23 implies POSIX.**  OpenBSD exposes POSIX/BSD
  interfaces independently of the ISO C standard; do not add a GNU
  dialect to reach them.
- **Editing generated `dist-newstyle` files.**  They are build output,
  not source.  Change `openbsd.cabal` instead.

## References

- `openbsd.cabal`
- `README.md` sections "Supported OpenBSD versions", "Language
  standards", "Testing", and "Continuous integration"
- `.github/workflows/ci.yml`
- `src/System/OpenBSD/Internal.hs`
- `cbits/openbsd.c`
- `test/fixtures/`
