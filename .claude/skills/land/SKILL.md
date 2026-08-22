---
name: land
description: Merge an approved Hydrophone PR with a real merge commit, then remove its worktree and delete both branch refs. Use only when Tim explicitly says to merge, land, or ship a PR — never on your own initiative.
---

# Land an approved PR

Runs **only** on an explicit instruction from Tim ("merge #42", "land it"). A green PR
is not permission; review is his.

The merge is always a true merge commit. `--squash` and `--rebase` are forbidden here:
the whole point is that `git log --graph` keeps showing where the branch forked and
where it joined.

## 1. Guards — every one, before merging

```sh
gh pr view <n> --json number,state,isDraft,headRefName,headRefOid,baseRefName,mergeStateStatus,statusCheckRollup
git fetch origin --prune
```

Stop and report — do not merge, do not fix — if any of these holds:

- state is not `OPEN`, or `isDraft` is true (a draft means its gate never ran)
- `baseRefName` is not `main`
- `headRefOid` is not the commit you verified; something was pushed since
- `mergeStateStatus` is `DIRTY`/`BLOCKED`, or the branch is behind `main`
- checks are failing or still running — merge only on green, unless Tim overrides in
  the same breath

Conflicts and staleness are reported, never silently resolved. If Tim asks you to
refresh the branch: `git merge origin/main` inside its worktree (never rebase), re-run
the full done gate from the `issue` skill, push, then re-check these guards.

## 2. Merge

```sh
gh pr merge <n> --merge --match-head-commit <verified-sha>
```

`--match-head-commit` makes the merge fail rather than land a commit nobody reviewed.
From a cloud session, the equivalent is the GitHub MCP `merge_pull_request` with
`merge_method: "merge"` — never `squash`, never `rebase`.

Verify it landed as a merge commit:

```sh
git fetch origin --prune
git merge-base --is-ancestor <verified-sha> origin/main
git log --graph --oneline -8 origin/main
```

## 3. Cleanup

From the primary checkout:

```sh
git checkout main
git merge --ff-only origin/main
git worktree remove .worktrees/<branch>
git branch -d <branch>
git push origin --delete <branch>
git worktree prune
```

- `git worktree remove` refuses if the worktree is dirty. That is a signal, not an
  obstacle: report the uncommitted work and ask before using `--force`.
- `git branch -d` refuses if the branch is unmerged. Never reach for `-D` — investigate.
- Deleting both refs costs nothing in the graph. The fork and join lines come from the
  merge commit's two parents, which are permanent; the refs were only labels.

## 4. Report

Four lines: merge commit SHA, that `main` is synced and clean, worktree removed, refs
deleted (local + remote). Then stop — do not start the next issue.
