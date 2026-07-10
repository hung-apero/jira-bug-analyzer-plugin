# Bug-analysis rules — reality-check + reproduce-first before diagnosing

The **maintainable** ruleset for HOW the analyzer investigates a bug (Golden Rule `[REPRO]`), applied at
**Phase 3** alongside the existing Fix-1…Fix-8 flow. The analyzer follows this at **Fix-5.5** (repro) and
carries the result into **Fix-6** (root cause) / **Fix-8** (approval) / the confidence scorecard.

> **How to maintain (this is the ONE place):** edit / add / remove rules here. Keep each a short, checkable
> imperative. Changes sync project↔user-scope and apply to every project the skill analyzes. Don't scatter
> analysis rules into the phase files — link back to a rule id (`A#`). Complements `fix-code-rules.md`
> (that governs *writing* the fix; this governs *diagnosing* it).

Foundation: **evidence over assumption.** A root cause without a confirmed (or strongly-evidenced) trigger is a
hypothesis, not a diagnosis — and you do not fix a hypothesis.

## 1. Reality check — is this a real code bug?
- **A1** Before diagnosing, classify the ticket: **real app-code bug** vs a non-code cause — config/console (Remote Config, ad-unit IDs, flags, CMS) · backend/server · stale build/env/device · works-as-designed · duplicate · cannot-reproduce. **Cite the evidence** for the verdict (a log line, a spec statement, a code path, a ledger row).
- **A2** Not a real code bug → route to **Phase 4 Fix-9** (non-code `[VN]` comment) or defer; do NOT branch or invent a code fix to look done.
- **A3** **Duplicate check first:** read `record_bug_status.md`; a matching `root_cause_slug` (in-flight/done) → surface the duplicate + ask (`Skip`/`Fix anyway`) before deep analysis.

## 2. Reproduce first — on-device (`[REPRO]`)
- **A4** **Reproduce the bug on-device BEFORE settling a root cause.** Acquire the device lock (`references/helpers/device-lock.md` — serialized, shared with Phase 5), follow the repro steps from the ticket + media, and **observe via human-mcp** (`eyes_analyze`, text back — `references/helpers/media-analysis.md`). A confirmed on-device repro is the evidence anchor.
- **A5** **Save the repro evidence** — image for a static/visual bug, screen-recording for a dynamic/flow/animation/crash bug — into `.jira-bug/evidence/<TICKET>/`. This is the **"before" state Phase 5 reuses** (don't capture the bug state twice).
- **A6** **Trace the trigger→symptom code path** the repro exercised on the latest `origin/<BASE>` (`git grep`/`git show`, read-only). The root cause MUST connect the observed repro to a specific `file:line` — not a guess from the description.

## 3. Device policy — strict under `--auto`, graceful interactive (A7)
- **A7a `--auto` → a device is HARD-REQUIRED, no static fallback.** If no device is obtainable, the lock can't be acquired within the bounded wait, or the repro ladder (§4) fails → **defer + end-of-run report** (`deferred: unreproducible`/`no-device`). `--auto` NEVER auto-fixes a bug it could not reproduce on-device — this is the `[AUTO]` "confident-only, defer the rest" bar.
- **A7b Interactive (default) → repro-first, degrade gracefully.** Device genuinely unavailable / lock busy after the bounded wait → fall back to **static evidence-based repro** (derive deterministic steps + trace the code path, §2 A6 without the device) and **flag the analysis `not device-verified`** in the Fix-6 block. The dev decides whether to proceed.

## 4. Can't reproduce → candidate-cases ladder, then defer
- **A8** Not reproduced on the ticket's steps → **enumerate candidate trigger-cases** and drive each to try to trigger it: app state (empty / first-run / logged-out / offline) · remote-config/flag variant · timing/race (slow net, rapid taps, backgrounding) · data variant (long text, missing field, locale) · device/OS variant · build variant (release vs debug).
- **A9** A case reproduces → that's the trigger → proceed to root cause (A6) noting the exact condition.
- **A10** No case reproduces after the ladder → **defer as unreproducible; NEVER guess-fix.** Interactive → post a `[VN]` comment asking the reporter for exact steps / a video / the build + device, move the ticket back to **Request**. `--auto` → defer (`unreproducible`) + report.

## 5. Rigor
- **A11** **One evidence-backed root cause** — every claim cites a `file:line`, log, media frame, or repro observation. Split evidence → pick the single most-likely and put the one confirming check in *Câu hỏi cần làm rõ* (never present (a)/(b)/(c) as the answer).
- **A12** **Verifiability:** the repro steps you confirmed **become the Phase-5 verify script.** If you cannot state how Phase 5 will reproduce + verify the fix, the diagnosis is not done — clarify or defer.
- **A13** **Honest scope sizing** — state the files + blast radius so the confidence scorecard and fix-vs-defer decision are grounded, not optimistic.
- **A14** **No Phase-4 handoff without a confirmed or strongly-evidenced trigger.** Hypothesis-only → clarify (Fix-7) or defer (`--auto`) — do not branch/fix.

## Scorecard link
The **`deterministic_repro`** criterion in `references/helpers/confidence-rubric.md` is scored from the A4/A8 result: **reproduced on-device (A4) or via a candidate case (A9) → full points**; **not reproduced (A10) → 0** — which, with the other criteria, routes `--auto` to defer. Interactive `not device-verified` (A7b) scores repro conservatively (partial/0) and always still asks the dev at Fix-8.

## Analysis checklist (what "analyzed" means)
A ticket is properly analyzed only when: **reality-checked** (A1–A3) · **reproduced** on-device (A4–A6) or, interactive-only, static+flagged (A7b) or run through the ladder (A8–A9) · **or deferred** if unreproducible (A10) · with **one evidence-backed, verifiable, scoped root cause** (A11–A14). Anything short of this is not ready for Fix-8.
