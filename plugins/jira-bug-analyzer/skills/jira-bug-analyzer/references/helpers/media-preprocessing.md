# Media preprocessing — shrink before a native-vision Read (`[TOKEN]`, FALLBACK path only)

> **This recipe applies ONLY on the native-vision FALLBACK path.** The primary path is human-mcp (`references/helpers/media-analysis.md`) — it takes a file path and returns text, so bytes never enter Claude's context and there is nothing to shrink. Use the shrink steps below ONLY when human-mcp is unavailable (exhausted-today / not configured) and Claude-native vision Reads the bytes into context. In that case: multimodal Reads dominate token cost — a raw phone screenshot or 4K image costs thousands of tokens, a whole video far more — so shrink first.
>
> **Keep ONE full-resolution copy on disk for evidence** (PR / Jira attachment); Read the **shrunk** copy for analysis.

## Images — Jira attachments · on-device screencaps · Figma reference shots
- **Resize to ≤1280px long edge before Read** (analysis inputs — Jira attachments; ≤1280 keeps on-screen text/UI legible for the root-cause read). Phone screenshots are 1080×2400+ — wasteful. macOS: `sips -Z 1280 in.png --out small.jpg`. Portable (`imagemagick` skill): `magick in.png -resize '1280x1280>' -quality 80 small.webp`. **Read `small.*`, never the original.**
- **Compress to JPEG/WebP q80** — UI/text stays legible at a fraction of the bytes/tokens. Convert PNG screenshots → JPEG/WebP unless transparency is load-bearing.
- **Crop to the region of interest** when the bug is one widget: `magick in.png -crop WxH+X+Y roi.png` — Read the crop, not the whole screen.
- A device screencap taken only to *navigate* (find a tap target) can be resized harder (≤512px) — full detail is only needed for the decisive before/after states.

## Video — Jira repro attachments / hosted links
- **Never Read the whole mp4.** Use the Fix-5 ladder (`references/phase3-analyze.md`): extract frames — `fps=1`, or scene-change only `select='gt(scene,0.3)'` — into a `scale=300:-1` tile montage and Read that; zoom only the transition/crash window (`-ss <t> -t <dur> -vf "fps=6,..."`).
- **Trim** intro/outro/idle segments before extracting frames.
- **Narrated** video (rare for bug repros) → transcribe the audio (`ai-multimodal` / whisper) and Read the text where the narration carries the info — cheaper than frames.
- The skill's own `screenrecord` evidence is **saved for proof, not Read back** — observe behaviour via live screencaps during the drive; only the *Jira repro* video gets the extract-and-Read treatment.

## Documents — Confluence spec / Figma / external Sheets
- Already digested incrementally into `spec.md` / `figma.md` at Phase 2 (that IS summarize-incrementally + RAG). At Analyze/Verify, read the **relevant section / Figma node**, not the whole page (Context-source rule, `references/phase3-analyze.md`). Never dump a 100-page Confluence page into context — extract the screen's section.
