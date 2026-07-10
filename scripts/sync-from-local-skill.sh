#!/usr/bin/env bash
# Re-publish the live skill at ~/.claude/skills/jira-bug-analyzer into this plugin.
# Run after editing the skill locally, then commit + push this repo.
#
#   ./scripts/sync-from-local-skill.sh            # sync + show diff
#   SKILL_SRC=/path/to/skill ./scripts/sync-from-local-skill.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SKILL_SRC="${SKILL_SRC:-$HOME/.claude/skills/jira-bug-analyzer}"
DEST="$REPO_ROOT/plugins/jira-bug-analyzer/skills/jira-bug-analyzer"

if [ ! -f "$SKILL_SRC/SKILL.md" ]; then
  echo "ERROR: source skill not found at $SKILL_SRC (no SKILL.md). Set SKILL_SRC=..." >&2
  exit 1
fi

echo "Syncing: $SKILL_SRC  ->  $DEST"
mkdir -p "$DEST"
# --delete so removed files in the source disappear here too. Never touch VCS/OS cruft.
rsync -a --delete --exclude '.DS_Store' "$SKILL_SRC/" "$DEST/"

echo ""
echo "Done. Review changes:"
( cd "$REPO_ROOT" && git status --short "plugins/jira-bug-analyzer/skills/jira-bug-analyzer" || true )
echo ""
echo "Next: bump version in plugins/jira-bug-analyzer/.claude-plugin/plugin.json + .claude-plugin/marketplace.json,"
echo "      then: git add -A && git commit -m 'chore: sync skill' && git push"
