# ci-infra

Tooling for the self-hosted GitHub Actions runner fleet (`dgx-ci`, `zrm-ci`, WSL, Mac).

## Provisioning a new runner host

After `config.sh` has registered the runner, validate and remediate the host:

```bash
curl -fsSL https://raw.githubusercontent.com/insurex/ci-infra/main/scripts/runner-healthcheck.sh | bash -s -- --fix
```

Report only (no changes):

```bash
curl -fsSL https://raw.githubusercontent.com/insurex/ci-infra/main/scripts/runner-healthcheck.sh | bash
```

Exit codes: `0` all pass, `1` failures, `2` warnings only — usable as a provisioning gate.

Install all helpers permanently:

```bash
curl -fsSL https://raw.githubusercontent.com/insurex/ci-infra/main/scripts/install.sh | bash
```

> If this repo is **private**, raw URLs need auth:
> ```bash
> curl -fsSL -H "Authorization: token $GH_TOKEN" \
>   https://raw.githubusercontent.com/insurex/ci-infra/main/scripts/runner-healthcheck.sh | bash
> ```
> Making the repo public avoids the token entirely. Nothing here contains secrets.

## Scripts

| Script | Purpose |
|---|---|
| `runner-healthcheck.sh` | Validate a runner host; `--fix` remediates. Linux / WSL2 / macOS. |
| `runner-jobs.sh` | Live job-level view: what's running, pass/fail. |
| `runner-steps.sh` | Live step-level view; auto-switches per job. |
| `runner-tail.sh` | Raw newest worker log; auto-switches per job. |
| `install.sh` | Installs the above into `~/.local/bin`. |

## What the health check covers

Each check maps to a failure observed in production, not a generic checklist.

- **Registration** — configured at all; reports whether it is an **org-** or **repo-level**
  runner and which settings page it appears on. An org runner in a non-default group is
  invisible on any repo's runner page, which reads as "not registered".
- **Service** — installed and enabled, not just running in somebody's terminal.
- **Docker** — daemon reachable *by the runner process* (read from `/proc/<pid>/status`,
  not the invoking shell, which may have stale groups). Flags the case where the runner
  advertises a `docker` **label** it cannot honour: workflows *pin* container jobs to
  such hosts, so a broken daemon actively attracts the jobs it will fail.
- **`.path`** — duplicates, missing `/usr/bin`.
- **Toolchain** — `git`, `bash`, `tar`, `curl`; warns on absent `flock`.
- **Workspace** — stale `core.sparseCheckout` in a reused `_work` checkout (checkout does
  not clear it, so every later job on that repo gets a partial tree and installs fail);
  container-left root-owned files that break checkout with `EACCES`.
- **Capacity** — disk, RAM (warns under 8G against heavy-tier labels), `_diag` growth.

### WSL specifics

- **systemd not enabled** — `svc.sh` cannot install a service, so the runner dies with the
  terminal. Prints the `/etc/wsl.conf` fix.
- **Runner under `/mnt/c`** — 9p I/O is far slower and breaks file modes.
- **Clock drift** after host sleep, which breaks TLS and auth.
- Docker Desktop WSL integration vs. native `usermod`.

## Gotchas this encodes

Two things about runner logs that are easy to lose an afternoon to:

1. The runner writes `Step result:` **empty** for steps that *pass* — only failures carry a
   value. Grepping for `Step result: Succeeded` finds nothing.
2. Every job gets a **new** `_diag/Worker_*.log` file, so a plain `tail -f` goes silent as
   soon as the next job starts. `runner-steps` / `runner-tail` auto-switch.

## Testing

`RUNNER_HC_PLATFORM=wsl|linux|macos` forces platform detection so the WSL and macOS
branches can be exercised from any host. That simulates the logic, not the platform —
give a genuinely new platform one real run before trusting it.
