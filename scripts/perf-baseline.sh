#!/bin/bash
# scripts/perf-baseline.sh — reproducible perf baseline for Treemux.
# Usage: bash scripts/perf-baseline.sh /path/to/Debug/Treemux.app
# Scenarios:
#   A. cold start with a pre-expanded ~1000-row file tree (10s sample)
#   B. git-status refresh with that tree visible (8s sample, touch .git/index)
set -euo pipefail

APP="${1:?usage: perf-baseline.sh <Treemux.app>}"
FIXTURE="$HOME/.treemux-perf-fixture"
STATE_DIR="$HOME/.treemux-debug"
OUT_DIR="$(mktemp -d)"
PID=""

# --- 0. Safety net: make sure we never leave a debug Treemux process running,
# even if `sample` fails or the script is interrupted mid-way.
cleanup() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Poll `pgrep -f "$1"` until it reports no match, up to "$2" seconds
# (0.3s interval). Returns 0 once gone, 1 on timeout (caller decides severity).
wait_for_gone() {
  local pattern="$1" timeout_s="$2" tries
  tries=$(( (timeout_s * 10 + 2) / 3 ))
  for ((i = 0; i < tries; i++)); do
    pgrep -f "$pattern" >/dev/null 2>&1 || return 0
    sleep 0.3
  done
  return 1
}

# --- 1. Synthetic repo: 10 dirs x 100 files = 1000 tree rows, deterministic.
if [ ! -d "$FIXTURE/.git" ]; then
  rm -rf "$FIXTURE"; mkdir -p "$FIXTURE"
  ( cd "$FIXTURE"
    git init -q
    for d in $(seq -w 1 10); do
      mkdir -p "dir$d"
      for f in $(seq -w 1 100); do echo "x" > "dir$d/file$f.txt"; done
    done
    git add -A && git -c user.email=perf@treemux -c user.name=perf commit -qm seed )
fi

# --- 2. Seed debug state: fileBrowser tab with all 10 dirs expanded.
pkill -f "$APP/Contents/MacOS/Treemux" 2>/dev/null || true
wait_for_gone "$APP/Contents/MacOS/Treemux" 5 || \
  echo "warn: old Treemux process still around after 5s, continuing anyway" >&2
rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
python3 - "$FIXTURE" "$STATE_DIR" <<'PY'
import json, sys, uuid
fixture, state_dir = sys.argv[1], sys.argv[2]
u = lambda: str(uuid.uuid4()).upper()
ws_id, tab_id = u(), u()
expanded = [f"{fixture}/dir{d:02d}" for d in range(1, 11)]
state = {"selectedWorkspaceID": ws_id, "version": 1, "workspaces": [{
  "id": ws_id, "isArchived": False, "isBuiltInDefaultTerminal": False,
  "isPinned": False, "kind": "repository", "name": "perf-fixture",
  "repositoryPath": fixture,
  "worktreeStates": [{"selectedTabID": tab_id, "worktreePath": fixture, "tabs": [{
    "id": tab_id, "isManuallyNamed": False, "kind": "fileBrowser",
    "layout": {"pane": {"_0": {"paneID": u()}}}, "panes": [], "title": "files",
    "fileBrowserState": {"rootPath": fixture, "rootKind": "project",
      "splitRatio": 0.28, "expandedDirs": expanded, "showsHiddenFiles": False,
      "subTabs": [], "activeSubTabID": None}}]}]}]}
json.dump(state, open(f"{state_dir}/workspace-state.json", "w"), indent=2)
PY

# --- 3. Scenario A: launch + 10s sample.
open "$APP"
for ((i = 0; i < 50; i++)); do  # 50 * 0.3s = 15s
  PID=$(pgrep -nf "$APP/Contents/MacOS/Treemux" 2>/dev/null || true)
  [ -n "$PID" ] && break
  sleep 0.3
done
if [ -z "$PID" ]; then
  echo "error: Treemux did not launch within 15s (no process matched $APP/Contents/MacOS/Treemux)" >&2
  exit 1
fi
sample "$PID" 10 -file "$OUT_DIR/a.txt" >/dev/null 2>&1
RSS_A=$(ps -o rss= -p "$PID" | tr -d ' ')

# --- 4. Scenario B: git refresh + 8s sample.
sleep 2
sample "$PID" 8 -file "$OUT_DIR/b.txt" >/dev/null 2>&1 &
SP=$!; sleep 1; touch "$FIXTURE/.git/index"; wait $SP
RSS_B=$(ps -o rss= -p "$PID" | tr -d ' ')
kill "$PID" 2>/dev/null || true

# --- 5. Parse main-thread SwiftUI-graph sample counts.
report() {
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
path, label, rss = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, errors="ignore").read().splitlines()
main, out = [], None
for l in lines:
    m = re.match(r"^    (\d+) Thread_\d+.*(Main Thread|DispatchQueue_1)", l)
    if m: out = int(m.group(1)); main = []; continue
    if out is not None:
        if re.match(r"^    \d+ Thread_", l): break
        main.append(l)
if out is None:
    print(f"error: no main-thread sample block found in {path} (label={label}); "
          f"'sample' output format may have changed, or the process exited before sampling",
          file=sys.stderr)
    sys.exit(1)
body = "\n".join(main)
def count(pat):
    # NOTE: pat may contain alternation ("A|B"); wrap it in a non-capturing
    # group so Python's regex "|" (lowest precedence) doesn't split across
    # the whole expression and strand the (\d+) capture group on one branch
    # only (that produced empty-string matches -> int('') crash).
    return sum(int(n) for n in re.findall(r"(\d+) [^\n]*(?:" + pat + ")", body))
print(f"| {label} | {out} | {count('ViewGraph')} | {count('AG::|AGGraph')} | "
      f"{count('NSHostingView')} | {int(rss)//1024}MB |")
PY
}
echo "| 场景 | 主线程样本 | ViewGraph | AttributeGraph | NSHostingView | RSS |"
echo "|---|---|---|---|---|---|"
report "$OUT_DIR/a.txt" "A 启动+1000行树(10s)" "$RSS_A"
report "$OUT_DIR/b.txt" "B git刷新(8s)" "$RSS_B"
echo "(raw samples: $OUT_DIR)"
