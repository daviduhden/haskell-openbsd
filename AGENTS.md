# Agent instructions

## What this repository is

`openbsd` is a Haskell package exposing OpenBSD-only security interfaces:
`pledge(2)`, `unveil(2)`, privilege dropping, `chroot(2)`, credentials,
process titles/daemonization, `arc4random(3)`, routing domains, secure
memory helpers, and password hashing.  It is not a portable POSIX
library and it does not build on Linux or macOS: both
`src/System/OpenBSD/Internal.hs` and `cbits/openbsd.c` stop with a
compiler error outside OpenBSD.

The package targets OpenBSD 7.9 by default and OpenBSD 8.0 when the
`openbsd80` Cabal flag is enabled.  The flag gates `getexecpath(3)` and
removes the legacy `exec` and `error` promises from the typed `Promise`
inventory.  GHC 9.10 or newer is required because the package uses
`GHC2024`; the C code and fixtures use ISO C23.

## Architecture

- `src/System/OpenBSD.hs` re-exports the public modules.
- `src/System/OpenBSD/*.hs` contains the typed, documented wrappers.
  `System.OpenBSD.Internal` is the only library module with raw
  `foreign import` declarations and is not exposed.
- `cbits/openbsd.c` exists only to hide the variadic
  `setproctitle(3)` format string behind a fixed `"%s"` literal.  Do
  not move general syscall wrappers into C.
- `test/Spec.hs` is a custom sequential test harness, not Hspec,
  Tasty, or HUnit.  `test/fixtures/*.c` are native probes compiled by
  the suite with `/usr/bin/cc`.
- `openbsd.cabal` is the source of truth for modules, flags, language
  baselines, warnings, and dependencies.  `.github/workflows/ci.yml`
  runs both flag states on real OpenBSD 8.0 VMs (amd64 and arm64).

## Conventions

- Write documentation and comments in US English.  Match the existing
  Haddock style: a `{- | Module ... Description ... -}` header on every
  public module, `{- | ... -}` on exported functions, and `-- ^` on
  record fields.
- Keep raw FFI in `System.OpenBSD.Internal`; public modules deal in
  typed values and documented policy.
- Convert typed values with explicit total functions (`promiseName`,
  `permissionString`).  `Show` is for diagnostics, never for native
  serialization.
- Reject embedded NUL bytes before a `CString` conversion
  (`checkNoNul`).  Reject negative lengths and values that do not fit
  the native type instead of silently truncating them.
- Use `throwErrnoIfMinus1_` or `throwErrnoPathIfMinus1_` for kernel
  failures so the original `errno` reaches the caller.  Do not add
  wrappers that turn a failed syscall into a successful no-op.
- Keep `{- FOURMOLU_DISABLE -}` / `{- FOURMOLU_ENABLE -}` around export
  lists that contain CPP directives.  The project follows Fourmolu 0.21
  formatting; there is no formatter configuration file to change.
- Do not rename public functions, remove constructors, or change
  exported types without treating the change as a package version and
  ABI decision.  See the Cabal/ABI skill.

## Commands that actually exist

There is no Makefile and no `make` target.  CI installs the native
toolchain with `pkg_add ghc cabal-install`; do not install packages on a
workstation.  On the disposable OpenBSD host:

```sh
cabal update
cabal build all
cabal test all --test-show-details=direct
cabal test all -fopenbsd80 --test-show-details=direct
cabal check
cabal sdist
cabal list-bin -fopenbsd80 test:openbsd-tests
```

The C23 baseline is checked in CI with:

```sh
cc --version
echo 'int main(void) { return 0; }' > /tmp/c23-probe.c
cc -std=c23 -Wall -Wextra -Werror -o /tmp/c23-probe /tmp/c23-probe.c
/tmp/c23-probe
```

The README also documents local static validation of the workflow with
`yamllint --strict` and `zizmor` (pedantic persona); those are not CI
jobs in the current workflow.  For documentation-only changes, use
`git diff --check` and `git status --short` to check whitespace and the
working tree.

## Security and testing policy

- Never run the privileged, `chroot`, or `pledge` tests on a developer
  workstation.  Use the disposable OpenBSD 8.0 VM; do not install
  packages, change system configuration, or perform destructive tests.
- `cabal test` exercises real kernel behavior.  Some tests expect a
  child to die from `SIGABRT`; that is a pass.  Five root-only tests
  cover privilege dropping, `Initgroups`, the `id` lifecycle,
  `enterChroot`, and set-ID exec; CI fails if they are skipped.
- Both Cabal flag states must be built and tested on OpenBSD 8.0.  The
  default state keeps 7.9 compatibility; `openbsd80` covers the
  8.0-only symbol and the reduced promise inventory.
- Static inspection on a non-OpenBSD host can verify types, call
  sites, CPP guards, paths, and documentation.  It cannot verify
  syscall behavior, FFI ABI, or C fixtures.  Do not claim a build or
  test passed unless it ran on OpenBSD.

Security invariants that must not be weakened:

- `pledge(2)` is monotonic and process-wide.  `pledgeParts Nothing`
  means `NULL` (leave unchanged); `Just []` means the exit-only empty
  state.  Exec promises are a ceiling for descendants, not a universal
  sandbox, and do not grant `execve(2)` permission.
- Do not call `pledge []` from a live threaded Haskell child after
  `forkProcess`; the native C probe is the supported way to test it.
- `mask_` only defers asynchronous exceptions on the calling thread.
  It does not make separate kernel calls atomic; a partial privilege
  drop or chroot is fatal for the current process.
- `mimmutable(2)` takes only explicit native mappings, never GC or
  `malloc` memory.  `setprogname(3)` stores its pointer, so its buffer
  is intentionally never freed.  `closefrom(2)` must propagate
  `EBADF`, not turn it into a no-op.
- `chroot(2)` and `getpeereid(3)` happen before pledging; `chroot` is
  not a complete sandbox.  Exec promises are not a replacement for
  unveil, chroot, privilege dropping, or OS isolation.

## Working with existing changes

Run `git status --short` before editing.  Treat modified or untracked
files as someone else's work unless the task explicitly owns them; do
not revert or reformat unrelated changes.  Read the diff before
finishing and keep edits scoped.  Do not commit, push, tag, or open pull
requests unless asked.

## Continuous Agent & Skills Maintenance

Agent instructions and skills are living repository artifacts.

Every repository modification MUST include an agent/skills synchronization step.

Before completing any task, inspect the applicable AGENTS.md and SKILL.md files, update the affected instructions, and validate their consistency with the implementation.

A code change without the corresponding agent knowledge maintenance is considered incomplete.

Never claim completion when the synchronization step has been skipped or has failed.

This applies to code, tests, dependencies, configuration, workflows, documentation, architecture, and agent/skill files themselves. At the end of each task:

1. Inspect all repository instruction sources with `rg --files --hidden -g 'AGENTS.md' -g '*.agent.md' -g 'SKILL.md' -g '.github/instructions/**' -g '.cursor/rules/**' -g 'CLAUDE.md' -g 'GEMINI.md' -g 'copilot-instructions.md'`. Include tool-specific files discovered by the search even if they are not listed here.
2. Map changed paths to relevant skills using each skill's “When to use” section and specialized agent responsibilities. Review root/nested instructions governing the paths, matching skills, and directly referenced instructions.
3. For project changes, make a substantive, reusable update to at least one applicable AGENTS.md, specialized agent file, or SKILL.md. Keep examples, commands, paths, assumptions, and validation procedures aligned with the implementation. A docs-only change may itself be the knowledge update when it changes agent-operational guidance.
4. Update an existing skill when a reusable procedure, tool, safety rule, validation, or project assumption changes in its area. Create a skill only for a recurring, distinct responsibility with no suitable existing skill; define its trigger, procedure, validation, and references, then link it here. Do not create skills for one-off tasks.
5. Keep specialized agents synchronized with this policy and their skills. Each must identify related skills, review them after changes, revise incorrect or stale guidance, run or delegate relevant checks, and report synchronization. Avoid duplicating skill procedures; link to the canonical skill.
6. Validate changed instruction files: preserve skill frontmatter, require useful content, check local Markdown links and referenced paths where mechanically identifiable, run `perl -c scripts/check-agent-sync.pl`, and run `perl scripts/check-agent-sync.pl --base BASE --head HEAD` (or its documented local default) plus `git diff --check`.
7. Review the complete diff for semantic relevance. Automation checks changed-file coverage, substantive text, basic structure, and resolvable local Markdown links; it cannot decide whether a knowledge update is genuinely relevant. That semantic review is mandatory.

The automated check rejects project changes without a substantive instruction/skill change. If synchronization or validation cannot be completed, fix it or report the task as incomplete with the exact limitation; never silently skip it. When an instruction or skill changes, perform one complete end-of-task review of the policy, affected references, and validator. Repeat validation only to check a correction, avoiding recursive maintenance loops.

### Mandatory Definition of Done

- [ ] Repository changes implemented.
- [ ] Relevant agent instructions reviewed.
- [ ] Relevant skills reviewed.
- [ ] Affected AGENTS.md / SKILL.md files updated.
- [ ] Obsolete knowledge removed.
- [ ] New reusable knowledge incorporated.
- [ ] Agent and skill references validated.
- [ ] Automated maintenance checks passed.
- [ ] Final synchronization status reported.

If any item fails, fix it or declare the limitation and the task incomplete. Every final report must include **Agent & Skills Synchronization** with agents reviewed, skills reviewed, instruction files updated, reusable knowledge added/corrected, validations actually run, and status **PASS** or **FAIL**.

## Skills

Load the relevant skill before changing the corresponding area:

| Skill | Use for |
| --- | --- |
| [`openbsd-haskell-ffi`](.agents/skills/openbsd-haskell-ffi/SKILL.md) | raw FFI, C shim, marshaling, `errno`, memory ownership, ABI types |
| [`typed-security-apis`](.agents/skills/typed-security-apis/SKILL.md) | `Promise`, `Permission`, `Account`, `Rtable`, policy and ordering |
| [`process-fork-exec-safety`](.agents/skills/process-fork-exec-safety/SKILL.md) | `forkProcess`, exec promises, daemonization, descriptors, runtime caveats |
| [`cabal-and-abi-compatibility`](.agents/skills/cabal-and-abi-compatibility/SKILL.md) | Cabal flags, GHC2024/C23, OpenBSD 7.9/8.0 gating, versioning, sdist |
| [`ffi-unit-and-integration-tests`](.agents/skills/ffi-unit-and-integration-tests/SKILL.md) | test harness, C fixtures, root tests, expected signals, CI commands |

There are currently no specialized agent definition files. If one is added, it must include a **Post-Change Knowledge Synchronization** section: identify and review related skills after every change, update changed behavior and reusable knowledge, verify its own instructions, run or delegate validations, and report the result. This policy applies regardless of agent tool or vendor.
