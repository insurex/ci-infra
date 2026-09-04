#!/usr/bin/env bash
# install-hook.sh - install the pre-job workspace reset hook for every runner
# service on this host.
#
#   curl -fsSL <raw-url>/install-hook.sh | bash
#
# Container jobs run as root and leave root-owned files in the reused _work tree.
# chmod(2) returns EPERM for a non-owner whatever the mode bits say, so the next
# job's checkout fails with EACCES and pnpm install dies on linkBins. This hook
# reclaims the workspace before each job via a throwaway root container.
set -euo pipefail
HOOK=/opt/gha-hooks/job-started-reset.sh

sudo mkdir -p /opt/gha-hooks
sudo tee "$HOOK" >/dev/null <<'HOOKBODY'
#!/usr/bin/env bash
set -uo pipefail
W="${RUNNER_WORKSPACE:-}"
[ -n "$W" ] || exit 0
docker run --rm -v "$W:/w" alpine:3 sh -c "chown -R $(id -u):$(id -g) /w; chmod -R a+rwX /w" || true
exit 0
HOOKBODY
sudo chmod +x "$HOOK"
echo "installed $HOOK"

SVCS=$(systemctl list-units --type=service --all --no-legend 2>/dev/null \
       | grep -oE 'actions\.runner\.[^ ]*\.service' | sort -u)
[ -n "$SVCS" ] || { echo "no actions.runner services found - install runners first" >&2; exit 1; }

for S in $SVCS; do
  D="/etc/systemd/system/${S}.d"
  sudo mkdir -p "$D"
  printf '[Service]\nEnvironment="ACTIONS_RUNNER_HOOK_JOB_STARTED=%s"\n' "$HOOK" | sudo tee "$D/hooks.conf" >/dev/null
  echo "wired $S"
done
sudo systemctl daemon-reload
for S in $SVCS; do sudo systemctl restart "$S"; done
echo "ALL DONE - hook active on $(printf '%s\n' $SVCS | wc -l) service(s)"
