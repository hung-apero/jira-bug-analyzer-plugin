# PR watcher — surface review comments + clean up worktree on close

> **This is the Jobs A (review comments) + B (worktree cleanup) helper that `--manager` drives.** The orchestration (when to run, the per-board reconcile loop, the board scan, and Job C KB-backfill) lives in **`references/phase-manager-mode.md`** — read that for the mode; read this for the mechanics. **Job C (KB-backfill on ticket→Done) is NOT in this file** — it's owned by `phase-manager-mode.md` + `references/helpers/memory.md`.

Read this when arming the watcher on PR creation (Phase 6), or when running the reconcile via `--manager` (or the minimal Init-5 worktree cleanup on skill start).

**The ticket is already Resolved at PR-creation time** (Fix-13 transitions → Resolved + logs work + comments the PR link before the watcher is armed). The watcher therefore does **NOT** resolve, log work, or comment on merge. Two jobs per watched PR:
1. **New review comments → notify + draft, apply on approval:** while the PR is open, detect review/line/issue comments from other reviewers and **notify** with a summary. Drafting a fix per comment and applying it (edit + push + reply) happens **interactively on the dev's approval** — never auto-edited unattended (review comments are often questions/ambiguous).
2. **Merge/close → clean up:** detect the PR leaving OPEN and **remove the fix worktree** (kept open until now so review fixes were possible), then drop the watch entry.

## ⚠️ How the watcher actually triggers — read before trusting "auto"

`CronCreate` is **NOT a background daemon.** Per its own contract: jobs *"only fire while the REPL is idle"* and (unless `durable: true`) are *"gone when Claude exits."* There is **no process that runs while Claude is closed.** So there are exactly two real triggers, and the **second is the load-bearing one**:

- **(A) In-session cron** — the 1-min poll fires *only while this Claude session stays open and idle*. Good for catching review comments minutes later while the dev is still around. Useless once the session closes.
- **(B) `--manager` reconcile** — running `/jira-bug-analyzer --manager <KEY>` reads the **watch file**, surfaces & fixes pending review comments, cleans up any merged/closed PR's worktree, and backfills the KB. This is the durable path that survives session death — **but only if the watch file was written.** (A normal skill start also does the *minimal* Init-5 worktree cleanup, but the full reconcile is manager mode.)

**Therefore the watch-file write — not the cron — is the arming action.** If the file write fails, arming failed: say so (review comments won't be auto-surfaced; re-run `--manager` to reconcile). The cron is best-effort sugar on top. Never tell the dev "it watches in the background even if you close Claude" — tell them "it surfaces comments if this session is still open, otherwise the next time you run `--manager`." Nothing here gates the ticket's resolution — that already happened at PR creation.

## Watch state file

`.jira-bug/pr-watch.json` at the **target project root** (untracked — add to `.git/info/exclude`; never `git add`). A map keyed by PR number; one entry per open PR the skill created:

```json
{
  "<PR>": {
    "pr": 123,
    "base": "main",
    "branch": "phase1/fixbug/AIP568-191",
    "worktree": "../learnova-AIP568-191",
    "tickets": [
      { "key": "AIP568-191", "summary": "Energy reward missing on highscore streak" }
    ],
    "cronId": "<cron id from CronCreate>",
    "createdAt": "<ISO8601>",
    "commentsCursor": "<ISO8601 of the newest review comment already notified — init = arm time>"
  }
}
```

`commentsCursor` advances past comments already surfaced so the watcher never re-notifies the same one. (Tickets are already Resolved, so the entry exists only for review-comment surfacing + worktree cleanup.)

Batch = one PR, many entries in `tickets`.

## Arm (Fix-13, after the ticket is Resolved + PR link commented)

Ask **as options** `Watch for review comments` (default) / `Don't watch`.

**Watch** — arm in this order, because step 1 is the durable part and steps 2–3 are best-effort:
1. **Write/append the PR entry to the watch file** (`.jira-bug/pr-watch.json` at the target project root; add it to `.git/info/exclude` first). **Then verify it on disk** (`test -f` + parse the JSON back). **If the write fails → arming FAILED:** tell the dev review comments won't be auto-surfaced and they must re-run the skill to reconcile. Do not claim the watcher is armed. (The ticket is already Resolved regardless.)
2. Register (or reuse) **one** recurring `CronCreate` with **`durable: true`** polling **every 1 minute** (`* * * * *`), so it at least survives a Claude restart. Store the returned id as `cronId`.
3. **Verify the cron registered** via `CronList`; if it's absent, **don't fail** — note that live polling is off, a `--manager` run still covers it, and continue.
4. **Tell the dev the honest expectation** (don't overpromise): *"Armed. If this session stays open, new review comments surface within ~1 min; if you close Claude, they surface the next time you run `/jira-bug-analyzer --manager <KEY>`. The worktree is removed when the PR merges/closes."* Echo how to cancel (`CronDelete`).

**Don't watch** — no watcher; the dev handles review comments themselves and removes the worktree manually after merge (`git worktree remove ../learnova-<...>`). The ticket is already Resolved.

## Each cron fire (and each `--manager` reconcile) — per watch entry

1. **Acquire an atomic per-PR lock** (`mkdir`-style, same pattern as `device-lock.md`, keyed by PR) so a cron fire and a startup reconcile never collide. Locked → skip this entry this pass.
2. `gh pr view <PR> --json state -q .state`:
   - `OPEN` → **poll for new review comments** (below), then leave the entry, release lock, wait for the next fire.
   - `MERGED` or `CLOSED` → **remove the fix worktree** (`git worktree remove <worktree>`, if still present), notify a short per-PR summary (`merged` vs `closed without merge`), remove the entry. **Do NOT touch Jira** — already Resolved.
3. Release the lock. When the watch file becomes empty → `CronDelete` the watcher and delete the file.

## Review-comment poll (each fire, while OPEN) — notify only, never auto-edit

Fetch comments newer than `commentsCursor`, authored by **someone other than the token owner** (don't react to your own replies):
- Reviews: `gh api repos/{owner}/{repo}/pulls/<PR>/reviews`
- Line comments: `gh api repos/{owner}/{repo}/pulls/<PR>/comments`
- Issue comments: `gh api repos/{owner}/{repo}/issues/<PR>/comments`

If any new → **notify** (push notification / scheduled-session output) a concise list: `author · file:line · snippet` per comment. Advance `commentsCursor` to the newest seen so it isn't re-notified. The unattended cron **stops here** — it does NOT edit code. Applying fixes is the interactive flow below, run when the dev engages (or at Init-5 if comments are pending).

## Address review comments — interactive (notify → draft → apply on approval)

Triggered when the dev engages after a comment notification, or surfaced at Init-5 when a watched PR has pending comments. Never runs unattended.
1. **List** the new comments: `author · file:line · body`.
2. **Per comment, draft** a response: either a concrete proposed code fix, or — if the comment is a question / ambiguous / non-actionable — a drafted reply asking for clarification (do NOT guess an edit).
3. **Ask as options** (per comment or batched): `Apply drafted fix` / `Edit draft` / `Reply only` / `Skip`.
4. **On `Apply`:** edit in the PR's worktree → if behavior changed, re-run **Phase 5 adb self-verify** (`references/phase5-verify.md` — NOT mobile-mcp) → push to the PR branch (`--force-with-lease`) → **reply on the thread** acknowledging (`gh api ... /pulls/<PR>/comments/<id>/replies` for line comments, or a PR comment).
5. Advance `commentsCursor` past everything handled; clear the pending flag.

Resolving a review thread or marking the comment addressed is the reviewer's call — don't auto-resolve their threads.

## Recovery — minimal Init-5 cleanup on skill start · full reconcile via `--manager`

The session may have been killed while a PR was open. There are two recovery paths:
- **Minimal Init-5 cleanup (any skill start):** read the watch file and, for each `MERGED`/`CLOSED` PR, **remove the fix worktree** (if still present) + drop the entry. Cheap, non-interactive — keeps stale worktrees from piling up. It does NOT chase review comments or backfill the KB.
- **Full reconcile (`/jira-bug-analyzer --manager <KEY>`):** the durable path — per PR:
  - `MERGED` or `CLOSED` → **remove the fix worktree** (if still present) and drop the entry. (No Jira work — already Resolved at PR creation.) Then **Job C KB-backfill** (`references/phase-manager-mode.md`).
  - `OPEN` → ensure the watcher cron still exists; if its `cronId` is gone (cron was killed / session ended — the normal case), **re-`CronCreate` with `durable: true`** the 1-min poll so in-session detection resumes. Also **re-poll review comments since `commentsCursor`** and, if any are pending, surface them to the dev (the Address-comments flow) — catches comments left while the session/cron were dead.

> Because the cron dies with the session, an `OPEN` PR will almost always have a missing `cronId` at the next startup — that's expected, not an error. Re-arming the cron just restores live polling for as long as the new session stays open.
- File empty afterward → `CronDelete` + delete the file.

Same atomic per-PR lock as the cron fire, so a reconcile and a concurrently-firing cron don't collide.
