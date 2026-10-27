#!/usr/bin/env python3
"""Enforce structural agent/skill synchronization for a Git change set."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTRUCTION = re.compile(
    r"(^|/)(AGENTS\.md|[^/]+\.agent\.md|SKILL\.md)$|(^|/)"
    r"(CLAUDE\.md|GEMINI\.md|copilot-instructions\.md)$|"
    r"^\.github/instructions/.+\.instructions\.md$|^\.cursor/rules/.+\.mdc$",
    re.IGNORECASE,
)
SKILL = re.compile(r"(^|/)SKILL\.md$", re.IGNORECASE)
LINK = re.compile(r"!?(?:\[[^\]]*\])\(([^)]+)\)")


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True, stderr=subprocess.PIPE)


def changed_paths(base: str, head: str | None) -> set[str]:
    if head:
        output = git("diff", "--name-only", "--diff-filter=ACDMRT", f"{base}...{head}")
        return {line for line in output.splitlines() if line}
    # Local mode compares the worktree and index with BASE, and includes untracked files.
    output = git("diff", "--name-only", "--diff-filter=ACDMRT", base)
    paths = {line for line in output.splitlines() if line}
    staged = git("diff", "--cached", "--name-only", "--diff-filter=ACDMRT", base)
    paths.update(line for line in staged.splitlines() if line)
    untracked = git("ls-files", "--others", "--exclude-standard")
    paths.update(line for line in untracked.splitlines() if line)
    return paths


def substantive_diff(paths: set[str], base: str, head: str | None) -> bool:
    args = ["diff", "--unified=0"]
    args.append(f"{base}...{head}" if head else base)
    args.extend(["--", *sorted(paths)])
    try:
        diff = git(*args)
    except subprocess.CalledProcessError:
        return False
    for line in diff.splitlines():
        if not line.startswith(("+", "-")) or line.startswith(("+++", "---")):
            continue
        if meaningful_content(line[1:]):
            return True
    if head is None:
        untracked = set(git("ls-files", "--others", "--exclude-standard").splitlines())
        for path in paths & untracked:
            try:
                lines = (ROOT / path).read_text(encoding="utf-8").splitlines()
            except (OSError, UnicodeError):
                continue
            if any(meaningful_content(line) for line in lines):
                return True
    return False


def meaningful_content(line: str) -> bool:
    content = line.strip()
    if not content or content.startswith(("#", "<!--", "-->")):
        return False
    if re.fullmatch(r"[-*]\s*\[[ xX]\]\s*", content):
        return False
    # Short headings, blank lines, and checkbox-only edits cannot satisfy policy.
    return len(re.sub(r"[`*_]", "", content)) >= 12


def check_markdown(path: str, errors: list[str]) -> None:
    file = ROOT / path
    try:
        text = file.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        errors.append(f"cannot read {path}: {exc}")
        return
    if not re.search(r"^#\s+\S", text, re.MULTILINE):
        errors.append(f"{path}: missing a level-one Markdown title")
    if SKILL.search(path):
        if not text.startswith("---\n") or not re.search(r"\n---\n", text[4:]):
            errors.append(f"{path}: SKILL.md must retain YAML frontmatter")
        else:
            frontmatter = text.split("---", 2)[1]
            if not re.search(r"(?m)^name:\s*\S", frontmatter):
                errors.append(f"{path}: frontmatter is missing name")
            if not re.search(r"(?m)^description:\s*\S", frontmatter):
                errors.append(f"{path}: frontmatter is missing description")
        if "## Maintenance & Continuous Learning" not in text:
            errors.append(f"{path}: missing Maintenance & Continuous Learning section")
    if path.lower().endswith(".agent.md") and "## Post-Change Knowledge Synchronization" not in text:
        errors.append(f"{path}: missing Post-Change Knowledge Synchronization section")
    for target in LINK.findall(text):
        target = target.strip().split()[0].strip("<>\"'")
        if not target or target.startswith(("https://", "http://", "mailto:", "#", "data:")):
            continue
        target_path = target.split("#", 1)[0].split("?", 1)[0]
        if not target_path:
            continue
        resolved = (file.parent / target_path).resolve()
        try:
            resolved.relative_to(ROOT)
        except ValueError:
            errors.append(f"{path}: local link escapes repository: {target}")
            continue
        if not resolved.exists():
            errors.append(f"{path}: broken local Markdown link: {target}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="HEAD", help="base Git ref; local default is HEAD")
    parser.add_argument("--head", help="head Git ref; omit to include staged, unstaged, and untracked files")
    args = parser.parse_args()
    try:
        paths = changed_paths(args.base, args.head)
    except subprocess.CalledProcessError as exc:
        print(f"agent-sync: cannot inspect Git changes: {exc.stderr.strip()}", file=sys.stderr)
        return 2
    if not paths:
        print("agent-sync: no changed files; synchronization check passed")
        return 0

    instruction_paths = {path for path in paths if INSTRUCTION.search(path)}
    project_paths = paths - instruction_paths
    if project_paths and not instruction_paths:
        print("agent-sync: FAIL: project changes have no changed agent instruction or skill file.", file=sys.stderr)
        print("Update an applicable AGENTS.md, specialized agent file, or SKILL.md with substantive reusable knowledge.", file=sys.stderr)
        print("Changed project files: " + ", ".join(sorted(project_paths)), file=sys.stderr)
        return 1
    if instruction_paths and not substantive_diff(instruction_paths, args.base, args.head):
        print("agent-sync: FAIL: instruction changes contain no substantive content (whitespace, headings, or empty edits do not count).", file=sys.stderr)
        return 1

    errors: list[str] = []
    for path in sorted(instruction_paths):
        if path.endswith((".md", ".mdc")):
            check_markdown(path, errors)
    if errors:
        print("agent-sync: FAIL:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print("agent-sync: PASS: " + str(len(paths)) + " changed path(s), " + str(len(instruction_paths)) + " changed instruction file(s)")
    print("agent-sync: structural checks do not assess semantic relevance; review the diff manually")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
