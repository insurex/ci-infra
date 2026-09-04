#!/usr/bin/env bash
# setup-runners.sh - install N self-hosted GitHub Actions runners on one Linux/WSL host.
#
#   curl -fsSL <raw-url>/setup-runners.sh | bash -s -- --token AXXXX
#
# Idempotent: re-running re-registers (--replace) and skips downloads already present.
set -euo pipefail

TOKEN=""; COUNT=3; GROUP="dgx-ci"; LABELS="zrm-ci,docker"
PREFIX=""; RUSER="gha-runner"; RVER="2.337.0"; ORG="https://github.com/insurex"
BASE="/opt/actions-runner-local"

usage() {
  cat <<'USAGE'
setup-runners.sh --token <registration-token> [options]

  --token T     org registration token (Settings > Actions > Runners > New runner)
  --count N     how many runners to install            (default 3)
  --group G     runner group                           (default dgx-ci)
  --labels L    comma-separated labels                 (default zrm-ci,docker)
  --prefix P    runner name prefix, names are P-1..P-N (default: hostname, lowercased)
  --user U      unix user to run as                    (default gha-runner)
  --version V   runner version                         (default 2.337.0)
  --url URL     org/repo url                           (default https://github.com/insurex)

Only add the `docker` label if docker genuinely works for --user; workflows pin
container jobs to runners advertising it.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --token)   shift; TOKEN="${1:-}" ;;
    --count)   shift; COUNT="${1:-}" ;;
    --group)   shift; GROUP="${1:-}" ;;
    --labels)  shift; LABELS="${1:-}" ;;
    --prefix)  shift; PREFIX="${1:-}" ;;
    --user)    shift; RUSER="${1:-}" ;;
    --version) shift; RVER="${1:-}" ;;
    --url)     shift; ORG="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

[ -n "$TOKEN" ] || { echo "ERROR: --token is required" >&2; usage >&2; exit 64; }
[ -z "$PREFIX" ] && PREFIX=$(hostname | tr '[:upper:]' '[:lower:]')

TARBALL="actions-runner-linux-x64-${RVER}.tar.gz"
URL="https://github.com/actions/runner/releases/download/v${RVER}/${TARBALL}"

echo "host    : $(hostname)"
echo "user    : $RUSER"
echo "runners : $COUNT  (${PREFIX}-1 .. ${PREFIX}-${COUNT})"
echo "group   : $GROUP"
echo "labels  : $LABELS"
echo

# runner user
if ! id "$RUSER" >/dev/null 2>&1; then
  echo "creating user $RUSER"
  sudo useradd -m "$RUSER"
fi
if getent group docker >/dev/null 2>&1 && ! id -nG "$RUSER" | tr ' ' '\n' | grep -qx docker; then
  echo "adding $RUSER to docker group"
  sudo usermod -aG docker "$RUSER"
fi

for N in $(seq 1 "$COUNT"); do
  D="${BASE}-${N}"
  NAME="${PREFIX}-${N}"
  echo "=== $NAME  ($D) ==="
  sudo mkdir -p "$D"
  sudo chown "$RUSER:$RUSER" "$D"

  if [ ! -f "$D/config.sh" ]; then
    if [ ! -f "$D/r.tar.gz" ]; then
      sudo -u "$RUSER" -H bash -c "cd '$D' && curl -fSL -o r.tar.gz '$URL'"
    fi
    sudo -u "$RUSER" -H bash -c "cd '$D' && tar xzf r.tar.gz && rm -f r.tar.gz"
  fi

  sudo -u "$RUSER" -H bash -c "cd '$D' && ./config.sh --url '$ORG' --token '$TOKEN' --runnergroup '$GROUP' --labels '$LABELS' --name '$NAME' --work _work --unattended --replace"

  # Per-runner pnpm store: siblings sharing one store corrupt it on a hard kill
  # (ERR_SQLITE_ERROR / database disk image is malformed).
  sudo -u "$RUSER" -H bash -c "grep -q npm_config_store_dir '$D/.env' 2>/dev/null || echo 'npm_config_store_dir=/home/${RUSER}/.pnpm-store-${N}' >> '$D/.env'"

  ( cd "$D" && sudo ./svc.sh install "$RUSER" && sudo ./svc.sh start )
  echo
done

echo "ALL DONE - $COUNT runner(s) installed."
echo "next: install the pre-job reset hook, then verify with runner-healthcheck"
