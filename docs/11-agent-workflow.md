# 11 — Agent Workflow

How agents (Claude Code, Codex, anything else pointed at this repo) do work here:
one piece of work per **worktree**, one **branch**, one **PR**, then a hard stop
for review, and a **merge commit** that keeps the branch visible in the graph
forever.

`AGENTS.md` is the enforceable short form of this document — one behavior per
line, no rationale. The executable procedures live in
`.claude/skills/issue/SKILL.md` (start → PR → stop) and
`.claude/skills/land/SKILL.md` (merge → cleanup). This page explains *why*, so
the rules can be applied to situations they don't literally cover.

## The loop

1. **Assign.** Tim names the issue. Agents never pick their own work.
2. **Isolate.** The agent creates `.worktrees/issue-<n>-<slug>` on branch
   `issue-<n>-<slug>`, based on `origin/main`.
3. **Build.** Small conventional commits inside that worktree only.
4. **Gate.** Build, tests, SwiftLint, live verification, `PROGRESS.md` entry.
5. **PR.** Push, open the PR with verification evidence, report three lines, stop.
6. **Review.** Tim reviews. Nothing moves without him.
7. **Land.** On his word: `--merge` with a matched head commit, then the worktree
   and both refs are removed.

## Why worktrees, inside the repo

Several issues run in parallel, and more than one agent window may be open at
once. A shared working directory means one agent's half-finished edit lands in
another's build — the failure mode that produced per-issue worktrees on the
previous project. `git worktree` gives each branch its own checked-out tree over
one object store: cheap to create, impossible to cross-contaminate, and each
worktree gets its own DerivedData because the path differs.

They live at `.worktrees/` **inside** the repo (gitignored) rather than in
`/tmp`, so they are visible in the Finder next to the work they belong to,
survive reboots, and disappear with the repo if it's ever moved or cleared. The
directory name always equals the branch name — one look at `git worktree list`
says what is in flight.

Consequences worth knowing:

- Create worktrees from the primary checkout, never nested inside another one.
- The primary checkout's `git status` stays clean while agents work; if it
  doesn't, something wrote to the wrong tree.
- `git worktree remove` refuses on a dirty tree. That refusal is information —
  find out what's uncommitted before forcing anything.
- A worktree is a full copy of the sources sitting inside the repo, so
  `.worktrees` is excluded in `.swiftlint.yml` — otherwise `swiftlint` at the
  repo root lints every in-flight branch as well as `main`.

## Why merge commits, never squash or rebase

Every merge into `main` is a real merge commit with two parents. That is the only
thing that preserves the shape of the work: `git log --graph` shows where the
branch left `main`, the commits made on it, and where it came back. Squash
flattens a day of reasoning into one opaque commit; rebase rewrites the commits
so the fork never existed. Both destroy the audit trail that makes it possible,
months later, to see how a subsystem got the way it is.

Same reason the individual commits on a branch are never squashed before the PR,
and the same reason a stale branch is refreshed by merging `origin/main` *into*
it rather than rebasing onto it.

Deleting the branch refs after a merge costs nothing: a ref is a label, while the
fork and join are recorded in the merge commit's parents. `git log --graph
--oneline main` draws the same picture whether or not `issue-42-…` still exists.

## Why the agent stops at the PR

The PR is the handoff, and review is Tim's job. An agent that keeps pushing —
chasing CI, answering review bots, tidying its own diff — moves the target while
the reviewer is reading it, and quietly converts "I reviewed this" into "I
reviewed something like this."

So after the PR is opened the agent does not watch CI, does not implement review
comments, does not merge, does not start the next issue. Red CI on its own PR is
not an exception; it's information for Tim, who decides whether to hand the
branch back. Work resumes only on an explicit new instruction.

This is the deliberate difference from the usual "drive the PR to green"
posture — in this repo, driving stops at the PR.

## Why the gate is four checks, not one

CI here builds and tests, but the things Hydrophone gets wrong are rarely
compile errors. Gapless transitions, device switching, AirPlay clocks, USB DAC
unplugs — those fail only against real hardware and a real server, which is why
live verification is part of the gate and why the PR body has to say what was
played, where, and what was observed (see `08` for the manual checklist). A
player change claimed without live verification is not done.

The `PROGRESS.md` entry belongs to the same branch as the code for the same
reason the merge commit matters: the log should explain the diff without anyone
having to reconstruct it later.

## Parallel batches

Branches may run concurrently, one agent per worktree. The constraint is file
ownership: two in-flight branches must not own the same file, because whoever
merges second inherits a conflict the reviewer never saw. Agents declare their
expected files at intake; genuine overlap is reported so Tim can sequence the
merges rather than discovering the collision at merge time.

For batches of three or more, the dispatching agent writes
`docs/handoffs/<date>-<batch>.md`: the issue table with primary files,
dependencies between issues, file-overlap risk, and a suggested merge order. It
exists so the next agent doesn't re-derive scope and conflict risk per issue.

## Stale branches and conflicts

If `main` moves and a branch no longer merges cleanly, the agent stops and says
so. It does not rebase (that would rewrite the branch), and it does not merge
`main` in on its own initiative (that changes what the reviewer already read).
On request it merges `origin/main` into the branch, resolves, re-runs the whole
gate, and pushes — a refresh is a new state, so it earns a new verification.

## Cloud sessions

Claude Code on the web runs on Linux: no Xcode, no simulator, no DAC, no music
server. The gate cannot be satisfied there, so the rules degrade honestly rather
than pretending:

- No worktree — the session's clone is the branch. Naming, commit style and the
  `PROGRESS.md` entry are unchanged.
- The PR opens as a **draft**, with Verification recorded as `not run — cloud
  session, no Xcode/server`. GitHub won't merge a draft, so an unverified change
  cannot land by accident.
- Verification, undrafting, merging and cleanup all happen on the Mac.

## What still lands on `main` directly

Feature and fix work always goes through a branch and a PR. Documentation,
`PROGRESS.md` and `site/` tweaks may be committed straight to `main` when Tim
asks for them directly, and the release pipeline (`scripts/publish.sh`) keeps its
main-based bump → build → tag → release flow described in `07`.
