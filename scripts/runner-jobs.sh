#!/usr/bin/env bash
# Job-level view: what the runner is working on, and whether it passed.
# Usage: runner-jobs        # live
#        runner-jobs -n 40  # last 40 job events, no follow
# Auto-detect the runner service on this host; RUNNER_SVC overrides.
SVC="${RUNNER_SVC:-$(systemctl list-units --type=service --all --no-legend 2>/dev/null \
      | grep -oE 'actions\.runner\.[^ ]*\.service' | head -1)}"
if [ -z "$SVC" ]; then
  echo "runner-jobs: no actions.runner service found on this host." >&2
  echo "  (is the runner installed as a service? try: runner-healthcheck)" >&2
  exit 1
fi
G='\033[0;32m'; R='\033[0;31m'; Y='\033[0;33m'; C='\033[0;36m'; N='\033[0m'
color() {
  while IFS= read -r l; do
    case "$l" in
      *"result: Succeeded"*) printf "${G}%s${N}\n" "$l" ;;
      *"result: Failed"*)    printf "${R}%s${N}\n" "$l" ;;
      *"result: Canceled"*)  printf "${Y}%s${N}\n" "$l" ;;
      *"Running job:"*)      printf "${C}%s${N}\n" "$l" ;;
      *)                     printf "%s\n" "$l" ;;
    esac
  done
}
FILTER='Running job:|completed with result:|Connected to GitHub|Listening for Jobs'
if [ "${1:-}" = "-n" ]; then
  journalctl -u "$SVC" --no-pager -n "${2:-40}" 2>/dev/null | grep -E "$FILTER" | color
else
  journalctl -u "$SVC" -f -n 20 2>/dev/null | grep --line-buffered -E "$FILTER" | color
fi
