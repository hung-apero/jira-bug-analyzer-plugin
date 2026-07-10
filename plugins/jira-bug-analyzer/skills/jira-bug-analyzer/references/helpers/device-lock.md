# Device lock — serialize on-device verify across processes/projects

> **Two device consumers now share this lock:** the **Phase-5 verify** step AND the **Phase-3 `[REPRO]`** step (`bug-analysis-rules.md` A4 — the analyzer reproduces the bug on-device before root-causing). Both MUST go through `device-lock.sh`. In multi/team mode several analyzers reproduce in parallel but there is one device → they **serialize best-effort on this lock** (bounded wait + retry cap); a lock-miss degrades per the device policy — **`--auto` defers that ticket** (device hard-required), **interactive falls back to static repro + a `not device-verified` flag** (A7). Same TTL/owner-token mechanism below applies to both steps.

Read this when running the verify step OR the Phase-3 repro step. The step installs + launches on a physical device/emulator, and **only one process may drive a given device at a time**. Two concurrent verifies racing `adb install`/launch/screenshot on the same serial corrupt each other's install and capture the wrong app — and the colliding process is often **another project** (this same skill from a different repo, a parallel orchestrator fix, or a manual session).

So **before** acquiring a device for verify, take an **exclusive, cross-project lock keyed by the adb serial**, and release it the moment verify is done. If a device is already locked by another process/project, **do not grab it** — pick a different free device, or wait until it frees.

## Mechanism — ALWAYS use `assets/device-lock.sh` (never hand-roll the lock, never bare `adb install`)

> **[HARD RULE] Every `adb install` / on-device drive in this skill MUST go through `device-lock.sh` first.** A bare `adb -s <serial> install …` (what the verify step used to do) bypasses the lock entirely, so a second session/project clobbers the first session's APK on the same device — exactly the "another session installed a new APK, my verify is now testing the wrong build" failure. The lock is a SCRIPT, not prose, precisely so it can't be skipped.
>
> **Owner token = the Claude SESSION ID, not a pid.** The old pid-keyed lock was broken: every shell call the agent makes is a *separate* process, so `$$` died between calls and the lock looked "stale" instantly (zero protection). The script keys the lock on a stable **owner token** you pass (use the session id) + a **TTL** (default 1800s), so the claim survives across the many adb commands of one verify, refreshes when you re-acquire with the same token, and self-heals after the TTL if a session crashes without releasing.

```bash
SKILL=<skill-dir>; LOCK="bash $SKILL/assets/device-lock.sh"
TOKEN=<claude-session-id>          # stable per session — the owner identity

# 1. pick + claim a device (prints the first UNLOCKED connected serial, already claimed):
SERIAL=$($LOCK free-serial "$TOKEN" 1800)
[ -z "$SERIAL" ] && echo "all devices busy — wait / tell the user" && exit
# …or claim a specific serial:
$LOCK acquire <SERIAL> "$TOKEN" 1800        # ACQUIRED → you own it · BUSY (exit 3) → someone else holds it

# 2. install THROUGH the lock (acquire-then-install -r -d, keeps the lock held):
$LOCK install <SERIAL> "$TOKEN" <apk>        # never a bare `adb install`

# 3. drive the app with plain adb against the serial you OWN (screencap/input/logcat) …

# 4. release the instant verify is done (or on abandon/exit):
$LOCK release <SERIAL> "$TOKEN"

# inspect: $LOCK status <SERIAL>   ·   $LOCK list   (shows FREE | LOCKED | STALE + owner/project)
```

## Rules

- **Lock dir is global** (`~/.claude/jira-bug-analyzer/device-locks/`) so a lock taken by one project is visible to every other project's run of this skill. The script always uses this path; never place a lock under the worktree.
- **Always `acquire`/`install` before driving, always `release` after.** Hold for the whole run → self-verify span; release as soon as the device is no longer needed — after Verified OK, on a failed build/run, and **always** on abandon/exit. The TTL is a safety net for crashes, not a substitute for releasing.
- **`BUSY` (exit 3) means another live session owns it — do NOT steal it.** Pick another free serial (`free-serial`) or wait/poll. Only `FORCE=1 device-lock.sh release …` when you are certain the holder is dead and the TTL hasn't reclaimed it yet.
- **Stale reclaim is automatic:** a lock past its TTL (crashed/abandoned session) is silently reclaimed on the next `acquire`. `status`/`list` show it as `STALE`.
- **Multiple connected devices:** `free-serial` already prefers an unlocked serial; only wait if every connected device is locked. **No free device → tell the user and wait/poll**, never force-grab a locked one.
- **Batch:** the per-bug verify turns are already serial, but still acquire/release per turn (or hold across the batch with periodic re-acquire to refresh the TTL) so an interleaved run from another project can take the device between your bugs.
