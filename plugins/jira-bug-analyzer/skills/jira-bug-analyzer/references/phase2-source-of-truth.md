# Phase 2 — Source-of-truth capture (per project + phase, background / non-blocking)

> The flow's second phase: **Intake (phase1) → Source-of-truth capture (THIS phase) → Analyze (phase3) → Fix (phase4).** Runs once per project+phase. It captures the **FULL project+phase ground truth** (Confluence spec, Figma, external-link content) into the shared memory repo — **phase-scoped, independent of which tickets were picked**, so the one capture serves every ticket in the phase and fixes match intended design, not just suppress the symptom (supersedes the old per-repo `CLAUDE.md` gate). **This is no longer a blocking gate.** The only synchronous step is **discovery (§2.0)** — which resolves the spec/figma links **automatically** in the common case and asks the dev **only** when detection comes back fuzzy or empty; the capture/digest itself runs in the **background** while Analyze (phase3) proceeds. Shared machinery it leans on lives in `references/run-blocks.md`; the memory mechanics + file schemas live in `references/helpers/memory.md`. Cross-cutting invariants are SKILL.md **Golden Rules** — cited by tag, not restated.

## When it runs — discover synchronously, capture in the background
Two parts, in order:
1. **Discover (synchronous — §2.0 below).** Resolve the spec + figma links. **Do NOT open with a paste prompt.** Walk the discovery ladder: a STRONG hit is adopted with **zero prompts**; a fuzzy/ambiguous result becomes a **one-tap pick-list**; only when the ladder finds **nothing** does the run fall back to the blocking free-text ask. **Spec + figma remain mandatory to END UP with** — what changed is that the agent now *finds* them instead of demanding them. The resolved links are themselves usable context immediately (phase3 Context-source rule), so analysis never waits for the digest.
2. **Capture (background, non-blocking).** Dispatch the `source-of-truth` subagent to capture the **complete phase ground truth — the FULL spec / figma / external content, NOT scoped to the picked tickets** — as a **background** task (`run_in_background: true`). Do **NOT** WAIT for it before the analyzer (multi: before the fan-out; single: before Fix-3). The one capture serves **every** ticket in the phase — never re-captured per pick, never trimmed to the picked subset. Analyze/Fix read the digest from memory **once it lands**, falling back to the resolved links until then (phase3 Context-source rule). Launch **once per phase per session** (cache the result; skip re-launch on later re-pull turns unless a source is flagged stale **or `metadata.json` still lists a pending external source** → re-attempt the direct read, per the external-sources section below).

## §2.0 — Auto-discovery ladder (run this BEFORE any ask)
The dev almost always already put the links where the agent can see them — on the ticket. Asking them to paste what is already on the ticket is pure friction. So: **detect first, ask last.**

Walk the rungs **in order and SHORT-CIRCUIT** — the moment spec (and figma) are resolved at STRONG, stop. In the common case the whole ladder costs **one `jira_get_issue` you were making anyway** (with an extra `include`). Every rung is MCP-native; **there is no discovery script**.

| # | Source | How | Tier | Fires in practice? |
|---|---|---|---|---|
| **L0** | `<PHASE>/doc/metadata.json` present + fresh | memory (already the cache path today) | — → SOT ready, **no discovery, no ask** | **often** (2nd+ run of a phase) |
| **L1** | `setup.json` `sotByPhase[<PHASE>]` | `assets/setup-json.sh get <file> sotByPhase.<PHASE>.spec` | **STRONG** | **often — the main win.** Asked once per phase, then never again |
| **L2** | The picked tickets' `description` + `comments` — Confluence/Figma URLs (**host-agnostic**, see "URL shapes") | free — bodies already in context from the pull. **Read the RAW wiki `description` from `jira_search`, NOT `jira_get_issue`** (see the corruption trap) | **STRONG** | **rarely** — only on tooling-created tickets |
| **L2b** | The tickets' **remote links** (+ parent) — a Confluence page *explicitly linked to the ticket* | `jira_get_issue(<KEY>, include="remote_links")` → `remote_links[].object.url` + `.title` | **STRONG** | **rarely** — see the coverage reality below |
| **L2c** | **Labels** — a ticket created by the `confluence-to-jira` tooling carries `auto-from-confluence` + `confluence-<page-slug>` | already in `fields.labels`; the slug names the spec page | **STRONG** | tooling-created tickets only |
| **L3a** | **Siblings of the previous phase's spec** — the old spec URL hands you the space *and* the parent for free | `confluence_get_page_children(<parent of sotByPhase[phaseN-1].spec>)`, match title `Phase <N>` | MEDIUM | when a prior phase was captured |
| **L3b** | Confluence search | `confluence_search` (raw CQL): `type=page AND text ~ "<PROJ>" AND title ~ "Phase <N>"`, limit 5, recent first | **FUZZY** | **the primary rung for human-filed bugs** → pick-list |
| **L4** | Figma links **inside the resolved spec body** | free — the capture already scans the spec for embedded links | **STRONG** | **the only realistic figma source** |
| **L5** | Figma file whose name matches the project/phase | `mcp__figma-bridge__list_files` | FUZZY | last resort |

### ⚠️ Coverage reality — measured, not assumed (do NOT promise "zero prompts" for bugs)
Probed against real Apero boards (AIP686 / AIP304 / AIP688), **the tickets this skill actually processes — human-filed bugs — carry no links at all**: `remote_links` is `[]`, there is no Confluence URL in the description or comments, and there are **ZERO `figma.com` URLs anywhere across all three projects** (designs get referenced as `prnt.sc` / `streamable.com` links or inline image attachments instead). Only tickets created by the `confluence-to-jira` tooling (labelled `auto-from-confluence`) carry a spec link.

So be honest about what each rung buys:
- **L2 / L2b / L2c are a bonus**, not the backbone — they fire on tooling-created tickets and essentially never on a hand-filed bug.
- **L1 is the real win**: the dev is asked **at most once per phase**, and the answer is then cached *per phase* (never mis-inherited from another phase, which is what happens today).
- **L3b is the primary discovery rung for a human-filed bug** → it produces a **pick-list**, not a silent adopt.
- **Figma will usually come from L4** (a link inside the spec) or from the ask. **Do not build a figma rung against ticket bodies** — there is nothing there to find.
- Expect **NONE → the paste-ask** to still fire on a fresh phase whose spec was never saved. That is correct behavior, not a failure.

### ⚠️ The URL-corruption trap — regex the RAW wiki field, never the converted one
`jira_get_issue` converts Jira wiki markup → markdown and **silently strips `+` from URLs**:
`…/display/PROJ/Phase+4%3A+Gamification` → `…/display/PROJ/Phase4%3AGamification` — **which 404s.** Any L2 body-regex that reads `jira_get_issue`'s `description` therefore yields dead links, unrecoverably (you cannot re-insert the spaces post-hoc).
- **L2b's `remote_links[].object.url` is NOT affected** — it is the only source that returns a correct URL. **Prefer it.**
- For L2, read the **raw wiki `description` via `jira_search`** (`fields=description`), where the link is still `[Title|https://…/Phase+4%3A+Gamification]`.
- Match the **wiki-markup link form**, not just a bare URL: `\[([^|\]]+)\|(https?://[^\]\s]+)\]`, and allow `+` and `%XX` in the path.
- On Jira **Server**, `remote_links[]` entries have **only** `object.url` + `object.title` — `relationship`, `globalId` and `application.name` are absent. Do not branch on them.

**A dead/absent MCP is not an error** — that rung is skipped and the ladder falls through to the next. Discovery must never crash or block the run.

### URL shapes — match HOST-AGNOSTICALLY (Cloud *and* self-hosted Server)
**Do NOT hardcode `atlassian.net`.** Many orgs (Apero included) run **self-hosted Confluence/Jira Server**, where the spec lives on `confluence.<org>` and the URL shape is completely different from Cloud's. A Cloud-only regex silently detects nothing and the whole ladder collapses to the paste-ask. Match **any** of:

| Product | Cloud | Self-hosted Server |
|---|---|---|
| **Confluence** | `<site>.atlassian.net/wiki/spaces/<SPACE>/pages/<ID>/<Title>` | `confluence.<org>/pages/viewpage.action?pageId=<ID>` · `confluence.<org>/display/<SPACE>/<Title>` |
| **Jira** | `<site>.atlassian.net/browse/<KEY>` | `jira.<org>/browse/<KEY>` |

→ Treat a URL as **Confluence** when its host contains `confluence`, **or** its path contains `/wiki/spaces/`, `/pages/viewpage.action`, or `/display/`. Figma is a fixed SaaS host: `figma.com/(design|file|proto|board)/…`.
→ The org's actual hosts are already known at runtime — derive them from the configured Jira/Confluence MCP base URLs rather than assuming, and never assume Cloud.
→ `sotByPhase[…].spec` may be stored as a bare URL string **or** as an object (`{"confluence": "<url>"}` — the shape some existing setups already carry). Accept both on read; write the bare string.

### Tier → behavior
| Outcome | Do this |
|---|---|
| **STRONG, unambiguous** | **Adopt. Zero prompts.** Emit ONE `[VN]` line naming the evidence, so the dev can catch a wrong adoption at a glance: `✅ Tự phát hiện spec: "AIP686 — Phase 3 Reader" (từ remote-link của AIP686-179)` · `✅ Tự phát hiện Figma: "Reader v2" (link nằm trong spec)` |
| **FUZZY**, or **≥2 STRONG candidates that disagree** | **One-tap `AskUserQuestion` `[OPTIONS]` pick-list** — top 3 candidates, each showing *title · nguồn · vì sao khớp* — plus `Dán link khác` (free-text) and `Không có`. Never a bare paste prompt. *(This is also what finally brings Phase 2 into line with `[OPTIONS]` — the old blank ask violated it.)* |
| **NONE** (ladder exhausted, nothing found) | Fall back to the **blocking free-text ask, unchanged** — the original behavior, now the last resort instead of the entry point. `spec`+`figma` still cannot be waived here. |
| **`[AUTO]` (`--auto`)** | STRONG → adopt. FUZZY/NONE → **never ask** (`[AUTO]` no-inline-asks): proceed with whatever was resolved and record the gap in the "what's missing" report + the end-of-run report. Discovery never stalls the auto loop. |

### The `<PHASE>` chicken-and-egg — read this before implementing L3
The phase is normally *derived from the spec title* (next section) — but L3a/L3b need the phase in order to *find* the spec. Resolve it this way:
- **`@N` given** → authoritative. It targets discovery; L3a/L3b are enabled.
- **No `@N`** → run the **ticket-local rungs ONLY** (L1 / L2 / L2b / L4 — none of them need to know the phase), then derive the phase from the found spec's title exactly as today. **Skip blind CQL** — searching for `title ~ "Phase <N>"` without an `N` is meaningless.

### Persist what was resolved
On adopt (STRONG) or confirm (pick-list), write the phase's entry to **BOTH** the local `.jira-bug/setup.json` mirror **AND** the shared `project/<PROJ>/setup.json`, same turn, via `memory-keeper` (`[BGMEM]` — background, non-blocking):
```
setup-json.sh merge-set <file> 'sotByPhase.phase3={"spec":"…","figma":"…","otherRefs":"…","detectedFrom":"remotelink:AIP686-179","confirmedBy":"hungnd","savedAt":"2026-07-14"}'
```
**Use the dotted form** — a plain `sotByPhase={…}` REPLACES the object and destroys the other phases' entries. Local-only = the next dev gets re-asked, so the shared push is mandatory, not deferred. Schema + the legacy-flat demotion rule: `references/helpers/memory.md`.

**`--rediscover`** forces a fresh detect: skip the L0 (`metadata.json`) and L1 (`sotByPhase`) short-circuits and re-walk the ladder from L2. Use it when the spec page moved, or a wrong page was adopted.

## Which phase folder — confirm `<PHASE>` from the spec title
Before writing anything, resolve `<PHASE>` (it scopes every path: `<PHASE>/doc/`, `<PHASE>/session/`, the `phaseX/` fix-branch prefix):
- An explicit **`@N` arg** (SKILL.md Mode dispatch) → `phase = phaseN`, authoritative.
- **No `@N`** → the subagent **reads the Confluence spec page title(s)/parent breadcrumb and derives the phase from it** (a "Phase 3 / Sprint 3 / Milestone 3" marker in the title → `phase3`). The spec title is the source of truth for which phase this work belongs to — do **not** default to `phase1` just because it's the fallback.
- Only if neither `@N` nor a phase-bearing title exists → `phase1`, and say so.
- If `@N` and the title disagree, honor `@N` but **surface the mismatch** to the dev. Record the resolved phase in the digest heading (e.g. `# <PROJ> Phase 3 — … Spec Digest`) so a wrong folder is caught early.

## What it captures
The **FULL phase content** (never a picked-ticket subset). **One `.md` per source** under `project/<PROJ>/<PHASE>/doc/`, each a digest (`status: present`) or — for an external source that couldn't be read — a `pending` placeholder:
- **`spec.md` (Confluence behavior + copy) — REQUIRED**, **`figma.md` (Figma link + per-screen `node-id`/name/layout notes) — REQUIRED**, **one `<slug>.md` per external source** (each Google Sheet / Drive / external URL the spec references gets its OWN file named for the source — e.g. `ad_script.md`, `iap_pricing.md`; peers of `spec.md`) **— captured whenever the spec references external sources**.
- **`[RAG]` STRUCTURE every digest for section-retrieval — never a blob.** `spec.md` and `figma.md` MUST be written as: (1) a **TOC at the very top** — a bullet list of `- <anchor-slug> — <screen / feature name>` for every section; then (2) **one `## <anchor-slug> — <screen / feature>` section per screen/feature**, chunked so each is self-contained. The anchor slug is stable kebab-case (e.g. `reader-unlock-sheet`, `home-banner`). This is what lets an analyzer read ONLY its ticket's section (Phase-3 Context-source rule) instead of the whole spec — the retrieval index, no vector store. Keep each section tight; cross-reference rather than duplicate. (`figma.md` sections key on the screen + its `node-id`; `<slug>.md` external sources stay single-purpose, no TOC needed.)
- **`metadata.json` — the status manifest AND the cache-coherence anchor AND the `[RAG]` retrieval index.** ONE file at `project/<PROJ>/<PHASE>/doc/metadata.json` recording per source: status · version · capturedAt · confirmedBy, **plus a `sections` array — the list of `<anchor-slug>` (+ one-line topic) present in that digest**. A single read tells the gate what's captured / stale / pending AND **which section maps to a ticket's screen/feature — so the analyzer retrieves the right anchor WITHOUT opening the whole digest first**. The keeper rewrites it (status + `sections`) on every gate run that touches a source.

### metadata.json is how local cache reconciles with remote memory — check it FIRST
At the start of the gate, reconcile the **local cache against remote memory via `metadata.json`** before doing anything else:
- **No `metadata.json` in remote memory** → **create one**, and **init the source of truth from the links resolved by the §2.0 discovery ladder** (auto-detected in the common case; the dev is asked only if the ladder returns NONE), then write `metadata.json` from the captured sources. (If the source digests `spec.md`/`figma.md` already exist but the manifest is missing — a legacy capture — offer to build the manifest from the present digests instead of forcing a full re-init; either way the run ends with a `metadata.json`.)
- **Local cache outdated vs the remote `metadata.json` version** → **update the local cache from remote** (re-pull / refresh the local mirror) before reading the digests, so analysis runs on the current SOT.
- **Local matches remote (versions equal, fresh)** → reuse silently.

Runs the memory-keeper `source-of-truth` action (`references/helpers/memory.md`). It reads `metadata.json` to decide per source: present + fresh → reuse; stale (live version newer) → re-capture + bump; absent → capture. Staleness rule + schemas live in `references/helpers/memory.md`.
- **`spec.md` + `figma.md` are MANDATORY to END UP WITH — there is NO skip/waive for these.** But **do NOT open with a paste prompt** — run the **§2.0 discovery ladder** first; it resolves them with zero prompts in the common case. Only when the ladder returns **NONE** → **ASK the dev to paste the Confluence + Figma link** and BLOCK the *ask* until both are supplied. The dev may not opt out, and "we don't have it" is not an accepted answer for these two — keep asking (or let the dev cancel the run). Once the links are resolved (detected **or** pasted), the **digest capture runs in the background** — do NOT block analysis waiting for the digest; the links are usable context immediately (phase3 Context-source rule). **`[AUTO]` never asks** — see the §2.0 tier table.

## External sources inside the spec → each its own peer file `<slug>.md` (read directly; unreadable → flag `pending`, re-try each run; does NOT block — NO request folder)
A Confluence spec routinely embeds links the Jira/Confluence MCP cannot read — **Google Sheets, Google Drive, external URLs**. **Each such source gets its OWN `.md` file named for it** (e.g. the spec references an "ad script" sheet → `ad_script.md`; an IAP-pricing sheet → `iap_pricing.md`), a peer of `spec.md` at the same `<PHASE>/doc/` level — NOT inlined into `spec.md`, NOT aggregated into one combined file. When distilling the spec, the `source-of-truth` subagent detects every such link, gives it a slug, and **reads it directly**:
- **Google Sheets** → `WebFetch` the CSV export `https://docs.google.com/spreadsheets/d/<ID>/export?format=csv&gid=<GID>` (follow the 307 redirect to the `googleusercontent.com` export host and fetch that). Works whenever the sheet is link-shared/public.
- **Google Drive file** → `WebFetch` `https://drive.google.com/uc?export=download&id=<ID>` (follow the 303 redirect to `drive.usercontent.google.com/download?...`). Works for link-shared files; binary (`.mxfile`/image/PDF) → capture a description/digest, note it's binary.
- Also try any authenticated Google MCP if connected (`Google_Drive`), else WebFetch is the default.
- **Readable (HTTP 200 / content returned)** → write the content into that source's own `<slug>.md` (`status: present`, `method: auto-direct-read`), add the source to `metadata.json` as `present`, **push**.
- **Unreadable (HTTP 401 / login / permission-denied)** → write `<slug>.md` with a `status: pending` placeholder (the link URL + a one-line note of what content it holds + the HTTP status seen) and add the source to `metadata.json` as `pending`. **There is NO `requests/` folder and NO co-worker hand-off** — the dev can paste the content straight into that `<slug>.md` if it's needed before a re-try succeeds.
- The capture does **NOT block** on pending external data: write `spec.md` + every readable `<slug>.md` as `status: present` from the accessible content and **proceed** — analysis runs with available context, the pending sources explicitly flagged so the fixer doesn't silently guess them.
- **Re-try (every turn that hits the capture, incl. `--resume`):** if `metadata.json` lists any external source still `pending`, the subagent `pull 0`s and **re-attempts the direct read** — now readable → fill its `<slug>.md`, flip it `present` in `metadata.json`, push the updated `<slug>.md` + `metadata.json`; still unreadable → keep flagged, proceed. This is the only case where the capture re-runs work on a later turn despite the per-phase cache.

## Tell the dev WHAT is missing — mandatory, every run (`[VN]`)
When the gate returns and the SOT is not 100% complete, the orchestrator **must show the dev an itemized "what's missing" report** — never a bare count like *"6 external links"*. The dev has to know precisely what is absent and what to do about it. Print it `[VN]` whenever **any** of these hold (re-pull / cached / `--resume` turns included — re-show it each turn until the gaps close):
- an external source's `<slug>.md` is still `status: pending` (mirrored in `metadata.json`) — a Google Sheet/Drive/URL the MCP couldn't read, or
- a required source had to be pasted manually / is partial.

**The SOT is phase-scoped — its only goal is to build/maintain the source of truth, NOT to serve a ticket set.** Report the WHOLE phase's source gaps. **Do NOT tie gaps to tickets** — no "affects tickets" / "Ảnh hưởng vé" / `informs`-ticket column. The report is purely about which source data is present / missing / pending for the phase.

Format — one row per phase gap, with enough to act (NO ticket column):
```markdown
⚠️ Source-of-truth chưa đầy đủ — Phase <N> (<PROJ>)
| Thiếu gì | Nội dung đang chờ | Vì sao thiếu / cách lấy |
|---|---|---|
| Google Sheet: IAP (iap_pricing.md) | SKU/giá coin-pack cho auto-burn | Link 401 (không đọc trực tiếp được) — tự thử lại mỗi lượt; hoặc dev dán nội dung vào iap_pricing.md |
…
→ Việc dựng source-of-truth VẪN hoàn tất với phần đã đọc được; các ô trên là dữ liệu BỔ SUNG còn chờ (link chưa đọc được), không tự bịa.
```
State plainly: which gaps are **blocking** (a required `spec`/`figma` link that discovery could not resolve AND the dev never supplied at the NONE-fallback ask → `blocked`, stop — analysis can't begin without *some* spec/figma input) vs which are **non-blocking** (pending external sources → proceed, flagged). Tell the dev the concrete next step per row — the capture re-attempts the direct read on the next run, or the dev can paste the content into that source's `<slug>.md` themselves. **Do not bury this in a one-liner.**

## Push + return
Push each touched file as its own commit — `spec.md` / `figma.md` / each external `<slug>.md` plus **`metadata.json`** (always rewritten when any source changed). The background subagent returns one of:
- **`capturing`** — the mandatory links were resolved (detected via §2.0, or pasted) and the digest is still being written. This is the normal launch result: Analyze (phase3) proceeds **immediately** on the resolved links and switches to the digest once it lands (Context-source rule). The capture pushes its files when done.
- **`ready` | `built`** — the digest finished (cached/fresh or freshly captured). A pending external link is **not** a block (the spec is resolved; only a downstream Sheet is awaited) — it still returns `ready` **with the itemized "what's missing" report above shown to the dev** (not just a count).
- **`blocked`** — a **required** source (`spec`/`figma`) was neither resolved by the §2.0 ladder nor supplied at the NONE-fallback ask. **On `blocked`, do NOT dispatch analyzers** — surface which required link is missing and stop. The subagent's return MUST carry the structured pending list (per row: what / awaited content / why-unreadable) so the orchestrator can render the table verbatim.

> Confluence + Figma MCP were already provisioned at **init** (the required `MCP_SETUP` step) — at capture time only **re-confirm liveness** (ToolSearch `mcp__confluence__*` / `mcp__figma__*`); do NOT provision/add defs here. Still not live despite init setup (e.g. a connector hiccup) → ask the dev to paste the Confluence/Figma content as the fallback.

Once the mandatory links are resolved — detected by §2.0 or, failing that, pasted (return `capturing`/`ready`/`built`) → proceed to **Phase 3** (`references/phase3-analyze.md`): claim → analyze. Only `blocked` (a required link neither detected nor supplied) stops the run.
