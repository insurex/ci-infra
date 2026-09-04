#!/usr/bin/env bash
# Follow the newest GitHub Actions *worker* log, auto-switching when a new job starts.
# Usage: runner-tail            # follow job logs
#        runner-tail -n 100     # show 100 lines of context on each switch
set -u
DIAG="${RUNNER_DIAG:-$HOME/actions-runner/_diag}"
CTX="${2:-20}"; [ "${1:-}" = "-n" ] || CTX=20
cd "$DIAG" 2>/dev/null || { echo "runner-tail: no such dir: $DIAG" >&2; exit 1; }
cur=""; tp=""
cleanup() { [ -n "$tp" ] && kill "$tp" 2>/dev/null; echo; exit 0; }
trap cleanup INT TERM
echo "watching $DIAG for new jobs (Ctrl-C to stop)..."
while :; do
  new=$(ls -t Worker_*.log 2>/dev/null | head -1)
  if [ -n "$new" ] && [ "$new" != "$cur" ]; then
    [ -n "$tp" ] && kill "$tp" 2>/dev/null
    cur="$new"
    printf '\n\033[1;36m=== %s ===\033[0m\n' "$cur"
    tail -n "$CTX" -f "$cur" & tp=$!
  fi
  sleep 2
done
