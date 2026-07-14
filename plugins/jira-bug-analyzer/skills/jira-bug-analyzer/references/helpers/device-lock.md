# Device lock — serialize on-device verify across processes/projects

> **Two device consumers now share this lock:** the **Phase-5 verify** step AND the **Phase-3 `[REPRO]`** step (`bug-analysis-rules.md` A4 — the analyzer reproduces the bug on-device before root-causing). Both MUST go through `device-lock.sh`. In multi/team mode several analyzers reproduce in parallel but there is one device → they **serialize best-effort on this lock** (bounded wait + retry cap); a lock-miss degrades per the device policy — **`--auto` defers that ticket** (device hard-required), **interactive falls back to static repro + a `not device-verified` flag** (A7). Same TTL/owner-token mechanism below applies to both steps.

Read this when running the verify step OR the Phase-3 repro step. The step installs + launches on a physical device/emulator, and **only one process may drive a given device at a time**. Two concurrent verifies racing `adb install`/launch/screenshot on the same serial corrupt each other's install and capture the wrong app — and the colliding process is often **another project** (this same skill from a different repo, a parallel orchestrator fix, or a manual session).

So **before** acquiring a device for verify, take an **exclusive, cross-project lock keyed by the adb serial**, and release it the moment verify is done. If a device is already locked by another process/project, **do not grab it** — pick a different free device, or wait until it frees.

## Mechanism — ALWAYS use `assets/device-lock.sh` (never hand-roll the lock, never a bare `adb -s`)

> **[HARD RULE 1 — EVERY adb command that touches a device goes through `device-lock.sh exec`.** Not just `install` — `am start`, `input`, `screencap`, `screenrecord`, `uiautomator`, `logcat`, all of it. A bare `adb -s <serial> …` bypasses the lock completely: the script cannot stop what it never sees, so a second terminal happily drives the device this session owns, clobbers its APK, and captures the other session's screen as "evidence". `exec` asserts ownership before every call **and refreshes the TTL** (so a long verify can never look stale to a peer).
>
> **[HARD RULE 2 — the owner token is the RAW Claude session id, byte-identical for every call of the session.** Every phase, every ticket, every subagent passes the SAME token. **Never** append a role or ticket (`<sid>-analyzer-319` is a BUG — it was the real cause of the lock failing): a per-role token makes your own session go `BUSY` against *itself*, which teaches the agent the lock is broken and to bypass it with bare adb. The script now **rejects** a malformed token with `BADTOKEN` (exit 2) rather than letting it silently self-collide. Two terminals = two session ids = real mutual exclusion.
>
> **[HARD RULE 3 — `BUSY` / `NOTOWNER` (exit 3) means STOP.** Another live session owns that device. Take a different free serial, or wait and poll. **Never** "work around it" by running adb directly, and never `FORCE=1` unless you have confirmed the holder is dead.

```bash
SKILL=<skill-dir>; LOCK="$SKILL/assets/device-lock.sh"
TOKEN=<raw claude session id>       # e.g. 5d149c68-… — SAME string in every call, every subagent. No suffixes.

# 1. pick + claim a device (prints the first UNLOCKED connected serial, already claimed):
SERIAL=$(bash "$LOCK" free-serial "$TOKEN" 1800)
[ -z "$SERIAL" ] && echo "all devices busy — wait / tell the user" && exit
# …or claim a specific serial:
bash "$LOCK" acquire <SERIAL> "$TOKEN" 1800   # ACQUIRED → you own it · BUSY (exit 3) → someone else holds it

# 2. install THROUGH the lock (acquire-then-install -r -d, keeps the lock held):
bash "$LOCK" install <SERIAL> "$TOKEN" <apk>  # never a bare `adb install`

# 3. drive the app THROUGH the lock — every single adb call, no exceptions:
bash "$LOCK" exec <SERIAL> "$TOKEN" -- shell am start -n <pkg>/<launcher>
bash "$LOCK" exec <SERIAL> "$TOKEN" -- exec-out screencap -p > <evidence>/<ticket>.png
bash "$LOCK" exec <SERIAL> "$TOKEN" -- shell input tap <x> <y>
bash "$LOCK" exec <SERIAL> "$TOKEN" -- logcat -d -t 100
# NOTOWNER (exit 3) → a peer session owns it: stop, do NOT fall back to `adb -s`.

# 4. release the instant verify is done (or on abandon/exit):
bash "$LOCK" release <SERIAL> "$TOKEN"

# inspect: bash "$LOCK" status <SERIAL>   ·   bash "$LOCK" list   (FREE | LOCKED | STALE + owner/project)
```

## Rules

- **Lock dir is global** (`~/.claude/jira-bug-analyzer/device-locks/`) so a lock taken by one project is visible to every other project's run of this skill. The script always uses this path; never place a lock under the worktree.
- **Always `acquire`/`install` before driving, always `release` after.** Hold for the whole run → self-verify span; release as soon as the device is no longer needed — after Verified OK, on a failed build/run, and **always** on abandon/exit. The TTL is a safety net for crashes, not a substitute for releasing.
- **Subagents inherit the token, they don't mint one.** Phase 5 dispatches the verifier (`android-self-verify` / `android-ui-verify`) with BOTH `--serial` **and** `--owner-token <session-id>`; the subagent drives via `device-lock.sh exec` with that token and does **not** acquire or release (the parent owns the lock). A subagent that invents its own token gets `NOTOWNER` and must stop, not bypass.
- **`BUSY` / `NOTOWNER` (exit 3) means another live session owns it — do NOT steal it.** Pick another free serial (`free-serial`) or wait/poll. Only `FORCE=1 device-lock.sh release …` when you are certain the holder is dead and the TTL hasn't reclaimed it yet.
- **Stale reclaim is automatic and serialized:** a lock past its TTL (crashed/abandoned session) is reclaimed on the next `acquire`, under an internal meta-lock so two peers can't both reclaim and end up both owning it. A lock whose owner file is still being written is NOT stale (60s grace) — it is a live claim. `status`/`list` show `STALE`. **Never `rm -rf` a lockdir by hand** to "unstick" it; that reintroduces the double-owner bug the meta-lock exists to prevent.
- **Long drives can't expire:** every `exec` refreshes the TTL, so a verify that runs past 1800s stays owned as long as it keeps touching the device.
- **Multiple connected devices:** `free-serial` already prefers an unlocked serial; only wait if every connected device is locked. **No free device → tell the user and wait/poll**, never force-grab a locked one.
- **Batch:** the per-bug verify turns are already serial, but still acquire/release per turn (or hold across the batch with periodic re-acquire to refresh the TTL) so an interleaved run from another project can take the device between your bugs.
