# Jira Bug Analyzer — Claude Code Plugin

A Claude Code plugin that packages the **jira-bug-analyzer** skill: a harness-loop agent
that fetches Jira bug tickets via MCP, analyzes attached images/videos, scores each bug
against a confidence rubric, verifies fixes on-device via `adb`, opens PRs, and learns into
a shared GitHub memory.

Modes: **single** (fix one ticket by key), **multi** (pull the board, fix several together),
**manager** (`--manager` — PR review comments, worktree cleanup, KB backfill), **team** (`--team`).

## Install

```bash
# 1. Add this marketplace (private repo — requires gh access to hung-apero/jira-bug-analyzer-plugin)
/plugin marketplace add hung-apero/jira-bug-analyzer-plugin

# 2. Install the plugin
/plugin install jira-bug-analyzer@apero-tools
```

Then invoke the skill:

```
/jira-bug-analyzer AIP686-179     # single mode (ticket key)
/jira-bug-analyzer AIP686         # multi mode (project/board key)
/jira-bug-analyzer --manager AIP686
```

## Prerequisites

The skill auto-installs its MCP servers on first run (jira, confluence, figma, human-mcp)
and prompts for the per-dev `JIRA_PERSONAL_TOKEN`. It also expects, at their gates:
`gh` (authenticated with access to the memory repo `hung-apero/jira-bug-memory`), `adb`
(for on-device verify), and a Gradle Android project for the fix/build phases.

## Repo layout (marketplace + plugin monorepo)

```
.claude-plugin/marketplace.json          # marketplace manifest (name: apero-tools)
plugins/jira-bug-analyzer/
  .claude-plugin/plugin.json             # plugin manifest
  skills/jira-bug-analyzer/              # the skill (SKILL.md + assets + references + team)
scripts/sync-from-local-skill.sh         # re-publish the live ~/.claude skill into this repo
```

## Maintaining

The skill in this repo is a published copy of the live skill at
`~/.claude/skills/jira-bug-analyzer`. After editing the live skill:

```bash
./scripts/sync-from-local-skill.sh
# bump version in plugins/jira-bug-analyzer/.claude-plugin/plugin.json + marketplace.json
git add -A && git commit -m "chore: sync skill" && git push
```

Consumers pick up the update with `/plugin marketplace update apero-tools`.
