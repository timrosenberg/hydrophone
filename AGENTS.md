# Hydrophone — agent contract

**META**: config-file syntax only → one behavior per line → no prose → every line triggers action

## SOURCES
- product/architecture context: `CLAUDE.md`
- workflow rationale: `docs/11-agent-workflow.md`
- executable procedures: `.claude/skills/issue/SKILL.md` · `.claude/skills/land/SKILL.md`
- subsystem contracts: `docs/00`–`10`, `docs/PROGRESS.md`

## BRANCH
- one_worktree_per_branch: `.worktrees/<branch>` — directory name equals branch name
- create_from: `git worktree add --no-track -b <branch> .worktrees/<branch> origin/main` — from the primary checkout, never nested in a worktree
- no_track: without `--no-track` the branch tracks `origin/main` and git suggests `git push origin HEAD:main`
- name_issue: `issue-<n>-<slug>`
- name_unticketed: `fix-<slug>` · `chore-<slug>` · `docs-<slug>`
- worktrees_gitignored: `.worktrees/` never committed
- no_direct_main: feature and fix work always via branch + PR
- main_allowed: docs, `docs/PROGRESS.md`, `site/` tweaks when Tim asks directly
- release_exception: `scripts/publish.sh` keeps its main-based bump/tag/release flow

## COMMITS
- style: conventional + scope — `feat(ui):` `fix(engine):` `fix(app):` `docs:` `chore:` `site:`
- granularity: small and meaningful — commits are the provenance
- never_squash: history is preserved end-to-end
- attribution: agent authorship stays in the commit `Co-Authored-By` trailer — no model or tool names in PR titles, PR bodies, or code comments

## DONE_GATE [ALL_FOUR_BEFORE_PR]
- build: `xcodebuild -project Hydrophone.xcodeproj -scheme Hydrophone -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO` → zero warnings
- test: same command with `test` → suite passes
- lint: `swiftlint` → zero violations
- live: verify the change against a real server (Settings → Connection demo button); record server, date, observation
- progress_entry: dated `docs/PROGRESS.md` entry + refreshed Milestone/Verification blocks, same branch
- docs_sync: update any `docs/` contract the change touches
- gate_unmet: state which check failed and stop — never open the PR anyway

## PR
- base: `main`
- body: `Closes #<n>` · What changed · Verification (build/tests/swiftlint/live) · Notes & out of scope
- then_stop: report PR URL + branch + worktree path, end the turn

## AFTER_PR [HARD_STOP]
- no_ci_watch: never re-run, chase, or fix CI on your own PR
- no_review_fixes: never act on review comments unless Tim starts you again
- no_merge: never merge your own PR
- no_next_issue: never roll on to other work
- resume_only_on: an explicit new instruction from Tim

## LAND [ON_TIMS_WORD_ONLY]
- merge_method: `gh pr merge <n> --merge --match-head-commit <verified-sha>` — true merge commit
- forbidden: `--squash` · `--rebase` · fast-forward merge · rewriting branch history
- preconditions: open · not draft · base `main` · head unchanged since verification · mergeable · checks green
- cleanup: ff `main` → `git worktree remove` → `git branch -d` → `git push origin --delete` → `git worktree prune`
- graph_intact: refs are labels; the fork/join lines live in the merge commit's two parents

## STALE_OR_CONFLICT
- default: stop and report — never self-resolve
- on_request: `git merge origin/main` inside the worktree, never rebase, then re-run the full gate
- progress_conflict: `docs/PROGRESS.md` collides on almost every refresh — resolve by keeping both entries, newest-first; drop nothing

## PARALLEL
- assignment: Tim names the issues; agents never pick their own
- ownership: declare owned files at intake; no two in-flight branches own the same file
- overlap: report it and let Tim sequence the merges
- batch_ge_3: write `docs/handoffs/<date>-<batch>.md` — issues, primary files, dependencies, merge order

## CLOUD_SESSION [claude.ai/code]
- no_worktree: the session clone is the branch
- gate_unavailable: no Xcode, simulator, DAC, or server
- pr_draft: open as draft; Verification says `not run — cloud session, no Xcode/server`
- land_locally: verification, undrafting, merge, and cleanup happen on the Mac

## FORBIDDEN [NEVER_DO]
- third-party dependencies — Apple frameworks only
- credentials in URLs, logs, commits, or issue/PR text
- squash or rebase merges into `main`
- claiming a check that was not run
- scope creep beyond the stated issue
- re-breaking the CLAUDE.md gotchas (Up Next drag · Now Playing placement · NSToolbar context menus · AirPlay nominal rate · route-change rebuild)
