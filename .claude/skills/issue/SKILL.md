---
name: issue
description: Work one Hydrophone issue end-to-end in its own git worktree and branch, then open a PR and stop. Use when asked to work, start, take, or implement an issue ("work issue 42", "start #17 on a branch"), or to put a named fix on its own branch.
---

# Work an issue → PR → stop

One piece of work, one worktree, one branch, one PR. You open the PR and **stop**.
Tim reviews. Merging and cleanup happen later, only when he says so — that is the
`land` skill, not this one.

Read `docs/11-agent-workflow.md` once if anything below needs its rationale.

## 1. Intake

- Resolve the work: an issue number (`gh issue view <n>`), or an agreed slug for
  unticketed work. Neither → ask which, and stop.
- Read the issue in full, plus the `docs/` file that owns the subsystem (CLAUDE.md's
  "read the right doc" table).
- Restate before touching git, in one block: **scope** (what lands), **out of scope**
  (what explicitly does not), **files you expect to own**. If the issue conflicts with
  `docs/` or CLAUDE.md, say so and stop — never improvise a product decision.

## 2. Worktree

Branch and worktree directory always share one name:

- issue-backed: `issue-<n>-<slug>` — e.g. `issue-42-airplay-rate-skip`
- unticketed: `fix-<slug>` / `chore-<slug>` / `docs-<slug>`

Run from the **primary checkout** — the repo root, where `git rev-parse --git-dir`
prints `.git` — never from inside another worktree:

```sh
git fetch origin --prune
git worktree add -b issue-<n>-<slug> .worktrees/issue-<n>-<slug> origin/main
cd .worktrees/issue-<n>-<slug>
```

Guards, all before you write code:

- Branch or path already exists → stop and report; never reuse or force.
- Base the branch on `origin/main`, never on another issue branch.
- `.worktrees/` is gitignored; the primary checkout's `git status` must stay clean.

## 3. Implement

- Work only inside your worktree. Never edit files in the primary checkout or another
  worktree.
- Commit in small, meaningful steps — the commits are the provenance and are never
  squashed. Conventional style, matching `git log`: `feat(ui):`, `fix(engine):`,
  `fix(app):`, `docs:`, `chore:`, `site:`.
- Stay inside the stated scope. New problems you notice → note them for a follow-up
  issue, do not widen the branch.
- Obey the house rules and the gotchas list in CLAUDE.md (Up Next drag, Now Playing
  panel placement, NSToolbar right-clicks, AirPlay sample rate, route-change rebuild).
- Zero third-party dependencies. Credentials never leave the Keychain.

## 4. Done gate — all four, or no PR

Run them; paste the real result. Never claim a check you did not run.

```sh
xcodebuild -project Hydrophone.xcodeproj -scheme Hydrophone \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project Hydrophone.xcodeproj -scheme Hydrophone \
  -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
swiftlint
```

1. **Build** — succeeds with zero compiler warnings.
2. **Tests** — the suite passes.
3. **SwiftLint** — zero violations.
4. **Live verification** — run the app against a real server (Settings → Connection has
   a demo-server button) and confirm the changed behavior by hand. Write down what you
   played, on which server, and what you observed. A player change claimed without live
   verification is not done.

Then, in the same branch, a `docs/PROGRESS.md` entry: newest-first dated section, and
the "Milestone status" / "Verification status" blocks at the top brought current. Update
any `docs/` file whose contract you changed.

A gate you cannot satisfy → stop and say which one and why. Do not open the PR anyway.

## 5. PR

```sh
git push -u origin issue-<n>-<slug>
```

Retry a network failure up to 4 times (2s, 4s, 8s, 16s). Then open the PR against
`main` with this body:

```markdown
Closes #<n>

## What changed
- <one line per change, in reviewer terms>

## Verification
- build: clean, zero warnings
- tests: pass (`xcodebuild … test`)
- swiftlint: clean
- live: <server, date, what was played and observed>

## Notes & out of scope
- <deliberate omissions, follow-ups worth filing>
```

Drop the `Closes` line for unticketed work and describe the change instead.

## 6. Stop

Report exactly three lines — PR URL, branch, worktree path — and end the turn.

Until Tim starts you again on this PR, you do **not**:

- watch CI, re-run checks, or push fixes for a red build
- answer or implement review comments
- merge, or delete anything
- start the next issue

This hard stop is the point of the workflow, not an oversight. If CI is red or a
reviewer is waiting, that is Tim's call to hand back to you.

## Parallel work

Several issues may be in flight at once, one worktree each.

- One agent per worktree. Never two agents in one worktree, never two worktrees on one
  branch.
- Declare owned files at intake. Two in-flight branches must not own the same file; if
  the work genuinely overlaps, say so and let Tim sequence them.
- Merge order is Tim's; a branch that goes stale waits — see below.
- Three or more issues dispatched as a batch: write a short handoff note under
  `docs/handoffs/<date>-<batch>.md` — issue table with primary files, dependencies,
  file-overlap risk, suggested merge order.

## Stale or conflicting branch

`main` moved and your branch no longer merges cleanly → **stop and report it**. Do not
rebase (it destroys the branch line), do not merge `origin/main` in on your own
initiative. When Tim asks you to refresh:

```sh
git merge origin/main       # inside the worktree; never rebase
```

resolve, re-run the full done gate, push. Lockfiles and generated files get regenerated
by their tooling, never hand-edited.

## Cloud sessions (Claude Code on the web)

A cloud session has no Xcode, no simulator, no DAC and no music server, so the done gate
cannot be met there.

- No worktree — the session's own clone is the branch. Same branch naming, same commit
  style, same `docs/PROGRESS.md` entry.
- Open the PR as a **draft** (`gh pr create --draft`, or `draft: true` via the GitHub
  MCP tools), and state plainly in the Verification section: `not run — cloud session,
  no Xcode/server`. GitHub will not merge a draft, which is the safeguard.
- Then stop, exactly as above. Verification, undrafting, merge and cleanup all happen on
  the Mac.
