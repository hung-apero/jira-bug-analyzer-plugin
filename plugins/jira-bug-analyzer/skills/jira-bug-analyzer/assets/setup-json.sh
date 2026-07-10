#!/usr/bin/env bash
# Canonical, trailing-comma-tolerant read/write for jira-bug-analyzer setup.json files.
#
# This is the ONE place setup.json is written. Every save goes through json.dump so the file
# is ALWAYS valid JSON — a hand-written trailing comma (e.g. `"savedBy": "x",}`) is exactly what
# silently broke remote-config reuse: strict json.load threw, so a PRESENT config read as empty,
# the local mirror never hydrated, and baseBranch never round-tripped. Reads here strip trailing
# commas before parsing, so an already-corrupt file still resolves AND self-heals on the next write.
#
# Usage:
#   setup-json.sh get       <file> <key>            -> prints value ('' if absent/unparseable)
#   setup-json.sh merge-set <file> key=val [key=val...] -> merge keys into <file>, canonical write
#
# merge-set values: parsed as JSON when valid (objects/arrays/numbers/bool), else taken as a string.
#   setup-json.sh merge-set s.json baseBranch=develop savedBy=hungnd
#   setup-json.sh merge-set s.json 'pullQuery={"jql":"...","sprintMode":"sprinted"}'

set -euo pipefail

cmd="${1:-}"; shift || true

case "$cmd" in
  get)
    file="${1:-}"; key="${2:-}"
    [ -f "$file" ] || { printf ''; exit 0; }
    python3 - "$file" "$key" <<'PY' 2>/dev/null || printf ''
import json, re, sys
path, key = sys.argv[1], sys.argv[2]
try:
    text = open(path).read()
except Exception:
    print(""); sys.exit()
try:
    d = json.loads(text)
except Exception:
    # tolerate trailing commas: `,}` / `,]`
    try:
        d = json.loads(re.sub(r',(\s*[}\]])', r'\1', text))
    except Exception:
        print(""); sys.exit()
v = d.get(key, "") if isinstance(d, dict) else ""
if v in (None, False):
    v = ""
print(v if isinstance(v, str) else json.dumps(v))
PY
    ;;
  merge-set)
    file="${1:-}"; shift || true
    [ -n "$file" ] || { echo "merge-set: missing <file>" >&2; exit 2; }
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    python3 - "$file" "$@" <<'PY'
import json, re, sys
path = sys.argv[1]
pairs = sys.argv[2:]
d = {}
try:
    text = open(path).read()
    try:
        d = json.loads(text)
    except Exception:
        d = json.loads(re.sub(r',(\s*[}\]])', r'\1', text))   # self-heal trailing commas
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}
for p in pairs:
    if "=" not in p:
        continue
    k, v = p.split("=", 1)
    try:
        d[k] = json.loads(v)          # objects/arrays/numbers/bool
    except Exception:
        d[k] = v                       # plain string
json.dump(d, open(path, "w"), indent=2)
open(path, "a").write("\n")
PY
    ;;
  *)
    echo "usage: setup-json.sh get <file> <key> | merge-set <file> key=val [key=val...]" >&2
    exit 2
    ;;
esac
