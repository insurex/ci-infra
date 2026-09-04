#!/usr/bin/env bash
# Install the runner helper scripts into ~/.local/bin.
#   curl -fsSL https://raw.githubusercontent.com/insurex/ci-infra/main/scripts/install.sh | bash
set -euo pipefail
RAW="${RAW_BASE:-https://raw.githubusercontent.com/insurex/ci-infra/main/scripts}"
DEST="${DEST:-$HOME/.local/bin}"
mkdir -p "$DEST"
for s in runner-healthcheck runner-jobs runner-steps runner-tail; do
  curl -fsSL "$RAW/$s.sh" -o "$DEST/$s"
  chmod +x "$DEST/$s"
  echo "installed $DEST/$s"
done
case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo; echo "NOTE: $DEST is not on your PATH. Add to your shell rc:"; echo "  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
echo; echo "run 'runner-healthcheck' to validate this host."
