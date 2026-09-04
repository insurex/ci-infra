#!/usr/bin/env bash
# Step-level view: which step of the CURRENT job is running, and whether it failed.
# Follows the newest worker log, auto-switching when a new job starts.
# Note: the runner writes "Step result:" EMPTY for successful steps, so a step that
# just scrolls past passed; failures are marked explicitly, as is the final job result.
set -u
DIAG="${RUNNER_DIAG:-$HOME/actions-runner/_diag}"
cd "$DIAG" 2>/dev/null || { echo "runner-steps: no such dir: $DIAG" >&2; exit 1; }
G=$'\033[0;32m'; R=$'\033[0;31m'; C=$'\033[1;36m'; N=$'\033[0m'
filter() {
  sed -u -nE \
    -e "s/.*Processing step: DisplayName='([^']+)'.*/\1/p" \
    -e "s/.*Step result: ([A-Za-z]+).*/RESULT:\1/p" \
    -e "s/.*Job result after all job steps finish: ([A-Za-z]+).*/JOB:\1/p" \
  | while IFS= read -r l; do
      case "$l" in
        RESULT:Failed)    printf "     %sX failed%s\n" "$R" "$N" ;;
        RESULT:*)         printf "     - %s\n" "${l#RESULT:}" ;;
        JOB:Succeeded)    printf "  %s== JOB SUCCEEDED ==%s\n" "$G" "$N" ;;
        JOB:Failed)       printf "  %s== JOB FAILED ==%s\n" "$R" "$N" ;;
        JOB:*)            printf "  == JOB %s ==\n" "${l#JOB:}" ;;
        *)                printf "  %s\n" "$l" ;;
      esac
    done
}
cur=""; tp=""
cleanup() { [ -n "$tp" ] && kill "$tp" 2>/dev/null; echo; exit 0; }
trap cleanup INT TERM
echo "watching steps in $DIAG (Ctrl-C to stop)..."
while :; do
  new=$(ls -t Worker_*.log 2>/dev/null | head -1)
  if [ -n "$new" ] && [ "$new" != "$cur" ]; then
    [ -n "$tp" ] && kill "$tp" 2>/dev/null
    cur="$new"
    printf "\n%s=== %s ===%s\n" "$C" "$cur" "$N"
    ( tail -n +1 -f "$cur" | filter ) & tp=$!
  fi
  sleep 2
done
