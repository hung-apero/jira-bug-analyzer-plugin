#!/usr/bin/env bash
# Google-Sheet-as-board fetch + parse for the jira-bug-analyzer skill (`--google-sheet`).
# Deterministic, robust CSV handling (real csv parser — quoted fields / embedded newlines in the
# multi-line "Chi tiết" cell must not split a row). The MODEL never line-splits the CSV itself.
#
# Read-only: downloads the sheet's CSV export, locates the header row (a QC sheet has a status-legend
# block ABOVE the header), auto-detects columns by an EN+VN alias table, extracts each bug row, and
# harvests attachment URLs from the details/summary/expected cells (attachments live INSIDE the
# "Chi tiết" column as ibb.co / streamable links — not a dedicated column). Never writes the sheet.
#
# Usage:
#   sheet-board.sh csv-url <any-sheet-URL>          -> prints the derived CSV export URL
#   sheet-board.sh fetch   <csvUrl> [columnMapJson] -> prints JSON {columnMap, headerRow, rows[],
#                                                       warnings[], needMap[]} (columnMapJson overrides
#                                                       the auto-detected map, key=header-name)
#
# rows[] entry: {id, feature, summary, details, expected, status, priority, reporter,
#                attachments:[{url,kind}]}  (kind ∈ image|video|link)
set -euo pipefail

cmd="${1:-}"; shift || true

case "$cmd" in
  csv-url)
    url="${1:-}"
    python3 - "$url" <<'PY'
import re,sys
u=sys.argv[1] if len(sys.argv)>1 else ""
m=re.search(r'/spreadsheets/d/([a-zA-Z0-9_-]+)', u)
if not m:
    print(""); sys.exit()
sid=m.group(1)
g=re.search(r'[#&?]gid=([0-9]+)', u)
gid=g.group(1) if g else "0"
print(f"https://docs.google.com/spreadsheets/d/{sid}/export?format=csv&gid={gid}")
PY
    ;;
  fetch)
    csvurl="${1:-}"; mapjson="${2:-}"
    [ -n "$csvurl" ] || { echo '{"rows":[],"warnings":["missing csvUrl"],"needMap":[]}'; exit 0; }
    tmp="$(mktemp 2>/dev/null || echo /tmp/sheet-board.$$.csv)"
    trap 'rm -f "$tmp"' EXIT
    # -L follow the 307 to googleusercontent; empty file on failure -> parser reports it.
    curl -sL --max-time 30 "$csvurl" -o "$tmp" 2>/dev/null || true
    python3 - "$tmp" "$mapjson" <<'PY'
import csv,json,re,sys
path=sys.argv[1]; mapraw=sys.argv[2] if len(sys.argv)>2 else ""
override={}
if mapraw:
    try: override={k:v for k,v in json.loads(mapraw).items()}
    except Exception: override={}

# --- field -> header aliases (lowercased, EN + VN). first match wins per field ---
ALIASES={
 "id":       ["n°","no","no.","stt","id","key","#","bug id","bug no"],
 "feature":  ["feature","tính năng","tinh nang","màn hình","man hinh","screen","module"],
 "summary":  ["tóm tắt lỗi","tom tat loi","tóm tắt","tom tat","summary","title","tiêu đề","mô tả lỗi","mo ta loi","issue","bug"],
 "details":  ["chi tiết","chi tiet","detail","details","mô tả","mo ta","description","note","ghi chú"],
 "expected": ["kết quả mong muốn","ket qua mong muon","expected","expected result","mong muốn"],
 "status":   ["trạng thái","trang thai","status","state"],
 "priority": ["mức độ","muc do","severity","priority","mức độ ưu tiên","sev"],
 "reporter": ["người phát hiện lỗi","nguoi phat hien loi","người phát hiện","reporter","tester","qc","phát hiện"],
}
REQUIRED=["summary","status"]

def norm(s): return re.sub(r'\s+',' ',(s or "").strip().lower())

try:
    with open(path,newline='',encoding='utf-8',errors='replace') as f:
        table=list(csv.reader(f))
except Exception as e:
    print(json.dumps({"rows":[],"warnings":["read failed: %s"%e],"needMap":[]})); sys.exit()

if not table or not any(any(c.strip() for c in r) for r in table):
    print(json.dumps({"rows":[],"warnings":["empty CSV (sheet not link-shared, wrong gid, or fetch failed)"],"needMap":[]})); sys.exit()

# --- locate the header row: scan first 40 rows for the best alias-match row that also has summary+status ---
def match_map(row):
    m={}; used=set()
    for i,cell in enumerate(row):
        n=norm(cell)
        if not n or i in used: continue
        for field,al in ALIASES.items():
            if field in m: continue
            if n in al or any(n==a for a in al):
                m[field]=i; used.add(i); break
    return m

best=None; best_i=-1; best_score=-1
for i,row in enumerate(table[:40]):
    m=match_map(row)
    score=len(m)+ (2 if "summary" in m else 0)+(1 if "status" in m else 0)
    # a header row = summary detected, OR a clearly-header row (≥3 alias hits) whose missing
    # required columns the dev can supply via the override map.
    if score>best_score and ("summary" in m or len(m)>=3):
        best,best_i,best_score=m,i,score

warnings=[]; needMap=[]
if best is None:
    print(json.dumps({"rows":[],"warnings":["no header row found (looked for a Summary/Tóm tắt column in the first 40 rows)"],"needMap":REQUIRED})); sys.exit()

header=table[best_i]
colmap={f: (header[idx].strip() if idx < len(header) and header[idx].strip() else "col%d"%idx) for f,idx in best.items()}
idx_by_field=dict(best)
# apply overrides (field -> header NAME): resolve name back to a column index
if override:
    hlower=[norm(h) for h in header]
    for f,name in override.items():
        nn=norm(name)
        if nn in hlower:
            idx_by_field[f]=hlower.index(nn); colmap[f]=header[hlower.index(nn)].strip()
for req in REQUIRED:
    if req not in idx_by_field: needMap.append(req)
if needMap:
    print(json.dumps({"columnMap":colmap,"headerRow":best_i,"rows":[],"warnings":warnings,"needMap":needMap})); sys.exit()

# --- attachment URL harvesting + image/video classification ---
URL=re.compile(r'https?://[^\s,;"\']+')
IMG_HOST=("ibb.co","imgur.com","i.imgur","prnt.sc","postimg","imgbb")
VID_HOST=("streamable.com","loom.com","youtube.com","youtu.be","vimeo.com")
IMG_EXT=(".png",".jpg",".jpeg",".webp",".gif",".bmp")
VID_EXT=(".mp4",".mov",".webm",".mkv",".avi")
def classify(u):
    lu=u.lower()
    if any(h in lu for h in VID_HOST) or lu.endswith(VID_EXT): return "video"
    if any(h in lu for h in IMG_HOST) or lu.endswith(IMG_EXT): return "image"
    if "drive.google" in lu: return "link"
    return "link"

def cell(row,f):
    i=idx_by_field.get(f)
    return row[i].strip() if (i is not None and i < len(row)) else ""

rows=[]; blanks=0
for row in table[best_i+1:]:
    if not any(c.strip() for c in row):
        blanks+=1
        if blanks>=3: break
        continue
    blanks=0
    summary=cell(row,"summary")
    idv=cell(row,"id")
    if not summary: continue                 # a bug row must have a summary
    urls=[]; seen=set()
    for f in ("details","summary","expected"):
        for u in URL.findall(cell(row,f)):
            u=u.rstrip(').,;')
            if u not in seen: seen.add(u); urls.append({"url":u,"kind":classify(u)})
    rows.append({
        "id": idv,
        "feature": cell(row,"feature"),
        "summary": summary,
        "details": cell(row,"details"),
        "expected": cell(row,"expected"),
        "status": cell(row,"status"),
        "priority": cell(row,"priority"),
        "reporter": cell(row,"reporter"),
        "attachments": urls,
    })

if not rows: warnings.append("header found but no bug rows below it")
print(json.dumps({"columnMap":colmap,"headerRow":best_i,"rows":rows,"warnings":warnings,"needMap":[]},ensure_ascii=False))
PY
    ;;
  *)
    echo "usage: sheet-board.sh csv-url <sheet-url> | fetch <csvUrl> [columnMapJson]" >&2
    exit 2
    ;;
esac
