#!/bin/bash
# Reproducible memory/CPU comparison: Lantern vs Google Chrome, same pages, same order.
#
# Chrome runs on a throwaway --user-data-dir so your real profile, history and session
# are never touched. That also means Chrome runs with no extensions, which makes it
# LIGHTER than a typical real-world Chrome -- the comparison is deliberately generous
# to Chrome.
#
#   ./tools/bench.sh              full run (~25 min)
#   IDLE_WAIT=60 ./tools/bench.sh quick run (skips the sleep-threshold wait)
set -uo pipefail
cd "$(dirname "$0")/.."

PAGES=(
  "https://en.wikipedia.org/wiki/Lantern"
  "https://news.ycombinator.com"
  "https://github.com/trending"
  "https://www.theverge.com"
  "https://www.cnn.com"
)
SETTLE=${SETTLE:-45}         # let pages finish loading before measuring
CPU_WINDOW=${CPU_WINDOW:-30} # both browsers fully awake: apples to apples
IDLE_WAIT=${IDLE_WAIT:-380}  # past Lantern's 5 min sleep threshold
KDIR="$HOME/Library/Application Support/Lantern"
CHROME_PROFILE="/tmp/lantern-bench-chrome-profile"
OUT=build/bench.tsv
mkdir -p build
[ -x build/waitwindow ] || swiftc -O -swift-version 5 -o build/waitwindow tools/waitwindow.swift

# Always hand the user's config back the way we found it, even on Ctrl-C.
restore_config() {
  python3 -c "
import json, os
p = os.path.expanduser('~/Library/Application Support/Lantern/config.json')
try: d = json.load(open(p))
except Exception: raise SystemExit
d['blockAdsAndTrackers'] = True
d['hibernateAfterMinutes'] = 5
json.dump(d, open(p, 'w'), indent=2)
"
  rm -rf "$CHROME_PROFILE"
}
trap restore_config EXIT INT TERM

# Lantern's sleep threshold is lowered for the benchmark so a run takes minutes rather
# than an hour. It is recorded in the results so the number is never implicit.
HIBERNATE_MIN=${HIBERNATE_MIN:-1}
set_hibernate() {
  python3 -c "
import json, os, sys
p = os.path.expanduser('~/Library/Application Support/Lantern/config.json')
d = json.load(open(p)); d['hibernateAfterMinutes'] = float(sys.argv[1])
json.dump(d, open(p, 'w'), indent=2)
" "$1"
}

now()  { perl -MTime::HiRes -e 'printf "%.3f", Time::HiRes::time()'; }
emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$OUT"; }
json() { ./tools/kmem --json "$1"; }
field() { python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('$1', 0))"; }

# Quit gracefully and wait for the processes to actually go away. Hard-killing Chrome
# leaves a stale SingletonLock, which makes the next launch bail out and measure zero.
quit_all() {
  osascript -e 'quit app "Google Chrome"' >/dev/null 2>&1
  osascript -e 'quit app "Lantern"' >/dev/null 2>&1
  local i=0
  while [ $i -lt 40 ]; do
    pgrep -f "Lantern.app/Contents/MacOS" >/dev/null 2>&1 ||       pgrep -f "Google Chrome.app/Contents/MacOS" >/dev/null 2>&1 || break
    sleep 0.5; i=$((i+1))
  done
  pkill -f "Lantern.app/Contents/MacOS" >/dev/null 2>&1
  pkill -f "Google Chrome" >/dev/null 2>&1
  sleep 2
  rm -f "$CHROME_PROFILE"/Singleton* 2>/dev/null
}

# Poll until the app actually reports processes, so we never measure a browser that
# failed to come up.
wait_running() {
  local app="$1" i=0
  while [ $i -lt 50 ]; do
    [ "$(json "$app" | field procs)" != "0" ] && return 0
    sleep 0.5; i=$((i+1))
  done
  echo "WARNING: $app never reported a running process" >&2
  return 1
}

# --- launch helpers -----------------------------------------------------------
lantern_launch()  { rm -f "$KDIR/session.json"; open -a /Applications/Lantern.app "$@"; }
lantern_cmd()     { echo "open -a /Applications/Lantern.app"; }
CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
chrome_launch() {
  # Refuse to start a second instance: a duplicate would forward URLs to whatever
  # profile is already open, including the real one.
  if pgrep -f "Google Chrome.app/Contents/MacOS" >/dev/null 2>&1; then
    echo "ABORT: a Chrome instance is already running; close it first." >&2
    exit 1
  fi
  "$CHROME_BIN" --user-data-dir="$CHROME_PROFILE" \
      --no-first-run --no-default-browser-check "$@" >/dev/null 2>&1 &
}

# Confirm Chrome is really on the throwaway profile before we measure anything.
# ps truncates args to terminal width without -ww, and a freshly launched Chrome can
# take a moment to exec, so poll before giving up.
# NB: no `grep -q` in a pipeline here. `-q` exits on first match, the upstream ps/grep
# takes SIGPIPE, and `set -o pipefail` reports the whole pipeline as failed -- which made
# this check flake depending on how many processes happened to match.
chrome_on_throwaway() {
  local n
  n=$(ps -axww -o args | grep -cF "user-data-dir=$CHROME_PROFILE")
  [ "${n:-0}" -gt 0 ]
}

assert_chrome_isolated() {
  local i=0
  while [ $i -lt 24 ]; do
    chrome_on_throwaway && return 0
    sleep 0.5; i=$((i+1))
  done
  echo "ABORT: Chrome is not running on the throwaway profile; refusing to measure." >&2
  quit_all; exit 1
}

# --- one full measurement pass ------------------------------------------------
# $1 label   $2 app-bundle-name   $3 window-owner-name   $4 launcher function
measure() {
  local label="$1" app="$2" owner="$3" launcher="$4"

  echo ">>> $label"
  quit_all

  # Warm-up launch, discarded: avoids first-run and cold-page-cache bias.
  $launcher >/dev/null 2>&1; sleep 8; quit_all

  # 1. Cold launch to a window on screen.
  local t
  if [ "$app" = "Google Chrome" ]; then
    t=$(./build/waitwindow "$owner" 40 -- "$CHROME_BIN" \
          --user-data-dir="$CHROME_PROFILE" --no-first-run --no-default-browser-check)
  else
    rm -f "$KDIR/session.json"
    t=$(./build/waitwindow "$owner" 40 -- open -a /Applications/Lantern.app)
  fi
  emit "$label" launch_seconds "$t"
  echo "    cold launch to window: ${t}s"
  [ "$app" = "Google Chrome" ] && assert_chrome_isolated

  # 2. Idle, one tab, nothing loaded.
  wait_running "$app" || { quit_all; $launcher >/dev/null 2>&1; wait_running "$app"; }
  sleep 8
  local j; j=$(json "$app")
  emit "$label" idle_footprint_bytes "$(echo "$j" | field footprint_bytes)"
  emit "$label" idle_procs "$(echo "$j" | field procs)"
  echo "    idle one tab: $(echo "$j" | field footprint_bytes) bytes, $(echo "$j" | field procs) procs"
  quit_all

  # 3. Open all pages in one launch, let them settle, measure.
  $launcher "${PAGES[@]}" >/dev/null 2>&1
  wait_running "$app"
  [ "$app" = "Google Chrome" ] && { sleep 5; assert_chrome_isolated; }
  sleep "$SETTLE"
  j=$(json "$app")
  local awake_fp awake_cpu
  awake_fp=$(echo "$j" | field footprint_bytes)
  awake_cpu=$(echo "$j" | field cpu_ns)
  emit "$label" awake_footprint_bytes "$awake_fp"
  emit "$label" awake_procs "$(echo "$j" | field procs)"
  echo "    ${#PAGES[@]} tabs awake: $awake_fp bytes, $(echo "$j" | field procs) procs"

  # 4. CPU over a short window while both browsers are fully awake.
  sleep "$CPU_WINDOW"
  j=$(json "$app")
  local cpu2; cpu2=$(echo "$j" | field cpu_ns)
  emit "$label" cpu_awake_ns_per_s "$(python3 -c "print(($cpu2-$awake_cpu)/$CPU_WINDOW)")"
  echo "    idle CPU while awake: $(python3 -c "print(round(($cpu2-$awake_cpu)/$CPU_WINDOW/1e7,1))")% of one core"

  # 5. Long idle: does the browser give memory back?
  sleep "$IDLE_WAIT"
  j=$(json "$app")
  local rest_fp; rest_fp=$(echo "$j" | field footprint_bytes)
  emit "$label" rest_footprint_bytes "$rest_fp"
  emit "$label" rest_procs "$(echo "$j" | field procs)"
  # No CPU figure for this phase on purpose: tabs are torn down during the window, so
  # summing per-process CPU counters loses the dead processes' time and goes negative.
  echo "    after ${IDLE_WAIT}s idle: $rest_fp bytes, $(echo "$j" | field procs) procs"
  quit_all
}

# --- run ----------------------------------------------------------------------
# ONLY=lantern|chrome runs a subset; APPEND=1 keeps existing rows (same page set and
# timings required, or the table mixes methodologies).
[ "${APPEND:-0}" = "1" ] || : > "$OUT"
rm -rf "$CHROME_PROFILE"
echo "pages: ${#PAGES[@]} | settle ${SETTLE}s | cpu window ${CPU_WINDOW}s | idle ${IDLE_WAIT}s"

python3 - <<'PY'
import json, os
p = os.path.expanduser("~/Library/Application Support/Lantern/config.json")
d = json.load(open(p)); d["blockAdsAndTrackers"] = True; json.dump(d, open(p, "w"), indent=2)
PY
set_hibernate "$HIBERNATE_MIN"
emit "meta" hibernate_minutes "$HIBERNATE_MIN"
emit "meta" pages "${#PAGES[@]}"
emit "meta" idle_wait_seconds "$IDLE_WAIT"
if [ "${ONLY:-all}" = "all" ] || [ "${ONLY:-all}" = "lantern" ]; then
  measure "Lantern" "Lantern" "Lantern" lantern_launch
fi

python3 - <<'PY'
import json, os
p = os.path.expanduser("~/Library/Application Support/Lantern/config.json")
d = json.load(open(p)); d["blockAdsAndTrackers"] = False; json.dump(d, open(p, "w"), indent=2)
PY
if [ "${ONLY:-all}" = "all" ] || [ "${ONLY:-all}" = "lantern" ]; then
  measure "Lantern (blocker off)" "Lantern" "Lantern" lantern_launch
fi

python3 - <<'PY'
import json, os
p = os.path.expanduser("~/Library/Application Support/Lantern/config.json")
d = json.load(open(p)); d["blockAdsAndTrackers"] = True; json.dump(d, open(p, "w"), indent=2)
PY

if [ "${ONLY:-all}" = "all" ] || [ "${ONLY:-all}" = "chrome" ]; then
  measure "Google Chrome" "Google Chrome" "Google Chrome" chrome_launch
fi

rm -rf "$CHROME_PROFILE"
rm -f "$KDIR/session.json"
echo
echo "=== raw results ($OUT) ==="
cat "$OUT"
