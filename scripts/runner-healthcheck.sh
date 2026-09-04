#!/usr/bin/env bash
# runner-healthcheck — validate a GitHub Actions self-hosted runner host.
#
# Portable across native Linux, Windows WSL2, and macOS. Diagnoses by default;
# --fix applies the safe remediations. Exit 0 = all pass, 1 = failures, 2 = warnings only.
#
# Every check here corresponds to an outage actually observed on this fleet.
#
# Usage:
#   runner-healthcheck              # report only
#   runner-healthcheck --fix        # report + remediate what is safely fixable
#   runner-healthcheck --dir ~/actions-runner

set -uo pipefail

usage() {
  cat <<'USAGE'
runner-healthcheck - validate a GitHub Actions self-hosted runner host.

  --fix          apply the safe remediations as well as reporting
  --dir PATH     runner root to inspect (default: $HOME/actions-runner)
  -h, --help     this text

Exit: 0 = all pass, 1 = failures, 2 = warnings only.
Env:  RUNNER_DIR, RUNNER_HC_PLATFORM=wsl|linux|macos (force platform, for testing)

Run over the network:
  curl -fsSL <raw-url> | bash
  curl -fsSL <raw-url> | bash -s -- --fix
USAGE
}

RUNNER_DIR="${RUNNER_DIR:-}"
DO_FIX=0
DISCOVERED=""

# A host often runs SEVERAL runners (the WSL boxes run three, in
# /opt/actions-runner-local-{1,2,3}). Find every runner root so we can say so,
# rather than silently checking one and implying the host is fine.
discover_runners() {
  local d
  for d in "$HOME"/actions-runner /opt/actions-runner-local-* /opt/actions-runner* \
           /actions-runner* "$HOME"/actions-runner-*; do
    [ -d "$d" ] || continue
    # a real runner root has the config script or a registration
    if [ -f "$d/config.sh" ] || [ -f "$d/.runner" ]; then
      printf '%s\n' "$d"
    fi
  done | awk '!seen[$0]++'
}
# NOTE: a while/shift loop, not `for a in "$@"` - `shift` inside a for loop does
# not affect the already-captured iteration list, which makes `--dir PATH` fragile.
# Usage text is a heredoc, not `sed "$0"`, because under `curl | bash` the script
# arrives on stdin and $0 is "bash" - there is no file to read it back from.
while [ $# -gt 0 ]; do
  case "$1" in
    --fix)     DO_FIX=1 ;;
    --dir)     shift; [ $# -gt 0 ] || { echo "--dir needs a path" >&2; exit 64; }; RUNNER_DIR="$1" ;;
    --dir=*)   RUNNER_DIR="${1#--dir=}" ;;
    -h|--help) usage; exit 0 ;;
    *)         echo "unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; B=$'\033[1m'; N=$'\033[0m'

if [ -z "$RUNNER_DIR" ]; then
  DISCOVERED=$(discover_runners)
  if [ -n "$DISCOVERED" ]; then
    RUNNER_DIR=$(printf '%s\n' "$DISCOVERED" | head -1)
  else
    RUNNER_DIR="$HOME/actions-runner"
  fi
fi
PASS=0; WARN=0; FAIL=0
ok()   { printf "  ${G}PASS${N}  %s\n" "$*"; PASS=$((PASS+1)); }
warn() { printf "  ${Y}WARN${N}  %s\n" "$*"; WARN=$((WARN+1)); }
bad()  { printf "  ${R}FAIL${N}  %s\n" "$*"; FAIL=$((FAIL+1)); }
info() { printf "        %s\n" "$*"; }
hdr()  { printf "\n${B}== %s ==${N}\n" "$*"; }
FIXES=0
fixed(){ printf "  ${G}FIXED${N} %s\n" "$*"; FIXES=$((FIXES+1)); }

# ---------- platform ----------
OS="unknown"; IS_WSL=0; SVC_MGR="none"
# RUNNER_HC_PLATFORM=wsl|linux|macos forces platform detection (for testing the
# WSL/macOS branches from another host). Leave unset in normal use.
case "${RUNNER_HC_PLATFORM:-$(uname -s)}" in
  wsl)   OS="wsl";   IS_WSL=1; [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ] && SVC_MGR="systemd" ;;
  linux) OS="linux"; [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ] && SVC_MGR="systemd" ;;
  macos) OS="macos"; SVC_MGR="launchd" ;;
esac
[ "$OS" = "unknown" ] && case "$(uname -s)" in
  Linux)
    OS="linux"
    grep -qi microsoft /proc/version 2>/dev/null && { OS="wsl"; IS_WSL=1; }
    [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ] && SVC_MGR="systemd"
    ;;
  Darwin) OS="macos"; SVC_MGR="launchd" ;;
esac

hdr "Host"
info "platform : $OS  ($(uname -s) $(uname -r))"
info "hostname : $(hostname)"
info "user     : $(id -un)  (uid $(id -u))"
info "runner   : $RUNNER_DIR"
info "init     : $SVC_MGR"
NRUN=$(printf '%s\n' "$DISCOVERED" | grep -c . 2>/dev/null || echo 0)
if [ "${NRUN:-0}" -gt 1 ]; then
  printf "\n  ${Y}NOTE${N}  this host has %s runner installations; only the first is checked below.\n" "$NRUN"
  printf '%s\n' "$DISCOVERED" | sed 's/^/          /'
  info "check each: runner-healthcheck --dir <path>"
fi

# ---------- 1. runner configured ----------
hdr "Runner registration"
if [ ! -d "$RUNNER_DIR" ]; then
  bad "runner dir not found: $RUNNER_DIR"
  info "install first: https://github.com/actions/runner/releases  then ./config.sh"
elif [ ! -f "$RUNNER_DIR/.runner" ]; then
  bad ".runner missing — host has the runner binaries but was never configured"
  info "run: cd $RUNNER_DIR && ./config.sh --url <org-or-repo-url> --token <token>"
else
  # .runner has a UTF-8 BOM; strip it before parsing.
  RCFG=$(sed '1s/^\xEF\xBB\xBF//' "$RUNNER_DIR/.runner")
  getj() { printf '%s' "$RCFG" | tr -d '\n' | sed -nE "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"?([^\",}]*)\"?.*/\1/p"; }
  A_NAME=$(getj agentName); A_URL=$(getj gitHubUrl); A_POOL=$(getj poolName); A_ID=$(getj agentId)
  ok "configured as '$A_NAME' (id ${A_ID:-?})"
  info "scope : ${A_URL:-?}"
  info "group : ${A_POOL:-Default}"
  A_PATH="${A_URL#*://}"; A_PATH="${A_PATH#*/}"
  A_SEGS=$(printf '%s' "$A_PATH" | awk -F/ '{print NF}')
  if [ "${A_SEGS:-1}" -ge 2 ]; then
    info "level : REPO-level runner — Settings > Actions > Runners on that repo"
  else
    info "level : ORG-level runner — Settings > Actions > Runners of the ORG, group '${A_POOL:-Default}'"
    info "        NOT visible on any single repo's runner page; needs org-owner access to view"
  fi
  [ -f "$RUNNER_DIR/.credentials" ] && ok "credentials present" || bad ".credentials missing — re-run config.sh"
fi

# ---------- 2. service install ----------
hdr "Service (survives logout/reboot)"
if [ "$IS_WSL" = 1 ] && [ "$SVC_MGR" != "systemd" ]; then
  bad "WSL without systemd — ./svc.sh cannot install a service here"
  info "fix: add to /etc/wsl.conf then 'wsl --shutdown' from Windows:"
  info "     [boot]"
  info "     systemd=true"
  info "without this the runner only lives as long as the WSL terminal window."
elif [ "$SVC_MGR" = "systemd" ]; then
  SVC=$(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep -oE 'actions\.runner\.[^ ]*\.service' | head -1)
  if [ -z "$SVC" ]; then
    bad "no actions.runner systemd service installed — runner is running interactively (or not at all)"
    info "fix: cd $RUNNER_DIR && sudo ./svc.sh install \$(id -un) && sudo ./svc.sh start"
    if [ "$DO_FIX" = 1 ]; then
      if pgrep -f Runner.Worker >/dev/null 2>&1; then
        warn "skipping service install — a job is running right now"
      else
        ( cd "$RUNNER_DIR" && sudo ./svc.sh install "$(id -un)" >/dev/null 2>&1 && sudo ./svc.sh start >/dev/null 2>&1 ) \
          && fixed "installed + started runner service" || bad "svc.sh install failed (needs sudo)"
      fi
    fi
  else
    [ "$(systemctl is-active "$SVC")" = "active" ] && ok "service active: $SVC" || bad "service installed but NOT active: $SVC"
    [ "$(systemctl is-enabled "$SVC" 2>/dev/null)" = "enabled" ] && ok "enabled at boot" || warn "not enabled at boot (sudo systemctl enable $SVC)"
  fi
elif [ "$SVC_MGR" = "launchd" ]; then
  if launchctl list 2>/dev/null | grep -q actions.runner; then ok "launchd service loaded"
  else bad "no launchd runner service — cd $RUNNER_DIR && ./svc.sh install && ./svc.sh start"; fi
else
  warn "no recognised service manager; cannot verify the runner is supervised"
fi

# ---------- 3. docker (capability label must be true) ----------
hdr "Docker"
LABEL_DOCKER=0
# Labels are server-side, but config.sh echoes them into the setup log.
if [ -d "$RUNNER_DIR/_diag" ] && grep -rhoE "Read value: '[^']*docker[^']*'" "$RUNNER_DIR/_diag"/Runner_*.log 2>/dev/null | grep -q docker; then
  LABEL_DOCKER=1
fi
if ! command -v docker >/dev/null 2>&1; then
  if [ "$LABEL_DOCKER" = 1 ]; then bad "runner advertises a 'docker' label but docker is NOT installed"
  else warn "docker not installed (fine only if no workflow needs containers here)"; fi
else
  DOCKER_OK=0
  docker version --format '{{.Server.APIVersion}}' >/dev/null 2>&1 && DOCKER_OK=1
  # The shell running this check may have stale supplementary groups (a login that
  # predates `usermod -aG docker`). What actually matters is whether the RUNNER
  # process can reach the daemon, so read its real groups from /proc.
  RUNNER_HAS_DOCKER=-1
  if [ "$OS" != "macos" ]; then
    DGID=$(getent group docker 2>/dev/null | cut -d: -f3)
    RPID=$(pgrep -f 'Runner.Listener' 2>/dev/null | head -1)
    if [ -n "${DGID:-}" ] && [ -n "${RPID:-}" ] && [ -r "/proc/$RPID/status" ]; then
      if grep '^Groups:' "/proc/$RPID/status" | tr ' \t' '\n\n' | grep -qx "$DGID"; then
        RUNNER_HAS_DOCKER=1
      else
        RUNNER_HAS_DOCKER=0
      fi
    fi
  fi
  if [ "$DOCKER_OK" = 1 ]; then
    ok "docker daemon reachable (API $(docker version --format '{{.Server.APIVersion}}' 2>/dev/null))"
  elif [ "$RUNNER_HAS_DOCKER" = 1 ]; then
    ok "runner process HAS the docker group (pid $RPID) — daemon reachable for jobs"
    info "this shell cannot reach docker only because its login predates the group change; harmless."
  elif [ "$RUNNER_HAS_DOCKER" = 0 ]; then
    bad "the RUNNING runner process lacks the docker group — container jobs will fail"
    info "you were added to the group but the runner was not restarted since."
    info "fix: sudo systemctl restart \"$(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep -oE 'actions\.runner\.[^ ]*\.service' | head -1)\""
  else
    bad "docker CLI present but daemon UNREACHABLE as $(id -un)"
    info "this fails 'Initialize containers' and every containerised scanner step."
    if [ "$OS" = "macos" ]; then
      info "fix: start Docker Desktop and enable it at login."
    elif [ "$IS_WSL" = 1 ]; then
      info "fix (Docker Desktop): enable WSL integration for this distro in Docker Desktop > Settings > Resources > WSL Integration"
      info "fix (native):         sudo usermod -aG docker $(id -un) && restart the runner service"
    else
      info "fix: sudo usermod -aG docker $(id -un)  # then RESTART the runner service"
    fi
    if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
      warn "user IS in the docker group — the runner process predates the change; restart it"
    elif [ "$DO_FIX" = 1 ] && [ "$OS" != "macos" ] && getent group docker >/dev/null 2>&1; then
      sudo usermod -aG docker "$(id -un)" && fixed "added $(id -un) to docker group (restart the runner service to apply)"
    fi
  fi
  [ "$LABEL_DOCKER" = 1 ] && info "runner advertises the 'docker' label — workflows PIN container jobs to this host, so docker must stay working"
fi

# ---------- 4. .path hygiene ----------
hdr "PATH (.path)"
if [ -f "$RUNNER_DIR/.path" ]; then
  TOT=$(tr ':' '\n' < "$RUNNER_DIR/.path" | grep -c .)
  UNIQ=$(tr ':' '\n' < "$RUNNER_DIR/.path" | grep . | sort -u | wc -l | tr -d ' ')
  if [ "$TOT" -ne "$UNIQ" ]; then
    warn ".path has $((TOT-UNIQ)) duplicate entries ($TOT total, $UNIQ unique)"
    if [ "$DO_FIX" = 1 ]; then
      cp -p "$RUNNER_DIR/.path" "$RUNNER_DIR/.path.bak-$(date +%Y%m%d-%H%M%S)"
      awk -v RS=':' -v ORS='' '{gsub(/\n$/,"")} !s[$0]++ {printf "%s%s",(n++?":":""),$0} END{print "\n"}' \
        "$RUNNER_DIR/.path.bak-"* > "$RUNNER_DIR/.path.tmp" 2>/dev/null \
        && mv "$RUNNER_DIR/.path.tmp" "$RUNNER_DIR/.path" && fixed "deduplicated .path (backup kept; restart service to apply)"
    fi
  else
    ok ".path has no duplicates ($TOT entries)"
  fi
  for d in /usr/bin /bin; do
    tr ':' '\n' < "$RUNNER_DIR/.path" | grep -qx "$d" || warn ".path is missing $d"
  done
else
  warn ".path not present (runner will inherit the service environment)"
fi

# ---------- 5. toolchain ----------
hdr "Toolchain"
for t in git bash tar curl; do
  command -v "$t" >/dev/null 2>&1 && ok "$t  $(command -v $t)" || bad "$t MISSING (required by actions/checkout and friends)"
done
for t in node python3; do
  command -v "$t" >/dev/null 2>&1 && ok "$t  $(command -v $t)" || info "$t not on host PATH (fine if workflows use setup-node / setup-python)"
done
if [ "$OS" != "macos" ]; then
  command -v flock >/dev/null 2>&1 && ok "flock present (cross-job store locking)" || warn "flock absent — concurrent pnpm store rebuilds are unguarded"
fi

# ---------- 6. workspace hygiene ----------
hdr "Workspace (_work)"
W="$RUNNER_DIR/_work"
if [ ! -d "$W" ]; then
  info "no _work yet (runner has not taken a job)"
else
  SPARSE=0; ROOTOWNED=0
  while IFS= read -r gd; do
    repo=$(dirname "$gd")
    if [ "$(git -C "$repo" config --get core.sparseCheckout 2>/dev/null)" = "true" ]; then
      bad "STALE SPARSE-CHECKOUT: $repo  (checks out a partial tree; installs fail with no root manifest)"
      SPARSE=$((SPARSE+1))
      if [ "$DO_FIX" = 1 ]; then
        git -C "$repo" sparse-checkout disable 2>/dev/null && fixed "cleared sparse-checkout in $repo"
      fi
    fi
  done < <(find "$W" -maxdepth 3 -name .git -type d 2>/dev/null)
  [ "$SPARSE" = 0 ] && ok "no stale sparse-checkouts"
  ROOTOWNED=$(find "$W" -maxdepth 4 ! -user "$(id -un)" 2>/dev/null | head -1)
  if [ -n "$ROOTOWNED" ]; then
    warn "files in _work not owned by $(id -un) (left by a container job; breaks checkout clean with EACCES)"
    info "example: $ROOTOWNED"
    info "fix: docker run --rm -v \"$W:/w\" alpine:3 sh -c 'chown -R $(id -u):$(id -g) /w'"
  else
    ok "no foreign-owned files in _work"
  fi
fi

# ---------- 7. capacity ----------
hdr "Capacity"
AVAIL=$(df -Pk "$RUNNER_DIR" 2>/dev/null | awk 'NR==2{printf "%.0f", $4/1048576}')
if [ -n "$AVAIL" ]; then
  [ "$AVAIL" -lt 20 ] && bad "only ${AVAIL}G free on the runner volume (<20G) — builds will fail unpredictably" \
    || { [ "$AVAIL" -lt 50 ] && warn "${AVAIL}G free (<50G) — watch it" || ok "${AVAIL}G free"; }
fi
if [ "$OS" = "macos" ]; then
  MEMG=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
else
  MEMG=$(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo 2>/dev/null)
fi
if [ -n "${MEMG:-}" ] && [ "${MEMG:-0}" -gt 0 ]; then
  [ "$MEMG" -lt 8 ] && warn "${MEMG}G RAM — heavy jobs OOM below ~8G; do not label this host for heavy tiers" \
    || ok "${MEMG}G RAM"
fi
if [ -d "$RUNNER_DIR/_diag" ]; then
  DSZ=$(du -sm "$RUNNER_DIR/_diag" 2>/dev/null | cut -f1)
  NOLD=$(find "$RUNNER_DIR/_diag" -name 'Worker_*.log' -mtime +7 2>/dev/null | wc -l | tr -d ' ')
  if [ "${DSZ:-0}" -gt 500 ] || [ "${NOLD:-0}" -gt 200 ]; then
    warn "_diag is ${DSZ}M with $NOLD logs older than 7d"
    if [ "$DO_FIX" = 1 ]; then
      find "$RUNNER_DIR/_diag" -name 'Worker_*.log' -mtime +7 -delete 2>/dev/null && fixed "pruned worker logs older than 7 days"
    else
      info "prune: find $RUNNER_DIR/_diag -name 'Worker_*.log' -mtime +7 -delete"
    fi
  else
    ok "_diag ${DSZ}M ($NOLD logs older than 7d)"
  fi
fi

# ---------- 8. WSL-specific ----------
if [ "$IS_WSL" = 1 ]; then
  hdr "WSL specifics"
  case "$RUNNER_DIR" in
    /mnt/*) bad "runner lives on $RUNNER_DIR (a Windows drive via /mnt) — 9p I/O is drastically slower and breaks file modes"
            info "move it onto the Linux filesystem, e.g. ~/actions-runner" ;;
    *)      ok "runner is on the Linux filesystem (not /mnt)" ;;
  esac
  info "clock: $(date -u '+%Y-%m-%d %H:%M:%SZ') — WSL clocks drift after host sleep and drift breaks TLS/auth."
  info "if you see auth or TLS errors after a resume: sudo hwclock -s   (or 'wsl --shutdown' from Windows)"
  if [ -f /etc/wsl.conf ]; then ok "/etc/wsl.conf present"; else warn "no /etc/wsl.conf — systemd and automount options are unset"; fi
fi

# ---------- summary ----------
hdr "Summary"
printf "  ${G}%d pass${N}   ${Y}%d warn${N}   ${R}%d fail${N}" "$PASS" "$WARN" "$FAIL"
[ "$FIXES" -gt 0 ] && printf "   ${G}%d fixed${N}" "$FIXES"
printf "\n"
if [ "$FIXES" -gt 0 ]; then
  # A finding is counted when detected, which is BEFORE --fix remediates it on the
  # same pass. So counts above can name problems that no longer exist. We do not
  # claim success we have not observed - re-run to get a clean verdict.
  printf "\n  %d remediation(s) applied. The counts above were taken BEFORE fixing,\n" "$FIXES"
  printf "  so re-run without --fix to confirm the real state:\n"
  printf "    %s\n" "${0##*/}"
fi
if [ "$FAIL" -gt 0 ]; then
  [ "$DO_FIX" = 1 ] || printf "\n  re-run with ${B}--fix${N} to apply the safe remediations.\n"
  exit 1
fi
[ "$WARN" -gt 0 ] && exit 2
exit 0
